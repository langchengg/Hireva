import Foundation

public struct DocumentTextSanitizer {
    public struct Result {
        public let originalContent: String
        public let sanitizedContent: String
        public let sanitizedPreview: String
        public let sanitizationWarnings: [String]
        public let wasSanitized: Bool
    }
    
    // Set of known formatting commands where we DO preserve the argument content
    private static let formattingCommands: Set<String> = [
        "textbf", "textit", "section", "subsection", "subsubsection", "underline", "emph", "title", "author", "mbox", "hypertarget"
    ]
    
    // Set of known LaTeX preamble/layout commands that we discard completely (including their arguments)
    private static let discardCommands: Set<String> = [
        "documentclass", "usepackage", "geometry", "hypersetup", "definecolor", "pagestyle", "thispagestyle",
        "color", "colorlet", "selectfont", "setlength", "addtolength", "fancyhead", "fancyfoot", "fancyhf",
        "pagenumbering", "RequirePackage", "ProvidesClass", "LoadClass", "DeclareOption", "ProcessOptions",
        "titleformat", "titlespacing"
    ]
    
    // Set of layout commands without arguments to strip
    private static let discardParameterless: Set<String> = [
        "hfill", "vspace", "hspace", "noindent", "centering", "small", "large", "Huge", "normalsize",
        "pagebreak", "newline", "clearpage", "vfill", "large", "footnotesize", "scriptsize", "tiny",
        "Large", "LARGE", "huge", "Huge"
    ]
    
    public static func sanitize(_ content: String) -> Result {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Result(
                originalContent: content,
                sanitizedContent: content,
                sanitizedPreview: "",
                sanitizationWarnings: [],
                wasSanitized: false
            )
        }
        
        var warnings: [String] = []
        var text = trimmed
        var wasSanitized = false
        
