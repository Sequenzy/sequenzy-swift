#if canImport(UIKit) && canImport(UserNotifications)
    import UIKit

    /// Shared by every placement view in the app: one cache per placement key,
    /// fetches batched across views that appear in the same run loop turn, and
    /// each item reported displayed once per app session. Content belongs to
    /// one contact: identifying someone else or resetting empties the cache,
    /// and answers for the previous contact are dropped.
    @MainActor
    public final class SequenzyPlacements {
        public static let shared = SequenzyPlacements()

        private var items: [String: InAppMessage] = [:]
        private var loaded: Set<String> = []
        private var observers: [String: [UUID: (InAppMessage?) -> Void]] = [:]
        private var pending: Set<String> = []
        private var scheduled = false
        // Item ids are per contact, so these never need clearing.
        private var displayed: Set<String> = []
        // The newest request sent for each key: an older answer arriving
        // later (a refresh in flight during a dismissal) must not win.
        private var latestRequest: [String: Int] = [:]
        private var requests = 0
        // Dismissed this session: a fetch that raced the report must not bring
        // the item back.
        private var dismissed: Set<String> = []
        // Who the cached content belongs to; nil until known.
        private var contact: String??
        // Bumped when the contact changes so a late answer for the previous
        // one is dropped.
        private var generation = 0
        private var lastFetch = Date.distantPast

        /// Refetch on foreground at most this often.
        static let foregroundRefresh: TimeInterval = 60

        /// What the placement shows now, from the last fetch; nil when empty.
        public func item(for placementId: String) -> InAppMessage? { items[placementId] }

        /// Calls `handler` with the placement's item now (if fetched) and on
        /// every change. Observing a new placement fetches it.
        public func observe(_ placementId: String, _ handler: @escaping (InAppMessage?) -> Void) -> UUID {
            let token = UUID()
            observers[placementId, default: [:]][token] = handler
            if loaded.contains(placementId) {
                handler(items[placementId])
            } else {
                schedule([placementId])
            }
            return token
        }

        public func stopObserving(_ placementId: String, token: UUID) {
            observers[placementId]?[token] = nil
            if observers[placementId]?.isEmpty == true { observers[placementId] = nil }
        }

        /// Fetch one placement again, or every observed one.
        public func refresh(_ placementId: String? = nil) {
            schedule(placementId.map { [$0] } ?? Array(observers.keys))
        }

        /// Reports the item shown; once per item per app session.
        public func logDisplayed(_ item: InAppMessage) {
            guard displayed.insert(item.id).inserted else { return }
            Sequenzy.report(.displayed, for: item)
        }

        /// Reports a dismissal, empties the slot and asks for its next item.
        public func dismiss(_ item: InAppMessage) {
            dismissed.insert(item.id)
            guard let key = item.placement else {
                Sequenzy.report(.dismissed, for: item)
                return
            }
            if items[key]?.id == item.id { set(key, nil) }
            // Ask for the next item once the server has the dismissal: sooner,
            // it still answers with the dismissed item.
            guard let client = Sequenzy.requireClient() else { return }
            Task { @MainActor [weak self] in
                _ = await client.report(.dismissed, messageId: item.id)
                self?.schedule([key])
            }
        }

        /// After identify (the contact key: external ID or email) or reset (nil).
        func identityChanged(email: String?) {
            if let known = contact, known == email {
                refresh()
                return
            }
            contact = .some(email)
            // Another contact's content must never show: forget every slot,
            // cached ones too, so a view that appears later fetches.
            generation += 1
            pending.removeAll()
            let observed = Array(observers.keys)
            items.removeAll()
            loaded.removeAll()
            for key in observed { set(key, nil) }
            if email != nil { refresh() }
        }

        func didBecomeActive() {
            if Date().timeIntervalSince(lastFetch) >= Self.foregroundRefresh { refresh() }
        }

        private func set(_ key: String, _ item: InAppMessage?) {
            loaded.insert(key)
            items[key] = item
            for handler in observers[key]?.values.map({ $0 }) ?? [] { handler(item) }
        }

        private func schedule(_ keys: [String]) {
            pending.formUnion(keys)
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                let batch = Array(self.pending)
                self.pending.removeAll()
                if !batch.isEmpty { self.fetch(batch) }
            }
        }

        private func fetch(_ keys: [String]) {
            guard let client = Sequenzy.currentClient else { return }
            let started = generation
            lastFetch = Date()
            Task { @MainActor in
                // Whoever is signed in now owns what this fetch returns.
                if self.contact == nil, started == self.generation {
                    let current = await client.contactKey
                    if self.contact == nil { self.contact = .some(current) }
                }
                var start = 0
                while start < keys.count {
                    let chunk = Array(keys[start..<min(start + SequenzyClient.maxPlacementsPerRequest, keys.count)])
                    start += SequenzyClient.maxPlacementsPerRequest
                    self.requests += 1
                    let request = self.requests
                    for key in chunk { self.latestRequest[key] = request }
                    // A failed fetch keeps what was showing; empty slots stay
                    // collapsed until the next refresh.
                    guard let found = try? await client.fetchPlacements(chunk) else { continue }
                    guard started == self.generation else { return }
                    for key in chunk where self.latestRequest[key] == request {
                        let item = found[key].flatMap { self.dismissed.contains($0.id) ? nil : $0 }
                        self.set(key, item)
                    }
                }
            }
        }
    }

    /// A slot in your layout that shows Sequenzy content for one placement,
    /// drawn to mobile-sdks/DESIGN.md (the card layout without unread dot, pin
    /// or close control). Hidden with no intrinsic height while there is
    /// nothing to show, so a stack view collapses it. Reports displayed once
    /// per item per session, clicks and dismissals.
    ///
    ///     let hero = SequenzyPlacementView(placementId: "home_hero")
    ///     stackView.addArrangedSubview(hero)
    @MainActor
    public final class SequenzyPlacementView: UIView {
        /// The placement key defined in Sequenzy, e.g. `home_hero`.
        @IBInspectable public var placementId: String = "" {
            didSet { if placementId != oldValue { follow() } }
        }

        /// Called when the slot's content changes; nil when it collapses.
        public var onChange: ((InAppMessage?) -> Void)?

        public private(set) var item: InAppMessage?

        private let placements: SequenzyPlacements
        private var token: UUID?
        private var followedId: String?
        private let card = UIView()

        public init(placementId: String, placements: SequenzyPlacements? = nil) {
            self.placements = placements ?? .shared
            self.placementId = placementId
            super.init(frame: .zero)
            setUp()
        }

        public required init?(coder: NSCoder) {
            placements = .shared
            super.init(coder: coder)
            setUp()
        }

        private func setUp() {
            isHidden = true
            card.translatesAutoresizingMaskIntoConstraints = false
            card.clipsToBounds = true
            addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: topAnchor),
                card.bottomAnchor.constraint(equalTo: bottomAnchor),
                card.leadingAnchor.constraint(equalTo: leadingAnchor),
                card.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        public override var intrinsicContentSize: CGSize {
            item == nil ? CGSize(width: UIView.noIntrinsicMetric, height: 0) : super.intrinsicContentSize
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                unfollow()
            } else {
                follow()
                if let item { placements.logDisplayed(item) }
            }
        }

        private func follow() {
            guard window != nil else { return }
            if placementId.isEmpty {
                unfollow()
                show(nil)
                return
            }
            if followedId == placementId, token != nil { return }
            unfollow()
            followedId = placementId
            token = placements.observe(placementId) { [weak self] item in self?.show(item) }
        }

        private func unfollow() {
            if let token, let followedId { placements.stopObserving(followedId, token: token) }
            token = nil
            followedId = nil
        }

        private func show(_ next: InAppMessage?) {
            let changed = next != item
            item = next
            guard changed else { return }
            card.subviews.forEach { $0.removeFromSuperview() }
            isHidden = next == nil
            if let next {
                build(next)
                if window != nil { placements.logDisplayed(next) }
            }
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
            onChange?(next)
        }

        private func build(_ item: InAppMessage) {
            let style = item.style
            let text = UIColor(sequenzyHex: style.textColor, fallback: .label)
            card.backgroundColor = UIColor(sequenzyHex: style.backgroundColor, fallback: .systemBackground)
            card.layer.cornerRadius = CGFloat(style.cornerRadius)
            card.layer.borderWidth = 1 / UIScreen.main.scale
            card.layer.borderColor = text.withAlphaComponent(0.08).cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.05
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 0, height: 1)
            switch item.layout {
            case .card: buildCard(item)
            case .banner: buildBanner(item)
            case .hero: buildHero(item, image: placementImageURL(item.imageUrl))
            }
        }

        /// Image across the top at 2:1, then the text and text-link buttons.
        private func buildCard(_ item: InAppMessage) {
            let style = item.style
            let colors = PlacementColors(style, overImage: false)
            let column = UIStackView()
            column.axis = .vertical
            pin(column, in: card)
            if let url = placementImageURL(item.imageUrl) {
                let image = imageView(style)
                image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 0.5).isActive = true
                column.addArrangedSubview(image)
                load(url, into: image) { image.isHidden = true }
            }
            let content = textStack(item, colors: colors, hero: false, bodyLines: 4)
            content.isLayoutMarginsRelativeArrangement = true
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
            column.addArrangedSubview(content)
            let (primary, secondary) = placementButtons(item.buttons)
            if let primary, let last = content.arrangedSubviews.last {
                content.setCustomSpacing(12, after: last)
                let row = UIStackView()
                row.axis = .horizontal
                row.spacing = 20
                row.alignment = .leading
                let links: [(InAppButton?, UIColor)] = [(primary, colors.eyebrow), (secondary, colors.muted)]
                for (button, color) in links {
                    guard let button else { continue }
                    let control = UIButton(type: .system)
                    control.setTitle(button.label, for: .normal)
                    control.setTitleColor(color, for: .normal)
                    control.titleLabel?.font = UIFontMetrics.default.scaledFont(for: style.font(size: 15, weight: .semibold))
                    control.contentHorizontalAlignment = .leading
                    control.addAction(UIAction { [weak self] _ in self?.tap(button, in: item) }, for: .touchUpInside)
                    row.addArrangedSubview(control)
                }
                let spacer = UIView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(spacer)
                content.addArrangedSubview(row)
            }
        }

        /// A 56 thumbnail beside the text, with a filled primary button.
        private func buildBanner(_ item: InAppMessage) {
            let style = item.style
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 12
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
            pin(row, in: card)
            if let url = placementImageURL(item.imageUrl) {
                let image = imageView(style)
                image.layer.cornerRadius = min(CGFloat(style.cornerRadius), 12)
                NSLayoutConstraint.activate([
                    image.widthAnchor.constraint(equalToConstant: 56),
                    image.heightAnchor.constraint(equalToConstant: 56),
                ])
                row.addArrangedSubview(image)
                load(url, into: image) { image.isHidden = true }
            }
            let colors = PlacementColors(style, overImage: false)
            let content = textStack(item, colors: colors, hero: false, bodyLines: 2)
            addFilledButtons(item, colors: colors, to: content, spacing: 10)
            row.addArrangedSubview(content)
        }

        /// Text over the image (or the surface), at least half as tall as wide.
        /// Built in its own container so its constraints leave with it when
        /// another item replaces it.
        private func buildHero(_ item: InAppMessage, image url: URL?) {
            let style = item.style
            let colors = PlacementColors(style, overImage: url != nil)
            let hero = UIView()
            pin(hero, in: card)
            if let url {
                let image = imageView(style)
                // The picture never sizes the slot (DESIGN.md "Images").
                for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
                    image.setContentHuggingPriority(.fittingSizeLevel, for: axis)
                    image.setContentCompressionResistancePriority(.fittingSizeLevel, for: axis)
                }
                pin(image, in: hero)
                let scrim = PlacementScrimView()
                pin(scrim, in: hero)
                // A failed image draws the item as without one.
                load(url, into: image) { [weak self] in
                    guard let self, self.item?.id == item.id else { return }
                    self.card.subviews.forEach { $0.removeFromSuperview() }
                    self.buildHero(item, image: nil)
                }
            }
            let content = textStack(item, colors: colors, hero: true, bodyLines: 3)
            addFilledButtons(item, colors: colors, to: content, spacing: 14)
            content.translatesAutoresizingMaskIntoConstraints = false
            hero.addSubview(content)
            // As short as the text and the 2:1 minimum allow.
            let hug = hero.heightAnchor.constraint(equalToConstant: 0)
            hug.priority = .fittingSizeLevel
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 20),
                content.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -20),
                content.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -20),
                content.topAnchor.constraint(greaterThanOrEqualTo: hero.topAnchor, constant: 20),
                hero.heightAnchor.constraint(greaterThanOrEqualTo: hero.widthAnchor, multiplier: 0.5),
                hug,
            ])
        }

        /// Eyebrow, title and body (the card or hero type ramp).
        private func textStack(_ item: InAppMessage, colors: PlacementColors, hero: Bool, bodyLines: Int) -> UIStackView {
            let style = item.style
            let stack = UIStackView()
            stack.axis = .vertical
            stack.alignment = .fill
            func label(_ value: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, lines: Int = 0) -> UILabel {
                let label = UILabel()
                label.text = value
                label.font = UIFontMetrics.default.scaledFont(for: style.font(size: size, weight: weight))
                label.adjustsFontForContentSizeCategory = true
                label.textColor = color
                label.numberOfLines = lines
                return label
            }
            let eyebrow = item.eyebrow.trimmingCharacters(in: .whitespacesAndNewlines)
            if !eyebrow.isEmpty {
                let view = label(eyebrow, size: hero ? 13 : 12, weight: .semibold, color: colors.eyebrow)
                stack.addArrangedSubview(view)
                stack.setCustomSpacing(hero ? 6 : 4, after: view)
            }
            if !item.title.isEmpty {
                let view = label(item.title, size: hero ? 20 : 16, weight: hero ? .bold : .semibold, color: colors.text)
                stack.addArrangedSubview(view)
                stack.setCustomSpacing(item.layout == .banner ? 4 : 6, after: view)
            }
            if !item.body.isEmpty {
                stack.addArrangedSubview(label(item.body, size: 14, weight: .regular, color: colors.muted, lines: bodyLines))
            }
            return stack
        }

        /// A filled primary button, then the other button as a text link.
        private func addFilledButtons(_ item: InAppMessage, colors: PlacementColors, to stack: UIStackView, spacing: CGFloat) {
            let style = item.style
            let (primary, secondary) = placementButtons(item.buttons)
            guard let primary else { return }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(spacing, after: last) }
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 16
            row.alignment = .center
            let font = UIFontMetrics.default.scaledFont(for: style.font(size: 14, weight: .semibold))
            let filled = UIButton(type: .system)
            filled.setTitle(primary.label, for: .normal)
            filled.setTitleColor(colors.onFill, for: .normal)
            filled.titleLabel?.font = font
            filled.backgroundColor = colors.fill
            filled.layer.cornerRadius = min(CGFloat(style.buttonRadius), 18)
            filled.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
            filled.heightAnchor.constraint(equalToConstant: 36).isActive = true
            filled.addAction(UIAction { [weak self] _ in self?.tap(primary, in: item) }, for: .touchUpInside)
            row.addArrangedSubview(filled)
            if let secondary {
                let link = UIButton(type: .system)
                link.setTitle(secondary.label, for: .normal)
                link.setTitleColor(colors.muted, for: .normal)
                link.titleLabel?.font = font
                link.addAction(UIAction { [weak self] _ in self?.tap(secondary, in: item) }, for: .touchUpInside)
                row.addArrangedSubview(link)
            }
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            stack.addArrangedSubview(row)
        }

        private func imageView(_ style: InAppStyle) -> UIImageView {
            let image = UIImageView()
            image.contentMode = .scaleAspectFill
            image.clipsToBounds = true
            image.backgroundColor = UIColor(sequenzyHex: style.textColor, fallback: .label).withAlphaComponent(0.06)
            return image
        }

        private func pin(_ view: UIView, in container: UIView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        private func load(_ url: URL, into view: UIImageView, onFailure: @escaping () -> Void) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let loaded = data.flatMap(UIImage.init(data:))
                DispatchQueue.main.async {
                    if let loaded { view.image = loaded } else { onFailure() }
                }
            }.resume()
        }

        private func tap(_ button: InAppButton, in item: InAppMessage) {
            if button.action == .dismiss {
                placements.dismiss(item)
            } else {
                Sequenzy.handleButtonTap(button, in: item)
            }
        }
    }

    /// The background-image gradient (mobile-sdks/DESIGN.md "Images").
    final class PlacementScrimView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            let gradient = layer as? CAGradientLayer
            gradient?.colors = [0, 0.55, 0.82].map { UIColor(white: 0, alpha: $0).cgColor }
            gradient?.locations = [0, 0.55, 1]
        }

        required init?(coder: NSCoder) { nil }
    }

    /// An https image URL, or nil.
    func placementImageURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    /// WCAG contrast ratio, 1 to 21.
    func placementContrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
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
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The eyebrow and first button color of a placement card
    /// (mobile-sdks/DESIGN.md): the accent when its contrast with the card is
    /// at least 3:1, otherwise the muted text color.
    func placementAccent(_ style: InAppStyle) -> UIColor {
        let accent = UIColor(sequenzyHex: style.buttonColor, fallback: .label)
        let background = UIColor(sequenzyHex: style.backgroundColor, fallback: .systemBackground)
        return placementContrast(accent, background) >= 3
            ? accent : UIColor(sequenzyHex: style.mutedTextColor, fallback: .secondaryLabel)
    }

    /// Text and button colors of a placement item: on its surface, or over a
    /// hero image (mobile-sdks/DESIGN.md "Colors").
    struct PlacementColors {
        let text: UIColor
        let muted: UIColor
        let eyebrow: UIColor
        let fill: UIColor
        let onFill: UIColor

        init(_ style: InAppStyle, overImage: Bool) {
            let accent = UIColor(sequenzyHex: style.buttonColor, fallback: .label)
            let buttonText = UIColor(sequenzyHex: style.buttonTextColor, fallback: .white)
            if overImage {
                let keepsAccent = placementContrast(accent, UIColor(white: 0.12, alpha: 1)) >= 2
                text = .white
                muted = UIColor(white: 1, alpha: 0.82)
                eyebrow = UIColor(white: 1, alpha: 0.9)
                fill = keepsAccent ? accent : .white
                onFill = keepsAccent ? buttonText : UIColor(white: 0.07, alpha: 1)
            } else {
                text = UIColor(sequenzyHex: style.textColor, fallback: .label)
                muted = UIColor(sequenzyHex: style.mutedTextColor, fallback: .secondaryLabel)
                eyebrow = placementAccent(style)
                fill = accent
                onFill = buttonText
            }
        }
    }

    /// The primary button (the first that acts, else the first) and the other.
    func placementButtons(_ buttons: [InAppButton]) -> (primary: InAppButton?, secondary: InAppButton?) {
        guard !buttons.isEmpty else { return (nil, nil) }
        let index = buttons.firstIndex { $0.action != .dismiss } ?? 0
        let other = buttons.indices.first { $0 != index }
        return (buttons[index], other.map { buttons[$0] })
    }
