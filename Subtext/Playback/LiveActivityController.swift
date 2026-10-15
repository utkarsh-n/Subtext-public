import ActivityKit
import Foundation
import os

private let log = Logger(subsystem: "com.utkarsh.subtext", category: "LiveActivity")

@MainActor
final class LiveActivityController {
    typealias State = SubtextActivityAttributes.ContentState

    /// Updates closer than this are coalesced (trailing edge): states are absolute, so dropping
    /// intermediates is safe (docs/v2/island.md §2.3).
    static let minSpacing: TimeInterval = 0.25
    /// A transient phase (checking) that is followed by a final state gets that final state
    /// re-pushed this long later, in case the first push was dropped (docs/v2/checkin.md, unverified).
    static let rePushDelay: TimeInterval = 2.0

    private var activity: Activity<SubtextActivityAttributes>?
    private var lastState: State?
    private var lastStaleDate: Date?
    private var lastSentAt: Date = .distantPast
    private var pending: (state: State, attributes: SubtextActivityAttributes, staleDate: Date?)?
    private var flushTask: Task<Void, Never>?
    private var rePushTask: Task<Void, Never>?
    private var lastTransientAt: Date?

    var hasActivity: Bool {
        guard let activity else { return false }
        return activity.activityState == .active
    }

    func reattach() {
        activity = Activity<SubtextActivityAttributes>.activities.first { $0.activityState == .active }
    }

    func start(attributes: SubtextActivityAttributes, state: State, staleDate: Date? = nil) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.warning("Live Activities are disabled for Subtext")
            return
        }
        endAll()
        do {
            activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate))
            lastState = state
            lastStaleDate = staleDate
            lastSentAt = .now
            log.info("Started activity \(self.activity?.id ?? "nil", privacy: .public)")
        } catch {
            log.error("Activity request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pushes a state only when it (or the stale date) differs from the last one shown, and no
    /// sooner than `minSpacing` after the previous push.
    func update(state: State, attributes: SubtextActivityAttributes, staleDate: Date? = nil) {
        guard state != lastState || staleDate != lastStaleDate else { return }
        guard let activity, activity.activityState == .active else {
            start(attributes: attributes, state: state, staleDate: staleDate)
            return
        }
        let now = Date.now
        let gap = now.timeIntervalSince(lastSentAt)
        if gap >= Self.minSpacing {
            // A state waiting for the trailing edge is older than this one: drop it, or it
            // would be pushed after the newer state.
            pending = nil
            flushTask?.cancel()
            flushTask = nil
            send(state: state, staleDate: staleDate, to: activity)
        } else {
            pending = (state, attributes, staleDate)
            if flushTask == nil {
                let wait = Self.minSpacing - gap
                flushTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard let self, !Task.isCancelled else { return }
                    self.flushTask = nil
                    guard let p = self.pending else { return }
                    self.pending = nil
                    guard p.state != self.lastState || p.staleDate != self.lastStaleDate else { return }
                    if let a = self.activity, a.activityState == .active {
                        self.send(state: p.state, staleDate: p.staleDate, to: a)
                    } else {
                        self.start(attributes: p.attributes, state: p.state, staleDate: p.staleDate)
                    }
                }
            }
        }
    }

    private func send(state: State, staleDate: Date?, to activity: Activity<SubtextActivityAttributes>) {
        lastState = state
        lastStaleDate = staleDate
        lastSentAt = .now
        Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        rePushTask?.cancel()
        rePushTask = nil
        if state.phase == .checkingIn {
            lastTransientAt = .now
        } else if let t = lastTransientAt, Date.now.timeIntervalSince(t) < 10 {
            // A final state right after a transient one: re-push it once so a dropped update
            // cannot leave "checking" on the glass.
            lastTransientAt = nil
            rePushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.rePushDelay))
                guard let self, !Task.isCancelled, self.lastState == state,
                      let a = self.activity, a.activityState == .active else { return }
                self.lastSentAt = .now
                await a.update(ActivityContent(state: state, staleDate: staleDate))
            }
        }
    }

    /// Manual End: remove immediately. `endForInactivity` passes a final card and `.after(15 min)`.
    func end(final: State? = nil, dismissalPolicy: ActivityUIDismissalPolicy = .immediate) {
        flushTask?.cancel(); flushTask = nil
        rePushTask?.cancel(); rePushTask = nil
        pending = nil
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        lastStaleDate = nil
        lastTransientAt = nil
        let content = final.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await activity.end(content, dismissalPolicy: dismissalPolicy) }
    }

    private func endAll() {
        for stray in Activity<SubtextActivityAttributes>.activities {
            Task { await stray.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
