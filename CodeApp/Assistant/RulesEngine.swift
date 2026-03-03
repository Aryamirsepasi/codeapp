//
//  RulesEngine.swift
//  CodeApp
//
//  Hierarchical markdown rules engine. Loads .codeapp/rules.md files from
//  global, project root, rules directory, and subdirectories. Supports
//  YAML-like frontmatter for filtering and import resolution.
//

import Foundation

@MainActor
final class RulesEngine {

    // MARK: - Types

    struct RulesFile {
        let url: URL
        let scope: RuleScope
        let frontmatter: RuleFrontmatter?
        let content: String
    }

    struct RuleFrontmatter {
        var paths: [String]?
        var description: String?
        var applyTo: String?  // "agent", "chat", "both"
    }

    enum RuleScope: Comparable {
        case global
        case projectRoot
        case rulesDirectory
        case subdirectory(String)

        // Comparable conformance — more specific scopes sort later
        private var sortOrder: Int {
            switch self {
            case .global: return 0
            case .projectRoot: return 1
            case .rulesDirectory: return 2
            case .subdirectory: return 3
            }
        }

        static func < (lhs: RuleScope, rhs: RuleScope) -> Bool {
            lhs.sortOrder < rhs.sortOrder
        }
    }

    // MARK: - State

    private var cachedRules: [RulesFile] = []
    private var loadedSubdirectories: Set<String> = []
    private static let maxLinesCap = 200
    private static let maxImportDepth = 5

    // MARK: - Public API

    /// Load rules from the full hierarchy. Call once at session start or on reload.
    func loadRules(workspaceRoot: URL) async -> [RulesFile] {
        cachedRules.removeAll()
        loadedSubdirectories.removeAll()

        // 1. Global rules: Documents/.codeapp/rules.md
        let globalDir = getRootDirectory().appendingPathComponent(".codeapp")
        await loadSingleRule(
            at: globalDir.appendingPathComponent("rules.md"),
            scope: .global
        )

        // 2. Project root rules: {workspace}/.codeapp/rules.md
        let projectDir = workspaceRoot.appendingPathComponent(".codeapp")
        await loadSingleRule(
            at: projectDir.appendingPathComponent("rules.md"),
            scope: .projectRoot
        )

        // 3. Rules directory: {workspace}/.codeapp/rules/*.md
        let rulesDir = projectDir.appendingPathComponent("rules")
        await loadRulesDirectory(at: rulesDir)

        return cachedRules
    }

    /// Returns concatenated rules content, filtered by file path and mode.
    func rulesContent(forFilePath filePath: String?, mode: String) -> String {
        let applicable = cachedRules.filter { rule in
            // Filter by applyTo
            if let applyTo = rule.frontmatter?.applyTo {
                switch applyTo.lowercased() {
                case "agent": if mode != "agent" { return false }
                case "chat": if mode != "chat" { return false }
                case "both": break
                default: break
                }
            }

            // Filter by paths glob
            if let paths = rule.frontmatter?.paths, let filePath {
                let matched = paths.contains { pattern in
                    globMatch(pattern: pattern, path: filePath)
                }
                if !matched { return false }
            }

            return true
        }

        guard !applicable.isEmpty else { return "" }

        return applicable
            .sorted { $0.scope < $1.scope }
            .map { $0.content }
            .joined(separator: "\n\n---\n\n")
    }

    /// Lazily load rules from a subdirectory (triggered when agent reads files there).
    func loadSubdirectoryRules(directoryPath: String, workspaceRoot: URL) async {
        let normalized = directoryPath.hasPrefix("/")
            ? String(directoryPath.dropFirst()) : directoryPath

        guard !loadedSubdirectories.contains(normalized) else { return }
        loadedSubdirectories.insert(normalized)

        let ruleURL = workspaceRoot
            .appendingPathComponent(normalized)
            .appendingPathComponent(".codeapp")
            .appendingPathComponent("rules.md")

        await loadSingleRule(at: ruleURL, scope: .subdirectory(normalized))
    }

