import Foundation
import PDFKit

/// Result of extracting text from one local file. Coverage is always honest:
/// omissions are listed rather than silently dropped (spec §5, §11).
public struct Extraction: Sendable {
    public var status: IndexStatus
    public var sections: [ExtractedSection]
    public var omissions: [String]
    public var detail: String?

    public static func status(_ s: IndexStatus, _ detail: String? = nil) -> Extraction {
        Extraction(status: s, sections: [], omissions: [], detail: detail)
    }
}

public struct ExtractedSection: Sendable, Equatable {
    public var heading: String?
    public var text: String
    public var locator: String?
}

public struct ExtractionLimits: Sendable {
    public var maxFileBytes: Int = 100 << 20
    public var maxCharacters: Int = 2_000_000
    public var maxPDFPages: Int = 2_000
    public init() {}
}

/// Scoped, credential-free extractor. Receives one URL, returns text; holds no
/// network or write capability. Version is recorded with each FileVersion.
public struct TextExtractor: Sendable {
    public static let version = 1
    public static let plainTextExtensions: Set<String> = ["txt", "text", "md", "markdown", "csv", "tsv", "tex", "org", "rst", "json", "yaml", "yml"]
    public static let supportedExtensions: Set<String> = plainTextExtensions.union(["pdf", "docx", "rtf"])

    public var limits: ExtractionLimits
    public init(limits: ExtractionLimits = .init()) { self.limits = limits }

    public func canExtract(_ url: URL) -> Bool { Self.supportedExtensions.contains(url.pathExtension.lowercased()) }

    public func extract(_ url: URL) -> Extraction {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { return .status(.unsupported) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > limits.maxFileBytes { return .status(.tooLarge, "Larger than \(limits.maxFileBytes >> 20) MB") }
        switch ext {
        case "pdf": return extractPDF(url)
        case "docx": return extractDOCX(url)
        case "rtf": return extractRTF(url)
        default: return extractPlain(url, markdown: ["md", "markdown"].contains(ext))
        }
    }

    // MARK: Plain text / Markdown

    func extractPlain(_ url: URL, markdown: Bool) -> Extraction {
        guard let data = try? Data(contentsOf: url) else { return .status(.failed, "Could not read file") }
        if data.prefix(8192).contains(0) { return .status(.failed, "Binary content") }
        var text = String(decoding: data, as: UTF8.self)
        var truncated = false
        if text.count > limits.maxCharacters { text = String(text.prefix(limits.maxCharacters)); truncated = true }
        let sections = markdown ? Self.splitMarkdown(text) : [ExtractedSection(heading: nil, text: text, locator: nil)]
        return Extraction(status: truncated ? .partial : .indexed, sections: sections,
                          omissions: truncated ? ["text after \(limits.maxCharacters) characters"] : [], detail: nil)
    }

    static func splitMarkdown(_ text: String) -> [ExtractedSection] {
        var sections: [ExtractedSection] = []
        var heading: String?
        var buffer: [Substring] = []
        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty || heading != nil { sections.append(ExtractedSection(heading: heading, text: body, locator: heading.map { "# " + $0 })) }
            buffer.removeAll()
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { flush(); heading = title; continue }
            }
            buffer.append(line)
        }
        flush()
        return sections
    }

    // MARK: RTF

    func extractRTF(_ url: URL) -> Extraction {
        guard let attributed = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
            return .status(.failed, "Could not parse RTF")
        }
        return Extraction(status: .indexed, sections: [ExtractedSection(heading: nil, text: attributed.string, locator: nil)],
                          omissions: ["formatting"], detail: nil)
    }

    // MARK: PDF

    func extractPDF(_ url: URL) -> Extraction {
        guard let doc = PDFDocument(url: url) else { return .status(.failed, "Could not open PDF") }
        if doc.isEncrypted && doc.isLocked { return .status(.encrypted, "Password-protected PDF") }
        var sections: [ExtractedSection] = []
        var chars = 0
        var truncated = false
        let pageCount = min(doc.pageCount, limits.maxPDFPages)
        if doc.pageCount > limits.maxPDFPages { truncated = true }
        for i in 0..<pageCount {
            guard let page = doc.page(at: i), let text = page.string, !text.isEmpty else { continue }
            chars += text.count
            sections.append(ExtractedSection(heading: "Page \(i + 1)", text: text, locator: "page=\(i + 1)"))
            if chars > limits.maxCharacters { truncated = true; break }
        }
        if sections.isEmpty {
            return .status(.metadataOnly, "No text layer (scanned PDF — OCR is not enabled)")
        }
        var omissions = ["layout", "images"]
        if truncated { omissions.append("pages beyond the extraction limit") }
        return Extraction(status: truncated ? .partial : .indexed, sections: sections, omissions: omissions, detail: nil)
    }

    // MARK: DOCX

    func extractDOCX(_ url: URL) -> Extraction {
        guard let data = try? Data(contentsOf: url) else { return .status(.failed, "Could not read file") }
        guard let zip = try? ZipReader(data: data), let xml = try? zip.extract("word/document.xml") else {
            return .status(.failed, "Not a readable Word document")
        }
        let parser = DocxParser()
        parser.parse(xml)
        var omissions = ["formatting", "comments"]
        if parser.equations > 0 { omissions.append("\(parser.equations) equation(s)") }
        if parser.drawings > 0 { omissions.append("\(parser.drawings) drawing(s)/image(s)") }
        if zip.entry(named: "word/comments.xml") != nil { omissions.append("document comments present") }
        let sections = parser.sections.isEmpty ? [] : parser.sections
        if sections.isEmpty { return Extraction(status: .metadataOnly, sections: [], omissions: omissions, detail: "No text found") }
        return Extraction(status: .indexed, sections: sections, omissions: omissions, detail: nil)
    }
}

/// SAX parser for WordprocessingML body text with heading detection.
final class DocxParser: NSObject, XMLParserDelegate {
    private(set) var sections: [ExtractedSection] = []
    private(set) var equations = 0
    private(set) var drawings = 0
    private var heading: String?
    private var body: [String] = []
    private var paragraph = ""
    private var paragraphIsHeading = false
    private var inText = false
    private var mathDepth = 0

    func parse(_ data: Data) {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldProcessNamespaces = false
        p.parse()
        flushSection()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "w:p": paragraph = ""; paragraphIsHeading = false
        case "w:pStyle":
            let v = (attributes["w:val"] ?? "").lowercased()
            if v.hasPrefix("heading") || v == "title" { paragraphIsHeading = true }
        case "w:t": if mathDepth == 0 { inText = true }
        case "w:tab": paragraph += "\t"
        case "w:br": paragraph += "\n"
        case "m:oMath": if mathDepth == 0 { equations += 1; paragraph += " [equation] " }; mathDepth += 1
        case "w:drawing", "w:pict": drawings += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "w:t": inText = false
        case "m:oMath": mathDepth = max(0, mathDepth - 1)
        case "w:p":
            let text = paragraph.trimmingCharacters(in: .whitespaces)
            if paragraphIsHeading && !text.isEmpty {
                flushSection()
                heading = text
            } else {
                body.append(text)
            }
        case "w:tc": paragraph += " | "
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { paragraph += string }
    }

    private func flushSection() {
        let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || heading != nil {
            sections.append(ExtractedSection(heading: heading, text: text, locator: heading.map { "heading=" + $0 }))
        }
        body.removeAll()
    }
}
