import Foundation

public struct PlacementCandidate: Hashable, Sendable {
    public let folder: String
    public let score: Double
    public let reasons: [String]
    public let examples: [String]
}

public struct PlacementSuggestion: Sendable {
    public let file: String
    public let candidates: [PlacementCandidate]
    /// Set when evidence is sparse or contradictory: keep the file in place and ask.
    public let question: String?
    public var abstained: Bool { candidates.isEmpty }
}

/// Ranks up to three destinations: protected areas and explicit rules first, then
/// exact relationships, then similarity. Strong evidence improves the
/// recommendation, never the permission (spec §8).
public struct PlacementSuggester: Sendable {
    public struct Context: Sendable {
        /// Existing files: (relative folder path, filename).
        public var existing: [(folder: String, name: String)]
        public var protectedFolders: Set<String>
        public var explicitRules: [OrganizationRule]
        /// folder → times the user rejected it as "wrong location".
        public var rejectedFolders: [String: Int]
        /// folder → times the user accepted / chose it.
        public var acceptedFolders: [String: Int]
        public init(existing: [(folder: String, name: String)], protectedFolders: Set<String> = [], explicitRules: [OrganizationRule] = [],
                    rejectedFolders: [String: Int] = [:], acceptedFolders: [String: Int] = [:]) {
            self.existing = existing; self.protectedFolders = protectedFolders; self.explicitRules = explicitRules
            self.rejectedFolders = rejectedFolders; self.acceptedFolders = acceptedFolders
        }
    }

    public init() {}

    static let stopwords: Set<String> = ["the", "and", "for", "of", "a", "an", "to", "in", "on", "draft", "final", "copy", "v1", "v2", "v3", "new", "doc", "file"]

    public static func tokens(_ s: String) -> Set<String> {
        var words: [String] = []
        var cur = ""
        for ch in s {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase, let last = cur.last, last.isLowercase { words.append(cur); cur = "" }
                cur.append(ch)
            } else { if !cur.isEmpty { words.append(cur) }; cur = "" }
        }
        if !cur.isEmpty { words.append(cur) }
        return Set(words.map { $0.lowercased() }.filter { $0.count >= 2 && !stopwords.contains($0) && Int($0) == nil })
    }

    public func suggest(fileName: String, context: Context, maxCandidates: Int = 3, minScore: Double = 0.35) -> PlacementSuggestion {
        let fileTokens = Self.tokens((fileName as NSString).deletingPathExtension)
        let ext = (fileName as NSString).pathExtension.lowercased()
        var byFolder: [String: [String]] = [:]
        for e in context.existing { byFolder[e.folder, default: []].append(e.name) }

        var scored: [PlacementCandidate] = []
        for (folder, names) in byFolder {
            if context.protectedFolders.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) { continue }
            var score = 0.0
            var reasons: [String] = []
            var examples: [String] = []
            let folderTokens = Self.tokens(folder.replacingOccurrences(of: "/", with: " "))
            let folderOverlap = fileTokens.intersection(folderTokens)
            if !folderOverlap.isEmpty {
                score += 0.45 * min(1, Double(folderOverlap.count) / Double(max(1, fileTokens.count)) * 1.5)
                reasons.append("Folder name matches “\(folderOverlap.sorted().joined(separator: "”, “"))”")
            }
            var best = 0.0
            for n in names {
                let t = Self.tokens((n as NSString).deletingPathExtension)
                guard !t.isEmpty, !fileTokens.isEmpty else { continue }
                let j = Double(t.intersection(fileTokens).count) / Double(t.union(fileTokens).count)
                if j > 0.15 { examples.append(n) }
                best = max(best, j)
            }
            if best > 0.15 { score += 0.4 * best; reasons.append("Similar files are here") }
            let sameExt = names.filter { ($0 as NSString).pathExtension.lowercased() == ext }.count
            if !ext.isEmpty, sameExt > 0 {
                score += 0.15 * Double(sameExt) / Double(names.count)
                if Double(sameExt) / Double(names.count) >= 0.8 { reasons.append("Holds mostly .\(ext) files") }
            }
            // Explicit placement rules referencing this folder name.
            let leaf = (folder as NSString).lastPathComponent.lowercased()
            for rule in context.explicitRules where rule.field == .placement && rule.status == .explicit {
                if rule.statement.lowercased().contains("“\(leaf)”") && rule.statement.lowercased().contains(".\(ext)") {
                    score += 0.3; reasons.append("Matches your rule: \(rule.statement)")
                }
            }
            score += 0.1 * Double(min(3, context.acceptedFolders[folder] ?? 0))
            score -= 0.4 * Double(context.rejectedFolders[folder] ?? 0)
            if score > 0 && !reasons.isEmpty {
                scored.append(PlacementCandidate(folder: folder, score: min(1, score), reasons: reasons, examples: Array(examples.prefix(3))))
            }
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && $0.folder < $1.folder) }
        let strong = scored.filter { $0.score >= minScore }
        if strong.isEmpty {
            return PlacementSuggestion(file: fileName, candidates: [],
                                       question: scored.isEmpty ? "I don't have enough examples to place “\(fileName)”. Where do files like this usually go?"
                                                                : "Should “\(fileName)” go in \(scored.prefix(2).map { "“\($0.folder)”" }.joined(separator: " or "))?")
        }
        // Contradictory evidence: two near-equal top candidates → ask a targeted question but still show both.
        var question: String?
        if strong.count >= 2, strong[0].score - strong[1].score < 0.05 {
            question = "This could belong in “\(strong[0].folder)” or “\(strong[1].folder)”. Which is right?"
        }
        return PlacementSuggestion(file: fileName, candidates: Array(strong.prefix(maxCandidates)), question: question)
    }

    /// Generic baseline (filename-and-type only) used for evaluation comparisons.
    public func baseline(fileName: String, context: Context) -> [String] {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var counts: [String: Int] = [:]
        for e in context.existing where (e.name as NSString).pathExtension.lowercased() == ext { counts[e.folder, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(3).map(\.key)
    }
}
