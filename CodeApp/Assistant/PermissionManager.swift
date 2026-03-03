//
//  PermissionManager.swift
//  CodeApp
//
//  Layered permission system for the AI agent. Evaluates tool calls against
//  deny/allow rules, session allowances, and the active permission mode.
//  Supports loading configuration from .codeapp/permissions.json.
//

import Foundation

// MARK: - Permission Types

enum PermissionMode: String, CaseIterable, Codable, Identifiable {
    case `default`
    case acceptEdits
    case readOnly
    case autoApprove

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .acceptEdits: return "Accept Edits"
        case .readOnly: return "Read Only"
        case .autoApprove: return "Auto Approve"
        }
    }

    var description: String {
        switch self {
        case .default: return "Prompt for writes and commands"
        case .acceptEdits: return "Auto-approve file edits, prompt for commands"
        case .readOnly: return "Deny all writes and commands"
        case .autoApprove: return "Approve everything automatically"
        }
    }
}

enum PermissionDecision {
    case allow
    case deny(String)
    case promptUser
}

struct PermissionRule: Codable {
    let toolName: String?
    let pathPattern: String?
    let commandPattern: String?
    let action: String  // "allow" or "deny"
}

// MARK: - Permission Manager

@MainActor
final class PermissionManager: ObservableObject {

    @Published var mode: PermissionMode = .default {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    private var sessionAllowances: Set<String> = []
    private var denyRules: [PermissionRule] = []
    private var allowRules: [PermissionRule] = []

    private static let modeKey = "codeassistant.permission.mode"

    // Tools classified by their side-effect level
    private static let readTools: Set<String> = ["read_file", "list_directory", "search_files"]
    private static let writeTools: Set<String> = ["write_file", "apply_edit"]
    private static let commandTools: Set<String> = ["run_command"]

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.modeKey),
           let mode = PermissionMode(rawValue: stored) {
            self.mode = mode
        }
    }

    // MARK: - Evaluation

    /// Evaluate whether a tool call should be allowed, denied, or prompt the user.
    func evaluate(toolName: String, arguments: [String: Any]) -> PermissionDecision {
        let path = arguments["path"] as? String
        let command = arguments["command"] as? String

        // 1. Deny rules match first
        for rule in denyRules {
            if ruleMatches(rule, toolName: toolName, path: path, command: command) {
                return .deny("Blocked by deny rule: \(rule.toolName ?? rule.pathPattern ?? rule.commandPattern ?? "unknown")")
            }
        }

        // 2. Allow rules match
        for rule in allowRules {
            if ruleMatches(rule, toolName: toolName, path: path, command: command) {
                return .allow
            }
        }

        // 3. Session allowances
        let sessionKey = buildSessionKey(toolName: toolName, path: path, command: command)
        if sessionAllowances.contains(sessionKey) {
            return .allow
        }

        // 4. Mode-based evaluation
        switch mode {
        case .autoApprove:
            return .allow

        case .readOnly:
            if Self.writeTools.contains(toolName) || Self.commandTools.contains(toolName) {
                return .deny("Read-only mode: \(toolName) is not permitted")
            }
            return .allow

        case .acceptEdits:
            if Self.readTools.contains(toolName) || Self.writeTools.contains(toolName) {
                return .allow
            }
            if Self.commandTools.contains(toolName) {
                return .promptUser
            }
            return .allow

        case .default:
            if Self.readTools.contains(toolName) {
                return .allow
            }
            return .promptUser
        }
    }

    // MARK: - Config Loading

    /// Load permission rules from a JSON config file.
    func loadConfig(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }

        struct ConfigFile: Codable {
            let deny: [PermissionRule]?
            let allow: [PermissionRule]?
            let mode: String?
        }

        guard let config = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return }

        denyRules = config.deny ?? []
        allowRules = config.allow ?? []

        if let modeStr = config.mode, let configMode = PermissionMode(rawValue: modeStr) {
            mode = configMode
        }
    }

    /// Load permission config from workspace.
    func loadForWorkspace(root: URL) {
        let configURL = root
            .appendingPathComponent(".codeapp")
            .appendingPathComponent("permissions.json")
        loadConfig(from: configURL)
    }

    // MARK: - Session Allowances

    /// Grant a session-scoped allowance (persists until conversation reset).
    func grantSession(key: String) {
        sessionAllowances.insert(key)
    }

    /// Grant session allowance for a specific tool call.
    func grantSessionForToolCall(toolName: String, arguments: [String: Any]) {
        let key = buildSessionKey(
            toolName: toolName,
            path: arguments["path"] as? String,
            command: arguments["command"] as? String
        )
        sessionAllowances.insert(key)
    }

    /// Clear session allowances (on new conversation).
    func clearSession() {
        sessionAllowances.removeAll()
    }

    // MARK: - Private

    private func ruleMatches(
        _ rule: PermissionRule, toolName: String, path: String?, command: String?
    ) -> Bool {
        // Tool name must match if specified
        if let ruleTool = rule.toolName, ruleTool != toolName {
            return false
        }

        // Path pattern must match if specified
        if let rulePattern = rule.pathPattern, let path {
            if !simpleGlobMatch(pattern: rulePattern, string: path) {
                return false
            }
        } else if rule.pathPattern != nil && path == nil {
            return false
        }

        // Command pattern must match if specified
        if let rulePattern = rule.commandPattern, let command {
            if !command.contains(rulePattern) {
                return false
            }
        } else if rule.commandPattern != nil && command == nil {
            return false
        }

        return true
    }

    private func buildSessionKey(toolName: String, path: String?, command: String?) -> String {
        if let path {
            return "\(toolName):\(path)"
        }
        if let command {
            return "\(toolName):\(command)"
        }
        return toolName
    }

    private func simpleGlobMatch(pattern: String, string: String) -> Bool {
        if pattern == "*" { return true }
        if pattern.hasPrefix("*.") {
            let ext = String(pattern.dropFirst(2))
            return string.hasSuffix(".\(ext)")
        }
        if pattern.hasSuffix("/*") {
            let dir = String(pattern.dropLast(2))
            return string.hasPrefix(dir)
        }
        return string == pattern || string.hasSuffix("/\(pattern)")
    }
}
