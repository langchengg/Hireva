import Foundation

struct TextChunk {
    var content: String
    var keywords: [String]
    var sectionTitle: String?
    var wordCount: Int
    var metadataJSON: String?
}

enum TextChunker {
    static func chunks(from text: String, maxWords: Int = 140, overlapWords: Int = 30) -> [TextChunk] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var output: [TextChunk] = []
        var currentSectionTitle: String? = nil

        for paragraph in paragraphs {
            // Check if the entire paragraph is a section header
            if let detected = detectSectionHeader(paragraph) {
                currentSectionTitle = detected
                output.append(TextChunk(
                    content: paragraph,
                    keywords: keywords(in: paragraph),
                    sectionTitle: currentSectionTitle,
                    wordCount: paragraph.split(whereSeparator: \.isWhitespace).count,
                    metadataJSON: nil
                ))
                continue
            }

            // Check if first line is a section header (e.g. ## Projects\nDetail...)
            let lines = paragraph.components(separatedBy: "\n")
            var paragraphContent = paragraph
            if let firstLine = lines.first, let detected = detectSectionHeader(firstLine) {
                currentSectionTitle = detected
                if lines.count > 1 {
                    paragraphContent = lines[1...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    output.append(TextChunk(
                        content: firstLine,
                        keywords: keywords(in: firstLine),
                        sectionTitle: currentSectionTitle,
                        wordCount: firstLine.split(whereSeparator: \.isWhitespace).count,
                        metadataJSON: nil
                    ))
                } else {
                    continue
                }
            }

            let pWords = paragraphContent.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !pWords.isEmpty else { continue }

            if pWords.count <= maxWords {
                output.append(TextChunk(
                    content: paragraphContent,
                    keywords: keywords(in: paragraphContent),
                    sectionTitle: currentSectionTitle,
                    wordCount: pWords.count,
                    metadataJSON: nil
                ))
            } else {
                // Paragraph too long. Split into units, preserving bullet points if present.
                var units: [String] = []
                let hasBullets = lines.contains { isBulletLine($0) }
                if hasBullets {
                    for line in lines {
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedLine.isEmpty else { continue }
                        let lineWords = trimmedLine.split(whereSeparator: \.isWhitespace).count
                        if lineWords > maxWords {
                            units.append(contentsOf: splitIntoSentences(trimmedLine))
                        } else {
                            units.append(trimmedLine)
                        }
                    }
                } else {
                    units = splitIntoSentences(paragraphContent)
                }

                // If sentence splitting returns nothing or just 1 huge unit that exceeds maxWords, fall back to window splitting
                if units.isEmpty || (units.count == 1 && units[0].split(whereSeparator: \.isWhitespace).count > maxWords) {
                    var start = 0
                    while start < pWords.count {
                        let end = min(start + maxWords, pWords.count)
                        let content = pWords[start..<end].joined(separator: " ")
                        output.append(TextChunk(
                            content: content,
                            keywords: keywords(in: content),
                            sectionTitle: currentSectionTitle,
                            wordCount: end - start,
                            metadataJSON: nil
                        ))
                        start = max(end - overlapWords, start + 1)
                    }
                } else {
                    // Group units into chunks with carryover overlap
                    var startUnitIdx = 0
                    var carryoverWords: [String] = []

                    while startUnitIdx < units.count {
                        var currentChunkWords: [String] = carryoverWords
                        var endUnitIdx = startUnitIdx

                        while endUnitIdx < units.count {
                            let unitWords = units[endUnitIdx].split(whereSeparator: \.isWhitespace).map(String.init)
                            if currentChunkWords.count + unitWords.count <= maxWords || currentChunkWords.count == carryoverWords.count {
                                currentChunkWords.append(contentsOf: unitWords)
                                endUnitIdx += 1
                            } else {
                                break
                            }
                        }

                        let content = currentChunkWords.joined(separator: " ")
                        output.append(TextChunk(
                            content: content,
                            keywords: keywords(in: content),
                            sectionTitle: currentSectionTitle,
                            wordCount: currentChunkWords.count,
                            metadataJSON: nil
                        ))

                        if endUnitIdx == units.count {
                            break
                        }

                        // Carryover the trailing overlapWords for the next chunk
                        if overlapWords > 0 && currentChunkWords.count > overlapWords {
                            carryoverWords = Array(currentChunkWords.suffix(overlapWords))
                        } else {
                            carryoverWords = []
                        }

                        startUnitIdx = endUnitIdx
                    }
                }
            }
        }

        return output
    }

