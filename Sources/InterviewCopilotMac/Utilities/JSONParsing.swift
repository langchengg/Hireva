import Foundation

enum JSONParsingError: LocalizedError {
    case noJSONObject
    case invalidData

    var errorDescription: String? {
        switch self {
        case .noJSONObject:
            return "The model response did not contain a JSON object."
        case .invalidData:
            return "The JSON response could not be decoded."
        }
    }
}

enum JSONParsing {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func decodeObject<T: Decodable>(_ type: T.Type, from content: String) throws -> T {
        let strictData = Data(content.utf8)
        if let decoded = try? decoder.decode(type, from: strictData) {
            return decoded
        }

        let json = try extractJSONObject(from: content)
        guard let data = json.data(using: .utf8) else {
            throw JSONParsingError.invalidData
        }
        if let decoded = try? decoder.decode(type, from: data) {
            return decoded
        }

        let repaired = repairJSONObject(json)
        guard let repairedData = repaired.data(using: .utf8) else {
            throw JSONParsingError.invalidData
        }
        return try decoder.decode(type, from: repairedData)
    }

    static func extractJSONObject(from content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        guard let start = trimmed.firstIndex(of: "{") else {
            throw JSONParsingError.noJSONObject
        }

        var depth = 0
        var inString = false
        var isEscaped = false
        var current = start

        while current < trimmed.endIndex {
            let character = trimmed[current]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(trimmed[start...current])
                    }
                }
            }
            current = trimmed.index(after: current)
        }

        if let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }

        throw JSONParsingError.noJSONObject
    }

    static func repairJSONObject(_ json: String) -> String {
        var repaired = json
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")

        repaired = repaired.replacingOccurrences(
            of: #",\s*([}\]])"#,
            with: "$1",
            options: .regularExpression
        )

        let openBraces = repaired.filter { $0 == "{" }.count
        let closeBraces = repaired.filter { $0 == "}" }.count
        if openBraces > closeBraces {
            repaired += String(repeating: "}", count: openBraces - closeBraces)
        }
        return repaired
    }

    static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    static func decodeArray<T: Decodable>(_ type: T.Type, from string: String) -> [T] {
        guard let data = string.data(using: .utf8),
              let values = try? decoder.decode([T].self, from: data) else {
            return []
        }
        return values
    }
}