        // Strip LaTeX comment lines and inline resume separators such as
        // "%----". These should never become RAG chunks or speakable answer text.
        if let regex = try? NSRegularExpression(pattern: #"(?m)[ \t]*%-{3,}.*$"#, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            if stripped != text {
                text = stripped
                warnings.append("LaTeX separator comments removed")
                wasSanitized = true
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*%.*(?:\n|$)"#, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            if stripped != text {
                text = stripped
                warnings.append("LaTeX comment lines removed")
                wasSanitized = true
            }
        }
        
        // 1. Strip everything before \begin{document} if present
        if let beginRange = text.range(of: "\\begin{document}") {
            text = String(text[beginRange.upperBound...])
            warnings.append("LaTeX preamble and document tags removed")
            wasSanitized = true
        }
        
        // Strip \end{document} and everything after
        if let endRange = text.range(of: "\\end{document}") {
            text = String(text[..<endRange.lowerBound])
            wasSanitized = true
        }
        
        // Let's implement our robust state-machine scanner to parse commands, arguments, and plain text
        var resultText = ""
        let chars = Array(text)
        var i = 0
        
        while i < chars.count {
            let char = chars[i]
            
            // Handle double backslash (newline in LaTeX)
            if char == "\\" && i + 1 < chars.count && chars[i+1] == "\\" {
                resultText.append("\n")
                i += 2
                wasSanitized = true
                continue
            }
            
            // Handle standard LaTeX escaped characters: \&, \%, \$, \_, \#, \{, \}
            if char == "\\" && i + 1 < chars.count && ["&", "%", "$", "_", "#", "{", "}"].contains(String(chars[i+1])) {
                resultText.append(chars[i+1])
                i += 2
                wasSanitized = true
                continue
            }
            
            // Handle general LaTeX command: \command
            if char == "\\" && i + 1 < chars.count && chars[i+1].isLetter {
                // Parse command name
                i += 1
                var cmdName = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "*") {
                    cmdName.append(chars[i])
                    i += 1
                }
                
                // Scan for consecutive arguments enclosed in curly braces {...}
                var arguments: [String] = []
                while i < chars.count {
                    // Skip optional parameters in bracket like [10pt] or [left=0.4in]
                    if chars[i] == "[" {
                        i += 1
                        var bracketDepth = 1
                        while i < chars.count && bracketDepth > 0 {
                            if chars[i] == "[" { bracketDepth += 1 }
                            else if chars[i] == "]" { bracketDepth -= 1 }
                            i += 1
                        }
                        continue
                    }
                    
                    // Check if followed by spaces/newlines before curly brace
                    let originalIdx = i
                    while i < chars.count && chars[i].isWhitespace {
                        i += 1
                    }
                    
                    if i < chars.count && chars[i] == "{" {
                        i += 1
                        var braceDepth = 1
                        var argContent = ""
                        while i < chars.count && braceDepth > 0 {
                            let c = chars[i]
                            if c == "{" { braceDepth += 1 }
                            else if c == "}" { braceDepth -= 1 }
                            if braceDepth > 0 {
                                argContent.append(c)
                            }
                            i += 1
                        }
                        arguments.append(argContent)
                    } else {
                        // Not followed by brace, restore index and stop searching for arguments
                        i = originalIdx
                        break
                    }
                }
                
                // Process command and its arguments
                let cmdLower = cmdName.lowercased()
                
                if cmdLower == "begin" || cmdLower == "end" {
                    // Itemize/enumerate environments tags - discard the command, process nothing, keep scanning
                    wasSanitized = true
                } else if cmdLower == "item" {
                    // List item
                    resultText.append("• ")
                    wasSanitized = true
                } else if cmdLower == "href" {
                    // Format \href{url}{text} -> text (url)
                    if arguments.count >= 2 {
                        resultText.append("\(arguments[1]) (\(arguments[0]))")
                    } else if arguments.count == 1 {
                        resultText.append(arguments[0])
                    }
                    wasSanitized = true
                } else if cmdLower == "url" {
                    if !arguments.isEmpty {
                        resultText.append(arguments[0])
                    }
                    wasSanitized = true
                } else if discardCommands.contains(cmdLower) {
                    // Discard completely
                    wasSanitized = true
                } else if formattingCommands.contains(cmdLower) {
                    // Preserve argument content, recursively sanitize them
                    for arg in arguments {
                        let subSanitized = sanitize(arg).sanitizedContent
                        resultText.append(subSanitized)
                    }
                    wasSanitized = true
                } else if discardParameterless.contains(cmdLower) {
                    // Parameterless discard
                    wasSanitized = true
                } else {
                    // Unknown or custom command like \rSubsection
                    // Extract and preserve all its arguments as plain text
                    var cleanArgs: [String] = []
                    for arg in arguments {
                        let subSanitized = sanitize(arg).sanitizedContent
                        if !subSanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            cleanArgs.append(subSanitized)
                        }
                    }
                    if !cleanArgs.isEmpty {
                        // Join arguments with space
                        resultText.append(" " + cleanArgs.joined(separator: " ") + " ")
                    }
                    wasSanitized = true
                }
                continue
            }
            
            // Append ordinary character
            resultText.append(char)
            i += 1
        }
        
        // Remove curly braces remaining in text if any
        resultText = resultText.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        
        // Normalize whitespaces and consecutive newlines (3+ newlines to exactly 2, consecutive spaces to exactly 1)
        if let regex = try? NSRegularExpression(pattern: "\\n{3,}", options: []) {
            let range = NSRange(resultText.startIndex..<resultText.endIndex, in: resultText)
            resultText = regex.stringByReplacingMatches(in: resultText, options: [], range: range, withTemplate: "\n\n")
        }
        if let regex = try? NSRegularExpression(pattern: "[ \\t]+", options: []) {
            let range = NSRange(resultText.startIndex..<resultText.endIndex, in: resultText)
            resultText = regex.stringByReplacingMatches(in: resultText, options: [], range: range, withTemplate: " ")
        }
        
        let sanitized = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if wasSanitized && sanitized != trimmed {
            warnings.append("LaTeX raw formatting commands stripped")
        } else {
            wasSanitized = false
        }
        
        let previewLimit = min(200, sanitized.count)
        let preview = String(sanitized.prefix(previewLimit))
        
        return Result(
            originalContent: content,
            sanitizedContent: sanitized,
            sanitizedPreview: preview,
            sanitizationWarnings: warnings,
            wasSanitized: wasSanitized
        )
    }
}
