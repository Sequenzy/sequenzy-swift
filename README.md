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
await Sequenzy.requestPushAuthorization()
Sequenzy.reset()                               // on sign-out

let cards = try await Sequenzy.fetchCards()    // inbox screen
```

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

## Layout

| Target                        | Contents                                                        |
| ----------------------------- | --------------------------------------------------------------- |
| `SequenzyCore`                | Protocol client, identity, event queue, payload parsing. Foundation only; builds on Linux. |
| `Sequenzy`                    | UIKit facade, APNs, notification taps, in-app presenter, privacy manifest |
| `SequenzyNotificationService` | Notification Service Extension base class                       |

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
