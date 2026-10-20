// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sequenzy",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "Sequenzy", targets: ["Sequenzy"]),
        .library(name: "SequenzyNotificationService", targets: ["SequenzyNotificationService"]),
    ],
    targets: [
        // Wire protocol, identity, event queue and payload parsing. Foundation
        // only, so it builds and tests on Linux as well as Apple platforms.
        .target(name: "SequenzyCore"),
        // UIKit integration: lifecycle, APNs registration, notification taps
        // and the in-app message presenter.
        .target(
            name: "Sequenzy",
            dependencies: ["SequenzyCore"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Drop-in UNNotificationServiceExtension for rich images and
        // delivery reports. Kept separate so the extension stays small.
        .target(name: "SequenzyNotificationService", dependencies: ["SequenzyCore"]),
        .testTarget(name: "SequenzyCoreTests", dependencies: ["SequenzyCore"]),
    ]
)
