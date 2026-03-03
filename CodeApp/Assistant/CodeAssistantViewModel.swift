//
//  CodeAssistantViewModel.swift
//  CodeApp
//
//  Created by Arya Mirsepasi.
//

import AIProxy
import Foundation

@MainActor
final class CodeAssistantViewModel: ObservableObject {

    struct Message: Identifiable, Codable {
        enum Role: String, Codable {
            case user
            case assistant
            case system
        }

        let id: UUID
        var role: Role
        var body: String
        var payload: String
        let createdAt: Date
        var attachments: [Attachment]
        var isStreaming: Bool
        var errorDescription: String?

        init(
            id: UUID = UUID(),
            role: Role,
            body: String,
            payload: String,
            createdAt: Date = Date(),
            attachments: [Attachment] = [],
            isStreaming: Bool = false,
            errorDescription: String? = nil
        ) {
            self.id = id
            self.role = role
            self.body = body
            self.payload = payload
            self.createdAt = createdAt
            self.attachments = attachments
            self.isStreaming = isStreaming
            self.errorDescription = errorDescription
        }
    }

    struct Attachment: Identifiable, Equatable, Codable {
        let id: UUID
        let url: URL
        let name: String
        let byteCount: Int
        let content: String
        let languageHint: String
        let wasTruncated: Bool

        init(
            id: UUID = UUID(),
            url: URL,
            name: String,
            byteCount: Int,
            content: String,
            languageHint: String,
            wasTruncated: Bool
        ) {
            self.id = id
            self.url = url
            self.name = name
            self.byteCount = byteCount
            self.content = content
            self.languageHint = languageHint
            self.wasTruncated = wasTruncated
        }

        var formattedSize: String {
            byteCount > 1024 ? "\(byteCount / 1024) KB" : "\(byteCount) B"
        }

        var promptBlock: String {
            """
            Attached file: \(name)
            ```\(languageHint)
            \(content)
            ```
            \(wasTruncated ? "_(truncated attachment)_": "")
            """
        }
    }

    enum AssistantError: LocalizedError {
        case missingAPIKey(provider: CodeAssistantProvider)
        case unsupportedAttachment
        case failedToReadFile
        case upstreamError(String)

        var errorDescription: String? {
            switch self {
            case let .missingAPIKey(provider):
                return "\(provider.displayName) API key is missing. Set it in Settings."
            case .unsupportedAttachment:
                return "Only UTF-8 text based files can be attached."
            case .failedToReadFile:
                return "Unable to read the selected file."
            case let .upstreamError(message):
                return message
            }
        }
    }

    struct Conversation: Identifiable, Codable {
        let id: UUID
        var title: String
        var messages: [Message]
        var createdAt: Date
    }

