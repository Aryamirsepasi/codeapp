//
//  SearchReplaceBlock.swift
//  CodeApp
//
//  Extracted from CodeAssistantPanel for reuse by agent tools.
//

import Foundation

struct SearchReplaceBlock: Identifiable {
    let id = UUID()
    let searchText: String
    let replaceText: String
    let language: String?
    /// Optional file path parsed from the SEARCH header (e.g. `<<<<<<< SEARCH path/to/file.swift`)
    var targetPath: String?

    var isValid: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var changePreview: String {
        let searchPreview = searchText.prefix(80) + (searchText.count > 80 ? "..." : "")
        let replacePreview = replaceText.prefix(80) + (replaceText.count > 80 ? "..." : "")
        return "\(searchPreview) → \(replacePreview)"
    }

    /// Parse all SEARCH/REPLACE blocks from AI-generated code.
    static func parse(from text: String) -> [SearchReplaceBlock] {
        var blocks: [SearchReplaceBlock] = []

        let patterns = [
            // Fenced code block with language and optional file path:
            // ```swift\n<<<<<<< SEARCH path/to/file.swift\n...\n=======\n...\n>>>>>>> REPLACE\n```
            #"```(\w*)\n<<<<<<< SEARCH(?:[ \t]+(\S+))?\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>> REPLACE\n```"#,
            // Fenced code block without language, optional file path:
            #"```\n<<<<<<< SEARCH(?:[ \t]+(\S+))?\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>> REPLACE\n```"#,
            // Raw markers, optional file path:
            #"<<<<<<< SEARCH(?:[ \t]+(\S+))?\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>> REPLACE"#,
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)

            for match in matches {
                var language: String? = nil
                var targetPath: String? = nil
                var searchText: String = ""
                var replaceText: String = ""

                if index == 0 {
                    // Pattern with language identifier + optional path
                    if match.numberOfRanges >= 5 {
                        if let langRange = Range(match.range(at: 1), in: text) {
                            let lang = String(text[langRange])
                            if !lang.isEmpty { language = lang }
                        }
                        if let pathRange = Range(match.range(at: 2), in: text) {
                            let path = String(text[pathRange])
                            if !path.isEmpty { targetPath = path }
                        }
                        if let searchRange = Range(match.range(at: 3), in: text) {
                            searchText = String(text[searchRange])
                        }
                        if let replaceRange = Range(match.range(at: 4), in: text) {
                            replaceText = String(text[replaceRange])
                        }
                    }
                } else {
                    // Patterns without language identifier, but with optional path
                    if match.numberOfRanges >= 4 {
                        if let pathRange = Range(match.range(at: 1), in: text) {
                            let path = String(text[pathRange])
                            if !path.isEmpty { targetPath = path }
                        }
                        if let searchRange = Range(match.range(at: 2), in: text) {
                            searchText = String(text[searchRange])
                        }
                        if let replaceRange = Range(match.range(at: 3), in: text) {
                            replaceText = String(text[replaceRange])
                        }
                    }
                }

                if !searchText.isEmpty {
                    blocks.append(SearchReplaceBlock(
                        searchText: searchText,
                        replaceText: replaceText,
                        language: language,
                        targetPath: targetPath
                    ))
                }
            }
        }

