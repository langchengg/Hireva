import Foundation
import PDFKit
import Vision
import AppKit
import CryptoKit
import ZIPFoundation

struct ExtractedMaterial: Codable, Equatable {
    struct Section: Codable, Equatable { var location: String; var text: String; var method: String }
    var filename: String
    var sha256: String
    var sections: [Section]
    var warnings: [String]
    var text: String { sections.map { "[\($0.location)]\n\($0.text)" }.joined(separator: "\n\n") }
}

enum MaterialError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// VNRequest supports cancellation from outside its synchronous perform call.
/// This token links Swift task cancellation to the active native OCR request.
final class MaterialExtractionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func install(_ request: VNRequest) throws {
        lock.lock()
        if cancelled { lock.unlock(); request.cancel(); throw CancellationError() }
        self.request = request
        lock.unlock()
    }
    func clear() { lock.lock(); request = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let current = request; lock.unlock()
        current?.cancel()
    }
    func check() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }
}

/// Bounded extraction only. No embedded links, macros, XML entities or archive
/// entries are executed or written to disk. The original stays available to review.
enum MaterialExtractionService {
    static let maxFileBytes = 20 * 1_024 * 1_024
    static let maxTextBytes = 2 * 1_024 * 1_024
    static let supportedExtensions = ["txt", "md", "markdown", "pdf", "docx", "png", "jpg", "jpeg", "tiff", "heic"]

    static func extractCancellable(url: URL) async throws -> (ExtractedMaterial, Data) {
        let cancellation = MaterialExtractionCancellation()
        let worker = Task.detached(priority: .utility) { try extract(url: url, cancellation: cancellation) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { cancellation.cancel(); worker.cancel() })
    }
    static func extractCancellable(data: Data, filename: String) async throws -> ExtractedMaterial {
        let cancellation = MaterialExtractionCancellation()
        let worker = Task.detached(priority: .utility) { try extract(data: data, filename: filename, cancellation: cancellation) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { cancellation.cancel(); worker.cancel() })
    }

