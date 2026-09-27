import Foundation
import Testing
import ZIPFoundation
import PDFKit
import AppKit
import CoreText
@testable import Hireva

@Suite(.serialized)
struct MaterialExtractionTests {
    @Test func commonDOCXListsRetainNestingWithoutInventingNumbers() throws {
        let xml = "<w:document xmlns:w='urn:test'><w:body><w:p><w:pPr><w:numPr><w:ilvl w:val='1'/><w:numId w:val='2'/></w:numPr></w:pPr><w:r><w:t>nested task</w:t></w:r></w:p></w:body></w:document>"
        let result = try MaterialExtractionService.extract(data: Self.docx(xml), filename: "list.docx")
        #expect(result.sections.first?.text == "  - nested task")
        #expect(result.warnings.contains { $0.contains("exact numbering") })
    }
    @Test func cancelledNativeExtractionRejectsWorkBeforeOCR() throws {
        let cancellation = MaterialExtractionCancellation()
        cancellation.cancel()
        #expect(throws: CancellationError.self) { try MaterialExtractionService.extract(data: Data("synthetic".utf8), filename: "cancel.txt", cancellation: cancellation) }
    }
    static func drawSample(_ context: CGContext) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let font = CTFontCreateWithName("Menlo" as CFString, 28, nil)
        for (index, text) in ["SYNTHETIC MATERIAL - NOT A REAL CANDIDATE", "Candidate: Alex Example", "Built a Swift validation service with a team.", "Personal contribution: implemented input validation.", "Result: no measured performance claim is supplied.", "if value <= 5:", "    result = value - 2", "Latency unit: ms; formula: x <= 5"].enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
            context.textPosition = CGPoint(x: 35, y: 740 - index * 70)
            CTLineDraw(line, context)
        }
    }
    @Test func realPDFImageOCRAndEncryptedPDF() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let consumer = try #require(CGDataConsumer(data: data))
        let pdf = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdf.beginPDFPage(nil); Self.drawSample(pdf); pdf.endPDFPage(); pdf.closePDF()
        let extracted = try MaterialExtractionService.extract(data: data as Data, filename: "synthetic-cv.pdf")
        #expect(extracted.sections.first?.location == "PDF page 1")
        #expect(extracted.text.contains("value <= 5"))
        #expect(extracted.text.contains("value - 2"))
        let bitmap = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        Self.drawSample(bitmap)
        let cgImage = try #require(bitmap.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        let ocr = try MaterialExtractionService.extract(data: png, filename: "synthetic-code.png")
        #expect(ocr.text.contains("validation"))
        #expect(ocr.text.contains("ms"))
        #expect(!ocr.warnings.isEmpty) // OCR does not certify indentation, operators or diagrams.
        let document = try #require(PDFDocument(data: data as Data))
        let locked = try #require(document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "synthetic-owner", PDFDocumentWriteOption.userPasswordOption: "synthetic-user"]))
        #expect(throws: (any Error).self) { try MaterialExtractionService.extract(data: locked, filename: "locked.pdf") }
        if let folder = ProcessInfo.processInfo.environment["HIREVA_TEST_ARTIFACT_DIR"] {
            let root = URL(fileURLWithPath: folder)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try (data as Data).write(to: root.appendingPathComponent("synthetic-cv.pdf"))
            try png.write(to: root.appendingPathComponent("synthetic-code.png"))
            try locked.write(to: root.appendingPathComponent("locked.pdf"))
            try Self.docx("<w:document xmlns:w='urn:test'><w:body><w:p><w:r><w:t>Synthetic role: Software Engineer. Build reliable Swift services. Review tests and document limitations. No personal experience implied.</w:t></w:r></w:p></w:body></w:document>").write(to: root.appendingPathComponent("synthetic-jd.docx"))
            try Data(ocr.text.utf8).write(to: root.appendingPathComponent("ocr-observed.txt"))
        }
    }
    static func docx(_ text: String, extraPath: String? = nil) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        let data = Data(text.utf8)
        for path in ["word/document.xml"] + (extraPath.map { [$0] } ?? []) {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return try #require(archive.data)
    }
    @Test func docxParagraphsBreaksAndTableLocations() throws {
        let xml = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>alpha ≤ 5 − 2</w:t><w:br/><w:t>中文文本</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>value 30 ms</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>
        """
        let result = try MaterialExtractionService.extract(data: Self.docx(xml), filename: "synthetic.docx")
        #expect(result.sections.count == 2)
        #expect(result.sections[0].text == "alpha ≤ 5 − 2\n中文文本")
        #expect(result.sections[1].location.contains("table 1, row 1, cell 1"))
        #expect(!result.text.contains("page"))
    }
    @Test func archiveTraversalEntitiesCorruptionAndBoundsFailClosed() throws {
        let xml = "<document><p><t>synthetic text</t></p></document>"
        let badPath = try Self.docx(xml, extraPath: "../escape")
        #expect(throws: (any Error).self) { try MaterialExtractionService.extract(data: badPath, filename: "bad.docx") }
        let entity = try Self.docx("<!DOCTYPE document [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><document>&x;</document>")
        #expect(throws: (any Error).self) { try MaterialExtractionService.extract(data: entity, filename: "bad.docx") }
        #expect(throws: (any Error).self) { try MaterialExtractionService.extract(data: Data("broken".utf8), filename: "bad.pdf") }
        #expect(throws: (any Error).self) { try MaterialExtractionService.extract(data: Data(), filename: "empty.txt") }
        #expect(throws: (any Error).self) { try MaterialExtractionService.extract(data: Data(repeating: 65, count: MaterialExtractionService.maxFileBytes + 1), filename: "large.txt") }
    }
    @Test func extractedTextIsIndexedAndOriginalRoundTrips() throws {
        let database = try AppDatabase(inMemory: true)
        defer { try? database.close() }
        let bytes = Data("Synthetic candidate built a Swift service, tested data validation and documented limitations. 中文支持。".utf8)
        let material = try MaterialExtractionService.extract(data: bytes, filename: "CV.md")
        let repository = DocumentRepository(database: database)
        let doc = try repository.saveDocument(type: .cv, title: "CV", content: material.text, material: material, originalData: bytes)
        #expect(try !repository.chunks(documentID: doc.id).isEmpty)
        #expect(try repository.source(documentID: doc.id)?.data == bytes)
        let again = try repository.saveDocument(type: .cv, title: "CV", content: material.text, material: material, originalData: bytes)
        #expect(again.id == doc.id)
        #expect(try repository.documents().count == 1)
        try repository.deleteDocument(id: doc.id)
        #expect(try repository.source(documentID: doc.id) == nil)
    }
    @Test func cancelledExtractionDoesNotReturnMaterial() async {
        let worker = Task { () throws -> ExtractedMaterial in
            try await Task.sleep(for: .milliseconds(20))
            return try MaterialExtractionService.extract(data: Data("Hello".utf8), filename: "a.txt")
        }
        worker.cancel()
        do { _ = try await worker.value; Issue.record("Cancellation ignored") } catch {}
    }
}
