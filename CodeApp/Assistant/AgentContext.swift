//
//  AgentContext.swift
//  CodeApp
//

import Foundation

/// Shared context passed to all agent tools during execution.
/// Class (not struct) so tools can mutate shared state like `filesReadByAgent`.
/// Not MainActor-isolated — tools access it from nonisolated async contexts.
final class AgentContext: @unchecked Sendable {
    enum PathResolutionError: LocalizedError {
        case emptyPath
        case pathTraversal(String)
        case outsideWorkspace(String)

        var errorDescription: String? {
            switch self {
            case .emptyPath:
                return "Path is empty."
            case .pathTraversal(let path):
                return "Path '\(path)' contains invalid traversal components."
            case .outsideWorkspace(let path):
                return "Path '\(path)' is outside the workspace root."
            }
        }
    }

    let workSpaceStorage: WorkSpaceStorage
    let workspaceRoot: URL
    let monacoInstance: EditorImplementation?
    let activeFileURL: URL?
    let workspaceIndexer: WorkspaceIndexer?

    // Phase 1: Rules engine
    var rulesEngine: RulesEngine?

    // Phase 3: Permission manager
    var permissionManager: PermissionManager?

    // Phase 5: Memory manager
    var memoryManager: MemoryManager?

    // Phase 6: Read-before-write tracking
    var filesReadByAgent: Set<String> = []

    init(
        workSpaceStorage: WorkSpaceStorage,
        workspaceRoot: URL,
        monacoInstance: EditorImplementation?,
        activeFileURL: URL?,
        workspaceIndexer: WorkspaceIndexer?,
        rulesEngine: RulesEngine? = nil,
        permissionManager: PermissionManager? = nil,
        memoryManager: MemoryManager? = nil
    ) {
        self.workSpaceStorage = workSpaceStorage
        self.workspaceRoot = workspaceRoot
        self.monacoInstance = monacoInstance
        self.activeFileURL = activeFileURL
        self.workspaceIndexer = workspaceIndexer
        self.rulesEngine = rulesEngine
        self.permissionManager = permissionManager
        self.memoryManager = memoryManager
    }

    /// Resolve a relative/absolute file path and ensure it remains within the workspace root.
    func resolveURL(for rawPath: String) throws -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PathResolutionError.emptyPath }
        if trimmed.split(separator: "/").contains("..") {
            throw PathResolutionError.pathTraversal(rawPath)
        }

        let candidate: URL
        if trimmed.hasPrefix("file://"),
            let fileURL = URL(string: trimmed),
            fileURL.isFileURL
        {
            candidate = fileURL
        } else if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else {
            candidate = workspaceRoot.appendingPathComponent(trimmed)
        }

        let resolved = candidate.standardizedFileURL
        let root = workspaceRoot.standardizedFileURL
        let rootWithSlash = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let isInside = resolved.path == root.path || resolved.path.hasPrefix(rootWithSlash)
        guard isInside else {
            throw PathResolutionError.outsideWorkspace(rawPath)
        }

        return resolved
    }

    func relativePath(for url: URL) -> String {
        let resolved = url.standardizedFileURL.path
        let root = workspaceRoot.standardizedFileURL.path
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        if resolved.hasPrefix(rootWithSlash) {
            return String(resolved.dropFirst(rootWithSlash.count))
        }
        return resolved
    }

    /// Check if a URL corresponds to the currently active editor file.
    func isActiveFile(_ url: URL) -> Bool {
        guard let active = activeFileURL else { return false }
        return active.standardizedFileURL == url.standardizedFileURL
    }
}
