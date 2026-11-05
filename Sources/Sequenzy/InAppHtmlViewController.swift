#if canImport(UIKit) && canImport(WebKit)
    import UIKit
    import WebKit

    /// Shows a custom HTML in-app message full screen in a transparent
    /// WKWebView. The document comes from the server with the Sequenzy JS
    /// bridge already injected; this controller is the other end of it.
    ///
    /// Isolation:
    /// - A non-persistent website data store: the document shares no cookies,
    ///   local storage or cache with the app's other web views, and nothing
    ///   it stores outlives the message.
    /// - It loads at `sequenzyInAppHtmlBaseURL`, never the app's own origin,
    ///   with no file access.
    /// - The bridge handler is installed for the main frame only; frames the
    ///   document embeds cannot call it.
    /// - Main-frame navigations away from the document are cancelled and go
    ///   through the app's URL handler instead; popups never open a window.
    final class InAppHtmlViewController: UIViewController {
        enum Outcome {
            /// Closed by the document, the close button or the system.
            case dismissed
            /// The document asked to open a link (already reported as a click).
            case opened(URL)
            /// Never finished loading; not reported, so it shows again later.
            case failed
        }

        private static let loadTimeout: TimeInterval = 10
        private static let handlerName = "sequenzy"

        private let message: InAppMessage
        private let onLoaded: () -> Void
        private let onFinish: (Outcome) -> Void
        private var webView: WKWebView?
        private var finished = false
        private var loaded = false
        private var bridgeCalls = 0
        private var timeout: Timer?

        init(message: InAppMessage, onLoaded: @escaping () -> Void, onFinish: @escaping (Outcome) -> Void) {
            self.message = message
            self.onLoaded = onLoaded
            self.onFinish = onFinish
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.allowsInlineMediaPlayback = true
            configuration.userContentController.add(
                WeakScriptMessageHandler(self), contentWorld: .page, name: Self.handlerName)

            let webView = WKWebView(frame: view.bounds, configuration: configuration)
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.accessibilityLabel = message.title.isEmpty ? "Message" : message.title
            // Hidden until it has loaded, so a slow document never shows a
            // blank overlay that blocks the app.
            webView.alpha = 0
            view.addSubview(webView)
            self.webView = webView

            if message.showCloseButton {
                let close = UIButton(type: .close)
                close.translatesAutoresizingMaskIntoConstraints = false
                close.accessibilityLabel = "Close"
                close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
                view.addSubview(close)
                NSLayoutConstraint.activate([
                    close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                    close.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                    close.widthAnchor.constraint(equalToConstant: 36),
                    close.heightAnchor.constraint(equalToConstant: 36),
                ])
                close.alpha = 0
            }

            timeout = Timer.scheduledTimer(withTimeInterval: Self.loadTimeout, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.loaded else { return }
                    self.finish(.failed)
                }
            }
            webView.loadHTMLString(message.html ?? "", baseURL: sequenzyInAppHtmlBaseURL)
        }

        override func accessibilityPerformEscape() -> Bool {
            finish(.dismissed)
            return true
        }

        @objc private func closeTapped() {
            finish(.dismissed)
        }

        fileprivate func didLoad() {
            guard !loaded, !finished else { return }
            loaded = true
            timeout?.invalidate()
            UIView.animate(withDuration: 0.2) {
                self.view.subviews.forEach { $0.alpha = 1 }
            }
            onLoaded()
        }

        fileprivate func finish(_ outcome: Outcome) {
            guard !finished else { return }
            finished = true
            timeout?.invalidate()
            webView?.configuration.userContentController.removeScriptMessageHandler(
                forName: Self.handlerName, contentWorld: .page)
            webView?.navigationDelegate = nil
            webView?.uiDelegate = nil
            webView?.stopLoading()
            onFinish(outcome)
        }

        fileprivate func handleBridge(_ body: Any) {
            guard !finished else { return }
            guard JSONSerialization.isValidJSONObject(body),
                let data = try? JSONSerialization.data(withJSONObject: body),
                let call = InAppHtmlBridgeMessage.parse(json: data)
            else { return }
            bridgeCalls += 1
            guard bridgeCalls <= InAppHtmlBridgeMessage.maxCallsPerDisplay else { return }
            switch call {
            case .close:
                finish(.dismissed)
            case .openUrl(let raw, _, let buttonId):
                open(raw, buttonId: buttonId)
            case .logClick(let buttonId):
                Sequenzy.reportFromPresenter(.clicked, messageId: message.id, buttonId: buttonId)
            case .track(let name, let properties):
                Sequenzy.track(name, properties: properties)
            case .setAttributes(let attributes):
                Sequenzy.setProfile(ProfileUpdate(attributes: attributes))
            case .setName(let firstName, let lastName):
                Sequenzy.setProfile(
                    ProfileUpdate(firstName: firstName.map { .set($0) }, lastName: lastName.map { .set($0) }))
            }
        }

        /// Reports the click and leaves; the presenter opens the link.
        fileprivate func open(_ raw: String, buttonId: String?) {
            guard InAppHtmlBridgeMessage.isAllowedUrl(raw), let url = URL(string: raw) else {
                print("[Sequenzy] In-app message link blocked: \(raw)")
                return
            }
            Sequenzy.reportFromPresenter(.clicked, messageId: message.id, buttonId: buttonId)
            finish(.opened(url))
        }
    }

    extension InAppHtmlViewController: WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            let url = navigationAction.request.url
            // The document itself (loadHTMLString), its own #fragment
            // navigations and anything inside embedded frames load normally.
            let withoutFragment = url?.absoluteString.split(separator: "#", maxSplits: 1).first.map(String.init)
            if !isMainFrame || withoutFragment == sequenzyInAppHtmlBaseURL.absoluteString
                || url?.absoluteString.hasPrefix("about:") == true
            {
                return .allow
            }
            if let url { open(url.absoluteString, buttonId: nil) }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoad()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if !loaded { finish(.failed) }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            if !loaded { finish(.failed) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(loaded ? .dismissed : .failed)
        }

        // window.open and target="_blank" links: open through the app,
        // never as a second web view.
        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { open(url.absoluteString, buttonId: nil) }
            return nil
        }
    }

    /// WKUserContentController retains its handlers; this keeps it from
    /// retaining the controller.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var target: InAppHtmlViewController?

        init(_ target: InAppHtmlViewController) {
            self.target = target
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            // Only the message's own document may call the bridge.
            guard message.frameInfo.isMainFrame else { return }
            let body = message.body
            MainActor.assumeIsolated {
                target?.handleBridge(body)
            }
        }
    }
#endif
