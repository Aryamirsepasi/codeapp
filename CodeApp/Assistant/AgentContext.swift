//
//  AgentContext.swift
//  CodeApp
//

import Foundation

/// Shared context passed to all agent tools during execution.
/// Class (not struct) so tools can mutate shared state like `filesReadByAgent`.
/// Not MainActor-isolated — tools access it from nonisolated async contexts.
final class AgentContext: @unchecked Sendable {
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

    /// Resolve a relative path against the workspace root.
    func resolveURL(for relativePath: String) -> URL {
        let cleaned = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
        return workspaceRoot.appendingPathComponent(cleaned)
    }

    /// Check if a URL corresponds to the currently active editor file.
    func isActiveFile(_ url: URL) -> Bool {
        guard let active = activeFileURL else { return false }
        return active.standardizedFileURL == url.standardizedFileURL
    }
}
