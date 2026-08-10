import Foundation
import Testing
@testable import Hireva

@Suite
struct ReleaseUnicodeSpanRegressionTests {
    @Test
    func splitterRangesRoundTripAgainstOriginalUnicodeSource() throws {
        let source = "🎯 İ e\u{301} 中文 preface.  What did you build with the café’s API?   How did you validate 中文 output? ✅"
        let sourceNSString = source as NSString
        let slices = MultiQuestionSplitter.splitWithRanges(source)

        #expect(slices.count == 2)
        let expectedTexts = [
            "What did you build with the café’s API?   ",
            "How did you validate 中文 output? ✅"
        ]
        let expectedStarts = [
            sourceNSString.range(of: "What did you build").location,
            sourceNSString.range(of: "How did you validate").location
        ]

        for (index, slice) in slices.enumerated() {
            #expect(slice.startUTF16 == expectedStarts[index])
            #expect(slice.startUTF16 >= 0)
            #expect(slice.endUTF16 <= sourceNSString.length)
            #expect(slice.startUTF16 < slice.endUTF16)
            guard slice.startUTF16 >= 0,
                  slice.endUTF16 <= sourceNSString.length,
                  slice.startUTF16 < slice.endUTF16 else {
                Issue.record("Invalid UTF-16 range: \(slice.startUTF16)..<\(slice.endUTF16)")
                continue
            }
            let range = NSRange(
                location: slice.startUTF16,
                length: slice.endUTF16 - slice.startUTF16
            )
            #expect(sourceNSString.substring(with: range) == slice.text)
            #expect(slice.text == expectedTexts[index])
        }
    }

    @Test
    func acceptedCandidateRangesReferToOriginalUncollapsedSource() throws {
        let source = "🎯 e\u{301} 中文 context.  What did you build with the café’s API?   How did you validate 中文 output? ✅"
        let sourceNSString = source as NSString
        let candidates = QuestionCandidatePipeline.extract(from: source, isFinal: true)
        let expectedSourceSlices = [
            "What did you build with the café’s API?",
            "How did you validate 中文 output?"
        ]

        #expect(candidates.count == expectedSourceSlices.count)
        for (index, candidate) in candidates.enumerated() {
            #expect(candidate.sourceStartUTF16 >= 0)
            #expect(candidate.sourceEndUTF16 <= sourceNSString.length)
            #expect(candidate.sourceStartUTF16 < candidate.sourceEndUTF16)
            guard candidate.sourceStartUTF16 >= 0,
                  candidate.sourceEndUTF16 <= sourceNSString.length,
                  candidate.sourceStartUTF16 < candidate.sourceEndUTF16 else {
                Issue.record("Invalid candidate UTF-16 range: \(candidate.sourceStartUTF16)..<\(candidate.sourceEndUTF16)")
                continue
            }
            let range = NSRange(
                location: candidate.sourceStartUTF16,
                length: candidate.sourceEndUTF16 - candidate.sourceStartUTF16
            )
            #expect(sourceNSString.substring(with: range) == expectedSourceSlices[index])
        }
    }
}
