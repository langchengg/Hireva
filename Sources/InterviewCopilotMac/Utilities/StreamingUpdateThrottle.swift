import Foundation

struct StreamingUpdateThrottle {
    let minimumInterval: TimeInterval
    let minimumCharacterDelta: Int

    private var lastPublishAt: Date?
    private var lastPublishedCharacterCount: Int = 0

    init(minimumInterval: TimeInterval = 0.075, minimumCharacterDelta: Int = 10) {
        self.minimumInterval = minimumInterval
        self.minimumCharacterDelta = minimumCharacterDelta
    }

    mutating func shouldPublish(characterCount: Int, now: Date = Date(), force: Bool = false) -> Bool {
        if force {
            record(characterCount: characterCount, now: now)
            return true
        }
        guard let lastPublishAt else {
            record(characterCount: characterCount, now: now)
            return true
        }
        let enoughCharacters = characterCount - lastPublishedCharacterCount >= minimumCharacterDelta
        let enoughTime = now.timeIntervalSince(lastPublishAt) >= minimumInterval
        guard enoughCharacters || enoughTime else { return false }
        record(characterCount: characterCount, now: now)
        return true
    }

    private mutating func record(characterCount: Int, now: Date) {
        lastPublishAt = now
        lastPublishedCharacterCount = characterCount
    }
}