    @Published var isPresented: Bool = false
    @Published var messages: [Message] = []
    @Published var currentInput: String = ""
    @Published var attachments: [Attachment] = []
    @Published var selectedProvider: CodeAssistantProvider {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: Self.providerDefaultsKey)
        }
    }
    @Published var isStreaming: Bool = false
    @Published var errorMessage: String?
    @Published var history: [Conversation] = [] {
        didSet {
            persistHistory()
        }
    }
    @Published var activeConversationTitle: String = "New Chat"
    @Published var temperature: Double = 0.2 {
        didSet {
            defaults.set(temperature, forKey: Self.temperatureDefaultsKey)
        }
    }

    /// Optional context about the user's current selection in the editor.
    /// This is populated by the UI layer just before sending a message so the
    /// model can reliably target edits to the right region of the file.
    struct SelectionContext {
        let text: String
        let startLine: Int
        let startColumn: Int
        let endLine: Int
        let endColumn: Int
        let languageHint: String?
    }

    @Published var selectionContext: SelectionContext?

    // MARK: - Agent Mode

    @Published var isAgentMode: Bool {
        didSet {
            defaults.set(isAgentMode, forKey: Self.agentModeDefaultsKey)
        }
    }
    @Published var agentSession: AgentSession?
    @Published var currentToolActivities: [ToolActivity] = []

    // MARK: - New Services (Phases 1-6)

    let rulesEngine = RulesEngine()
    let slashCommandEngine = SlashCommandEngine()
    let permissionManager = PermissionManager()
    let compactionService = CompactionService()
    let memoryManager = MemoryManager()

    var currentModel: String {
        modelOverrides[selectedProvider] ?? selectedProvider.defaultModel
    }

    var canSend: Bool {
        !currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    /// Estimated token count for the current input context.
    /// Uses simple approximation: ~4 characters per token (common heuristic).
    var estimatedTokenCount: Int {
        var totalChars = currentInput.count
        for attachment in attachments {
            totalChars += attachment.content.count
        }
        if let selection = selectionContext {
            totalChars += selection.text.count
        }
        // Add system prompt estimate (~2K tokens)
        let systemPromptTokens = 2000
        return (totalChars / 4) + systemPromptTokens
    }

    /// Token count color category for UI display.
    enum TokenLevel {
        case low      // < 4K tokens (green)
        case medium   // 4K-8K tokens (yellow)
        case high     // > 8K tokens (red)
    }

    var tokenLevel: TokenLevel {
        if estimatedTokenCount < 4000 {
            return .low
        } else if estimatedTokenCount < 8000 {
            return .medium
        } else {
            return .high
        }
    }

    var formattedTokenCount: String {
        if estimatedTokenCount >= 1000 {
            return String(format: "~%.1fK", Double(estimatedTokenCount) / 1000.0)
        } else {
            return "~\(estimatedTokenCount)"
        }
    }

    private let defaults: UserDefaults
    weak var app: MainApp?

    private var modelOverrides: [CodeAssistantProvider: String] = [:]
    private var streamTask: Task<Void, Never>?
    private let systemPrompt =
        """
        You are Code App's AI coding assistant embedded directly in the editor on iOS/iPadOS.
        Provide concise, actionable answers using clear Markdown formatting. Prefer idiomatic, production‑ready code with brief explanations when they materially help.

        You specialize in the following runtimes and should tailor examples and guidance accordingly:
        - Python 3.9.2
        - Clang 14.0.0 (C/C++)
        - PHP 8.3.2
        - Node.js 18.19.0
        - OpenJDK 8 (Java)
        - Swift 5.x (for Swift files)

        ## CRITICAL: Code Edit Format

        When you need to modify existing code, you MUST use the SEARCH/REPLACE block format. This is essential for the editor to apply your changes correctly.

        **Format:**
        ```language
        <<<<<<< SEARCH
        [exact lines from the original file to find - copy VERBATIM including whitespace]
        =======
        [your replacement code - this replaces the SEARCH block entirely]
        >>>>>>> REPLACE
        ```

        **Rules for SEARCH/REPLACE blocks:**
        1. The SEARCH section must contain EXACT text from the original file (character-for-character match including indentation and whitespace).
        2. Include 2-5 lines of unchanged context BEFORE and AFTER the actual change to anchor the location precisely.
        3. The SEARCH block should be the MINIMAL contiguous section needed. Don't include the entire file.
        4. Each SEARCH/REPLACE block handles ONE logical change. Use multiple blocks for multiple changes.
        5. SEARCH sections must be unique within the file - include enough context lines to ensure uniqueness.
        6. Always include structural anchors in SEARCH blocks:
           - Function/method signatures (e.g., `func myFunction() {`)
           - Class/struct/enum declarations
           - Import statements or module boundaries
           - Unique comment lines
           - Closing braces `}` that match structural openings
        7. Order multiple SEARCH/REPLACE blocks from top to bottom of the file.

        **Example - Fixing a bug in a function:**
        ```swift
        <<<<<<< SEARCH
            func calculateTotal(items: [Item]) -> Double {
                var total = 0.0
                for item in items {
                    total += item.price
                }
                return total
            }
        =======
            func calculateTotal(items: [Item]) -> Double {
                var total = 0.0
                for item in items {
                    total += item.price * Double(item.quantity)
                }
                return total
            }
        >>>>>>> REPLACE
        ```

        **Example - Adding a new method (place after existing code):**
        ```swift
        <<<<<<< SEARCH
            func existingMethod() {
                // existing code
            }
        }
        =======
            func existingMethod() {
                // existing code
            }

            func newMethod() {
                // new implementation
            }
        }
        >>>>>>> REPLACE
        ```

        **When NOT to use SEARCH/REPLACE:**
        - When showing new code snippets not related to file modification
        - When explaining concepts with example code
        - When the user asks for a complete new file
        - When demonstrating syntax or patterns

        ## Editing Behavior

        - When the client provides "Current selection (edit target)", treat that as the primary region to modify.
        - If no selection is provided but file content is attached, analyze the full file and use SEARCH/REPLACE for targeted edits.
        - Never re-format or rewrite the entire file unless explicitly requested.
        - Preserve the original code style, indentation, and conventions.

        ## General Guidelines

        - Be precise and avoid unnecessary verbosity.
        - Validate assumptions and ask for missing details when needed.
        - Emphasize security, performance, readability, and maintainability.
        - Provide step‑by‑step migration or debugging advice when appropriate.
        - Use platform‑appropriate tooling, testing, and packaging recommendations.
        - When presenting non-edit code blocks, specify the correct language for syntax highlighting.
        """

    private let agentSystemPrompt =
        """
        You are an expert coding agent embedded in Code App, an iOS/iPadOS code editor.
        You have access to tools that let you read files, write files, search code, list directories, and run shell commands in the user's workspace.

        ## Your Approach
        1. ALWAYS start by understanding the user's request fully.
        2. Use tools to explore the codebase before making changes — read relevant files first.
        3. Make targeted, surgical edits using the apply_edit tool.
        4. After making changes, verify them when possible (re-read the file, run a command).
        5. If a task requires multiple steps, plan them out and execute sequentially.

        ## Tool Usage Guidelines
        - **read_file**: Read file contents. Path is relative to workspace root.
        - **write_file**: Create new files or completely replace file contents. Use apply_edit for surgical edits.
        - **apply_edit**: Apply a SEARCH/REPLACE edit. The search text must EXACTLY match existing content.
        - **list_directory**: Explore project structure. Use '.' for workspace root.
        - **search_files**: Find code patterns across the workspace using grep.
        - **run_command**: Run shell commands (Python, Node, git, grep, etc.).

        ## Code Edit Format (SEARCH/REPLACE)
        When using apply_edit, the search text must be an EXACT match of existing file content including whitespace and indentation.
        Include 2-5 lines of context before and after the actual change for precise anchoring.

        ## Environment
        - iOS runtimes: Python 3.9.2, Node.js 18.19.0, Clang 14.0.0 (C/C++), PHP 8.3.2, OpenJDK 8
        - Shell commands run via ios_system (common Unix tools: grep, sed, awk, cat, ls, find, git, etc.)
        - File paths are relative to the workspace root directory
        - Cannot spawn background daemons or long-running servers

        ## Important Rules
        - Never modify files without reading them first.
        - Keep explanations concise. Focus on actions and results.
        - Preserve the original code style, indentation, and conventions.
        - If you cannot complete a task, explain what you tried and why it failed.
        - Report what files you changed and summarize the changes made.
        """

    /// System prompt with rules injected for chat mode.
    private var effectiveSystemPrompt: String {
        let rules = rulesEngine.rulesContent(forFilePath: nil, mode: "chat")
        if rules.isEmpty { return systemPrompt }
        return systemPrompt + "\n\n<rules>\n\(rules)\n</rules>"
    }

    private static let providerDefaultsKey = "codeassistant.provider.active"
    private static let temperatureDefaultsKey = "codeassistant.temperature"
    private static let agentModeDefaultsKey = "codeassistant.agentMode"
    private static func modelDefaultsKey(for provider: CodeAssistantProvider) -> String {
        "codeassistant.model.\(provider.rawValue)"
    }

    private static let maxAttachmentCharacters = 24_000
    private var activeConversationID = UUID()
    private static let historyDefaultsKey = "codeassistant.history.archive"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let storedProvider = defaults.string(forKey: Self.providerDefaultsKey),
            let provider = CodeAssistantProvider(rawValue: storedProvider)
        {
            selectedProvider = provider
        } else {
            selectedProvider = .openAI
        }

        for provider in CodeAssistantProvider.allCases {
            let storedModel = defaults.string(forKey: Self.modelDefaultsKey(for: provider))
            modelOverrides[provider] = storedModel ?? provider.defaultModel
        }

        if defaults.object(forKey: Self.temperatureDefaultsKey) != nil {
            temperature = defaults.double(forKey: Self.temperatureDefaultsKey)
        }

        // Default to agent mode on
        if defaults.object(forKey: Self.agentModeDefaultsKey) != nil {
            isAgentMode = defaults.bool(forKey: Self.agentModeDefaultsKey)
        } else {
            isAgentMode = true
        }

        loadHistory()
    }

    func updateModel(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalValue = normalized.isEmpty ? selectedProvider.defaultModel : normalized
        modelOverrides[selectedProvider] = finalValue
        defaults.set(finalValue, forKey: Self.modelDefaultsKey(for: selectedProvider))
    }

    func attach(item: WorkSpaceStorage.FileItemRepresentable) {
        guard let url = item._url else {
            errorMessage = AssistantError.failedToReadFile.errorDescription
            return
        }
        Task.detached(priority: .userInitiated) {
            let attachment = await Self.buildAttachment(from: url, displayName: item.name)
            await MainActor.run {
                switch attachment {
                case let .success(result):
                    if !self.attachments.contains(where: { $0.url == result.url }) {
                        self.attachments.append(result)
                    }
                    self.errorMessage = nil
                case let .failure(error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func clearConversation() {
        startNewConversation()
    }

    func startNewConversation() {
        archiveCurrentConversationIfNeeded()
        stopStreaming()
        messages.removeAll()
        attachments.removeAll()
        currentInput = ""
        errorMessage = nil
        activeConversationID = UUID()
        activeConversationTitle = "New Chat"
        permissionManager.clearSession()
    }

    /// Configure all services for the current workspace. Call when workspace changes.
    func configureForWorkspace() {
        guard let app, let workspaceURL = app.workSpaceStorage.currentDirectory._url else { return }

        // Load rules
        Task {
            _ = await rulesEngine.loadRules(workspaceRoot: workspaceURL)
        }

        // Scan commands
        slashCommandEngine.scan(workspaceRoot: workspaceURL)

        // Load permissions
        permissionManager.loadForWorkspace(root: workspaceURL)

        // Configure memory
        memoryManager.configure(workspaceRoot: workspaceURL)
        Task {
            _ = await memoryManager.loadIndex()
        }
    }

    func loadConversation(_ conversation: Conversation) {
        archiveCurrentConversationIfNeeded()
        stopStreaming()
        history.removeAll { $0.id == conversation.id }
        messages = conversation.messages
        activeConversationID = conversation.id
        activeConversationTitle = conversation.title
        currentInput = ""
        attachments.removeAll()
        errorMessage = nil
    }

    func deleteConversation(_ conversation: Conversation) {
        history.removeAll { $0.id == conversation.id }
    }

    func clearHistory() {
        history.removeAll()
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        agentSession?.cancel()
        agentSession = nil
        isStreaming = false
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].isStreaming = false
        }
    }

    func sendMessage() {
        let trimmed = currentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else {
            return
        }

        // Slash command interception (Phase 2)
        if trimmed.hasPrefix("/"), let (command, arguments) = slashCommandEngine.resolve(input: trimmed) {
            currentInput = ""
            dispatchSlashCommand(command, arguments: arguments)
            return
        }

        let userPayload = buildPayload(for: trimmed, attachments: attachments)

        let userMessage = Message(
            role: .user,
            body: trimmed.isEmpty ? "Attached files" : trimmed,
            payload: userPayload,
            attachments: attachments
        )
        messages.append(userMessage)
        if messages.count == 1 {
            activeConversationTitle = deriveTitle(from: messages)
        }
        currentInput = ""

        let placeholder = Message(
            role: .assistant,
            body: "",
            payload: "",
            attachments: [],
            isStreaming: true
        )
        messages.append(placeholder)
        isStreaming = true
        errorMessage = nil

        let conversationContext = messages.filter { $0.id != placeholder.id }
        let provider = selectedProvider
        let model = currentModel

        attachments.removeAll()

        // Agent mode: use the agentic tool-calling loop
        if isAgentMode {
            sendAgentMessage(
                userPayload: userPayload,
                conversationContext: conversationContext,
                placeholderID: placeholder.id,
                provider: provider,
                model: model
            )
            return
        }

        // Standard chat mode (no tools)
        streamTask = Task {
            do {
                switch provider {
                case .openAI:
                    try await streamOpenAI(
                        history: conversationContext,
                        placeholderID: placeholder.id,
                        model: model)
                case .anthropic:
                    try await streamAnthropic(
                        history: conversationContext,
                        placeholderID: placeholder.id,
                        model: model)
                case .openRouter:
                    try await streamOpenRouter(
                        history: conversationContext,
                        placeholderID: placeholder.id,
                        model: model)
                }
            } catch {
                await MainActor.run {
                    self.handle(error: error, placeholderID: placeholder.id)
                }
            }
        }
    }

    // MARK: - Agent Mode

    private func sendAgentMessage(
        userPayload: String,
        conversationContext: [Message],
        placeholderID: UUID,
        provider: CodeAssistantProvider,
        model: String
    ) {
        currentToolActivities.removeAll()

        guard let app else {
            handle(
                error: CodeAssistantViewModel.AssistantError.upstreamError(
                    "App reference not set. Cannot use agent mode."),
                placeholderID: placeholderID
            )
            return
        }

        guard let workspaceURL = app.workSpaceStorage.currentDirectory._url else {
            handle(
                error: CodeAssistantViewModel.AssistantError.upstreamError(
                    "No workspace directory open."),
                placeholderID: placeholderID
            )
            return
        }

        let context = AgentContext(
            workSpaceStorage: app.workSpaceStorage,
            workspaceRoot: workspaceURL,
            monacoInstance: app.monacoInstance,
            activeFileURL: app.activeTextEditor?.url,
            workspaceIndexer: app.workspaceIndexer,
            rulesEngine: rulesEngine,
            permissionManager: permissionManager,
            memoryManager: memoryManager
        )

        let session = AgentSession(
            provider: provider,
            model: model,
            temperature: temperature,
            systemPrompt: agentSystemPrompt,
            context: context
        )

        session.onTextDelta = { [weak self] delta in
            guard let self,
                let idx = self.messages.firstIndex(where: { $0.id == placeholderID })
            else { return }
            self.messages[idx].body += delta
        }

        session.onToolActivityUpdate = { [weak self] activity in
            guard let self else { return }
            if let idx = self.currentToolActivities.firstIndex(where: { $0.id == activity.id }) {
                self.currentToolActivities[idx] = activity
            } else {
                self.currentToolActivities.append(activity)
            }
        }

        // Permission request handler (Phase 3)
        session.onPermissionRequest = { [weak self] toolName, description, completion in
            guard let self, let app = self.app else {
                completion(false)
                return
            }
            app.notificationManager.postActionNotification(
                title: "Allow \(ToolActivity.displayName(for: toolName).lowercased())?",
                level: .warning,
                primary: { completion(true) },
                primaryTitle: "Allow",
                secondary: { completion(false) },
                secondaryTitle: "Deny",
                source: description
            )
        }

        session.onComplete = { [weak self] in
            self?.finalizeStream(for: placeholderID)
            self?.agentSession = nil

            // Memory evaluation (Phase 5)
            if let self {
                self.evaluateMemoryPersistence()
            }
        }

        session.onError = { [weak self] error in
            self?.handle(error: error, placeholderID: placeholderID)
            self?.agentSession = nil
        }

        // Pass prior conversation (excluding the placeholder) so the agent has context
        let priorMessages = conversationContext.filter { $0.role != .system }
        session.start(userMessage: userPayload, conversationHistory: priorMessages)
        agentSession = session
    }

    private func handle(error: Error, placeholderID: UUID) {
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].isStreaming = false
            messages[index].errorDescription = error.localizedDescription
        }
        errorMessage = error.localizedDescription
        isStreaming = false
        streamTask = nil
    }

    private func finalizeStream(for placeholderID: UUID) {
        if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
            messages[index].isStreaming = false
            messages[index].payload = messages[index].body
        }
        isStreaming = false
        streamTask = nil
    }

    private func streamOpenAI(
        history: [Message],
        placeholderID: UUID,
        model: String
    ) async throws {
        let apiKey = CodeAssistantSettings.apiKey(for: .openAI)
        guard !apiKey.isEmpty else {
            throw AssistantError.missingAPIKey(provider: .openAI)
        }

        let service = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)
        let requestBody = OpenAIChatCompletionRequestBody(
            model: model,
            messages: openAIMessages(from: history),
            temperature: temperature
        )

        let stream = try await service.streamingChatCompletionRequest(body: requestBody, secondsToWait: 60)
        do {
            for try await chunk in stream {
                guard let delta = chunk.choices.first?.delta.content else {
                    continue
                }
                if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                    messages[index].body += delta
                }
            }
            finalizeStream(for: placeholderID)
        } catch {
            throw error
        }
    }

    private func streamOpenRouter(
        history: [Message],
        placeholderID: UUID,
        model: String
    ) async throws {
        let apiKey = CodeAssistantSettings.apiKey(for: .openRouter)
        guard !apiKey.isEmpty else {
            throw AssistantError.missingAPIKey(provider: .openRouter)
        }

        let service = AIProxy.openRouterDirectService(unprotectedAPIKey: apiKey)
        let body = OpenRouterChatCompletionRequestBody(
            messages: openRouterMessages(from: history),
            models: [model],
            temperature: temperature
        )

        let stream = try await service.streamingChatCompletionRequest(body: body)
        do {
            for try await chunk in stream {
                guard let delta = chunk.choices.first?.delta.content else {
                    continue
                }
                if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                    messages[index].body += delta
                }
            }
            finalizeStream(for: placeholderID)
        } catch {
            throw error
        }
    }

    private func streamAnthropic(
        history: [Message],
        placeholderID: UUID,
        model: String
    ) async throws {
        let apiKey = CodeAssistantSettings.apiKey(for: .anthropic)
        guard !apiKey.isEmpty else {
            throw AssistantError.missingAPIKey(provider: .anthropic)
        }

        let service = AIProxy.anthropicDirectService(unprotectedAPIKey: apiKey)
        let body = AnthropicMessageRequestBody(
            maxTokens: 8192,
            messages: anthropicMessages(from: history),
            model: model,
            system: .text(effectiveSystemPrompt),
            temperature: temperature
        )

        let stream = try await service.streamingMessageRequest(
            body: body, secondsToWait: 60
        )
        for try await event in stream {
            if case .contentBlockDelta(let delta) = event,
               case .textDelta(let textDelta) = delta.delta {
                if let index = messages.firstIndex(where: { $0.id == placeholderID }) {
                    messages[index].body += textDelta.text
                }
            }
        }
        finalizeStream(for: placeholderID)
    }

    private func openAIMessages(from history: [Message]) -> [OpenAIChatCompletionRequestBody.Message] {
        var payload: [OpenAIChatCompletionRequestBody.Message] = [
            .system(content: .text(effectiveSystemPrompt))
        ]
        payload += history.compactMap { message in
            switch message.role {
            case .user:
                return .user(content: .text(message.payload))
            case .assistant:
                return .assistant(content: .text(message.payload))
            case .system:
                return .system(content: .text(message.payload))
            }
        }
        return payload
    }

    private func openRouterMessages(from history: [Message]) -> [OpenRouterChatCompletionRequestBody.Message] {
        var payload: [OpenRouterChatCompletionRequestBody.Message] = [
            .system(content: .text(effectiveSystemPrompt))
        ]
        payload += history.compactMap { message in
            switch message.role {
            case .user:
                return .user(content: .text(message.payload))
            case .assistant:
                return .assistant(content: .text(message.payload))
            case .system:
                return .system(content: .text(message.payload))
            }
        }
        return payload
    }

    private func anthropicMessages(from history: [Message]) -> [AnthropicInputMessage] {
        // System prompt is passed via the `system:` parameter on the request body.
        return history.compactMap { message in
            switch message.role {
            case .user:
                return AnthropicInputMessage(content: .text(message.payload), role: .user)
            case .assistant:
                return AnthropicInputMessage(content: .text(message.payload), role: .assistant)
            case .system:
                return nil
            }
        }
    }

    private func buildPayload(for text: String, attachments: [Attachment]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var blocks: [String] = []
        if !trimmed.isEmpty {
            blocks.append(trimmed)
        }

        if let selectionContext, !selectionContext.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var selectionHeader = "Current selection (edit target):\n"
            selectionHeader += "Lines \(selectionContext.startLine):\(selectionContext.startColumn) → \(selectionContext.endLine):\(selectionContext.endColumn)\n"

            let language = selectionContext.languageHint ?? "text"
            let fenced =
                "```\(language)\n\(selectionContext.text)\n```\n"

            blocks.append(selectionHeader + fenced)
        }

        let attachmentBlock = attachments.map(\.promptBlock).joined(separator: "\n\n")
        if !attachmentBlock.isEmpty {
            blocks.append(attachmentBlock)
        }

        // Clear selection context after it has been consumed for this request.
        selectionContext = nil

        return blocks
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func buildAttachment(from url: URL, displayName: String) -> Result<
        Attachment, AssistantError
    > {
        do {
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else {
                return .failure(.unsupportedAttachment)
            }
            var text = content
            var truncated = false
            if text.count > maxAttachmentCharacters {
                let index = text.index(text.startIndex, offsetBy: maxAttachmentCharacters)
                text = String(text[..<index])
                truncated = true
            }
            return .success(
                Attachment(
                    url: url,
                    name: displayName,
                    byteCount: data.count,
                    content: text,
                    languageHint: languageHint(for: url),
                    wasTruncated: truncated
                )
            )
        } catch {
            return .failure(.failedToReadFile)
        }
    }

    static func languageHint(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let mapping: [String: String] = [
            "swift": "swift",
            "m": "objectivec",
            "mm": "objectivec",
            "h": "c",
            "hpp": "cpp",
            "cpp": "cpp",
            "c": "c",
            "cc": "cpp",
            "js": "javascript",
            "ts": "typescript",
            "tsx": "tsx",
            "jsx": "jsx",
            "kt": "kotlin",
            "java": "java",
            "py": "python",
            "rb": "ruby",
            "php": "php",
            "cs": "csharp",
            "rs": "rust",
            "go": "go",
            "sql": "sql",
            "json": "json",
            "yml": "yaml",
            "yaml": "yaml",
            "sh": "bash",
            "bat": "batch",
            "md": "markdown",
            "html": "html",
            "css": "css",
            "scss": "scss",
        ]
        return mapping[ext] ?? "text"
    }

    private func persistHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        defaults.set(data, forKey: Self.historyDefaultsKey)
    }

    private func loadHistory() {
        guard let data = defaults.data(forKey: Self.historyDefaultsKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([Conversation].self, from: data) else { return }
        history = stored
    }

    private func archiveCurrentConversationIfNeeded() {
        guard !messages.isEmpty else { return }
        let snapshot = Conversation(
            id: activeConversationID,
            title: deriveTitle(from: messages),
            messages: messages,
            createdAt: Date()
        )
        history.removeAll { $0.id == snapshot.id }
        history.insert(snapshot, at: 0)
        if history.count > 20 {
            history = Array(history.prefix(20))
        }

        // Save session history for memory (Phase 5)
        let sessionId = activeConversationID
        let messageCopy = messages
        Task {
            await memoryManager.saveSessionHistory(messages: messageCopy, sessionId: sessionId)
        }
    }

    // MARK: - Slash Commands (Phase 2)

    private func dispatchSlashCommand(_ command: SlashCommand, arguments: String) {
        switch command.id {
        case "clear":
            clearConversation()

        case "help":
            let helpText = slashCommandEngine.commands.map { cmd in
                "**\(cmd.name)** — \(cmd.description)"
            }.joined(separator: "\n")

            messages.append(Message(
                role: .system,
                body: "Available commands:\n\n\(helpText)",
                payload: ""
            ))

        case "compact":
            performCompaction(arguments: arguments)

        case "init":
            performProjectInit(arguments: arguments)

        default:
            // Custom command: substitute $ARGUMENTS and send as user message
            let body = command.body.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
            currentInput = body
            sendMessage()
        }
    }

    // MARK: - Compaction (Phase 4)

    private func performCompaction(arguments: String) {
        guard !messages.isEmpty else {
            errorMessage = "No messages to compact."
            return
        }

        let messagesToCompact = messages
        let provider = selectedProvider
        let model = currentModel

        messages.append(Message(
            role: .system,
            body: "Compacting conversation...",
            payload: "",
            isStreaming: true
        ))
        isStreaming = true

        Task {
            do {
                let summary = try await compactionService.compact(
                    messages: messagesToCompact,
                    provider: provider,
                    model: model,
                    instructions: arguments
                )

                messages.removeAll()
                messages.append(Message(
                    role: .system,
                    body: "**Conversation Summary**\n\n\(summary)",
                    payload: summary
                ))
                isStreaming = false
            } catch {
                if let idx = messages.lastIndex(where: { $0.isStreaming }) {
                    messages[idx].isStreaming = false
                    messages[idx].errorDescription = error.localizedDescription
                }
                isStreaming = false
                errorMessage = "Compaction failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Project Discovery (Phase 6)

    private func performProjectInit(arguments: String) {
        guard let app, let workspaceURL = app.workSpaceStorage.currentDirectory._url else {
            errorMessage = "No workspace directory open."
            return
        }

        messages.append(Message(
            role: .system,
            body: "Discovering project structure...",
            payload: "",
            isStreaming: true
        ))
        isStreaming = true

        Task {
            do {
                // 1. Build file tree
                let tree = await buildFileTree(root: workspaceURL, maxDepth: 3)

                // 2. Detect and read config files
                let configs = await detectAndReadConfigFiles(root: workspaceURL)

                // 3. Send to LLM for rules generation
                let prompt = """
                Analyze this project and generate a `.codeapp/rules.md` file that will be injected as context \
                for the AI coding assistant. Include:
                - Project type and tech stack
                - Key conventions and patterns to follow
                - Important file paths and their purposes
                - Build/run/test commands
                - Any other helpful context for an AI assistant working in this project

                Keep it concise (under 100 lines). Use markdown format.

                \(arguments.isEmpty ? "" : "Additional instructions: \(arguments)\n")

                FILE TREE:
                \(tree)

                CONFIG FILES:
                \(configs)
                """

                let summary = try await compactionService.compact(
                    messages: [Message(role: .user, body: prompt, payload: prompt)],
                    provider: selectedProvider,
                    model: currentModel,
                    instructions: "Generate a rules file, not a summary."
                )

                // 4. Write to .codeapp/rules.md
                let codeappDir = workspaceURL.appendingPathComponent(".codeapp")
                try? FileManager.default.createDirectory(
                    at: codeappDir, withIntermediateDirectories: true
                )
                let rulesFile = codeappDir.appendingPathComponent("rules.md")
                try summary.data(using: .utf8)?.write(to: rulesFile)

                // 5. Reload rules engine
                await rulesEngine.reload(workspaceRoot: workspaceURL)

                // 6. Show confirmation
                if let idx = messages.lastIndex(where: { $0.isStreaming }) {
                    messages[idx].isStreaming = false
                    messages[idx].body = "Project initialized! Generated `.codeapp/rules.md`.\n\n\(summary)"
                }
                isStreaming = false

            } catch {
                if let idx = messages.lastIndex(where: { $0.isStreaming }) {
                    messages[idx].isStreaming = false
                    messages[idx].errorDescription = error.localizedDescription
                }
                isStreaming = false
                errorMessage = "Project init failed: \(error.localizedDescription)"
            }
        }
    }

    private func buildFileTree(root: URL, maxDepth: Int) async -> String {
        var lines: [String] = []
        let fm = FileManager.default
        let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".codeapp", "__pycache__", ".venv", "venv"]

        func walk(url: URL, depth: Int, prefix: String) {
            guard depth < maxDepth else { return }
            guard let contents = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for item in sorted {
                let name = item.lastPathComponent
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDir && skipDirs.contains(name) { continue }

                lines.append("\(prefix)\(isDir ? "\(name)/" : name)")
                if isDir {
                    walk(url: item, depth: depth + 1, prefix: prefix + "  ")
                }
            }
        }

        walk(url: root, depth: 0, prefix: "")
        return lines.joined(separator: "\n")
    }

    private func detectAndReadConfigFiles(root: URL) async -> String {
        let configNames = [
            "Package.swift", "package.json", "Cargo.toml", "Makefile",
            "requirements.txt", "pyproject.toml", ".gitignore", "README.md",
            "tsconfig.json", "build.gradle", "pom.xml", "go.mod",
            "Gemfile", "composer.json", "CMakeLists.txt",
        ]
        let fm = FileManager.default
        var result: [String] = []

        for name in configNames {
            let url = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8)
            else { continue }

            // Truncate README to first 100 lines
            var text = content
            if name == "README.md" {
                let lines = text.components(separatedBy: .newlines)
                if lines.count > 100 {
                    text = lines.prefix(100).joined(separator: "\n") + "\n[truncated]"
                }
            }
            // Cap all config files at 5000 chars
            if text.count > 5000 {
                text = String(text.prefix(5000)) + "\n[truncated]"
            }

            result.append("--- \(name) ---\n\(text)")
        }

        return result.joined(separator: "\n\n")
    }

    // MARK: - Memory Evaluation (Phase 5)

    private func evaluateMemoryPersistence() {
        guard let lastAssistant = messages.last(where: { $0.role == .assistant }),
              !lastAssistant.body.isEmpty
        else { return }

        let turn = lastAssistant.body
        let provider = selectedProvider
        let model = currentModel

        Task {
            let (persist, fact, topic) = await memoryManager.evaluateForPersistence(
                turn: turn, provider: provider, model: model
            )
            if persist {
                await memoryManager.persist(fact: fact, topic: topic)
            }
        }
    }

    // MARK: - Private Helpers

    private func deriveTitle(from messages: [Message]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
            }
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return "Chat \(formatter.string(from: Date()))"
    }
}
