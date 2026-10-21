import Foundation

#if canImport(ActivityKit)
    import ActivityKit
#endif

/// What Sequenzy keeps in an activity's attributes: the id your backend
/// uses to update and end it. A remotely started activity gets it from the
/// start request; set it yourself when the app starts one.
public struct SequenzyLiveActivityData: Codable, Hashable, Sendable {
    public var activityId: String

    public init(activityId: String) {
        self.activityId = activityId
    }
}

#if canImport(ActivityKit) && canImport(UIKit)
    /// Adopt in your `ActivityAttributes` so Sequenzy can address the
    /// activity. This module has no UIKit dependency, so the widget extension
    /// that draws the activity can link it too:
    ///
    /// ```swift
    /// @available(iOS 16.1, *)
    /// struct DeliveryAttributes: SequenzyLiveActivityAttributes {
    ///     struct ContentState: Codable, Hashable { var status: String; var minutesAway: Int }
    ///     var orderNumber: String
    ///     var sequenzy: SequenzyLiveActivityData
    /// }
    /// ```
    @available(iOS 16.1, *)
    public protocol SequenzyLiveActivityAttributes: ActivityAttributes {
        var sequenzy: SequenzyLiveActivityData { get }
    }
#endif
