import Foundation
import os

enum DateCoding {
    // Non-Sendable formatters stay behind the lock; only String/Date values leave.
    private static let formatters = OSAllocatedUnfairLock(uncheckedState: {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return (fractional: fractional, regular: regular)
    }())

    static func string(from date: Date) -> String {
        formatters.withLock { $0.fractional.string(from: date) }
    }

    static func date(from string: String) -> Date {
        formatters.withLock { $0.fractional.date(from: string) ?? $0.regular.date(from: string) ?? Date() }
    }
}
