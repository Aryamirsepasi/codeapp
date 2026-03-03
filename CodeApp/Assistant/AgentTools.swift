//
//  AgentTools.swift
//  CodeApp
//
//  Defines agent tools for the agentic loop: read_file, write_file, apply_edit,
//  list_directory, search_files, run_command.
//

import AIProxy
import Foundation

// MARK: - Tool Result

struct ToolResult {
    let content: String
    let isError: Bool

    init(_ content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    static func error(_ message: String) -> ToolResult {
        ToolResult(message, isError: true)
    }
}

// MARK: - Tool Protocol

protocol AgentTool {
    static var name: String { get }
    static var toolDescription: String { get }
    static var inputSchema: [String: AIProxyJSONValue] { get }

    func execute(arguments: [String: Any], context: AgentContext) async -> ToolResult
}

// MARK: - Tool Registry

final class ToolRegistry {
    private struct ToolEntry {
        let name: String
        let description: String
        let inputSchema: [String: AIProxyJSONValue]
        let factory: () -> any AgentTool
    }

    private var entries: [String: ToolEntry] = [:]

    func register<T: AgentTool>(_ tool: T) {
        let entry = ToolEntry(
            name: T.name,
            description: T.toolDescription,
            inputSchema: T.inputSchema,
            factory: { tool }
        )
        entries[T.name] = entry
    }

    func execute(name: String, arguments: [String: Any], context: AgentContext) async -> ToolResult {
        guard let entry = entries[name] else {
            return .error("Unknown tool: \(name)")
        }
        let tool = entry.factory()
        return await tool.execute(arguments: arguments, context: context)
    }

    func anthropicToolDefinitions() -> [AnthropicToolUnion] {
        entries.values.map { entry in
            .customTool(AnthropicTool(
                description: entry.description,
                inputSchema: entry.inputSchema,
                name: entry.name
            ))
        }
    }

    func openRouterToolDefinitions() -> [OpenRouterChatCompletionRequestBody.Tool] {
        entries.values.map { entry in
            .function(
                name: entry.name,
                description: entry.description,
                parameters: entry.inputSchema,
                strict: nil
            )
        }
    }

    func openAIToolDefinitions() -> [OpenAIChatCompletionRequestBody.Tool] {
        entries.values.map { entry in
            .function(
                name: entry.name,
                description: entry.description,
                parameters: entry.inputSchema,
                strict: nil
            )
        }
    }

    static let `default`: ToolRegistry = {
        let r = ToolRegistry()
        r.register(ReadFileTool())
        r.register(WriteFileTool())
        r.register(ApplyEditTool())
        r.register(ListDirectoryTool())
        r.register(SearchFilesTool())
        r.register(RunCommandTool())
        return r
    }()
}

// MARK: - read_file

struct ReadFileTool: AgentTool {
    static let name = "read_file"
    static let toolDescription = "Read the contents of a file at the given path (relative to workspace root). Returns the file content as UTF-8 text."
    static let inputSchema: [String: AIProxyJSONValue] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "File path relative to the workspace root",
            ]
        ],
        "required": ["path"],
    ]

    private static let maxReadSize = 32_000

    func execute(arguments: [String: Any], context: AgentContext) async -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required parameter: path")
        }

        let url = context.resolveURL(for: path)

        do {
            let data = try await context.workSpaceStorage.contents(at: url)
            guard var content = String(data: data, encoding: .utf8) else {
                return .error("File is not valid UTF-8 text: \(path)")
            }
            if content.count > Self.maxReadSize {
                content = String(content.prefix(Self.maxReadSize))
                    + "\n\n[Truncated at \(Self.maxReadSize) characters]"
            }

            // Track that this file has been read (for read-before-write enforcement)
            let resolvedPath = url.standardizedFileURL.path
            context.filesReadByAgent.insert(resolvedPath)

            // Trigger lazy subdirectory rule loading
            let directory = url.deletingLastPathComponent()
            let relativeDirPath = directory.path.replacingOccurrences(
                of: context.workspaceRoot.path, with: ""
            )
            if !relativeDirPath.isEmpty {
                await context.rulesEngine?.loadSubdirectoryRules(
                    directoryPath: relativeDirPath,
                    workspaceRoot: context.workspaceRoot
                )
            }

            return ToolResult(content)
        } catch {
            return .error("Failed to read file '\(path)': \(error.localizedDescription)")
        }
    }
}

// MARK: - write_file