#endif

#if canImport(SwiftUI) && canImport(UIKit) && canImport(UserNotifications)
    import SwiftUI

    /// SwiftUI slot for one placement. Sizes to its content and has zero
    /// height while there is nothing to show (a parent stack still adds its
    /// spacing around it).
    ///
    ///     SequenzyPlacement("home_hero")
    @available(iOS 14.0, *)
    public struct SequenzyPlacement: View {
        private let placementId: String
        @StateObject private var model = SequenzyPlacementModel()

        public init(_ placementId: String) {
            self.placementId = placementId
        }

        public var body: some View {
            // A zero-height view keeps the stack present while the slot is
            // empty, so onAppear fires and the placement is fetched.
            VStack(spacing: 0) {
                Color.clear.frame(height: 0)
                if let item = model.item {
                    SequenzyPlacementContent(item: item) { button in
                        if button.action == .dismiss {
                            SequenzyPlacements.shared.dismiss(item)
                        } else {
                            Sequenzy.handleButtonTap(button, in: item)
                        }
                    }
                    // A new item is a new view: its own image and onAppear.
                    .id(item.id)
                    .onAppear { SequenzyPlacements.shared.logDisplayed(item) }
                }
            }
            .onAppear { model.follow(placementId) }
            .onDisappear { model.unfollow() }
            .onChange(of: placementId) { model.follow($0) }
        }
    }

    @MainActor
    final class SequenzyPlacementModel: ObservableObject {
        @Published private(set) var item: InAppMessage?
        private var token: UUID?
        private var placementId: String?

        // Created from a view's property initializer, which may run off the
        // main actor before Swift 5.10.
        nonisolated init() {}

        func follow(_ id: String) {
            if placementId == id, token != nil { return }
            unfollow()
            placementId = id
            token = SequenzyPlacements.shared.observe(id) { [weak self] next in
                self?.item = next
            }
        }

        func unfollow() {
            if let token, let placementId {
                SequenzyPlacements.shared.stopObserving(placementId, token: token)
            }
            token = nil
            placementId = nil
        }
    }

    /// A placement item in its layout (mobile-sdks/DESIGN.md "Placement"):
    /// card, banner or hero, without unread dot, pin or close control.
    @available(iOS 14.0, *)
    struct SequenzyPlacementContent: View {
        let item: InAppMessage
        let onButton: (InAppButton) -> Void
        @State private var image: UIImage?
        @State private var imageFailed = false
        // The hero's width, for its 2:1 minimum height.
        @State private var width: CGFloat = 0

        private var style: InAppStyle { item.style }
        private var hero: Bool { item.layout == .hero }
        private var heroImage: Bool { hero && placementImageURL(item.imageUrl) != nil && !imageFailed }
        private var colors: PlacementColors { PlacementColors(style, overImage: heroImage) }

        private func font(_ size: CGFloat, _ weight: UIFont.Weight) -> Font {
            Font(style.font(size: size, weight: weight) as CTFont)
        }

        private var placeholder: Color {
            Color(UIColor(sequenzyHex: style.textColor, fallback: .label)).opacity(0.06)
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: CGFloat(style.cornerRadius), style: .continuous)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor(sequenzyHex: style.backgroundColor, fallback: .systemBackground)))
                .clipShape(shape)
                .overlay(shape.stroke(Color(UIColor(sequenzyHex: style.textColor, fallback: .label)).opacity(0.08), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.05), radius: 1, x: 0, y: 1)
                .onAppear(perform: loadImage)
        }

        @ViewBuilder private var content: some View {
            switch item.layout {
            case .card:
                VStack(alignment: .leading, spacing: 0) {
                    if placementImageURL(item.imageUrl) != nil, !imageFailed {
                        Rectangle().fill(placeholder).aspectRatio(2, contentMode: .fit).overlay(loadedImage).clipped()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        text(bodyLines: 4)
                        linkButtons.padding(.top, 12)
                    }
                    .padding(16)
                }
            case .banner:
                HStack(alignment: .top, spacing: 12) {
                    if placementImageURL(item.imageUrl) != nil, !imageFailed {
                        Rectangle().fill(placeholder).frame(width: 56, height: 56).overlay(loadedImage)
                            .clipShape(RoundedRectangle(cornerRadius: min(CGFloat(style.cornerRadius), 12), style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        text(bodyLines: 2)
                        filledButtons.padding(.top, 10)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            case .hero:
                heroBody
            }
        }

        private var heroBody: some View {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                text(bodyLines: 3)
                filledButtons.padding(.top, 14)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: width / 2, alignment: .bottomLeading)
            .background(
                Group {
                    if heroImage {
                        ZStack {
                            placeholder
                            loadedImage
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.black.opacity(0), location: 0),
                                    .init(color: Color.black.opacity(0.55), location: 0.55),
                                    .init(color: Color.black.opacity(0.82), location: 1),
                                ]),
                                startPoint: .top, endPoint: .bottom)
                        }
                    }
                }
            )
            .background(GeometryReader { proxy in Color.clear.preference(key: PlacementWidthKey.self, value: proxy.size.width) })
            .onPreferenceChange(PlacementWidthKey.self) { width = $0 }
        }

        private var loadedImage: some View {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
        }

        @ViewBuilder private func text(bodyLines: Int) -> some View {
            let eyebrow = item.eyebrow.trimmingCharacters(in: .whitespacesAndNewlines)
            if !eyebrow.isEmpty {
                Text(eyebrow)
                    .font(font(hero ? 13 : 12, .semibold))
                    .foregroundColor(Color(colors.eyebrow))
                    .padding(.bottom, hero ? 6 : 4)
            }
            if !item.title.isEmpty {
                Text(item.title)
                    .font(font(hero ? 20 : 16, hero ? .bold : .semibold))
                    .foregroundColor(Color(colors.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.body.isEmpty {
                Text(item.body)
                    .font(font(14, .regular))
                    .foregroundColor(Color(colors.muted))
                    .lineLimit(bodyLines)
                    .padding(.top, item.title.isEmpty ? 0 : (item.layout == .banner ? 4 : 6))
            }
        }

        @ViewBuilder private var linkButtons: some View {
            let (primary, secondary) = placementButtons(item.buttons)
            if let primary {
                HStack(spacing: 20) {
                    Button(primary.label) { onButton(primary) }
                        .font(font(15, .semibold))
                        .foregroundColor(Color(colors.eyebrow))
                    if let secondary {
                        Button(secondary.label) { onButton(secondary) }
                            .font(font(15, .semibold))
                            .foregroundColor(Color(colors.muted))
                    }
                }
            }
        }

        @ViewBuilder private var filledButtons: some View {
            let (primary, secondary) = placementButtons(item.buttons)
            if let primary {
                HStack(spacing: 16) {
                    Button(action: { onButton(primary) }) {
                        Text(primary.label)
                            .font(font(14, .semibold))
                            .foregroundColor(Color(colors.onFill))
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: min(CGFloat(style.buttonRadius), 18), style: .continuous)
                                    .fill(Color(colors.fill)))
                    }
                    .buttonStyle(.plain)
                    if let secondary {
                        Button(secondary.label) { onButton(secondary) }
                            .font(font(14, .semibold))
                            .foregroundColor(Color(colors.muted))
                    }
                }
            }
        }

        private func loadImage() {
            guard image == nil, let url = placementImageURL(item.imageUrl) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let loaded = data.flatMap(UIImage.init(data:))
                DispatchQueue.main.async {
                    if let loaded { image = loaded } else { imageFailed = true }
                }
            }.resume()
        }
    }

    @available(iOS 14.0, *)
    private struct PlacementWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
#endif
