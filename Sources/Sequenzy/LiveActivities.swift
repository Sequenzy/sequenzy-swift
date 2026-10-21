#if canImport(ActivityKit) && canImport(UIKit)
    import ActivityKit
    import Foundation
    @_exported import SequenzyLiveActivities

    @available(iOS 16.1, *)
    @MainActor
    enum LiveActivityObserver {
        static var observedTypes: Set<String> = []
        /// Token stream of each running activity, by ActivityKit id; cancelled
        /// when the activity ends.
        static var watched: [String: Task<Void, Never>] = [:]
        /// Latest update token per running activity, to skip repeats and to
        /// report its end.
        static var tokens: [String: String] = [:]
        /// Latest push-to-start token per activity type, to skip repeats.
        static var pushToStartTokens: [String: String] = [:]
        /// Ends every running activity of one observed type.
        static var enders: [@MainActor () async -> Void] = []

        static func report(_ token: LiveActivityToken) {
            guard let client = Sequenzy.requireClient() else { return }
            Sequenzy.enqueue { await client.registerLiveActivityToken(token) }
        }

        static func reportPushToStart(_ data: Data, typeName: String) {
            let token = LiveActivityToken(kind: .pushToStart, activityType: typeName, token: data)
            // The stream yields the current token again after we read it.
            guard pushToStartTokens[typeName] != token.token else { return }
            pushToStartTokens[typeName] = token.token
            report(token)
        }

        static func reportUpdate(_ token: LiveActivityToken, activity id: String) {
            guard tokens[id] != token.token else { return }
            tokens[id] = token.token
            report(token)
        }

        static func reportEnded(activity id: String, pushToken: Data?) {
            watched.removeValue(forKey: id)?.cancel()
            let known = tokens.removeValue(forKey: id)
            let fallback = pushToken.map { data in data.map { String(format: "%02x", $0) }.joined() }
            guard let token = known ?? fallback, let client = Sequenzy.requireClient() else { return }
            Sequenzy.enqueue { await client.liveActivityEnded(token: token) }
        }

        static func watch<Attributes: SequenzyLiveActivityAttributes>(
            _ activity: Activity<Attributes>, typeName: String
        ) {
            guard watched[activity.id] == nil else { return }
            // An activity that ended or was dismissed while the app was not
            // running never reports the change; it only shows its state.
            if activity.activityState == .ended || activity.activityState == .dismissed {
                reportEnded(activity: activity.id, pushToken: activity.pushToken)
                return
            }
            let activityId = activity.attributes.sequenzy.activityId
            let update = { (data: Data) in
                reportUpdate(
                    LiveActivityToken(kind: .update, activityType: typeName, activityId: activityId, token: data),
                    activity: activity.id)
            }
            if let data = activity.pushToken { update(data) }
            watched[activity.id] = Task { @MainActor in
                for await data in activity.pushTokenUpdates { update(data) }
            }
            Task { @MainActor in
                for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                    reportEnded(activity: activity.id, pushToken: activity.pushToken)
                    break
                }
            }
        }

        /// Stored update tokens of activities that are gone (they ended while
        /// the app was not running) are reported ended and forgotten.
        static func forgetVanished(typeName: String, runningActivityIds: Set<String>) {
            guard let client = Sequenzy.requireClient() else { return }
            Sequenzy.enqueue {
                for token in await client.liveActivityTokens
                where token.kind == .update && token.activityType == typeName
                    && !runningActivityIds.contains(token.activityId ?? "")
                {
                    await client.liveActivityEnded(token: token.token)
                }
            }
        }

        static func endAll() async {
            for end in enders { await end() }
        }
    }

    extension Sequenzy {
        /// Reports ActivityKit tokens for one `ActivityAttributes` type so
        /// your backend can start (iOS 17.2+), update and end its activities
        /// through Sequenzy. Call once per type, right after `configure`, in
        /// `application(_:didFinishLaunchingWithOptions:)`: iOS launches the
        /// app in the background when a push starts an activity, and the new
        /// activity's update token is reported from there.
        ///
        /// Activities your app starts itself need `pushType: .token` in
        /// `Activity.request` and a `sequenzy` attribute with your id.
        /// `reset()` ends the running activities of every observed type, so
        /// the next person on the device never sees the previous one's.
        @available(iOS 16.1, *)
        public static func observeLiveActivities<Attributes: SequenzyLiveActivityAttributes>(
            of type: Attributes.Type
        ) {
            guard requireClient() != nil else { return }
            let typeName = String(describing: type)
            guard LiveActivityObserver.observedTypes.insert(typeName).inserted else { return }

            if #available(iOS 17.2, *) {
                if let data = Activity<Attributes>.pushToStartToken {
                    LiveActivityObserver.reportPushToStart(data, typeName: typeName)
                }
                Task { @MainActor in
                    for await data in Activity<Attributes>.pushToStartTokenUpdates {
                        LiveActivityObserver.reportPushToStart(data, typeName: typeName)
                    }
                }
            }
            let running = Activity<Attributes>.activities
            for activity in running {
                LiveActivityObserver.watch(activity, typeName: typeName)
            }
            LiveActivityObserver.forgetVanished(
                typeName: typeName,
                runningActivityIds: Set(
                    running.filter { $0.activityState != .ended && $0.activityState != .dismissed }
                        .map { $0.attributes.sequenzy.activityId }))
            Task { @MainActor in
                for await activity in Activity<Attributes>.activityUpdates {
                    LiveActivityObserver.watch(activity, typeName: typeName)
                }
            }
            LiveActivityObserver.enders.append {
                for activity in Activity<Attributes>.activities {
                    if #available(iOS 16.2, *) {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    } else {
                        await activity.end(using: nil, dismissalPolicy: .immediate)
                    }
                }
            }
        }

        /// Ends the running activities of the observed types before `reset`.
        static func endLiveActivitiesForReset() async {
            if #available(iOS 16.1, *) {
                await LiveActivityObserver.endAll()
            }
        }
    }
#endif
