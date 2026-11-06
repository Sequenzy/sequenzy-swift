// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sequenzy",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "Sequenzy", targets: ["Sequenzy"]),
        .library(name: "SequenzyNotificationService", targets: ["SequenzyNotificationService"]),
        .library(name: "SequenzyLiveActivities", targets: ["SequenzyLiveActivities"]),
        .library(name: "SequenzyGeofences", targets: ["SequenzyGeofences"]),
    ],
    targets: [
        // Wire protocol, identity, event queue and payload parsing. Foundation
        // only, so it builds and tests on Linux as well as Apple platforms.
        .target(name: "SequenzyCore"),
        // UIKit integration: lifecycle, APNs registration, notification taps
        // and the in-app message presenter.
        .target(
            name: "Sequenzy",
            dependencies: ["SequenzyCore", "SequenzyLiveActivities"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Drop-in UNNotificationServiceExtension for rich images and
        // delivery reports. Kept separate so the extension stays small.
        .target(name: "SequenzyNotificationService", dependencies: ["SequenzyCore"]),
        // The ActivityAttributes protocol and data, with no UIKit, so the
        // Live Activity widget extension can link it.
        .target(name: "SequenzyLiveActivities"),
        // Core Location region monitoring. A separate product so apps that do
        // not use geofencing never link Core Location or declare location use.
        .target(
            name: "SequenzyGeofences",
            dependencies: ["Sequenzy"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "SequenzyCoreTests", dependencies: ["SequenzyCore"]),
    ]
)
