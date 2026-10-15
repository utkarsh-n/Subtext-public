import Foundation

/// Maps the wall clock onto media time: media = anchorMedia + (now − anchorWall) × rate.
struct PlaybackClock: Codable, Equatable {
    var anchorWall: Date
    var anchorMedia: Double
    var rate: Double
    var pausedAt: Double?

    init(media: Double = 0, at wall: Date = .now, rate: Double = 1, paused: Bool = true) {
        anchorWall = wall
        anchorMedia = media
        self.rate = rate
        pausedAt = paused ? media : nil
    }

    var isPaused: Bool { pausedAt != nil }

    func mediaTime(at wall: Date = .now) -> Double {
        if let pausedAt { return pausedAt }
        return anchorMedia + wall.timeIntervalSince(anchorWall) * rate
    }

    mutating func set(media: Double, at wall: Date = .now, rate: Double? = nil) {
        if let rate { self.rate = rate }
        anchorWall = wall
        anchorMedia = media
        if pausedAt != nil { pausedAt = media }
    }

    mutating func shift(by seconds: Double) {
        anchorMedia += seconds
        if let p = pausedAt { pausedAt = p + seconds }
    }

    mutating func pause(at wall: Date = .now) {
        guard pausedAt == nil else { return }
        pausedAt = mediaTime(at: wall)
    }

    mutating func resume(at wall: Date = .now) {
        guard let p = pausedAt else { return }
        anchorWall = wall
        anchorMedia = p
        pausedAt = nil
    }
}
