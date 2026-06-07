import Foundation

/// Latency health status for pipeline metrics
enum LatencyStatus: String, Codable {
    case pass
    case warn
    case fail
    case unknown

    var emoji: String {
        switch self {
        case .pass: return "✅"
        case .warn: return "⚠️"
        case .fail: return "🔴"
        case .unknown: return "⏳"
        }
    }
}

/// Latency budget targets and classification for interview pipeline stages
struct LatencyBudget {
    /// ASR first partial < 800ms PASS, < 1500ms WARN, else FAIL
    static func asrFirstPartial(_ ms: Int?) -> LatencyStatus {
        guard let ms else { return .unknown }
        if ms < 800 { return .pass }
        if ms < 1500 { return .warn }
        return .fail
    }

    /// ASR best selected < 2500ms PASS, < 4000ms WARN, else FAIL
    static func asrBestSelected(_ ms: Int?) -> LatencyStatus {
        guard let ms else { return .unknown }
        if ms < 2500 { return .pass }
        if ms < 4000 { return .warn }
        return .fail
    }

    /// RAG retrieval < 300ms PASS, < 600ms WARN, else FAIL
    static func ragRetrieval(_ ms: Int?) -> LatencyStatus {
        guard let ms else { return .unknown }
        if ms < 300 { return .pass }
        if ms < 600 { return .warn }
        return .fail
    }

    /// First visible answer <= 1500ms PASS, <= 3000ms WARN, else FAIL
    static func firstVisible(_ ms: Int?) -> LatencyStatus {
        guard let ms else { return .unknown }
        if ms <= 1500 { return .pass }
        if ms <= 3000 { return .warn }
        return .fail
    }

    /// First visible key point <= 3000ms PASS, <= 5000ms WARN, else FAIL
    static func firstKeyPoint(_ ms: Int?) -> LatencyStatus {
        guard let ms else { return .unknown }
        if ms <= 3000 { return .pass }
        if ms <= 5000 { return .warn }
        return .fail
    }

    /// Full card <= 8000ms PASS, <= 12000ms WARN, else FAIL
    static func fullCard(_ ms: Int?) -> LatencyStatus {
        guard let ms else { return .unknown }
        if ms <= 8000 { return .pass }
        if ms <= 12000 { return .warn }
        return .fail
    }

    /// Background persistence should not affect visible UI; values here are diagnostic only.
    static func backgroundPersistence(_ ms: Int?) -> LatencyStatus {
        guard let ms else { return .unknown }
        if ms <= 500 { return .pass }
        if ms <= 2000 { return .warn }
        return .fail
    }

    /// Classify an average value using the same thresholds (converts Double to Int)
    static func asrFirstPartialAvg(_ ms: Double?) -> LatencyStatus {
        guard let ms else { return .unknown }
        return asrFirstPartial(Int(ms))
    }

    static func asrBestSelectedAvg(_ ms: Double?) -> LatencyStatus {
        guard let ms else { return .unknown }
        return asrBestSelected(Int(ms))
    }

    static func ragRetrievalAvg(_ ms: Double?) -> LatencyStatus {
        guard let ms else { return .unknown }
        return ragRetrieval(Int(ms))
    }

    static func firstVisibleAvg(_ ms: Double?) -> LatencyStatus {
        guard let ms else { return .unknown }
        return firstVisible(Int(ms))
    }

    static func firstKeyPointAvg(_ ms: Double?) -> LatencyStatus {
        guard let ms else { return .unknown }
        return firstKeyPoint(Int(ms))
    }

    static func fullCardAvg(_ ms: Double?) -> LatencyStatus {
        guard let ms else { return .unknown }
        return fullCard(Int(ms))
    }

    static func backgroundPersistenceAvg(_ ms: Double?) -> LatencyStatus {
        guard let ms else { return .unknown }
        return backgroundPersistence(Int(ms))
    }
}

/// Rolling latency averages with percentile breakdowns
struct LatencyAverages {
    let count: Int
    let avgFirstVisibleMS: Double?
    let p50FirstVisibleMS: Int?
    let p90FirstVisibleMS: Int?
    let avgFirstKeyPointVisibleMS: Double?
    let p50FirstKeyPointVisibleMS: Int?
    let p90FirstKeyPointVisibleMS: Int?
    let avgAllKeyPointsVisibleMS: Double?
    let avgFollowUpVisibleMS: Double?
    let avgFullCardMS: Double?
    let p50FullCardMS: Int?
    let p90FullCardMS: Int?
    let avgDBPersistedMS: Double?
    let avgStageBStreamStartedMS: Double?
    let avgStageBFirstSectionMS: Double?
    let avgRagRetrievalMS: Double?
    let avgASRBestSelectedMS: Double?
    let softFallbackRate: Double?   // 0.0-1.0
    let failureRate: Double?        // 0.0-1.0 (stage_b_status != 'completed')

    static let empty = LatencyAverages(
        count: 0,
        avgFirstVisibleMS: nil,
        p50FirstVisibleMS: nil,
        p90FirstVisibleMS: nil,
        avgFirstKeyPointVisibleMS: nil,
        p50FirstKeyPointVisibleMS: nil,
        p90FirstKeyPointVisibleMS: nil,
        avgAllKeyPointsVisibleMS: nil,
        avgFollowUpVisibleMS: nil,
        avgFullCardMS: nil,
        p50FullCardMS: nil,
        p90FullCardMS: nil,
        avgDBPersistedMS: nil,
        avgStageBStreamStartedMS: nil,
        avgStageBFirstSectionMS: nil,
        avgRagRetrievalMS: nil,
        avgASRBestSelectedMS: nil,
        softFallbackRate: nil,
        failureRate: nil
    )
}
