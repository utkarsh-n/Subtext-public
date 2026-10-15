import Foundation

// Pure Foundation. Compiled into the app and into Tools/synctest (Subtext/Sync/Logic/**).
//
// Playback-rate estimate from (engine time, media time) points (docs/v2/checkin.md §6 with the
// critique's D8 rule):
//   • dense segments (≥ 6 points within the last 15 min) use V1's least-squares fit, moved here
//     verbatim from `SyncTracker.refitRate` (EMA 0.6/0.4, slope clamp 0.5…2, snap to 1);
//   • sparse segments (< 6 points, the locked-in case with one point per 30–300 s) use a
//     Theil–Sen slope over the last ≤ 8 points spanning ≥ 90 s;
//   • preset quantisation (|slope − preset| < 0.004) and stretch votes apply to both;
//   • `confirmed` = A's rule (≥ 6 points over ≥ 120 s) or two consecutive stretch votes.
// A hold/resume, seed, skip (any snap > 2 s) or re-acquire starts a new segment: the rate
// carries over as the prior, only the points reset.

struct RateEstimator: Equatable {
    struct Point: Equatable {
        var t: Date
        var media: Double
    }

    // Parameters (names and defaults = `SyncTracker.Tuning`; copied in `init(tuning:)`).
    var presets: [Double] = [1, 25 / 23.976, 23.976 / 25]
    var denseMinPoints = 6
    var denseMinSpanSeconds = 120.0
    var denseMaxSpanSeconds = 900.0
    var denseMaxPoints = 60
    var sparseMaxPoints = 8
    var sparseMinSpanSeconds = 90.0
    var presetTolerance = 0.004
    var freeSlopeFits = 3
    var stretchVotes = 2
    var confirmedMinPoints = 6
    var confirmedMinSpanSeconds = 120.0

    private(set) var rate: Double = 1
    private(set) var confirmed = false
    private(set) var points: [Point] = []
    /// Consecutive fits whose slope matched no preset (free slope adopted after `freeSlopeFits`).
    private(set) var freeFits = 0
    private(set) var lastVote: Double?
    private(set) var voteRun = 0
    /// The last raw fitted slope (debug line).
    private(set) var lastSlope: Double?
    private(set) var lastFit: Fit?
    /// Residual jitter σ_t of a single check-in in seconds (set from harness S10; drives a debug line only).
    var sigmaT = 0.1

    enum Fit: Equatable { case dense, sparse }

    init() {}

    init(tuning: SyncTracker.Tuning, speedWatching: Bool = false) {
        presets = tuning.searchRates
        if speedWatching { presets += [1.25, 1.5, 1.75, 2.0] }
        denseMinPoints = tuning.rateDenseMinPoints
        denseMaxSpanSeconds = tuning.rateDenseMaxSpanSeconds
        sparseMaxPoints = tuning.rateSparseMaxPoints
        sparseMinSpanSeconds = tuning.rateSparseMinSpanSeconds
        presetTolerance = tuning.ratePresetTolerance
        freeSlopeFits = tuning.rateFreeSlopeFits
        stretchVotes = tuning.rateStretchVotes
        confirmedMinPoints = tuning.rateConfirmedMinPoints
        confirmedMinSpanSeconds = tuning.rateConfirmedMinSpanSeconds
    }

    /// `σ_rate ≈ σ_t × √2 / baseline` over the current points (debug only).
    var sigma: Double {
        guard let first = points.first, let last = points.last else { return 0 }
        let baseline = last.t.timeIntervalSince(first.t)
        return baseline > 0 ? sigmaT * 2.0.squareRoot() / baseline : 0
    }

    var span: TimeInterval {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.t.timeIntervalSince(first.t)
    }

    // MARK: Inputs

    /// Starts a new segment: `rate` stays as the prior, points and vote run reset.
    mutating func newSegment() {
        points = []
        freeFits = 0
        lastVote = nil
        voteRun = 0
        lastSlope = nil
        lastFit = nil
    }

    /// Seeds the estimator from the tracker's V1 lock points on settle (dense history carried over).
    mutating func adopt(points: [(wall: Date, media: Double)], rate: Double, confirmed: Bool) {
        self.points = points.map { Point(t: $0.wall, media: $0.media) }
        self.rate = rate
        self.confirmed = confirmed
        freeFits = 0
    }

