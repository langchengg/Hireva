import Foundation

enum SSEEvent: Equatable {
    case token(String)
    case usage(promptTokens: Int, completionTokens: Int, totalTokens: Int, cachedPromptTokens: Int)
}

struct SSEParser {
    private var buffer = ""
    
    mutating func append(_ text: String) -> [SSEEvent] {
        buffer += text
        var events: [SSEEvent] = []
        
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newlineIndex])
            buffer.removeSubrange(..<buffer.index(after: newlineIndex))
            
            if let event = parseLine(line) {
                events.append(event)
            }
        }
        
        return events
    }
    
    func parseLine(_ line: String) -> SSEEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasPrefix(":") { return nil } // Ignore keep-alive comments
        
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return nil }
        
        guard let data = payload.data(using: .utf8) else { return nil }
        
        struct ResilientDeltaChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    var role: String?
                    var content: String?
                }
                var delta: Delta?
            }
            var choices: [Choice]?
            
            struct Usage: Decodable {
                var prompt_tokens: Int?
                var completion_tokens: Int?
                var total_tokens: Int?
                var prompt_tokens_details: PromptTokensDetails?
                struct PromptTokensDetails: Decodable {
                    var cached_tokens: Int?
                }
            }
            var usage: Usage?
        }
        
        guard let decoded = try? JSONDecoder().decode(ResilientDeltaChunk.self, from: data) else {
            return nil
        }
        
        // 1. Check for token content
        if let choices = decoded.choices {
            for choice in choices {
                if let content = choice.delta?.content, !content.isEmpty {
                    return .token(content)
                }
            }
        }
        
        // 2. Check for usage info
        if let usage = decoded.usage {
            let prompt = usage.prompt_tokens ?? 0
            let completion = usage.completion_tokens ?? 0
            let total = usage.total_tokens ?? 0
            let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
            return .usage(promptTokens: prompt, completionTokens: completion, totalTokens: total, cachedPromptTokens: cached)
        }
        
        return nil
    }
}
