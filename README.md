# Sequenzy for iOS

The official iOS SDK for [Sequenzy](https://sequenzy.com), the email
marketing platform for SaaS. Identify contacts, track events, receive push notifications and show in-app
messages and content cards from an iOS app. Events from your app start the same
sequences as your emails, and push and in-app messages are steps in them.
Full guide: [Mobile SDKs](https://docs.sequenzy.com/concepts/mobile-sdks).

## Install

Swift Package Manager: add `https://github.com/Sequenzy/sequenzy-swift` and link
`Sequenzy` to the app. For push images and delivery reports, link
`SequenzyNotificationService` to a Notification Service Extension. iOS 14+.

## Use

```swift
import Sequenzy

// application(_:didFinishLaunchingWithOptions:)
Sequenzy.configure(
    publicKey: "seq_pk_...",          // key with your bundle ID under Allowed app IDs
    companyId: "your-company-id",
    identityTokenProvider: { email in try await MyBackend.sequenzyToken(for: email) }
)

// application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
Sequenzy.registerDeviceToken(deviceToken)

Sequenzy.identify(email: user.email)          // after sign-in
Sequenzy.track("workout_completed", properties: ["minutes": 30])
await Sequenzy.requestPushPermission()        // prompt, or Settings if turned off
Sequenzy.reset()                               // on sign-out

let cards = try await Sequenzy.fetchCards()    // inbox screen
```

Registrations carry the notification permission, and push primers (in-app
messages with an "Asks for push" button) ask for it from the message.
`requestPushAuthorization(provisional: true)` delivers quietly to Notification
Center without a prompt.

`configure` installs a `UNUserNotificationCenter` delegate that shows
Sequenzy pushes while the app is open and handles taps. If your app sets its
own delegate, call `Sequenzy.presentationOptions(for:)` and
`Sequenzy.handleNotificationResponse(_:)` from it. Implement
`SequenzyInAppDelegate` to veto messages (`sequenzyShouldShow`) or open links
yourself (`sequenzyHandle(url:from:)`).

```swift
// Notification Service Extension
import SequenzyNotificationService
class NotificationService: SequenzyNotificationServiceExtension {}
```

## Custom HTML messages

[Custom HTML in-app messages](https://docs.sequenzy.com/concepts/in-app-html-messages) (surveys, Braze-style custom HTML) show
automatically in a `WKWebView` with a private, non-persistent data store. Their
JavaScript bridge closes the message, opens links through
`SequenzyInAppDelegate`, and logs events and attributes for the identified
contact. Set `Sequenzy.showsHtmlMessages = false` before `configure` to leave
them in the feed, or use `fetchMessages(includeHtml: true)` to present them
yourself.

## Live Activities

Your backend starts (iOS 17.2+), updates and ends Live Activities through the
Sequenzy API, CLI or MCP. Link `SequenzyLiveActivities` to both the app and the
widget extension (it has no UIKit, so extensions can use it), adopt
`SequenzyLiveActivityAttributes` and observe each type right after `configure`.
The SDK reports push-to-start and update tokens, links them on `identify`,
reports activities that end, and on `reset()` ends the running activities so
the next person never sees them.

```swift
// DeliveryAttributes.swift, in both the app and the widget extension
import ActivityKit
import SequenzyLiveActivities

@available(iOS 16.1, *)
struct DeliveryAttributes: SequenzyLiveActivityAttributes {
    struct ContentState: Codable, Hashable { var status: String; var minutesAway: Int }
    var orderNumber: String
    var sequenzy: SequenzyLiveActivityData   // the id your backend uses
}
```

```swift
// AppDelegate.swift, right after Sequenzy.configure(...)
import Sequenzy

if #available(iOS 16.1, *) {
    Sequenzy.observeLiveActivities(of: DeliveryAttributes.self)
}
```

Activities the app starts itself need `pushType: .token` and
`sequenzy: SequenzyLiveActivityData(activityId: "order-1234")`. The
[Live Activities guide](https://docs.sequenzy.com/concepts/push-notifications#live-activities)
walks through the Xcode setup (widget extension, Info.plist, target
membership) and a first test on your iPhone.

## Geofencing

Link `SequenzyGeofences` to report when the signed-in contact enters or leaves
your [geofences](https://docs.sequenzy.com/concepts/geofences). It is a
separate product so apps without geofencing never link Core Location.

```swift
import SequenzyGeofences

// application(_:didFinishLaunchingWithOptions:), after configure; also runs
// on the background launches iOS makes for region events
SequenzyGeofences.shared.start()
// once the user agreed to location-based messages
SequenzyGeofences.shared.requestAuthorization()   // "When In Use", then "Always"
SequenzyGeofences.shared.enable()
SequenzyGeofences.shared.disable()                // consent withdrawn
```

Add `NSLocationWhenInUseUsageDescription` and
`NSLocationAlwaysAndWhenInUseUsageDescription` to Info.plist. Monitoring needs
"Always" access with precise location, and only identified contacts are
tracked. iOS watches 20 regions per app: the SDK registers the 19 nearest
geofences plus one region around the device and fetches again when the device
leaves it. Lower `maxRegions` if the app monitors regions of its own.

## Layout

| Target                        | Contents                                                        |
| ----------------------------- | --------------------------------------------------------------- |
| `SequenzyCore`                | Protocol client, identity, event queue, payload parsing. Foundation only; builds on Linux. |
| `Sequenzy`                    | UIKit facade, APNs, notification taps, Live Activity tokens, in-app presenter, privacy manifest |
| `SequenzyNotificationService` | Notification Service Extension base class                       |
| `SequenzyLiveActivities`      | `SequenzyLiveActivityAttributes` for your ActivityAttributes; extension-safe |
| `SequenzyGeofences`           | Core Location region monitoring for your geofences, privacy manifest |

## Develop

```bash
swift test                                    # macOS
docker run --rm -v "$PWD/..":/w -w /w/swift swift:6.0-jammy swift test   # Linux
cd Example && xcodegen && open SequenzyExample.xcodeproj
```

Tests run against `../contract/fixtures`. This repository is updated from Sequenzy's SDK
sources with every release.

## Links

- [Sequenzy](https://sequenzy.com): email marketing, push, SMS and in-app
  messages for SaaS, with automated sequences and AI-written emails.
- [Mobile SDK guide](https://docs.sequenzy.com/concepts/mobile-sdks)
- [Push notifications](https://docs.sequenzy.com/concepts/push-notifications)
  and [in-app messages](https://docs.sequenzy.com/concepts/in-app-messages)
- [Pricing](https://sequenzy.com/pricing)
- Other Sequenzy SDKs: [Android](https://github.com/Sequenzy/sequenzy-android), [React Native](https://github.com/Sequenzy/sequenzy-react-native), [Flutter](https://github.com/Sequenzy/sequenzy-flutter)
