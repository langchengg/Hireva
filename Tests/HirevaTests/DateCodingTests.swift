import Foundation
import Testing
@testable import Hireva

struct DateCodingTests {
    @Test(arguments: [
        ("1970-01-01T00:00:01.125Z", 1.125),
        ("1970-01-01T01:00:01.125+01:00", 1.125),
        ("1969-12-31T23:00:01.125-01:00", 1.125),
        ("1970-01-01T00:00:01Z", 1.0),
        ("1969-12-31T23:59:59.000Z", -1.0)
    ])
    func storedTimestampFormatsRemainReadable(value: String, seconds: Double) {
        #expect(abs(DateCoding.date(from: value).timeIntervalSince1970 - seconds) < 0.00001)
    }

    @Test
    func storedOutputKeepsUTCAndMilliseconds() {
        #expect(DateCoding.string(from: Date(timeIntervalSince1970: 1.125)) == "1970-01-01T00:00:01.125Z")
        #expect(DateCoding.string(from: Date(timeIntervalSince1970: -1)) == "1969-12-31T23:59:59.000Z")
    }

    @Test
    func invalidStoredDateKeepsExistingCurrentDateFallback() {
        let before = Date()
        let result = DateCoding.date(from: "invalid stored date")
        #expect(result >= before && result <= Date())
    }

    @Test
    func concurrentRepositoryTimestampConversionsDoNotMixValues() async {
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<128 {
                group.addTask {
                    let date = Date(timeIntervalSince1970: Double(index) + 0.125)
                    let encoded = DateCoding.string(from: date)
                    return abs(DateCoding.date(from: encoded).timeIntervalSince(date)) < 0.00001
                }
            }
            for await valid in group { #expect(valid) }
        }
    }
}