    /// Force reload everything.
    func reload(workspaceRoot: URL) async {
        _ = await loadRules(workspaceRoot: workspaceRoot)
    }

    // MARK: - Private Loading

    private func loadSingleRule(at url: URL, scope: RuleScope) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)
        else { return }

        let (frontmatter, body) = parseFrontmatter(raw)
        let resolved = resolveImports(in: body, relativeTo: url.deletingLastPathComponent(), depth: 0)
        let truncated = truncateLines(resolved, max: Self.maxLinesCap)

        cachedRules.append(RulesFile(
            url: url,
            scope: scope,
            frontmatter: frontmatter,
            content: truncated
        ))
    }

    private func loadRulesDirectory(at directoryURL: URL) async {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents where fileURL.pathExtension == "md" {
            guard let data = try? Data(contentsOf: fileURL),
                  let raw = String(data: data, encoding: .utf8)
            else { continue }

            let (frontmatter, body) = parseFrontmatter(raw)
            let resolved = resolveImports(in: body, relativeTo: directoryURL, depth: 0)
            let truncated = truncateLines(resolved, max: Self.maxLinesCap)

            cachedRules.append(RulesFile(
                url: fileURL,
                scope: .rulesDirectory,
                frontmatter: frontmatter,
                content: truncated
            ))
        }
    }

    // MARK: - Frontmatter Parsing

    /// Parse YAML-like frontmatter between `---` markers.
    private func parseFrontmatter(_ text: String) -> (RuleFrontmatter?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return (nil, text) }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return (nil, text) }

        // Find closing ---
        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let endIdx = closingIndex else { return (nil, text) }

        var fm = RuleFrontmatter()
        for i in 1..<endIdx {
            let line = lines[i]
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = String(line[line.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)

                switch key {
                case "paths":
                    fm.paths = value.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                case "description":
                    fm.description = value
                case "applyto", "apply_to":
                    fm.applyTo = value
                default:
                    break
                }
            }
        }

        let body = lines[(endIdx + 1)...].joined(separator: "\n")
        return (fm, body)
    }

    // MARK: - Import Resolution

    /// Resolve `@filename.md` import lines by inlining referenced file content.
    private func resolveImports(in text: String, relativeTo directory: URL, depth: Int) -> String {
        guard depth < Self.maxImportDepth else { return text }

        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@") && trimmed.hasSuffix(".md") && !trimmed.contains(" ") {
                let filename = String(trimmed.dropFirst())  // remove @
                let importURL = directory.appendingPathComponent(filename)
                if let data = try? Data(contentsOf: importURL),
                   let content = String(data: data, encoding: .utf8) {
                    let resolved = resolveImports(
                        in: content, relativeTo: importURL.deletingLastPathComponent(), depth: depth + 1
                    )
                    result.append(resolved)
                } else {
                    result.append(line)  // keep unresolved import as-is
                }
            } else {
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func truncateLines(_ text: String, max: Int) -> String {
        let lines = text.components(separatedBy: .newlines)
        if lines.count <= max { return text }
        return lines.prefix(max).joined(separator: "\n") + "\n[Truncated]"
    }

    /// Simple glob matching supporting `*` and `**` patterns.
    private func globMatch(pattern: String, path: String) -> Bool {
        // Convert glob to regex
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "*" {
                let next = pattern.index(after: i)
                if next < pattern.endIndex && pattern[next] == "*" {
                    regex += ".*"
                    i = pattern.index(after: next)
                    // Skip trailing /
                    if i < pattern.endIndex && pattern[i] == "/" {
                        i = pattern.index(after: i)
                    }
                    continue
                } else {
                    regex += "[^/]*"
                }
            } else if c == "?" {
                regex += "[^/]"
            } else if c == "." {
                regex += "\\."
            } else {
                regex += String(c)
            }
            i = pattern.index(after: i)
        }
        regex += "$"

        return (try? NSRegularExpression(pattern: regex))?.firstMatch(
            in: path, range: NSRange(path.startIndex..., in: path)
        ) != nil
    }
}