    static func detectSectionHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Starts with # or ##
        if trimmed.hasPrefix("##") {
            return trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("#") {
            return trimmed.dropFirst(1).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. ALL-CAPS word followed by a colon
        if trimmed.hasSuffix(":") {
            let headerText = trimmed.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if !headerText.isEmpty && headerText.allSatisfy({ $0.isLetter || $0.isWhitespace }) {
                let letters = headerText.filter { $0.isLetter }
                if !letters.isEmpty && letters.allSatisfy({ $0.isUppercase }) {
                    return headerText
                }
            }
        }

        // 3. Completely ALL-CAPS line and <= 4 words / 30 chars
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count <= 4 && trimmed.count <= 30 {
            let letters = trimmed.filter { $0.isLetter }
            if !letters.isEmpty && letters.allSatisfy({ $0.isUppercase }) {
                return trimmed
            }
        }

        return nil
    }

    static func isBulletLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") || trimmed.hasPrefix("•") {
            return true
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        if let firstPart = parts.first, firstPart.hasSuffix(".") {
            let numStr = firstPart.dropLast()
            if !numStr.isEmpty && numStr.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        let chars = Array(text)
        var i = 0
        var currentSentence = ""

        let abbrevs: Set<String> = [
            "e.g", "i.e", "dr", "mr", "mrs", "etc", "vs", "al", "st", "inc", "co",
            "approx", "dept", "min", "max", "prof", "sr", "jr", "corp", "assoc",
            "ave", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct",
            "nov", "dec"
        ]

        while i < chars.count {
            let char = chars[i]
            currentSentence.append(char)

            if char == "." || char == "!" || char == "?" {
                var isBoundary = false

                // Look ahead for closing punctuation: ", ', ), ], }
                var nextIdx = i + 1
                while nextIdx < chars.count {
                    let nextChar = chars[nextIdx]
                    if nextChar == "\"" || nextChar == "'" || nextChar == ")" || nextChar == "]" || nextChar == "}" {
                        nextIdx += 1
                    } else {
                        break
                    }
                }

                let isAtEnd = (nextIdx >= chars.count)
                let isFollowedByWhitespace = !isAtEnd && chars[nextIdx].isWhitespace

                if isAtEnd || isFollowedByWhitespace {
                    isBoundary = true

                    // Include any skipped closing punctuation in current sentence
                    while i + 1 < nextIdx {
                        i += 1
                        currentSentence.append(chars[i])
                    }

                    // Avoid splitting decimals e.g. "3.14"
                    if char == "." && i > 0 && i < chars.count - 1 && chars[i-1].isNumber && chars[i+1].isNumber {
                        isBoundary = false
                    }

                    // Avoid splitting abbreviations e.g. "e.g."
                    if char == "." && isBoundary {
                        var word = ""
                        var j = i - 1
                        while j >= 0 && (chars[j] == "\"" || chars[j] == "'" || chars[j] == ")" || chars[j] == "]" || chars[j] == "}") {
                            j -= 1
                        }
                        if j >= 0 && chars[j] == "." {
                            j -= 1
                        }
                        while j >= 0 {
                            let prevChar = chars[j]
                            if prevChar.isLetter || prevChar == "." || prevChar == "-" || prevChar == "&" {
                                word = String(prevChar) + word
                                j -= 1
                            } else {
                                break
                            }
                        }

                        let lowerWord = word.lowercased()
                        if abbrevs.contains(lowerWord) || abbrevs.contains(lowerWord.replacingOccurrences(of: ".", with: "")) {
                            isBoundary = false
                        } else if word.count == 1 && word.first?.isUppercase == true {
                            isBoundary = false
                        }
                    }
                }

                if isBoundary {
                    sentences.append(currentSentence.trimmingCharacters(in: .whitespacesAndNewlines))
                    currentSentence = ""
                }
            }
            i += 1
        }

        if !currentSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(currentSentence.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return sentences.filter { !$0.isEmpty }
    }

    static func keywords(in text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "are", "was", "were",
            "you", "your", "our", "will", "have", "has", "had", "about", "into", "can",
            "able", "using", "use", "used", "role", "work", "team", "job", "description"
        ]

        let tokens = tokenize(text)
        let counted = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
        return counted
            .filter { key, _ in key.count > 2 && !stopWords.contains(key) }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(24)
            .map(\.key)
    }

    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
