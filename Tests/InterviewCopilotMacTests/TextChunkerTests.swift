import Testing
@testable import InterviewCopilotMac

@Suite
struct TextChunkerTests {
    @Test
    func chunksSplitLongParagraphsAndExtractMeaningfulKeywords() {
        let text = """
        Robotics perception project using MuJoCo simulation, visual language model reranking, grasp candidate generation, and failure analysis for language-conditioned grasping.
        """

        let chunks = TextChunker.chunks(from: text, maxWords: 8)

        #expect(chunks.count > 1)
        #expect(chunks.flatMap(\.keywords).contains("robotics"))
        #expect(chunks.flatMap(\.keywords).contains("mujoco"))
        #expect(!chunks.flatMap(\.keywords).contains("and"))
    }
}
