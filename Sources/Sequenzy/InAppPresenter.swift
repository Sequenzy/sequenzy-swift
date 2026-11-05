#if canImport(UIKit)
    import UIKit

    extension UIColor {
        convenience init(sequenzyHex hex: String, fallback: UIColor) {
            guard let rgb = parseHexColor(hex) else {
                self.init(cgColor: fallback.cgColor)
                return
            }
            self.init(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }

    extension InAppStyle {
        func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            for family in fontFamilies {
                if let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
                    .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
                    as UIFontDescriptor?,
                    UIFont.fontNames(forFamilyName: family).isEmpty == false
                {
                    return UIFont(descriptor: descriptor, size: size)
                }
            }
            return .systemFont(ofSize: size, weight: weight)
        }
    }

    /// Shows in-app messages one at a time in an overlay window above the app.
    @MainActor
    final class InAppPresenter {
        private var queue: [InAppMessage] = []
        private var shownIds: Set<String> = []
        private var window: UIWindow?
        private var current: InAppMessage?
        /// The contact the queued and shown messages were fetched for.
        private var owner: String?

        /// After identify: another contact's messages go before they can act
        /// for the new one.
        func signedIn(as email: String?) {
            guard email != owner else { return }
            dismissAll()
            owner = email
        }

        func enqueue(_ messages: [InAppMessage], owner: String?) {
            signedIn(as: owner)
            // An html item without its document came from a caller that did
            // not ask for html; it can't be drawn natively.
            for message in messages
            where message.kind == .message && (message.resolvedFormat != .html || message.html != nil) {
                guard !shownIds.contains(message.id), !queue.contains(where: { $0.id == message.id }),
                    current?.id != message.id
                else { continue }
                queue.append(message)
            }
            showNextIfIdle()
        }

        func dismissAll() {
            queue.removeAll()
            shownIds.removeAll()
            owner = nil
            hide()
        }

        private func showNextIfIdle() {
            guard current == nil else { return }
            while !queue.isEmpty {
                let message = queue.removeFirst()
                if Sequenzy.inAppDelegate?.sequenzyShouldShow(message) == false { continue }
                show(message)
                return
            }
        }

        private func show(_ message: InAppMessage) {
            guard
                let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
            else {
                // Not in the foreground; offer it again next time.
                queue.insert(message, at: 0)
                return
            }
            current = message
            shownIds.insert(message.id)

            let window = PassthroughWindow(windowScene: scene)
            window.windowLevel = .alert
            window.backgroundColor = .clear
            if message.resolvedFormat == .html {
                // Reported displayed once the document has loaded; one that
                // fails to load stays in the feed for a later launch. Until
                // then the window takes no touches, so the app underneath
                // stays usable while nothing is visible.
                window.isUserInteractionEnabled = false
                window.rootViewController = InAppHtmlViewController(
                    message: message,
                    onLoaded: { [weak window] in
                        window?.isUserInteractionEnabled = true
                        Sequenzy.reportFromPresenter(.displayed, messageId: message.id)
                    },
                    onFinish: { [weak self] outcome in self?.finishHtml(message, outcome: outcome) })
                window.isHidden = false
                self.window = window
                return
            }
            let controller = InAppMessageViewController(message: message) { [weak self] outcome in
                self?.finish(message, outcome: outcome)
            }
            window.rootViewController = controller
            window.passesTouchesOutsideContent = message.resolvedFormat == .banner
            window.isHidden = false
            self.window = window
            Sequenzy.reportFromPresenter(.displayed, messageId: message.id)
        }

        private func finishHtml(_ message: InAppMessage, outcome: InAppHtmlViewController.Outcome) {
            guard current?.id == message.id else { return }
            switch outcome {
            case .dismissed:
                Sequenzy.reportFromPresenter(.dismissed, messageId: message.id)
            case .opened(let url):
                // The click was reported with its button id when the
                // document asked to open the link.
                Sequenzy.open(url, from: message)
            case .failed:
                break
            }
            hide()
            showNextIfIdle()
        }

        private func finish(_ message: InAppMessage, outcome: InAppMessageViewController.Outcome) {
            // A late exit from a message dismissAll() already replaced.
            guard current?.id == message.id else { return }
            switch outcome {
            case .dismissed:
                Sequenzy.reportFromPresenter(.dismissed, messageId: message.id)
            case .tapped(let button):
                Sequenzy.reportFromPresenter(.clicked, messageId: message.id)
                if let raw = button?.url ?? message.buttons.first(where: { $0.action == .openUrl })?.url,
                    let url = URL(string: raw)
                {
                    Sequenzy.open(url, from: message)
                }
            }
            hide()
            showNextIfIdle()
        }

        private func hide() {
            window?.isHidden = true
            window = nil
            current = nil
        }
    }

    /// Lets taps outside a banner reach the app underneath.
    final class PassthroughWindow: UIWindow {
        var passesTouchesOutsideContent = false

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            let view = super.hitTest(point, with: event)
            if passesTouchesOutsideContent, view === rootViewController?.view { return nil }
            return view
        }
    }
#endif