    /// Forces the rate (user speed setting, tracker lock rate on a re-acquire).
    mutating func set(rate: Double, confirmed: Bool) {
        self.rate = rate
        self.confirmed = confirmed
    }

    /// Adds a (time, media) point and refits. Returns true when `rate` changed.
    @discardableResult
    mutating func add(t: Date, media: Double) -> Bool {
        let before = rate
        points.append(Point(t: t, media: media))
        points.sort { $0.t < $1.t }
        // Dense = V1's retention policy: the last 15 min, at most 60 points.
        let cutoff = t.addingTimeInterval(-denseMaxSpanSeconds)
        let recent = points.filter { $0.t >= cutoff }
        if recent.count >= denseMinPoints {
            points = Array(recent.suffix(denseMaxPoints))
            fitDense()
        } else {
            fitSparse()
        }
        if points.count >= confirmedMinPoints, span >= confirmedMinSpanSeconds { confirmed = true }
        return abs(rate - before) > 1e-9
    }

    /// A stretch vote: the candidate rate with the best onsetZ at a check-in. Two consecutive
    /// votes for the same rate confirm it and, when it differs from `rate`, adopt it.
    /// Returns true when `rate` changed.
    @discardableResult
    mutating func vote(rate voted: Double) -> Bool {
        if let last = lastVote, abs(last - voted) < 1e-6 {
            voteRun += 1
        } else {
            lastVote = voted
            voteRun = 1
        }
        guard voteRun >= stretchVotes else { return false }
        confirmed = true
        guard abs(voted - rate) > 1e-9 else { return false }
        rate = voted
        freeFits = 0
        return true
    }

    // MARK: Fits

    /// V1 `SyncTracker.refitRate`, verbatim (the dense acquiring path; S13 keeps V1 numbers).
    private mutating func fitDense() {
        lastFit = .dense
        let lockPoints = points
        guard lockPoints.count >= 6, let first = lockPoints.first, let last = lockPoints.last,
              last.t.timeIntervalSince(first.t) >= 120 else { return }
        confirmed = true
        let xs = lockPoints.map { $0.t.timeIntervalSince(first.t) }
        let ys = lockPoints.map(\.media)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var cov = 0.0, varX = 0.0
        for i in 0..<xs.count {
            cov += (xs[i] - mx) * (ys[i] - my)
            varX += (xs[i] - mx) * (xs[i] - mx)
        }
        guard varX > 0 else { return }
        var slope = cov / varX
        slope = min(2.0, max(0.5, slope))
        lastSlope = slope
        if abs(slope - 1) < 0.004 { slope = 1 }
        rate = rate * 0.6 + slope * 0.4
        if abs(rate - 1) < 0.002 { rate = 1 }
        // Preset quantisation applies to both fits (critique D8).
        if let preset = nearestPreset(to: rate) { rate = preset }
    }

    /// Theil–Sen over the last ≤ 8 points spanning ≥ 90 s, preset-quantised, free slope only
    /// after `freeSlopeFits` consecutive non-preset fits.
    private mutating func fitSparse() {
        lastFit = .sparse
        let pts = Array(points.suffix(sparseMaxPoints))
        guard pts.count >= 2, let first = pts.first, let last = pts.last,
              last.t.timeIntervalSince(first.t) >= sparseMinSpanSeconds else { return }
        var slopes: [Double] = []
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let dt = pts[j].t.timeIntervalSince(pts[i].t)
                guard dt > 1 else { continue }
                slopes.append((pts[j].media - pts[i].media) / dt)
            }
        }
        guard !slopes.isEmpty else { return }
        slopes.sort()
        let m = slopes.count
        let median = m % 2 == 1 ? slopes[m / 2] : (slopes[m / 2 - 1] + slopes[m / 2]) / 2
        let slope = min(2.0, max(0.5, median))
        lastSlope = slope
        if let preset = nearestPreset(to: slope) {
            rate = preset
            freeFits = 0
        } else {
            freeFits += 1
            if freeFits >= freeSlopeFits { rate = slope }
        }
    }

    private func nearestPreset(to slope: Double) -> Double? {
        var best: (rate: Double, d: Double)?
        for p in presets {
            let d = abs(slope - p)
            if d < presetTolerance, best == nil || d < best!.d { best = (p, d) }
        }
        return best?.rate
    }
}
