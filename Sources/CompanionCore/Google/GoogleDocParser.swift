import Foundation

/// Converts a Docs API document (fetched with includeTabsContent=true) into
/// ordered sections per tab, preserving headings, lists, table cell boundaries,
/// links and index ranges, and recording what could not be read (spec §6).
public struct GoogleDocParser {
    public struct Paragraph: Equatable, Sendable {
        public var tabID: String
        public var text: String
        public var startIndex: Int
        public var endIndex: Int
        public var headingLevel: Int?
        public var isListItem: Bool
        public var inTable: Bool
    }

    public struct Tab: Equatable, Sendable {
        public var id: String
        public var title: String
        public var paragraphs: [Paragraph]
    }

    public struct Result: Sendable {
        public var title: String
        public var revisionID: String?
        public var tabs: [Tab]
        public var coverage: ExtractionCoverage

        /// Sections grouped under the nearest heading, with tab + range locators.
        public func segments(assetID: UUID, version: String?) -> [DocumentSegment] {
            var out: [DocumentSegment] = []
            var ordinal = 0
            for tab in tabs {
                var heading: String?
                var buffer: [Paragraph] = []
                func flush() {
                    let text = buffer.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { buffer.removeAll(); return }
                    for chunk in SearchIndex.segment([ExtractedSection(heading: heading, text: text, locator: nil)], assetID: assetID,
                                                     kind: .googleDoc, version: version, tabID: tab.id) {
                        var c = chunk
                        c.startIndex = buffer.first?.startIndex
                        c.endIndex = buffer.last?.endIndex
                        c.ordinal = ordinal
                        c.heading = [tabs.count > 1 ? tab.title : nil, heading].compactMap { $0 }.joined(separator: " › ")
                        if c.heading?.isEmpty == true { c.heading = nil }
                        out.append(c)
                        ordinal += 1
                    }
                    buffer.removeAll()
                }
                for p in tab.paragraphs {
                    if p.headingLevel != nil, !p.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        flush()
                        heading = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        buffer.append(p)
                    }
                }
                flush()
            }
            return out
        }

        public func paragraph(containing index: Int, tabID: String?) -> Paragraph? {
            tabs.first { tabID == nil || $0.id == tabID }?.paragraphs.first { $0.startIndex <= index && index < $0.endIndex }
        }