struct WriteFileTool: AgentTool {
    static let name = "write_file"
    static let toolDescription = "Create a new file or completely replace the contents of an existing file. Use apply_edit for surgical edits to existing files. You must read existing files before overwriting them."
    static let inputSchema: [String: AIProxyJSONValue] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "File path relative to the workspace root",
            ],
            "content": [
                "type": "string",
                "description": "The complete file content to write",
            ],
        ],
        "required": ["path", "content"],
    ]

    func execute(arguments: [String: Any], context: AgentContext) async -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required parameter: path")
        }
        guard let content = arguments["content"] as? String else {
            return .error("Missing required parameter: content")
        }

        let url = context.resolveURL(for: path)
        let resolvedPath = url.standardizedFileURL.path

        // Enforce read-before-write for existing files
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        if fileExists && !context.filesReadByAgent.contains(resolvedPath) {
            return .error("You must read '\(path)' before overwriting it. Use read_file first.")
        }

        guard let data = content.data(using: .utf8) else {
            return .error("Content cannot be encoded as UTF-8")
        }

        do {
            try await context.workSpaceStorage.write(
                at: url, content: data, atomically: true, overwrite: true)

            // Sync Monaco if this is the active file
            if context.isActiveFile(url), let monaco = context.monacoInstance {
                await monaco.setValueForModel(url: url.absoluteString, value: content)
            }

            return ToolResult("Successfully wrote \(content.count) characters to \(path)")
        } catch {
            return .error("Failed to write file '\(path)': \(error.localizedDescription)")
        }
    }
}

// MARK: - apply_edit

struct ApplyEditTool: AgentTool {
    static let name = "apply_edit"
    static let toolDescription =
        "Apply a SEARCH/REPLACE edit to an existing file. The search text must exactly match existing content in the file. Use this for surgical edits rather than rewriting the entire file."
    static let inputSchema: [String: AIProxyJSONValue] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description": "File path relative to the workspace root",
            ],
            "search": [
                "type": "string",
                "description": "The exact text to find in the file (must match existing content)",
            ],
            "replace": [
                "type": "string",
                "description": "The replacement text",
            ],
        ],
        "required": ["path", "search", "replace"],
    ]

    func execute(arguments: [String: Any], context: AgentContext) async -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required parameter: path")
        }
        guard let search = arguments["search"] as? String else {
            return .error("Missing required parameter: search")
        }
        guard let replace = arguments["replace"] as? String else {
            return .error("Missing required parameter: replace")
        }

        let url = context.resolveURL(for: path)
        let resolvedPath = url.standardizedFileURL.path

        // Enforce read-before-write
        if !context.filesReadByAgent.contains(resolvedPath) {
            return .error("You must read '\(path)' before editing it. Use read_file first.")
        }

        // Read current content
        let original: String
        do {
            let data = try await context.workSpaceStorage.contents(at: url)
            guard let content = String(data: data, encoding: .utf8) else {
                return .error("File is not valid UTF-8 text: \(path)")
            }
            original = content
        } catch {
            return .error("Failed to read file '\(path)': \(error.localizedDescription)")
        }

        // Apply the edit using SearchReplaceBlock
        let block = SearchReplaceBlock(
            searchText: search, replaceText: replace, language: nil
        )
        guard let updated = block.apply(to: original) else {
            return .error(
                "Could not find the search text in '\(path)'. Ensure the search text exactly matches the file content."
            )
        }

        // Write back using async overload
        guard let data = updated.data(using: .utf8) else {
            return .error("Updated content cannot be encoded as UTF-8")
        }

        do {
            try await context.workSpaceStorage.write(
                at: url, content: data, atomically: true, overwrite: true)

            // Sync Monaco if active file
            if context.isActiveFile(url), let monaco = context.monacoInstance {
                await monaco.setValueForModel(url: url.absoluteString, value: updated)
            }

            return ToolResult("Successfully applied edit to \(path)")
        } catch {
            return .error("Failed to write file '\(path)': \(error.localizedDescription)")
        }
    }
}

// MARK: - list_directory

struct ListDirectoryTool: AgentTool {
    static let name = "list_directory"
    static let toolDescription =
        "List the contents of a directory. Returns file and subdirectory names with type indicators."
    static let inputSchema: [String: AIProxyJSONValue] = [
        "type": "object",
        "properties": [
            "path": [
                "type": "string",
                "description":
                    "Directory path relative to the workspace root. Use '.' or '' for the workspace root.",
            ]
        ],
        "required": ["path"],
    ]

