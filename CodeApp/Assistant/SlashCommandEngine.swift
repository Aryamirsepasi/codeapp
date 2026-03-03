//
//  SlashCommandEngine.swift
//  CodeApp
//
//  Slash command framework. Scans .codeapp/commands/ directories for custom
//  commands, registers built-in commands (/clear, /help, /compact, /init),
//  and provides autocomplete matching.
//

import Foundation

struct SlashCommand: Identifiable {
    let id: String           // filename without .md, or builtin name
    let name: String         // display name with /
    let description: String
    let allowedTools: [String]?
    let model: String?
    let body: String         // template with $ARGUMENTS placeholder
    let source: CommandSource

    enum CommandSource {
        case builtin
        case global
        case project
    }
}

@MainActor
final class SlashCommandEngine: ObservableObject {

    @Published private(set) var commands: [SlashCommand] = []

    // MARK: - Scanning

    /// Scan directories and register built-in + custom commands.
    func scan(workspaceRoot: URL?) {
        commands.removeAll()
        registerBuiltins()

        // Global commands: Documents/.codeapp/commands/*.md
        let globalDir = getRootDirectory()
            .appendingPathComponent(".codeapp")
            .appendingPathComponent("commands")
        loadCustomCommands(from: globalDir, source: .global)

        // Project commands: {workspace}/.codeapp/commands/*.md
        if let root = workspaceRoot {
            let projectDir = root
                .appendingPathComponent(".codeapp")
                .appendingPathComponent("commands")
            loadCustomCommands(from: projectDir, source: .project)
        }
    }

    // MARK: - Resolution

    /// Parse "/name args" and return matched command + arguments string.
    func resolve(input: String) -> (SlashCommand, String)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let withoutSlash = String(trimmed.dropFirst())
        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let commandName = parts.first else { return nil }

        let name = String(commandName).lowercased()
        let arguments = parts.count > 1 ? String(parts[1]) : ""

        guard let command = commands.first(where: { $0.id == name }) else {
            return nil
        }

        return (command, arguments.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Autocomplete

    /// Return commands matching a prefix (for autocomplete dropdown).
    func matchingCommands(prefix: String) -> [SlashCommand] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }

        let query = String(trimmed.dropFirst()).lowercased()
        if query.isEmpty {
            return commands
        }

        return commands.filter { $0.id.hasPrefix(query) }
    }

    // MARK: - Built-in Commands

    private func registerBuiltins() {
        commands.append(SlashCommand(
            id: "clear",
            name: "/clear",
            description: "Clear the current conversation",
            allowedTools: nil,
            model: nil,
            body: "",
            source: .builtin
        ))

        commands.append(SlashCommand(
            id: "help",
            name: "/help",
            description: "Show available commands",
            allowedTools: nil,
            model: nil,
            body: "",
            source: .builtin
        ))

        commands.append(SlashCommand(
            id: "compact",
            name: "/compact",
            description: "Summarize conversation to free context",
            allowedTools: nil,
            model: nil,
            body: "",
            source: .builtin
        ))

        commands.append(SlashCommand(
            id: "init",
            name: "/init",
            description: "Discover project and generate rules file",
            allowedTools: nil,
            model: nil,
            body: "",
            source: .builtin
        ))
    }

    // MARK: - Custom Command Loading

    private func loadCustomCommands(from directory: URL, source: SlashCommand.CommandSource) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents where fileURL.pathExtension == "md" {
            guard let data = try? Data(contentsOf: fileURL),
                  let raw = String(data: data, encoding: .utf8)
            else { continue }

            let id = fileURL.deletingPathExtension().lastPathComponent.lowercased()

            // Don't override built-ins
            guard !commands.contains(where: { $0.id == id }) else { continue }

            let (meta, body) = parseCommandFrontmatter(raw)

            commands.append(SlashCommand(
                id: id,
                name: "/\(id)",
                description: meta["description"] ?? "Custom command: \(id)",
                allowedTools: meta["tools"]?.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) },
                model: meta["model"],
                body: body,
                source: source
            ))
        }
    }

    /// Parse frontmatter from command files (same format as rules).
    private func parseCommandFrontmatter(_ text: String) -> ([String: String], String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return ([:], text) }

        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return ([:], text) }

        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let endIdx = closingIndex else { return ([:], text) }

        var meta: [String: String] = [:]
        for i in 1..<endIdx {
            let line = lines[i]
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = String(line[line.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
                meta[key] = value
            }
        }

        let body = lines[(endIdx + 1)...].joined(separator: "\n")
        return (meta, body)
    }
}