        return blocks
    }

    /// Apply this search/replace block to the original text.
    /// Returns the modified text if the search pattern was found, nil otherwise.
    func apply(to original: String) -> String? {
        // Strategy 1: Exact match
        if let range = original.range(of: searchText) {
            return original.replacingCharacters(in: range, with: replaceText)
        }

        // Strategy 2: Normalized whitespace match
        if let range = findNormalizedMatch(in: original) {
            return original.replacingCharacters(in: range, with: replaceText)
        }

        // Strategy 3: Line-by-line fuzzy match
        if let range = findFuzzyLineMatch(in: original) {
            return original.replacingCharacters(in: range, with: replaceText)
        }

        return nil
    }

    private func findNormalizedMatch(in original: String) -> Range<String.Index>? {
        let normalizeWhitespace: (String) -> String = { text in
            text.components(separatedBy: .newlines)
                .map { line in
                    let stripped = line.trimmingCharacters(in: .whitespaces)
                    let leadingCount = line.prefix(while: { $0.isWhitespace }).count
                    return String(repeating: " ", count: leadingCount) + stripped
                }
                .joined(separator: "\n")
        }

        let normalizedOriginal = normalizeWhitespace(original)
        let normalizedSearch = normalizeWhitespace(searchText)

        if let normalizedRange = normalizedOriginal.range(of: normalizedSearch) {
            let startOffset = normalizedOriginal.distance(
                from: normalizedOriginal.startIndex,
                to: normalizedRange.lowerBound
            )
            let endOffset = normalizedOriginal.distance(
                from: normalizedOriginal.startIndex,
                to: normalizedRange.upperBound
            )

            let originalLines = original.components(separatedBy: .newlines)
            let normalizedLines = normalizedOriginal.components(separatedBy: .newlines)

            var normalizedCharCount = 0
            var startLineIdx = 0
            var endLineIdx = 0

            for (idx, line) in normalizedLines.enumerated() {
                if normalizedCharCount + line.count >= startOffset {
                    startLineIdx = idx
                    break
                }
                normalizedCharCount += line.count + 1
            }

            normalizedCharCount = 0
            for (idx, line) in normalizedLines.enumerated() {
                normalizedCharCount += line.count + 1
                if normalizedCharCount >= endOffset {
                    endLineIdx = idx
                    break
                }
            }

            var startCharIdx = 0
            for i in 0..<startLineIdx {
                startCharIdx += originalLines[i].count + 1
            }

            var endCharIdx = 0
            for i in 0...min(endLineIdx, originalLines.count - 1) {
                endCharIdx += originalLines[i].count
                if i < endLineIdx {
                    endCharIdx += 1
                }
            }

            guard startCharIdx <= original.count && endCharIdx <= original.count else {
                return nil
            }

            let startIndex = original.index(original.startIndex, offsetBy: startCharIdx)
            let endIndex = original.index(original.startIndex, offsetBy: endCharIdx)

            return startIndex..<endIndex
        }

        return nil
    }

    private func findFuzzyLineMatch(in original: String) -> Range<String.Index>? {
        let searchLines = searchText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let originalLines = original.components(separatedBy: .newlines)

        guard searchLines.count >= 2, originalLines.count >= searchLines.count else {
            return nil
        }

        let firstSearchLine = searchLines[0]
        var bestStartIdx: Int? = nil
        var bestScore: Double = 0.7

        for (idx, originalLine) in originalLines.enumerated() {
            let trimmed = originalLine.trimmingCharacters(in: .whitespaces)
            let similarity = tokenSimilarity(firstSearchLine, trimmed)

            if similarity > bestScore {
                var matchScore = similarity

                for i in 1..<min(searchLines.count, originalLines.count - idx) {
                    let searchLine = searchLines[i]
                    let origLine = originalLines[idx + i].trimmingCharacters(in: .whitespaces)
                    let lineSim = tokenSimilarity(searchLine, origLine)
                    if lineSim > 0.6 {
                        matchScore += lineSim
                    }
                }

                let avgScore = matchScore / Double(searchLines.count)
                if avgScore > bestScore {
                    bestScore = avgScore
                    bestStartIdx = idx
                }
            }
        }

        guard let startIdx = bestStartIdx else {
            return nil
        }

        let lastSearchLine = searchLines.last!
        var endIdx = min(startIdx + searchLines.count, originalLines.count)

        for i in (startIdx + 1)..<min(startIdx + searchLines.count + 3, originalLines.count) {
            let trimmed = originalLines[i].trimmingCharacters(in: .whitespaces)
            if tokenSimilarity(lastSearchLine, trimmed) > 0.8 {
                endIdx = i + 1
                break
            }
        }

        var startOffset = 0
        for i in 0..<startIdx {
            startOffset += originalLines[i].count + 1
        }

        var endOffset = 0
        for i in 0..<endIdx {
            endOffset += originalLines[i].count
            if i < endIdx - 1 || endIdx < originalLines.count {
                endOffset += 1
            }
        }

        guard startOffset < original.count && endOffset <= original.count else {
            return nil
        }

        let startIndex = original.index(original.startIndex, offsetBy: startOffset)
        let endIndex = original.index(original.startIndex, offsetBy: min(endOffset, original.count))

        return startIndex..<endIndex
    }

    private func tokenSimilarity(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        if s1.isEmpty && s2.isEmpty { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }

        let tokens1 = Set(s1.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))
        let tokens2 = Set(s2.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))

        guard !tokens1.isEmpty || !tokens2.isEmpty else { return 0.0 }

        let intersection = tokens1.intersection(tokens2).count
        let union = tokens1.union(tokens2).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }
}