    static func extract(url: URL, cancellation: MaterialExtractionCancellation? = nil) throws -> (ExtractedMaterial, Data) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maxFileBytes else { throw MaterialError.invalid("Empty file or file exceeds 20 MB.") }
        let data = try Data(contentsOf: url)
        return (try extract(data: data, filename: url.lastPathComponent, cancellation: cancellation), data)
    }

    static func extract(data: Data, filename: String, cancellation: MaterialExtractionCancellation? = nil) throws -> ExtractedMaterial {
        try Task.checkCancellation()
        try cancellation?.check()
        guard !data.isEmpty, data.count <= maxFileBytes else { throw MaterialError.invalid("Empty file or file exceeds 20 MB.") }
        let ext = (filename as NSString).pathExtension.lowercased()
        var sections: [ExtractedMaterial.Section] = []
        var warnings: [String] = []
        switch ext {
        case "txt", "md", "markdown":
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw MaterialError.invalid("Expected UTF-8 text.") }
            sections = [.init(location: "text lines 1–\(text.components(separatedBy: .newlines).count)", text: text, method: "utf8")]
        case "docx":
            sections = try docx(data)
            warnings = ["Text and table cells only; Lists retain indentation as bullets; exact numbering, layout, drawings and tracked changes require original-document review."]
        case "pdf":
            guard let pdf = PDFDocument(data: data), !pdf.isEncrypted, !pdf.isLocked else { throw MaterialError.invalid("Damaged or encrypted PDF. Supply an unlocked copy.") }
            guard pdf.pageCount > 0, pdf.pageCount <= 100 else { throw MaterialError.invalid("PDF must have 1–100 pages.") }
            var total = 0
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { throw MaterialError.invalid("Unreadable PDF page.") }
                var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var method = "PDFKit text"
                if text.filter({ $0.isLetter || $0.isNumber }).count < 12 {
                    let thumbnail = page.thumbnail(of: NSSize(width: 1600, height: 2200), for: .mediaBox)
                    guard let image = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw MaterialError.invalid("PDF page cannot be rendered for OCR.") }
                    text = try recognize(image, cancellation: cancellation)
                    method = "Vision OCR"
                }
                total += text.utf8.count
                guard total <= maxTextBytes else { throw MaterialError.invalid("Extracted text exceeds 2 MB.") }
                sections.append(.init(location: "PDF page \(index + 1)", text: text, method: method))
            }
            warnings = ["Check reading order, tables and OCR symbols against the original PDF; no layout or diagram interpretation is claimed."]
        case "png", "jpg", "jpeg", "tiff", "heic":
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 12000, height <= 12000, width * height <= 40_000_000,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw MaterialError.invalid("Damaged image or image exceeds 40 megapixels.") }
            sections = [.init(location: "image 1", text: try recognize(image, cancellation: cancellation), method: "Vision OCR")]
            warnings = ["OCR only. Check minus signs, comparison operators, indentation, units and formulas. Arrows, charts and geometry have not been interpreted."]
        default: throw MaterialError.invalid("Unsupported format. Use TXT, Markdown, PDF, DOCX or an image.")
        }
        guard sections.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw MaterialError.invalid("No readable text found; review or transcribe the original.") }
        guard sections.reduce(0, { $0 + $1.text.utf8.count }) <= maxTextBytes else { throw MaterialError.invalid("Extracted text exceeds 2 MB.") }
        try Task.checkCancellation()
        return .init(filename: filename, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sections: sections, warnings: warnings)
    }

    private static func recognize(_ image: CGImage, cancellation: MaterialExtractionCancellation?) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        try cancellation?.install(request)
        defer { cancellation?.clear() }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = false // Do not silently repair code/math.
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        try cancellation?.check()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func docx(_ data: Data) throws -> [ExtractedMaterial.Section] {
        let archive = try Archive(data: data, accessMode: .read)
        var count = 0
        var total: UInt64 = 0
        var paths = Set<String>()
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard count <= 2048, !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains(":"),
                  !components.contains(".."), !components.contains("."), !entry.path.contains("\0"),
                  paths.insert(entry.path).inserted, entry.type != .symlink else { throw MaterialError.invalid("Unsafe DOCX archive entry.") }
            total += entry.uncompressedSize
            guard total <= 40 * 1_024 * 1_024,
                  entry.uncompressedSize <= max(1, entry.compressedSize) * 200 else { throw MaterialError.invalid("DOCX exceeds expanded-size or compression-ratio limits.") }
        }
        guard let document = archive["word/document.xml"], document.type == .file,
              document.uncompressedSize <= maxTextBytes else { throw MaterialError.invalid("DOCX document.xml missing or too large.") }
        var xml = Data()
        let crc = try archive.extract(document, bufferSize: 16384) { bytes in
            try Task.checkCancellation()
            guard xml.count + bytes.count <= maxTextBytes else { throw MaterialError.invalid("DOCX XML exceeds limit.") }
            xml.append(bytes)
        }
        guard crc == document.checksum else { throw MaterialError.invalid("DOCX checksum mismatch.") }
        guard let decodedXML = String(data: xml, encoding: .utf8) else { throw MaterialError.invalid("DOCX XML must use UTF-8.") }
        let xmlText = decodedXML.uppercased()
        guard !xmlText.contains("<!DOCTYPE"), !xmlText.contains("<!ENTITY") else { throw MaterialError.invalid("XML entity declarations are not allowed.") }
        let delegate = WordTextDelegate()
        let parser = XMLParser(data: xml)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), delegate.failure == nil else { throw MaterialError.invalid("Damaged or cancelled DOCX XML.") }
        return delegate.sections
    }
}

private final class WordTextDelegate: NSObject, XMLParserDelegate {
    var sections: [ExtractedMaterial.Section] = []
    var failure: Error?
    private var inText = false
    private var paragraph = ""
    private var paragraphNumber = 0
    private var listLevel: Int?
    private var hasNumbering = false
    private var table = 0
    private var inTable = false
    private var row = 0
    private var cell = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if Task.isCancelled { failure = CancellationError(); parser.abortParsing(); return }
        switch name {
        case "tbl": table += 1; inTable = true; row = 0
        case "tr": row += 1; cell = 0
        case "tc": cell += 1
        case "p": paragraph = ""; paragraphNumber += 1; listLevel = nil; hasNumbering = false
        case "numPr": hasNumbering = true
        case "ilvl": listLevel = min(8, max(0, Int(attributes["w:val"] ?? attributes["val"] ?? "0") ?? 0))
        case "numId": if attributes["w:val"] == "0" || attributes["val"] == "0" { hasNumbering = false }
        case "t": inText = true
        case "tab": paragraph += "\t"
        case "br", "cr": paragraph += "\n"
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { paragraph += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "tbl" { inTable = false }
        if name == "p", !paragraph.isEmpty {
            let location = inTable ? "DOCX table \(table), row \(row), cell \(cell), paragraph \(paragraphNumber)" : "DOCX paragraph \(paragraphNumber)"
            let text = hasNumbering ? String(repeating: "  ", count: listLevel ?? 0) + "- " + paragraph : paragraph
            sections.append(.init(location: location, text: text, method: "ZIPFoundation + XMLParser"))
        }
    }
}