    func execute(arguments: [String: Any], context: AgentContext) async -> ToolResult {
        let path = (arguments["path"] as? String) ?? "."
        let cleanPath = (path == "." || path.isEmpty) ? "" : path
        let url = cleanPath.isEmpty ? context.workspaceRoot : context.resolveURL(for: cleanPath)

        do {
            let urls = try await context.workSpaceStorage.contentsOfDirectory(at: url)
            let items = urls.map { fileURL in
                let isDir = fileURL.hasDirectoryPath
                return "\(isDir ? "[dir]  " : "[file] ")\(fileURL.lastPathComponent)"
            }

            if items.isEmpty {
                return ToolResult("Directory is empty: \(path)")
            }
            return ToolResult(items.joined(separator: "\n"))
        } catch {
            return .error(
                "Failed to list directory '\(path)': \(error.localizedDescription)")
        }
    }
}

// MARK: - search_files

struct SearchFilesTool: AgentTool {
    static let name = "search_files"
    static let toolDescription =
        "Search for a text pattern across files in the workspace using grep. Returns matching lines with file paths and line numbers."
    static let inputSchema: [String: AIProxyJSONValue] = [
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "The text or regex pattern to search for",
            ],
            "path": [
                "type": "string",
                "description":
                    "Optional subdirectory to search in (relative to workspace root). Defaults to entire workspace.",
            ],
            "include": [
                "type": "string",
                "description":
                    "Optional file glob pattern to filter (e.g. '*.swift', '*.ts')",
            ],
        ],
        "required": ["pattern"],
    ]

    private static let maxResults = 50

    func execute(arguments: [String: Any], context: AgentContext) async -> ToolResult {
        guard let pattern = arguments["pattern"] as? String else {
            return .error("Missing required parameter: pattern")
        }

        let searchPath: String
        if let path = arguments["path"] as? String, !path.isEmpty {
            searchPath = context.resolveURL(for: path).path
        } else {
            searchPath = context.workspaceRoot.path
        }

        var cmd = "grep -rn"
        if let include = arguments["include"] as? String, !include.isEmpty {
            cmd += " --include='\(include)'"
        }
        cmd += " --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.build --exclude-dir=DerivedData"
        cmd += " -- '\(pattern.replacingOccurrences(of: "'", with: "'\\''"))'"
        cmd += " '\(searchPath.replacingOccurrences(of: "'", with: "'\\''"))'"

        // Use Executor.runAsync which properly captures output from both
        // onStdout and onRequestInput callbacks
        let executor = Executor(
            root: context.workspaceRoot,
            sessionIdentifier: "com.thebaselab.agent.search.\(UUID().uuidString)",
            onStdout: { _ in },
            onStderr: { _ in },
            onRequestInput: { _ in }
        )

        let (output, _) = await executor.runAsync(command: cmd, timeout: 15)

        if output.isEmpty {
            return ToolResult("No matches found for pattern: \(pattern)")
        }

        let lines = output.components(separatedBy: "\n")
        if lines.count > Self.maxResults {
            let truncated = lines.prefix(Self.maxResults).joined(separator: "\n")
            return ToolResult(
                truncated + "\n\n[\(lines.count - Self.maxResults) more results truncated]")
        }
        return ToolResult(output)
    }
}

// MARK: - run_command

struct RunCommandTool: AgentTool {
    static let name = "run_command"
    static let toolDescription =
        "Run a shell command in the workspace directory. Available runtimes: Python 3.9, Node.js 18, Clang 14, PHP 8.3, git, and common Unix tools. Returns stdout and stderr."
    static let inputSchema: [String: AIProxyJSONValue] = [
        "type": "object",
        "properties": [
            "command": [
                "type": "string",
                "description": "The shell command to execute",
            ]
        ],
        "required": ["command"],
    ]

    func execute(arguments: [String: Any], context: AgentContext) async -> ToolResult {
        guard let command = arguments["command"] as? String else {
            return .error("Missing required parameter: command")
        }

        // Use Executor.runAsync which properly captures output from both
        // onStdout and onRequestInput callbacks
        let executor = Executor(
            root: context.workspaceRoot,
            sessionIdentifier: "com.thebaselab.agent.run.\(UUID().uuidString)",
            onStdout: { _ in },
            onStderr: { _ in },
            onRequestInput: { _ in }
        )

        let (output, exitCode) = await executor.runAsync(command: command, timeout: 30)

        var result = output
        if result.isEmpty {
            result = "(no output)"
        }
        if exitCode != 0 {
            result += "\n\n[Exit code: \(exitCode)]"
        }

        let maxChars = 16_000
        if result.count > maxChars {
            result = String(result.prefix(maxChars)) + "\n\n[Output truncated at \(maxChars) characters]"
        }

        return ToolResult(result, isError: exitCode != 0)
    }
}