        /// Exact text currently occupying [start, end) in a tab, if it lies within one paragraph.
        public func text(tabID: String?, start: Int, end: Int) -> String? {
            guard let p = paragraph(containing: start, tabID: tabID), end <= p.endIndex else { return nil }
            let chars = Array(p.text.utf16)
            let s = start - p.startIndex, e = end - p.startIndex
            guard s >= 0, e <= chars.count, s <= e else { return nil }
            return String(decoding: chars[s..<e], as: UTF16.self)
        }
    }

    public init() {}

    public func parse(_ doc: [String: Any]) -> Result {
        var coverage = ExtractionCoverage()
        var tabs: [Tab] = []
        var omissionCounts: [String: Int] = [:]

        func walkTabs(_ list: [[String: Any]]) {
            for tab in list {
                let props = tab["tabProperties"] as? [String: Any] ?? [:]
                let id = props["tabId"] as? String ?? "t.\(tabs.count)"
                let title = props["title"] as? String ?? "Tab"
                coverage.tabsTotal += 1
                if let body = (tab["documentTab"] as? [String: Any])?["body"] as? [String: Any] {
                    var paragraphs: [Paragraph] = []
                    walkContent(body["content"] as? [[String: Any]] ?? [], tabID: id, inTable: false, into: &paragraphs)
                    tabs.append(Tab(id: id, title: title, paragraphs: paragraphs))
                    coverage.tabsRead += 1
                } else {
                    omissionCounts["unreadable tab", default: 0] += 1
                }
                walkTabs(tab["childTabs"] as? [[String: Any]] ?? [])
            }
        }

        func walkContent(_ content: [[String: Any]], tabID: String, inTable: Bool, into out: inout [Paragraph]) {
            for el in content {
                if let p = el["paragraph"] as? [String: Any] {
                    let style = (p["paragraphStyle"] as? [String: Any])?["namedStyleType"] as? String ?? ""
                    var level: Int?
                    if style == "TITLE" { level = 0 }
                    else if style.hasPrefix("HEADING_"), let n = Int(style.dropFirst(8)) { level = n }
                    var text = ""
                    for pe in p["elements"] as? [[String: Any]] ?? [] {
                        if let run = pe["textRun"] as? [String: Any] {
                            let content = run["content"] as? String ?? ""
                            text += content
                            if let link = ((run["textStyle"] as? [String: Any])?["link"] as? [String: Any])?["url"] as? String {
                                coverage.links += 1
                                // Keep the URL as text evidence; it is never fetched automatically.
                                text = String(text.dropLast(content.count)) + content.trimmingCharacters(in: .newlines) + " (\(link))" + (content.hasSuffix("\n") ? "\n" : "")
                            }
                        } else if pe["inlineObjectElement"] != nil { omissionCounts["image/drawing", default: 0] += 1; text += "[image]" }
                        else if pe["equation"] != nil { omissionCounts["equation", default: 0] += 1; text += "[equation]" }
                        else if pe["footnoteReference"] != nil { omissionCounts["footnote", default: 0] += 1 }
                        else if let person = pe["person"] as? [String: Any] {
                            text += ((person["personProperties"] as? [String: Any])?["name"] as? String) ?? "[person]"
                        } else if let rich = pe["richLink"] as? [String: Any] {
                            text += ((rich["richLinkProperties"] as? [String: Any])?["title"] as? String) ?? "[link]"
                        } else if pe["autoText"] != nil || pe["pageBreak"] != nil || pe["columnBreak"] != nil || pe["horizontalRule"] != nil {
                            continue
                        } else { omissionCounts["unsupported element", default: 0] += 1 }
                    }
                    let start = el["startIndex"] as? Int ?? 0
                    let end = el["endIndex"] as? Int ?? start
                    let isList = p["bullet"] != nil
                    let rendered = (isList ? "• " : "") + text.trimmingCharacters(in: .newlines)
                    coverage.paragraphs += 1
                    out.append(Paragraph(tabID: tabID, text: isList ? rendered : text.trimmingCharacters(in: .newlines),
                                         startIndex: start, endIndex: end, headingLevel: level, isListItem: isList, inTable: inTable))
                } else if let table = el["table"] as? [String: Any] {
                    coverage.tables += 1
                    for (r, row) in (table["tableRows"] as? [[String: Any]] ?? []).enumerated() {
                        var cells: [String] = []
                        for cell in row["tableCells"] as? [[String: Any]] ?? [] {
                            var cellParas: [Paragraph] = []
                            walkContent(cell["content"] as? [[String: Any]] ?? [], tabID: tabID, inTable: true, into: &cellParas)
                            cells.append(cellParas.map(\.text).joined(separator: " / "))
                        }
                        let start = row["startIndex"] as? Int ?? 0
                        let end = row["endIndex"] as? Int ?? start
                        out.append(Paragraph(tabID: tabID, text: "Row \(r + 1): " + cells.joined(separator: " | "),
                                             startIndex: start, endIndex: end, headingLevel: nil, isListItem: false, inTable: true))
                    }
                } else if el["tableOfContents"] != nil || el["sectionBreak"] != nil {
                    continue
                } else {
                    omissionCounts["unsupported block", default: 0] += 1
                }
            }
        }

        if let list = doc["tabs"] as? [[String: Any]], !list.isEmpty {
            walkTabs(list)
        } else if let body = doc["body"] as? [String: Any] {
            // Legacy response without tabs.
            coverage.tabsTotal = 1; coverage.tabsRead = 1
            var paragraphs: [Paragraph] = []
            walkContent(body["content"] as? [[String: Any]] ?? [], tabID: "t.0", inTable: false, into: &paragraphs)
            tabs.append(Tab(id: "t.0", title: "Tab 1", paragraphs: paragraphs))
        }
        coverage.omissions = omissionCounts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)\($0.value == 1 ? "" : "s")" }
        coverage.omissions.append("comments and suggestions not read")
        return Result(title: doc["title"] as? String ?? "Untitled", revisionID: doc["revisionId"] as? String, tabs: tabs, coverage: coverage)
    }
}
