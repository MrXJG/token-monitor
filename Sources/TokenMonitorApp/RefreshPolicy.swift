import Foundation

enum RefreshPolicy {
    static let presets: [Double] = [10, 30, 60, 300]
    static let defaultSeconds = 60.0
    static let minimumSeconds = 5.0
    static let recommendedSeconds = 15.0
    static let maximumSeconds = 86_400.0

    static func isValid(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds.rounded() == seconds &&
            (minimumSeconds...maximumSeconds).contains(seconds)
    }

    static func parse(_ text: String) -> Double? {
        guard let seconds = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              isValid(Double(seconds)) else { return nil }
        return Double(seconds)
    }

    static func title(for seconds: Double) -> String {
        seconds == 300 ? "5 分钟" : "\(Int(seconds)) 秒"
    }
}

struct RefreshBackoff {
    private(set) var blockedUntil: Date?
    private var lastDelay = 0.0

    mutating func register(retryAfter: TimeInterval?, interval: TimeInterval, now: Date = Date()) -> TimeInterval {
        let fallback = min(max(RefreshPolicy.recommendedSeconds, interval * 2, lastDelay * 2), 900)
        let serverDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        let delay = max(fallback, serverDelay)
        lastDelay = delay
        blockedUntil = now.addingTimeInterval(delay)
        return delay
    }

    func remaining(now: Date = Date()) -> TimeInterval {
        max(0, blockedUntil?.timeIntervalSince(now) ?? 0)
    }

    mutating func reset() {
        blockedUntil = nil
        lastDelay = 0
    }
}
