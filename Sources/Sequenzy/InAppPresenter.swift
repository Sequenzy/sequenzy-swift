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

        func enqueue(_ messages: [InAppMessage]) {
            for message in messages where message.kind == .message {
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

            let controller = InAppMessageViewController(message: message) { [weak self] outcome in
                self?.finish(message, outcome: outcome)
            }
            let window = PassthroughWindow(windowScene: scene)
            window.windowLevel = .alert
            window.backgroundColor = .clear
            window.rootViewController = controller
            window.passesTouchesOutsideContent = message.resolvedFormat == .banner
            window.isHidden = false
            self.window = window
            Sequenzy.reportFromPresenter(.displayed, messageId: message.id)
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
