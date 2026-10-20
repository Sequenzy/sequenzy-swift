#if canImport(UIKit)
    import UIKit

    // Draws one message to mobile-sdks/DESIGN.md with UIKit; every size below
    // matches the other renderers.

    private struct Palette {
        let text: UIColor
        let muted: UIColor
        let eyebrow: UIColor
        let primaryBackground: UIColor
        let primaryText: UIColor
        let secondaryLink: UIColor
        let secondaryDismiss: UIColor
        let closeFill: UIColor
        let closeStroke: UIColor

        static func surface(_ style: InAppStyle) -> Palette {
            let text = UIColor(sequenzyHex: style.textColor, fallback: .label)
            let muted = UIColor(sequenzyHex: style.mutedTextColor, fallback: .secondaryLabel)
            let background = UIColor(sequenzyHex: style.backgroundColor, fallback: .systemBackground)
            let button = UIColor(sequenzyHex: style.buttonColor, fallback: .label)
            return Palette(
                text: text,
                muted: muted,
                eyebrow: contrast(button, background) >= 3 ? button : muted,
                primaryBackground: button,
                primaryText: UIColor(sequenzyHex: style.buttonTextColor, fallback: .white),
                secondaryLink: text,
                secondaryDismiss: muted,
                closeFill: text.withAlphaComponent(0.06),
                closeStroke: text.withAlphaComponent(0.6))
        }

        /// Over a background image's dark gradient.
        static func image(_ style: InAppStyle) -> Palette {
            let button = UIColor(sequenzyHex: style.buttonColor, fallback: .white)
            let keepsAccent = contrast(button, UIColor(white: 0.12, alpha: 1)) >= 2
            return Palette(
                text: .white,
                muted: UIColor(white: 1, alpha: 0.82),
                eyebrow: UIColor(white: 1, alpha: 0.9),
                primaryBackground: keepsAccent ? button : .white,
                primaryText: keepsAccent
                    ? UIColor(sequenzyHex: style.buttonTextColor, fallback: .white) : UIColor(white: 0.07, alpha: 1),
                secondaryLink: .white,
                secondaryDismiss: UIColor(white: 1, alpha: 0.82),
                closeFill: UIColor(white: 0, alpha: 0.32),
                closeStroke: .white)
        }
    }

    private func luminance(_ color: UIColor) -> CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio, 1 to 21.
    private func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The primary button (first link, or first button) and the other one.
    private func splitButtons(_ buttons: [InAppButton]) -> (primary: InAppButton?, secondary: InAppButton?) {
        let primaryIndex = buttons.firstIndex(where: { $0.action == .openUrl }) ?? 0
        let primary = buttons.indices.contains(primaryIndex) ? buttons[primaryIndex] : nil
        let secondary = buttons.enumerated().first(where: { $0.offset != primaryIndex })?.element
        return (primary, secondary)
    }

    /// A 12 × 12 X from two round-capped strokes, on a circle.
    private final class CloseButton: UIControl {
        private let circle = CAShapeLayer()
        private let cross = CAShapeLayer()
        private let diameter: CGFloat

        init(palette: Palette, diameter: CGFloat) {
            self.diameter = diameter
            super.init(frame: .zero)
            circle.fillColor = palette.closeFill.cgColor
            cross.strokeColor = palette.closeStroke.cgColor
            cross.lineWidth = 2
            cross.lineCap = .round
            layer.addSublayer(circle)
            layer.addSublayer(cross)
            isAccessibilityElement = true
            accessibilityLabel = "Close"
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.7 : 1 }
        }

        // Enlarges the touch target without moving the circle.
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -8, dy: -8).contains(point)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            circle.path = UIBezierPath(
                ovalIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            ).cgPath
            let path = UIBezierPath()
            path.move(to: CGPoint(x: center.x - 6, y: center.y - 6))
            path.addLine(to: CGPoint(x: center.x + 6, y: center.y + 6))
            path.move(to: CGPoint(x: center.x + 6, y: center.y - 6))
            path.addLine(to: CGPoint(x: center.x - 6, y: center.y + 6))
            cross.path = path.cgPath
        }
    }

    /// Dims while pressed.
    private final class PressableButton: UIButton {
        var pressedAlpha: CGFloat = 0.85
        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? pressedAlpha : 1 }
        }
    }

    /// A gradient layer that follows its view's size.
    private final class ScrimView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let gradient = layer as! CAGradientLayer
            gradient.colors = [
                UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.55).cgColor,
                UIColor(white: 0, alpha: 0.82).cgColor,
            ]
            gradient.locations = [0, 0.55, 1]
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    final class InAppMessageViewController: UIViewController {
        enum Outcome {
            case dismissed
            /// A link button, or the banner itself (nil button).
            case tapped(InAppButton?)
        }

        private let message: InAppMessage
        private let onFinish: (Outcome) -> Void
        private var finished = false
        private var style: InAppStyle { message.style }
        private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

        private let backdrop = UIView()
        private let panel = UIView()
        private var isSheet = false
        private var enter: (() -> Void)?
        private var leave: ((@escaping () -> Void) -> Void)?
        private var imageFailed = false
        private var appeared = false
        /// Re-applies padding that depends on the safe area once it is known.
        private var applySafeArea: (() -> Void)?

        init(message: InAppMessage, onFinish: @escaping (Outcome) -> Void) {
            self.message = message
            self.onFinish = onFinish
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            switch message.resolvedFormat {
            case .modal: buildModal()
            case .fullscreen: buildFullscreen()
            case .banner: buildBanner()
            }
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            applySafeArea?()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
            enter?()
            enter = nil
            UIAccessibility.post(notification: .screenChanged, argument: panel)
        }

        override func accessibilityPerformEscape() -> Bool {
            close(.dismissed)
            return true
        }

        /// Runs the exit animation once, then reports the outcome.
        private func close(_ outcome: Outcome) {
            guard !finished else { return }
            finished = true
            if let leave {
                leave { [onFinish] in onFinish(outcome) }
            } else {
                onFinish(outcome)
            }
        }

        private func handle(_ button: InAppButton) {
            close(button.action == .dismiss ? .dismissed : .tapped(button))
        }

        // MARK: Modal

        private func buildModal() {
            let wide = view.bounds.width >= 600 || (view.window?.bounds.width ?? UIScreen.main.bounds.width) >= 600
            let dialog = message.position == .center || wide
            isSheet = !dialog
            let placement = imagePlacement
            let onImage = placement == .background
            let palette = onImage ? Palette.image(style) : Palette.surface(style)

            backdrop.backgroundColor = UIColor(white: 0, alpha: onImage ? 0.5 : 0.4)
            backdrop.alpha = 0
            backdrop.isAccessibilityElement = false
            backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissTapped)))
            pin(backdrop, to: view)

            panel.backgroundColor = UIColor(sequenzyHex: style.backgroundColor, fallback: .systemBackground)
            panel.layer.cornerRadius = CGFloat(style.cornerRadius)
            panel.layer.cornerCurve = .continuous
            panel.clipsToBounds = true
            panel.accessibilityViewIsModal = true
            if isSheet { panel.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner] }
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)

            let stack = UIStackView()
            stack.axis = .vertical
            stack.translatesAutoresizingMaskIntoConstraints = false

            if onImage, let url = message.imageUrl {
                let image = imageView(url: url) { [weak self] in self?.rebuildWithoutImage() }
                pin(image, to: panel)
                pin(ScrimView(), to: panel)
            } else if placement == .top, let url = message.imageUrl {
                let image = imageView(url: url) { [weak self] in self?.rebuildWithoutImage() }
                stack.addArrangedSubview(image)
                image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 9.0 / 16.0).withPriority(.defaultHigh)
                    .isActive = true
                image.heightAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            }

            let content = contentStack(palette: palette, centered: dialog, fullscreen: false)
            content.isLayoutMarginsRelativeArrangement = true
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: placement == .top ? 20 : 28, leading: 24, bottom: 24, trailing: 24)
            stack.addArrangedSubview(content)
            // Long copy at large text sizes scrolls inside the panel; the
            // close button stays put above it.
            let scroll = UIScrollView()
            scroll.showsVerticalScrollIndicator = false
            scroll.alwaysBounceVertical = false
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(stack)
            panel.addSubview(scroll)

            let fitsContent = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
            fitsContent.priority = UILayoutPriority(700)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                fitsContent,
                scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
                scroll.topAnchor.constraint(greaterThanOrEqualTo: panel.topAnchor),
            ])
            if !onImage { scroll.topAnchor.constraint(equalTo: panel.topAnchor).isActive = true }

            if isSheet {
                // Bottom padding: 16 plus the home indicator, at least 24.
                applySafeArea = { [weak self, weak content] in
                    guard let self, let content else { return }
                    content.directionalLayoutMargins.bottom = max(16 + self.view.safeAreaInsets.bottom, 24)
                }
                applySafeArea?()
                NSLayoutConstraint.activate([
                    panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
                ])
                if onImage {
                    // 460 unless the copy needs more; the picture never sizes the sheet.
                    panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).withPriority(.defaultHigh)
                        .isActive = true
                    panel.heightAnchor.constraint(equalToConstant: 460).withPriority(UILayoutPriority(500))
                        .isActive = true
                }
                addGrabber(onImage: placement != nil)
                panel.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(sheetPanned)))
            } else {
                let width = panel.widthAnchor.constraint(equalToConstant: 360)
                width.priority = .defaultHigh
                NSLayoutConstraint.activate([
                    width,
                    panel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
                    panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    panel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
                    panel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
                ])
                if onImage {
                    // At least 5:4, taller only when the copy needs it.
                    panel.heightAnchor.constraint(greaterThanOrEqualTo: panel.widthAnchor, multiplier: 1.25)
                        .withPriority(.defaultHigh).isActive = true
                    panel.heightAnchor.constraint(equalTo: panel.widthAnchor, multiplier: 1.25)
                        .withPriority(UILayoutPriority(500)).isActive = true
                }
                panel.layer.masksToBounds = true
            }

            let close = CloseButton(
                palette: placement != nil ? Palette.image(style) : Palette.surface(style), diameter: 30)
            close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
                close.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            ])

            enter = { [weak self] in
                guard let self else { return }
                self.view.layoutIfNeeded()
                UIView.animate(withDuration: self.reduceMotion ? 0.18 : 0.22) { self.backdrop.alpha = 1 }
                if self.reduceMotion {
                    self.panel.alpha = 0
                    UIView.animate(withDuration: 0.18) { self.panel.alpha = 1 }
                } else if self.isSheet {
                    self.panel.transform = CGAffineTransform(translationX: 0, y: self.panel.bounds.height)
                    UIView.animate(
                        withDuration: 0.6, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0
                    ) { self.panel.transform = .identity }
                } else {
                    self.panel.alpha = 0
                    self.panel.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
                    UIView.animate(
                        withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0
                    ) {
                        self.panel.alpha = 1
                        self.panel.transform = .identity
                    }
                }
            }
            leave = { [weak self] done in
                guard let self else { return done() }
                let sheet = self.isSheet && !self.reduceMotion
                UIView.animate(
                    withDuration: self.reduceMotion ? 0.18 : (sheet ? 0.22 : 0.16), delay: 0, options: .curveEaseIn,
                    animations: {
                        self.backdrop.alpha = 0
                        if sheet {
                            self.panel.transform = CGAffineTransform(translationX: 0, y: self.panel.bounds.height + 40)
                        } else {
                            self.panel.alpha = 0
                            if !self.reduceMotion { self.panel.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
                        }
                    }, completion: { _ in done() })
            }
        }

        /// An image that fails to load leaves the plain surface: surface tones
        /// and the padding of a message without an image.
        private func rebuildWithoutImage() {
            guard !imageFailed, !finished else { return }
            imageFailed = true
            panel.subviews.forEach { $0.removeFromSuperview() }
            panel.gestureRecognizers?.forEach(panel.removeGestureRecognizer)
            backdrop.gestureRecognizers?.forEach(backdrop.removeGestureRecognizer)
            view.subviews.forEach { $0.removeFromSuperview() }
            panel.constraints.forEach { panel.removeConstraint($0) }
            panel.transform = .identity
            view.transform = .identity
            switch message.resolvedFormat {
            case .modal: buildModal()
            case .fullscreen: buildFullscreen()
            case .banner: return
            }
            // Already on screen: show the rebuilt layout without entering again.
            if appeared {
                enter = nil
                backdrop.alpha = 1
                view.alpha = 1
            }
        }

        private func addGrabber(onImage: Bool) {
            let grabber = UIView()
            grabber.backgroundColor =
                onImage
                ? UIColor(white: 1, alpha: 0.7)
                : UIColor(sequenzyHex: style.textColor, fallback: .label).withAlphaComponent(0.2)
            grabber.layer.cornerRadius = 2.5
            grabber.isAccessibilityElement = false
            grabber.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(grabber)
            NSLayoutConstraint.activate([
                grabber.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
                grabber.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
                grabber.widthAnchor.constraint(equalToConstant: 36),
                grabber.heightAnchor.constraint(equalToConstant: 5),
            ])
        }

        @objc private func sheetPanned(_ gesture: UIPanGestureRecognizer) {
            let dy = gesture.translation(in: view).y
            switch gesture.state {
            case .changed:
                // Upward drags resist at a third of the distance.
                panel.transform = CGAffineTransform(translationX: 0, y: dy > 0 ? dy : dy / 3)
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: view).y
                if dy > panel.bounds.height * 0.3 || velocity > 1000 {
                    close(.dismissed)
                } else {
                    UIView.animate(
                        withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0
                    ) { self.panel.transform = .identity }
                }
            default:
                break
            }
        }

        @objc private func dismissTapped() { close(.dismissed) }

        // MARK: Full screen

        private func buildFullscreen() {
            let placement = imagePlacement
            let onImage = placement == .background
            let palette = onImage ? Palette.image(style) : Palette.surface(style)
            view.backgroundColor = UIColor(sequenzyHex: style.backgroundColor, fallback: .systemBackground)
            view.accessibilityViewIsModal = true

            if onImage, let url = message.imageUrl {
                let image = imageView(url: url) { [weak self] in self?.rebuildWithoutImage() }
                pin(image, to: view)
                pin(ScrimView(), to: view)
            }

            let scroll = UIScrollView()
            scroll.alwaysBounceVertical = false
            scroll.contentInsetAdjustmentBehavior = .never
            pin(scroll, to: view)

            let column = UIStackView()
            column.axis = .vertical
            column.translatesAutoresizingMaskIntoConstraints = false
            scroll.addSubview(column)

            if placement == .top, let url = message.imageUrl {
                let image = imageView(url: url) { [weak self] in self?.rebuildWithoutImage() }
                column.addArrangedSubview(image)
                image.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.48).isActive = true
            }

            let body = UIStackView()
            body.axis = .vertical
            body.isLayoutMarginsRelativeArrangement = true
            applySafeArea = { [weak self, weak body] in
                guard let self, let body else { return }
                let insets = self.view.safeAreaInsets
                body.directionalLayoutMargins = NSDirectionalEdgeInsets(
                    top: placement == .top ? 28 : insets.top + 56, leading: 24, bottom: 16 + insets.bottom, trailing: 24)
            }
            applySafeArea?()
            let topSpacer = UIView()
            let bottomSpacer = UIView()
            if placement != .top { body.addArrangedSubview(topSpacer) }
            body.addArrangedSubview(textBlock(palette: palette, centered: false, fullscreen: true))
            if !onImage { body.addArrangedSubview(bottomSpacer) }
            if let buttons = buttonStack(palette: palette) { body.addArrangedSubview(buttons) }
            column.addArrangedSubview(body)

            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                column.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            ])
            if placement != .top, !onImage {
                // Content sits slightly above center: free space split 1 : 1.4.
                bottomSpacer.heightAnchor.constraint(equalTo: topSpacer.heightAnchor, multiplier: 1.4).isActive = true
            } else if placement == .top {
                bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            }

            let close = CloseButton(palette: placement != nil ? Palette.image(style) : palette, diameter: 32)
            close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            ])

            view.alpha = 0
            enter = { [weak self] in
                guard let self else { return }
                if !self.reduceMotion { self.view.transform = CGAffineTransform(translationX: 0, y: 24) }
                UIView.animate(withDuration: self.reduceMotion ? 0.18 : 0.28, delay: 0, options: .curveEaseOut) {
                    self.view.alpha = 1
                    self.view.transform = .identity
                }
            }
            leave = { [weak self] done in
                guard let self else { return done() }
                UIView.animate(
                    withDuration: self.reduceMotion ? 0.18 : 0.2, animations: { self.view.alpha = 0 },
                    completion: { _ in done() })
            }
        }

        // MARK: Banner

        private func buildBanner() {
            let palette = Palette.surface(style)
            let top = message.resolvedPosition == .top
            let link = splitButtons(message.buttons).primary.flatMap { $0.action == .openUrl ? $0 : nil }

            panel.backgroundColor = UIColor(sequenzyHex: style.backgroundColor, fallback: .systemBackground)
            panel.layer.cornerRadius = min(CGFloat(style.cornerRadius), 24)
            panel.layer.cornerCurve = .continuous
            panel.layer.borderWidth = 0.5
            panel.layer.borderColor = UIColor(sequenzyHex: style.textColor, fallback: .label).withAlphaComponent(0.06).cgColor
            panel.layer.shadowColor = UIColor.black.cgColor
            panel.layer.shadowOpacity = 0.16
            panel.layer.shadowRadius = 12
            panel.layer.shadowOffset = CGSize(width: 0, height: 8)
            panel.accessibilityIdentifier = "sequenzy.banner"
            panel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(panel)

            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(row)

            if let url = message.imageUrl {
                let image = imageView(url: url) { [weak row] in row?.arrangedSubviews.first?.isHidden = true }
                image.layer.cornerRadius = 10
                image.layer.cornerCurve = .continuous
                image.clipsToBounds = true
                NSLayoutConstraint.activate([
                    image.widthAnchor.constraint(equalToConstant: 44), image.heightAnchor.constraint(equalToConstant: 44),
                ])
                row.addArrangedSubview(image)
            }

            let text = UIStackView()
            text.axis = .vertical
            text.spacing = 0
            let hasTitle = !message.title.isEmpty
            if hasTitle {
                text.addArrangedSubview(label(message.title, size: 15, lineHeight: 20, weight: .semibold, color: palette.text))
            }
            if !message.body.isEmpty {
                let body =
                    hasTitle
                    ? label(message.body, size: 14, lineHeight: 19, weight: .regular, color: palette.muted)
                    : label(message.body, size: 15, lineHeight: 20, weight: .medium, color: palette.text)
                body.numberOfLines = hasTitle ? 2 : 3
                text.addArrangedSubview(body)
                if hasTitle { text.setCustomSpacing(2, after: text.arrangedSubviews[0]) }
            }
            if let link {
                let linkLabel = label(link.label, size: 14, lineHeight: 19, weight: .semibold, color: palette.eyebrow)
                if let last = text.arrangedSubviews.last { text.setCustomSpacing(6, after: last) }
                text.addArrangedSubview(linkLabel)
            }
            row.addArrangedSubview(text)

            let close = CloseButton(palette: palette, diameter: 28)
            close.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
            row.addArrangedSubview(close)

            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
                row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
                row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
                row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
                panel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                panel.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
                panel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24),
                top
                    ? panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
                    : panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            ])
            let fill = panel.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24)
            fill.priority = .defaultHigh
            fill.isActive = true

            if link != nil {
                text.isUserInteractionEnabled = true
                text.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bannerTapped)))
                text.isAccessibilityElement = true
                text.accessibilityTraits = .button
                text.accessibilityLabel = [message.title, message.body, link?.label ?? ""].filter { !$0.isEmpty }
                    .joined(separator: ". ")
            }
            panel.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(bannerPanned)))

            let direction: CGFloat = top ? -1 : 1
            enter = { [weak self] in
                guard let self else { return }
                self.view.layoutIfNeeded()
                if self.reduceMotion {
                    self.panel.alpha = 0
                    UIView.animate(withDuration: 0.18) { self.panel.alpha = 1 }
                } else {
                    self.panel.transform = CGAffineTransform(translationX: 0, y: direction * (self.panel.bounds.height + 80))
                    UIView.animate(
                        withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0
                    ) { self.panel.transform = .identity }
                }
            }
            leave = { [weak self] done in
                guard let self else { return done() }
                UIView.animate(
                    withDuration: 0.18, delay: 0, options: .curveEaseIn,
                    animations: {
                        if self.reduceMotion {
                            self.panel.alpha = 0
                        } else {
                            self.panel.transform = CGAffineTransform(
                                translationX: 0, y: direction * (self.panel.bounds.height + 80))
                        }
                    }, completion: { _ in done() })
            }
        }

        @objc private func bannerTapped() { close(.tapped(nil)) }

        @objc private func bannerPanned(_ gesture: UIPanGestureRecognizer) {
            let direction: CGFloat = message.resolvedPosition == .top ? -1 : 1
            let dy = gesture.translation(in: view).y
            switch gesture.state {
            case .changed:
                panel.transform = CGAffineTransform(translationX: 0, y: dy * direction > 0 ? dy : dy / 3)
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: view).y * direction
                if dy * direction > panel.bounds.height * 0.4 || velocity > 800 {
                    close(.dismissed)
                } else {
                    UIView.animate(
                        withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0
                    ) { self.panel.transform = .identity }
                }
            default:
                break
            }
        }

        // MARK: Parts

        private var imagePlacement: InAppMessage.ImagePlacement? {
            guard message.imageUrl != nil, !imageFailed else { return nil }
            return message.imagePlacement == .background ? .background : .top
        }

        private func contentStack(palette: Palette, centered: Bool, fullscreen: Bool) -> UIStackView {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.addArrangedSubview(textBlock(palette: palette, centered: centered, fullscreen: fullscreen))
            if let buttons = buttonStack(palette: palette) { stack.addArrangedSubview(buttons) }
            return stack
        }

        private func textBlock(palette: Palette, centered: Bool, fullscreen: Bool) -> UIStackView {
            let stack = UIStackView()
            stack.axis = .vertical
            let alignment: NSTextAlignment = centered ? .center : .natural
            // Centered headings keep clear of the close button in the corner.
            let inset: CGFloat = centered ? 20 : 0
            let eyebrow = message.eyebrow.trimmingCharacters(in: .whitespacesAndNewlines)
            if !eyebrow.isEmpty {
                let view = label(eyebrow, size: 13, lineHeight: 18, weight: .semibold, color: palette.eyebrow)
                view.textAlignment = alignment
                stack.addArrangedSubview(inset > 0 ? padded(view, horizontal: inset) : view)
                stack.setCustomSpacing(6, after: stack.arrangedSubviews.last!)
            }
            if !message.title.isEmpty {
                let title = label(
                    message.title, size: fullscreen ? 30 : 22, lineHeight: fullscreen ? 36 : 28, weight: .bold,
                    color: palette.text, kerning: fullscreen ? -0.6 : -0.4)
                title.textAlignment = alignment
                title.accessibilityTraits = .header
                stack.addArrangedSubview(inset > 0 ? padded(title, horizontal: inset) : title)
            }
            if !message.body.isEmpty {
                if let last = stack.arrangedSubviews.last, !message.title.isEmpty { stack.setCustomSpacing(8, after: last) }
                let body = label(
                    message.body, size: fullscreen ? 17 : 16, lineHeight: fullscreen ? 25 : 23, weight: .regular,
                    color: palette.muted)
                body.textAlignment = alignment
                stack.addArrangedSubview(body)
            }
            return stack
        }

        private func padded(_ view: UIView, horizontal: CGFloat) -> UIView {
            let container = UIView()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            ])
            return container
        }

        private func buttonStack(palette: Palette) -> UIView? {
            let (primary, secondary) = splitButtons(message.buttons)
            guard let primary else { return nil }
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 4
            stack.isLayoutMarginsRelativeArrangement = true
            stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 0, bottom: 0, trailing: 0)

            let primaryButton = button(primary, color: palette.primaryText, pressedAlpha: 0.85)
            primaryButton.backgroundColor = palette.primaryBackground
            primaryButton.layer.cornerRadius = min(CGFloat(style.buttonRadius), 26)
            primaryButton.layer.cornerCurve = .continuous
            primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            stack.addArrangedSubview(primaryButton)

            if let secondary {
                let secondaryButton = button(
                    secondary, color: secondary.action == .openUrl ? palette.secondaryLink : palette.secondaryDismiss,
                    pressedAlpha: 0.6)
                secondaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
                stack.addArrangedSubview(secondaryButton)
            }
            return stack
        }

        private func button(_ model: InAppButton, color: UIColor, pressedAlpha: CGFloat) -> UIButton {
            let button = PressableButton(type: .custom)
            button.pressedAlpha = pressedAlpha
            button.setTitle(model.label, for: .normal)
            button.setTitleColor(color, for: .normal)
            button.titleLabel?.font = scaledFont(size: 17, weight: .semibold)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            button.addAction(UIAction { [weak self] _ in self?.handle(model) }, for: .touchUpInside)
            return button
        }

        private func scaledFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
            UIFontMetrics.default.scaledFont(for: style.font(size: size, weight: weight), maximumPointSize: size * 1.4)
        }

        private func label(
            _ text: String, size: CGFloat, lineHeight: CGFloat, weight: UIFont.Weight, color: UIColor,
            kerning: CGFloat = 0
        ) -> UILabel {
            let label = UILabel()
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            let font = scaledFont(size: size, weight: weight)
            let scale = font.pointSize / size
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = lineHeight * scale
            paragraph.maximumLineHeight = lineHeight * scale
            paragraph.lineBreakMode = .byTruncatingTail
            label.attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: kerning,
                ])
            return label
        }

        /// An image on a faint placeholder; `onError` runs once if it fails to load.
        private func imageView(url raw: String, onError: @escaping () -> Void) -> UIImageView {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.backgroundColor = UIColor(sequenzyHex: style.textColor, fallback: .label).withAlphaComponent(0.06)
            view.isAccessibilityElement = false
            // Sized by the layout, never by the picture's own pixel size.
            for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
                view.setContentHuggingPriority(.defaultLow, for: axis)
                view.setContentCompressionResistancePriority(.defaultLow, for: axis)
            }
            guard let url = URL(string: raw), url.scheme == "https" else {
                DispatchQueue.main.async(execute: onError)
                return view
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap(UIImage.init(data:))
                DispatchQueue.main.async {
                    if let image { view.image = image } else { onError() }
                }
            }.resume()
            return view
        }

        private func pin(_ child: UIView, to parent: UIView) {
            child.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: parent.topAnchor),
                child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            ])
        }
    }

    extension NSLayoutConstraint {
        fileprivate func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
            self.priority = priority
            return self
        }
    }
#endif
