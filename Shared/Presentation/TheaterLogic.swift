import Foundation

// Foundation only: compiled into the app and the macOS harness. The Theater's gesture maths
// (docs/v2/island.md §1.7) with no SwiftUI, so the harness can assert on it (P8, P9).

enum TheaterLogic {
    /// 0.1 s of trim per 16 pt of horizontal drag → 160 pt per second.
    static let pointsPerDetent: Double = 16
    static let trimClamp: Double = 30
    /// One reel row per 56 pt of vertical drag.
    static let pointsPerCue: Double = 56
    /// Long-press thresholds.
    static let relistenHoldSeconds: Double = 0.6
    static let resyncHoldSeconds: Double = 1.5
    static let undoWindowSeconds: Double = 3
    static let chromeHideSeconds: Double = 3
    static let hudSeconds: Double = 1.4
    static let reelDecaySeconds: Double = 4

    /// Drag left = lines sooner (negative), same as the scrub wheel. Snapped to 0.1 s detents and
    /// clamped to ±`trimClamp`. `detent` is the value in tenths, for detent-change haptics.
    static func trim(startTrim: Double, translationX: Double) -> (value: Double, detent: Int) {
        let raw = startTrim - translationX / pointsPerDetent / 10
        // floor(x + 0.5) rather than schoolbook rounding: ties round the same way on both sides
        // of zero, so every detent is exactly 16 pt wide (schoolbook makes the zero detent 14 pt).
        let snapped = max(-trimClamp, min(trimClamp, (raw * 10 + 0.5).rounded(.down) / 10))
        // Normalise −0.0 so "0.0s" compares equal everywhere.
        let value = snapped == 0 ? 0 : snapped
        return (value, Int((value * 10).rounded()))
    }

    /// True when a detent step lands on zero or jumps across it (the alignment haptic). Leaving
    /// zero is an ordinary detent, so passing 0 fires exactly once per direction.
    static func crossedZero(from a: Double, to b: Double) -> Bool {
        if b == 0 { return a != 0 }
        if a == 0 { return false }
        return (a < 0) != (b < 0)
    }

    enum Role: Equatable, Sendable { case past, current, next, later }

    struct ReelRow: Equatable, Sendable {
        let cueIndex: Int
        let role: Role
    }

    struct Reel: Equatable, Sendable {
        /// Up to three rows: past, current (absent between lines when `offset == 0`), next.
        var rows: [ReelRow]
        /// The cue on screen now (nil between lines, or when a reel drag moved the centre).
        var current: Int?
        /// The line that follows.
        var next: Int?
        /// The row the reel is centred on; `jump(to:)` target when a reel drag ends.
        var centre: Int?

        func row(_ role: Role) -> Int? { rows.first { $0.role == role }?.cueIndex }
    }

    /// Rows around `media`, shifted by `offset` cues during a vertical reel drag. While not
    /// placed every slot is empty (black stage). With `offset == 0` the current slot is empty
    /// between lines and stays reserved; with an offset the centre row is drawn as current.
    static func reel(track: some IslandCueSource, media: Double, placed: Bool, offset: Int) -> Reel {
        guard placed, track.cueCount > 0 else { return Reel(rows: [], current: nil, next: nil, centre: nil) }
        let count = track.cueCount
        let current = track.cueIndex(at: media)
        let following: Int? = {
            if let c = current { return track.nextCueIndex(after: track.cueEnd(c) - 0.001).flatMap { $0 > c ? $0 : nil } }
            return track.nextCueIndex(after: media)
        }()
        if offset == 0 {
            var rows: [ReelRow] = []
            let anchor = current ?? following ?? count
            let past = anchor - 1
            if past >= 0 { rows.append(ReelRow(cueIndex: past, role: .past)) }
            if let c = current { rows.append(ReelRow(cueIndex: c, role: .current)) }
            if let n = following { rows.append(ReelRow(cueIndex: n, role: .next)) }
            return Reel(rows: rows, current: current, next: following, centre: current)
        }
        // Dragging the reel: the centre row is anchor + offset. Between lines the anchor is the
        // line that follows, so one row down from "nothing" is that next line.
        let base = current ?? ((following ?? count) - (offset > 0 ? 1 : 0))
        let centre = max(0, min(count - 1, base + offset))
        var rows: [ReelRow] = []
        if centre - 1 >= 0 { rows.append(ReelRow(cueIndex: centre - 1, role: .past)) }
        rows.append(ReelRow(cueIndex: centre, role: .current))
        if centre + 1 < count { rows.append(ReelRow(cueIndex: centre + 1, role: .next)) }
        return Reel(rows: rows, current: current, next: following, centre: centre)
    }

    /// Drag down (positive dy) = earlier line: −1 cue per +56 pt, 0 for |dy| < 28.
    static func reelOffset(translationY: Double) -> Int {
        Int((-translationY / pointsPerCue).rounded())
    }

    /// Theater text sizes (points of the current line), `theater.textSize`.
    enum TextSize: String, CaseIterable, Sendable {
        case medium, large, xl
        var points: Double {
            switch self {
            case .medium: 30
            case .large: 38
            case .xl: 48
            }
        }
        var label: String {
            switch self {
            case .medium: "Medium"
            case .large: "Large"
            case .xl: "Extra large"
            }
        }
    }

    /// "mm:ss" for the reel sheet.
    static func clockLabel(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
