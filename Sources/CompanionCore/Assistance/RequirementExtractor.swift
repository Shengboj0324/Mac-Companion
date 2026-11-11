import Foundation

public struct ExtractedRequirement: Equatable, Sendable {
    public var text: String
    public var status: RequirementStatus
    /// Verbatim source passage.
    public var evidence: String
    public var note: String?
}

public struct ExtractedDeadline: Equatable, Sendable {
    public var date: Date
    public var evidence: String
}

/// Deterministic assignment-description parser. Separates required, optional and
/// inferred items, each with verbatim evidence. It never invents problem
/// statements and never confirms anything on its own (spec §9, §17).
public struct RequirementExtractor: Sendable {
    public init() {}

    static let optionalMarkers = ["optional", "extra credit", "bonus", "if you want", "not required", "challenge problem", "for fun"]
    static let resourceMarkers = ["read ", "reading", "watch", "video", "review ", "see ", "skim", "textbook section"]
    static let requiredMarkers = ["must", "required", "include", "need to", "should", "complete", "write", "submit", "turn in", "answer", "do "]
    static let formatPatterns: [(String, String)] = [
        (#"(?i)\b(\d{1,2})[- ]?(pt|point)\b"#, "font size"),
        (#"(?i)double[- ]spaced"#, "spacing"),
        (#"(?i)single[- ]spaced"#, "spacing"),
        (#"(?i)(one|1)[- ]inch margins?"#, "margins"),
        (#"(?i)\b(MLA|APA|Chicago)\b"#, "citation style"),
        (#"(?i)\b(\d{3,5})\s*(-|to|–)\s*(\d{3,5})\s*words\b"#, "length"),
        (#"(?i)\b(at least|minimum of|max(imum)? of|no more than)\s+\d+\s+(words|pages|sources)\b"#, "length"),
    ]

    public func extract(_ description: String) -> (requirements: [ExtractedRequirement], deadlines: [ExtractedDeadline]) {
        var out: [ExtractedRequirement] = []
        var deadlines: [ExtractedDeadline] = []
        var lastProblemSection: String?? = nil
        for sentence in Self.sentences(description) {
            let lower = sentence.lowercased()
            let isOptional = Self.optionalMarkers.contains { lower.contains($0) }

            // "Optional: 53, 54." directly after a problem list continues that list.
            if isOptional, let section = lastProblemSection, let numbers = Self.bareNumberList(sentence) {
                let prefix = section.map { "Section \($0) " } ?? ""
                for n in numbers { out.append(.init(text: "\(prefix)problem \(n)", status: .optional, evidence: sentence, note: nil)) }
                continue
            }
            lastProblemSection = nil

            // Problem lists → one item per problem, never inventing their statements.
            let problems = Self.problemNumbers(in: sentence)
            if !problems.required.isEmpty || !problems.optional.isEmpty {
                let section = Self.section(in: sentence).map { "Section \($0) " } ?? ""
                for n in problems.required {
                    out.append(.init(text: "\(section)problem \(n)", status: isOptional && problems.optional.isEmpty ? .optional : .required,
                                     evidence: sentence, note: "Problem statement not provided — check the textbook"))
                }
                for n in problems.optional {
                    out.append(.init(text: "\(section)problem \(n)", status: .optional, evidence: sentence, note: nil))
                }
                lastProblemSection = .some(Self.section(in: sentence))
                continue
            }

            if let d = Self.deadline(in: sentence) { deadlines.append(ExtractedDeadline(date: d, evidence: sentence)) }

            // Formatting requirements become separate checkable items.
            var matchedFormat = false
            for (pattern, label) in Self.formatPatterns {
                if let r = sentence.range(of: pattern, options: .regularExpression) {
                    out.append(.init(text: "\(label.capitalized): \(sentence[r])", status: isOptional ? .optional : .required, evidence: sentence, note: nil))
                    matchedFormat = true
                }
            }
            if matchedFormat { continue }

            if lower.contains("submit") || lower.contains("share") && lower.contains("link") || lower.contains("editing access") || lower.contains("turn in") {
                out.append(.init(text: sentence, status: .required, evidence: sentence,
                                 note: "Companion will not submit or change sharing — do this yourself"))
                continue
            }
            if isOptional {
                out.append(.init(text: sentence, status: .optional, evidence: sentence, note: nil)); continue
            }
            if Self.resourceMarkers.contains(where: { lower.contains($0) }) && !Self.requiredMarkers.prefix(3).contains(where: { lower.contains($0) }) {
                out.append(.init(text: sentence, status: .inferred, evidence: sentence,
                                 note: "Listed as a resource; confirm whether it is required")); continue
            }
            if Self.requiredMarkers.contains(where: { lower.contains($0) }) {
                out.append(.init(text: sentence, status: .required, evidence: sentence, note: nil))
            }
        }
        return (out, deadlines)
    }

    // MARK: Parsing helpers

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Split on sentence ends that are not decimal points (e.g. "13.5").
            var current = ""
            let chars = Array(trimmed)
            for (i, ch) in chars.enumerated() {
                current.append(ch)
                if ch == "." || ch == ";" || ch == "!" || ch == "?" {
                    let prevDigit = i > 0 && chars[i - 1].isNumber
                    let nextDigit = i + 1 < chars.count && chars[i + 1].isNumber
                    if ch == "." && prevDigit && nextDigit { continue }
                    let s = current.trimmingCharacters(in: .whitespaces)
                    if s.count > 2 { result.append(s) }
                    current = ""
                }
            }
            let s = current.trimmingCharacters(in: .whitespaces)
            if s.count > 2 { result.append(s) }
        }
        return result.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "•-*· ")) }
    }

    /// "Optional: 53, 54." → [53, 54]; nil if the sentence contains other words.
    static func bareNumberList(_ s: String) -> [Int]? {
        var rest = s.lowercased()
        for m in optionalMarkers { rest = rest.replacingOccurrences(of: m, with: " ") }
        for w in ["and", "problems", "problem", "also", "&"] { rest = rest.replacingOccurrences(of: w, with: " ") }
        let tokens = rest.components(separatedBy: CharacterSet(charactersIn: " ,;:.()#")).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var out: [Int] = []
        for t in tokens {
            let parts = t.split(separator: "-")
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a <= b, b - a <= 50 { out += Array(a...b) }
            else if let n = Int(t) { out.append(n) } else { return nil }
        }
        return out
    }

    static func section(in s: String) -> String? {
        guard let r = s.range(of: #"(?i)(section|§)\s*(\d+(\.\d+)*)"#, options: .regularExpression) else { return nil }
        return s[r].components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }.first
    }

    /// Finds "problems 1, 5, 9-11 and 50" lists; numbers after "optional" go to optional.
    static func problemNumbers(in s: String) -> (required: [Int], optional: [Int]) {
        guard let start = s.range(of: #"(?i)\b(problems?|exercises?|questions?)\s*"#, options: .regularExpression)
                ?? s.range(of: #"(?:^|\s)#\s*(?=\d)"#, options: .regularExpression) else { return ([], []) }
        let tail = String(s[start.upperBound...])
        var required: [Int] = [], optional: [Int] = []
        var inOptional = false
        let tokens = tail.replacingOccurrences(of: "–", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: " ,;:()"))
            .filter { !$0.isEmpty }
        var i = 0
        var sawNumber = false
        while i < tokens.count {
            let t = tokens[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#."))
            if optionalMarkers.contains(where: { t.hasPrefix($0.split(separator: " ")[0]) }) { inOptional = true; i += 1; continue }
            if ["and", "&", "plus", "problems", "problem", "also", "are", "is"].contains(t) { i += 1; continue }
            let parts = t.split(separator: "-")
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a <= b, b - a <= 50 {
                (inOptional ? { optional += Array(a...b) } : { required += Array(a...b) })(); sawNumber = true
            } else if let n = Int(t), n > 0, n < 1000 {
                if inOptional { optional.append(n) } else { required.append(n) }
                sawNumber = true
            } else if sawNumber {
                // Stop at the first word that isn't part of the list, unless it introduces an optional list.
                if t.hasPrefix("optional") || t == "extra" || t == "bonus" { inOptional = true } else if !inOptional { break }
            }
            i += 1
        }
        return (required, optional)
    }

    static func deadline(in s: String) -> Date? {
        guard s.lowercased().contains("due") || s.lowercased().contains("deadline") else { return nil }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        return detector?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))?.date
    }
}
