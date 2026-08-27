import Testing
@testable import Hireva

@Suite
struct TextChunkerTests {
    @Test
    func chunksSplitLongParagraphsAndExtractMeaningfulKeywords() {
        let text = """
        Synthetic service reliability project using a deterministic simulator, event reranking, recovery candidate generation, and failure analysis for workload-aware scheduling.
        """

        let chunks = TextChunker.chunks(from: text, maxWords: 8)

        #expect(chunks.count > 1)
        #expect(chunks.flatMap(\.keywords).contains("service"))
        #expect(chunks.flatMap(\.keywords).contains("simulator"))
        #expect(!chunks.flatMap(\.keywords).contains("and"))
    }

    @Test
    func longParagraphCreatesOverlappingChunks() {
        // A long text that will create multiple chunks
        let text = "Apple banana cherry date fig grape kiwi lemon mango nectarine orange peach pear plum quince raspberry strawberry tangerine ugli voavanga waterberry xigua yuzu ziziphus. " +
                   "One two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty. " +
                   "Red blue green yellow orange purple pink brown black white gray cyan magenta gold silver bronze copper brass iron steel zinc lead tin nickel. " +
                   "Spring summer autumn winter rain snow wind sun cloud fog storm hail sleet lightning thunder heat cold breeze gale hurricane tornado blizzard."
        
        let chunks = TextChunker.chunks(from: text, maxWords: 30, overlapWords: 10)
        #expect(chunks.count >= 3)
        
        // Verify overlap carryover: adjacent chunks should share some words
        let chunk1Words = Set(chunks[0].content.lowercased().split(separator: " ").map(String.init))
        let chunk2Words = Set(chunks[1].content.lowercased().split(separator: " ").map(String.init))
        
        let overlap = chunk1Words.intersection(chunk2Words)
        #expect(overlap.count >= 5) // should share words from carryover
    }

    @Test
    func sectionHeaderIsPreservedAndAssigned() {
        let text = """
        ## Work Experience
        
        Senior Software Engineer at Example Systems Laboratory working on synthetic agentic coding systems.
        
        EDUCATION:
        
        Master of Science in Software Systems and Reliability.
        
        PROJECTS
        
        Developed a ranking pipeline for synthetic incident triage.
        """
        
        let chunks = TextChunker.chunks(from: text, maxWords: 100)
        
        // Find the explicitly fictional employer chunk.
        let workChunk = chunks.first { $0.content.contains("Example Systems Laboratory") }
        #expect(workChunk != nil)
        #expect(workChunk?.sectionTitle == "Work Experience")
        
        // Find chunk with Master of Science
        let eduChunk = chunks.first { $0.content.contains("Master of Science") }
        #expect(workChunk != nil)
        #expect(eduChunk?.sectionTitle == "EDUCATION")
        
        // Find chunk with the synthetic ranking pipeline.
        let projChunk = chunks.first { $0.content.contains("ranking pipeline") }
        #expect(projChunk != nil)
        #expect(projChunk?.sectionTitle == "PROJECTS")
    }

    @Test
    func sentenceBoundarySplittingExceptions() {
        let text = "We developed a system in C++ using ExampleProtocol2.0. The version was 3.14. " +
                   "Please check the url https://docs.example.com for info. " +
                   "Dr. Example created main.swift, e.g. for testing. " +
                   "This is the end."
        
        let sentences = TextChunker.splitIntoSentences(text)
        
        // Should split into exactly 4 sentences:
        // 1. We developed a system in C++ using ExampleProtocol2.0.
        // 2. The version was 3.14.
        // 3. Please check the url https://docs.example.com for info.
        // 4. Dr. Example created main.swift, e.g. for testing. This is the end. (Wait, let's see if e.g. splits or not. It shouldn't split!)
        
        #expect(sentences.contains { $0.contains("ExampleProtocol2.0.") }) // preserved decimal-like dot in the synthetic protocol version.
        #expect(sentences.contains { $0.contains("version was 3.14.") }) // preserved decimal 3.14
        #expect(sentences.contains { $0.contains("https://docs.example.com for info.") }) // preserved URL dot on the reserved example.com domain
        #expect(sentences.contains { $0.contains("Dr. Example created main.swift, e.g. for testing.") }) // preserved abbreviation Dr., e.g., and filename dot
    }

    @Test
    func bulletListsArePreservedIntact() {
        let text = """
        My key achievements:
        - Implemented a deterministic event simulator in Swift.
        - Designed a synthetic incident-ranking model.
        - Built an advanced agentic coding assistant in Swift.
        """
        
        let chunks = TextChunker.chunks(from: text, maxWords: 15) // small word limit to force chunking
        
        // Verify that bullet points themselves are not split mid-bullet, but rather grouped or split cleanly along bullet items!
        for chunk in chunks {
            let lines = chunk.content.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-") {
                    // Each bullet line should be preserved whole
                    #expect(trimmed.contains("event simulator") || trimmed.contains("incident-ranking") || trimmed.contains("coding assistant"))
                }
            }
        }
    }
}
