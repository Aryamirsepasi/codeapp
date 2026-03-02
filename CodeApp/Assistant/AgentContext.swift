//
//  AgentContext.swift
//  CodeApp
//

import Foundation

/// Shared context passed to all agent tools during execution.
struct AgentContext {
    let workSpaceStorage: WorkSpaceStorage
    let workspaceRoot: URL
    let monacoInstance: EditorImplementation?
    let activeFileURL: URL?
    let workspaceIndexer: WorkspaceIndexer?

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
