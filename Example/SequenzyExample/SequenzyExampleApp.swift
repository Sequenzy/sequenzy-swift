import Sequenzy
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let tokenURL = URL(string: info["SequenzyIdentityTokenUrl"] as? String ?? "")
        Sequenzy.configure(
            publicKey: info["SequenzyPublicKey"] as? String ?? "",
            companyId: info["SequenzyCompanyId"] as? String ?? "",
            apiBaseURL: URL(string: info["SequenzyApiBaseUrl"] as? String ?? "") ?? SequenzyConfiguration.defaultAPIBaseURL,
            // Your backend mints the token with its secret API key; the app
            // only ever sees the short-lived identity token.
            identityTokenProvider: { email in
                guard let tokenURL else { return "" }
                var request = URLRequest(url: tokenURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])
                let (data, _) = try await URLSession.shared.data(for: request)
                return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["identityToken"] as? String ?? ""
            },
            logLevel: .debug)
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Sequenzy.registerDeviceToken(deviceToken)
    }
}

@main
struct SequenzyExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var email = ""
    @State private var signedIn = false
    @State private var cards: [InAppMessage] = []
    @State private var status = "Not signed in"

    var body: some View {
        NavigationStack {
            List {
                if signedIn {
                    // In-app placements: inline slots that collapse when empty.
                    // The items draw their own card, so the rows are clear.
                    Section("Home hero (SwiftUI)") {
                        SequenzyPlacement("home_hero")
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section("Settings banner (UIKit)") {
                        PlacementSlot(placementId: "settings_banner")
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        Button("Log a workout") {
                            Sequenzy.track("workout_completed", properties: ["count": 3, "source": "ios-example"])
                            status = "Tracked workout_completed"
                        }
                        Button("Enable push notifications") {
                            Task { await Sequenzy.requestPushAuthorization() }
                        }
                        Button("Sign out", role: .destructive) {
                            Sequenzy.reset()
                            signedIn = false
                            cards = []
                            status = "Signed out"
                        }
                    }
                    Section("Inbox") {
                        if cards.isEmpty { Text("No cards yet").foregroundStyle(.secondary) }
                        ForEach(cards) { card in
                            VStack(alignment: .leading, spacing: 6) {
                                Text((card.pinned ? "📌 " : "") + card.title).font(.headline)
                                Text(card.body).foregroundStyle(.secondary)
                                if let button = card.buttons.first(where: { $0.action == .openUrl }) {
                                    Button(button.label) { Sequenzy.handleButtonTap(button, in: card) }
                                }
                            }
                            .onAppear { if !card.isRead { Sequenzy.report(.read, for: card) } }
                        }
                        .onDelete { offsets in
                            offsets.map { cards[$0] }.forEach { Sequenzy.report(.dismissed, for: $0) }
                            cards.remove(atOffsets: offsets)
                        }
                    }
                } else {
                    Section {
                        TextField("you@example.com", text: $email)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                        Button("Sign in") {
                            Sequenzy.identify(email: email)
                            signedIn = true
                            status = "Signed in"
                            Task { await loadCards() }
                        }
                    }
                }
                Text(status).foregroundStyle(.secondary)
            }
            .environment(\.defaultMinListRowHeight, 0)
            .navigationTitle("Sequenzy example")
            .refreshable { await loadCards() }
        }
    }

    private func loadCards() async {
        // identify() runs in the background; give it a moment on first sign-in.
        for _ in 0..<5 {
            if let loaded = try? await Sequenzy.fetchCards() {
                cards = loaded
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }
}

/// `SequenzyPlacementView` (UIKit) inside SwiftUI; apps with UIKit screens
/// add it to a stack view directly.
struct PlacementSlot: UIViewRepresentable {
    let placementId: String

    func makeUIView(context: Context) -> SequenzyPlacementView {
        let view = SequenzyPlacementView(placementId: placementId)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: SequenzyPlacementView, context: Context) {
        view.placementId = placementId
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SequenzyPlacementView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: uiView.item == nil ? 0 : size.height)
    }
}
