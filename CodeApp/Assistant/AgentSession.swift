//
//  AgentSession.swift
//  CodeApp
//
//  Drives the multi-turn agentic loop: sends messages with tools,
//  processes tool calls, sends tool results back, and iterates until
//  the model produces a final text response or budget is exhausted.
//

import AIProxy
import Foundation

// MARK: - Tool Activity (UI model)

struct ToolActivity: Identifiable {
    let id: UUID
    let toolName: String
    let summary: String
    var status: Status
    var resultPreview: String?
    let startedAt: Date
    var completedAt: Date?

    enum Status {
        case running
        case completed
        case failed
    }

    init(toolName: String, summary: String) {
        self.id = UUID()
        self.toolName = toolName
        self.summary = summary
        self.status = .running
        self.startedAt = Date()
    }

    static func displayName(for toolName: String) -> String {
        switch toolName {
        case "read_file": return "Reading file"
        case "write_file": return "Writing file"
        case "create_file": return "Creating file"
        case "apply_edit": return "Applying edit"
        case "list_directory": return "Listing directory"
        case "search_files": return "Searching files"
        case "run_command": return "Running command"
        default: return toolName
        }
    }
}

// MARK: - Internal Message Types

enum AgentInternalMessage {
    case system(String)
    case user(String)
    case assistantText(String)
    case assistantToolCalls([AgentToolCall])
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

struct AgentToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

enum OpenRouterReplayEnvelope {
    private static let marker = "codeapp_tool"

    static func toolCall(id: String, name: String, arguments: [String: Any]) -> String {
        let payload: [String: Any] = [
            "type": "tool_call",
            "id": id,
            "name": name,
            "arguments": arguments,
        ]
        return wrap(payload)
    }

    static func toolResult(toolCallID: String, content: String, isError: Bool) -> String {
        let payload: [String: Any] = [
            "type": "tool_result",
            "tool_call_id": toolCallID,
            "is_error": isError,
            "content": content,
        ]
        return wrap(payload)
    }

    static func normalizeHistoryContent(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        return trimmed.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func wrap(_ payload: [String: Any]) -> String {
        let json = serializeJSON(payload)
        return "<\(marker)>\(json)</\(marker)>"
    }

    private static func serializeJSON(_ dict: [String: Any]) -> String {
        guard
            JSONSerialization.isValidJSONObject(dict),
            let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
            let str = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return str
    }
}

struct StreamedToolCallAccumulator {
    private struct Entry {
        let order: Int
        var id: String
        var name: String
        var arguments: String
    }

    private var entries: [String: Entry] = [:]
    private var nextOrder = 0
    private var nextGeneratedID = 0
    private var nextFallbackKey = 0
    private var activeUnindexedKey: String?

    mutating func append(index: Int?, id: String?, name: String?, arguments: String?) {
        let key = resolveKey(index: index, id: id, name: name)
        var entry = entries[key] ?? Entry(
            order: nextOrder,
            id: (id?.isEmpty == false ? id : nil) ?? makeGeneratedID(),
            name: "",
            arguments: ""
        )
        if entries[key] == nil {
            nextOrder += 1
        }

        if let id, !id.isEmpty {
            entry.id = id
        }
        if let name, !name.isEmpty {
            entry.name = name
        }
        if let arguments, !arguments.isEmpty {
            entry.arguments += arguments
        }

        entries[key] = entry
        activeUnindexedKey = (index == nil) ? key : nil
    }

    func makeToolCalls(parseJSON: (String) -> [String: Any]) -> [AgentToolCall] {
        entries.values
            .sorted { $0.order < $1.order }
            .map { entry in
                let normalizedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return AgentToolCall(
                    id: entry.id,
                    name: normalizedName.isEmpty ? "__missing_tool_name__" : normalizedName,
                    arguments: parseJSON(entry.arguments)
                )
            }
    }

    private mutating func resolveKey(index: Int?, id: String?, name: String?) -> String {
        if let index {
            return "index:\(index)"
        }
        if let id, !id.isEmpty {
            return "id:\(id)"
        }
        if let activeUnindexedKey,
           let entry = entries[activeUnindexedKey],
           entry.name.isEmpty || (name?.isEmpty ?? true) {
            return activeUnindexedKey
        }

        let key = "fallback:\(nextFallbackKey)"
        nextFallbackKey += 1
        return key
    }

    private mutating func makeGeneratedID() -> String {
        defer { nextGeneratedID += 1 }
        return "toolcall-\(nextGeneratedID)"
    }
}

// MARK: - Agent Session

@MainActor
final class AgentSession: ObservableObject {

    enum SessionState {
        case idle
        case streaming
        case executingTools
        case completed
        case failed(Error)
        case cancelled
    }

    // MARK: Callbacks (set by ViewModel)

    var onTextDelta: ((String) -> Void)?
    var onToolActivityUpdate: ((ToolActivity) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((Error) -> Void)?

    /// Permission request callback. Parameters: tool name, description, completion (allow/deny).
    var onPermissionRequest: ((String, String, @escaping (Bool) -> Void) -> Void)?

    // MARK: Published state

    @Published private(set) var state: SessionState = .idle
    @Published private(set) var toolActivities: [ToolActivity] = []
    @Published private(set) var iterationCount: Int = 0

    // MARK: Configuration

    private let provider: CodeAssistantProvider
    private let model: String
    private let temperature: Double
    private let systemPrompt: String
    private let toolRegistry: ToolRegistry
    private let context: AgentContext
    private let maxIterations: Int
    private let maxTokenBudget: Int
    private let maxToolResultChars: Int

    // MARK: Internal state

    private var internalMessages: [AgentInternalMessage] = []
    private var estimatedTokensUsed: Int = 0
    private var task: Task<Void, Never>?

    // MARK: Init

    init(
        provider: CodeAssistantProvider,
        model: String,
        temperature: Double,
        systemPrompt: String,
        toolRegistry: ToolRegistry = .default,
        context: AgentContext,
        maxIterations: Int = 25,
        maxTokenBudget: Int = 100_000,
        maxToolResultChars: Int = 16_000
    ) {
        self.provider = provider
        self.model = model
        self.temperature = temperature
        self.systemPrompt = systemPrompt
        self.toolRegistry = toolRegistry
        self.context = context
        self.maxIterations = maxIterations
        self.maxTokenBudget = maxTokenBudget
        self.maxToolResultChars = maxToolResultChars
    }

    // MARK: - Public API

    func start(
        userMessage: String,
        conversationHistory: [CodeAssistantViewModel.Message]
    ) {
        state = .streaming

        internalMessages = [.system(systemPrompt)]

        // Inject rules context (Phase 1)
        if let rulesEngine = context.rulesEngine {
            let rules = rulesEngine.rulesContent(forFilePath: nil, mode: "agent")
            if !rules.isEmpty {
                internalMessages.append(.user("<rules>\n\(rules)\n</rules>"))
            }
        }

        // Inject memory context (Phase 5)
        if let memoryManager = context.memoryManager, memoryManager.isLoaded {
            Task {
                let memory = await memoryManager.loadIndex()
                if !memory.isEmpty {
                    // Insert after rules but before conversation history
                    let insertIdx = min(internalMessages.count, 2)
                    internalMessages.insert(.user("<memory>\n\(memory)\n</memory>"), at: insertIdx)
                }
            }
        }

        for msg in conversationHistory {
            switch msg.role {
            case .user:
                internalMessages.append(.user(msg.payload))
            case .assistant:
                internalMessages.append(.assistantText(msg.payload))
            case .system:
                break
            }
        }

        internalMessages.append(.user(userMessage))

        task = Task { [weak self] in
            guard let self else { return }

            await self.injectRAGContext(for: userMessage)

            do {
                switch self.provider {
                case .anthropic:
                    try await self.runAnthropicLoop()
                case .openAI:
                    try await self.runOpenAILoop()
                case .openRouter:
                    try await self.runOpenRouterLoop()
                }
                self.state = .completed
                self.onComplete?()
            } catch {
                if Task.isCancelled {
                    self.state = .cancelled
                } else {
                    self.state = .failed(error)
                    self.onError?(error)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        state = .cancelled
    }

    // MARK: - Anthropic Loop
    //
    // Uses streaming with AnthropicToolCallAccumulator for tool-call iterations.
    // Tool IDs are captured from contentBlockStart events.

    private func runAnthropicLoop() async throws {
        let apiKey = CodeAssistantSettings.apiKey(for: .anthropic)
        guard !apiKey.isEmpty else {
            throw CodeAssistantViewModel.AssistantError.missingAPIKey(provider: .anthropic)
        }

        let service = AIProxy.anthropicDirectService(unprotectedAPIKey: apiKey)
        let tools = toolRegistry.anthropicToolDefinitions()

        while iterationCount < maxIterations && !Task.isCancelled {
            iterationCount += 1
            state = .streaming

            let messages = buildAnthropicMessages()
            let body = AnthropicMessageRequestBody(
                maxTokens: 8192,
                messages: messages,
                model: model,
                system: .text(systemPrompt),
                temperature: temperature,
                tools: tools
            )

            let stream = try await service.streamingMessageRequest(
                body: body, secondsToWait: 120
            )

            var textContent = ""
            var toolCalls: [AgentToolCall] = []
            var accumulator = AnthropicToolCallAccumulator()
            var currentToolId: String?
            var stopReason: AnthropicStopReason?

            for try await event in stream {
                guard !Task.isCancelled else { throw CancellationError() }

                switch event {
                case .contentBlockStart(let blockStart):
                    if case .toolUseBlock(let toolUseBlock) = blockStart.contentBlock {
                        currentToolId = toolUseBlock.id
                    }
                case .contentBlockDelta(let delta):
                    if case .textDelta(let textDelta) = delta.delta {
                        textContent += textDelta.text
                        onTextDelta?(textDelta.text)
                    }
                case .messageDelta(let msgDelta):
                    stopReason = msgDelta.delta.stopReason
                default:
                    break
                }

                if let (toolName, toolInput) = try accumulator.append(event) {
                    let toolId = currentToolId ?? UUID().uuidString
                    toolCalls.append(
                        AgentToolCall(id: toolId, name: toolName, arguments: toolInput))
                    currentToolId = nil
                }
            }

            if stopReason == .toolUse && !toolCalls.isEmpty {
                internalMessages.append(.assistantToolCalls(toolCalls))
                if !textContent.isEmpty {
                    internalMessages.append(.assistantText(textContent))
                }

                state = .executingTools
                for toolCall in toolCalls {
                    await executeToolCall(toolCall)
                }

                updateTokenEstimate()
                checkCompactionHint()
                if estimatedTokensUsed > maxTokenBudget {
                    onTextDelta?("\n\n[Token budget exceeded — summarizing results]")
                    break
                }

                continue
            } else {
                if !textContent.isEmpty {
                    internalMessages.append(.assistantText(textContent))
                }
                break
            }
        }

        if iterationCount >= maxIterations {
            onTextDelta?("\n\n[Maximum iterations reached]")
        }
    }

    // MARK: - OpenAI Loop

    private func runOpenAILoop() async throws {
        let apiKey = CodeAssistantSettings.apiKey(for: .openAI)
        guard !apiKey.isEmpty else {
            throw CodeAssistantViewModel.AssistantError.missingAPIKey(provider: .openAI)
        }

        let service = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)
        let tools = toolRegistry.openAIToolDefinitions()

        while iterationCount < maxIterations && !Task.isCancelled {
            iterationCount += 1
            state = .streaming

            let messages = buildOpenAIMessages()
            let requestBody = OpenAIChatCompletionRequestBody(
                model: model,
                messages: messages,
                temperature: temperature,
                tools: tools
            )

            let stream = try await service.streamingChatCompletionRequest(
                body: requestBody, secondsToWait: 120
            )

            var textContent = ""
            var toolCallAccumulator = StreamedToolCallAccumulator()
            for try await chunk in stream {
                guard !Task.isCancelled else { throw CancellationError() }

                if let delta = chunk.choices.first?.delta {
                    if let content = delta.content {
                        textContent += content
                        onTextDelta?(content)
                    }

                    if let calls = delta.toolCalls {
                        for call in calls {
                            toolCallAccumulator.append(
                                index: call.index,
                                id: nil,
                                name: call.function?.name,
                                arguments: call.function?.arguments
                            )
                        }
                    }
                }
            }

            let toolCalls = toolCallAccumulator.makeToolCalls(parseJSON: parseJSON)
            if !toolCalls.isEmpty {

                internalMessages.append(.assistantToolCalls(toolCalls))
                if !textContent.isEmpty {
                    internalMessages.append(.assistantText(textContent))
                }

                state = .executingTools
                for toolCall in toolCalls {
                    await executeToolCall(toolCall)
                }

                updateTokenEstimate()
                checkCompactionHint()
                if estimatedTokensUsed > maxTokenBudget {
                    onTextDelta?("\n\n[Token budget exceeded — summarizing results]")
                    break
                }

                continue
            } else {
                if !textContent.isEmpty {
                    internalMessages.append(.assistantText(textContent))
                }
                break
            }
        }
    }

    // MARK: - OpenRouter Loop

    private func runOpenRouterLoop() async throws {
        let apiKey = CodeAssistantSettings.apiKey(for: .openRouter)
        guard !apiKey.isEmpty else {
            throw CodeAssistantViewModel.AssistantError.missingAPIKey(provider: .openRouter)
        }

        let service = AIProxy.openRouterDirectService(unprotectedAPIKey: apiKey)
        let tools = toolRegistry.openRouterToolDefinitions()

        while iterationCount < maxIterations && !Task.isCancelled {
            iterationCount += 1
            state = .streaming

            let messages = buildOpenRouterMessages()
            let requestBody = OpenRouterChatCompletionRequestBody(
                messages: messages,
                models: [model],
                temperature: temperature,
                tools: tools
            )

            let stream = try await service.streamingChatCompletionRequest(body: requestBody)

            var textContent = ""
            var toolCallAccumulator = StreamedToolCallAccumulator()
            for try await chunk in stream {
                guard !Task.isCancelled else { throw CancellationError() }

                if let delta = chunk.choices.first?.delta {
                    if let content = delta.content {
                        textContent += content
                        onTextDelta?(content)
                    }

                    if let calls = delta.toolCalls {
                        for call in calls {
                            toolCallAccumulator.append(
                                index: call.index,
                                id: nil,
                                name: call.function?.name,
                                arguments: call.function?.arguments
                            )
                        }
                    }
                }
            }

            let toolCalls = toolCallAccumulator.makeToolCalls(parseJSON: parseJSON)
            if !toolCalls.isEmpty {

                internalMessages.append(.assistantToolCalls(toolCalls))
                if !textContent.isEmpty {
                    internalMessages.append(.assistantText(textContent))
                }

                state = .executingTools
                for toolCall in toolCalls {
                    await executeToolCall(toolCall)
                }

                updateTokenEstimate()
                checkCompactionHint()
                if estimatedTokensUsed > maxTokenBudget {
                    onTextDelta?("\n\n[Token budget exceeded — summarizing results]")
                    break
                }

                continue
            } else {
                if !textContent.isEmpty {
                    internalMessages.append(.assistantText(textContent))
                }
                break
            }
        }

        if iterationCount >= maxIterations {
            onTextDelta?("\n\n[Maximum iterations reached]")
        }
    }

    // MARK: - Tool Execution

    private func executeToolCall(_ toolCall: AgentToolCall) async {
        let summary = toolCallSummary(toolCall)
        var activity = ToolActivity(toolName: toolCall.name, summary: summary)
        toolActivities.append(activity)
        onToolActivityUpdate?(activity)

        // Permission check (Phase 3)
        if let permissionManager = context.permissionManager {
            let decision = permissionManager.evaluate(
                toolName: toolCall.name,
                arguments: toolCall.arguments
            )

            switch decision {
            case .deny(let reason):
                let content = "[Permission denied] \(reason)"
                if let idx = toolActivities.firstIndex(where: { $0.id == activity.id }) {
                    toolActivities[idx].status = .failed
                    toolActivities[idx].resultPreview = content
                    toolActivities[idx].completedAt = Date()
                    activity = toolActivities[idx]
                }
                onToolActivityUpdate?(activity)
                internalMessages.append(
                    .toolResult(toolUseId: toolCall.id, content: content, isError: true))
                return

            case .promptUser:
                let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    if let handler = onPermissionRequest {
                        handler(toolCall.name, summary) { allowed in
                            continuation.resume(returning: allowed)
                        }
                    } else {
                        continuation.resume(returning: true)
                    }
                }

                if !approved {
                    let content = "[Permission denied by user]"
                    if let idx = toolActivities.firstIndex(where: { $0.id == activity.id }) {
                        toolActivities[idx].status = .failed
                        toolActivities[idx].resultPreview = content
                        toolActivities[idx].completedAt = Date()
                        activity = toolActivities[idx]
                    }
                    onToolActivityUpdate?(activity)
                    internalMessages.append(
                        .toolResult(toolUseId: toolCall.id, content: content, isError: true))
                    return
                }

                // Grant session allowance so same action won't prompt again
                permissionManager.grantSessionForToolCall(
                    toolName: toolCall.name,
                    arguments: toolCall.arguments
                )

            case .allow:
                break
            }
        }

        let result = await toolRegistry.execute(
            name: toolCall.name,
            arguments: toolCall.arguments,
            context: context
        )

        var content = result.content
        if content.count > maxToolResultChars {
            content =
                String(content.prefix(maxToolResultChars))
                + "\n\n[Output truncated at \(maxToolResultChars) characters]"
        }

        if let idx = toolActivities.firstIndex(where: { $0.id == activity.id }) {
            toolActivities[idx].status = result.isError ? .failed : .completed
            toolActivities[idx].resultPreview = String(content.prefix(200))
            toolActivities[idx].completedAt = Date()
            activity = toolActivities[idx]
        }
        onToolActivityUpdate?(activity)

        internalMessages.append(
            .toolResult(toolUseId: toolCall.id, content: content, isError: result.isError))
    }

    private func toolCallSummary(_ toolCall: AgentToolCall) -> String {
        let displayName = ToolActivity.displayName(for: toolCall.name)
        if let path = toolCall.arguments["path"] as? String {
            return "\(displayName): \(path)"
        }
        if let command = toolCall.arguments["command"] as? String {
            let short =
                command.count > 60 ? String(command.prefix(60)) + "..." : command
            return "\(displayName): \(short)"
        }
        if let pattern = toolCall.arguments["pattern"] as? String {
            return "\(displayName): \(pattern)"
        }
        return displayName
    }

    // MARK: - Message Building

    private func buildAnthropicMessages() -> [AnthropicInputMessage] {
        // System prompt is passed via the `system:` parameter on the request body
        var result: [AnthropicInputMessage] = []

        for msg in internalMessages {
            switch msg {
            case .system:
                break
            case .user(let text):
                result.append(
                    AnthropicInputMessage(content: .text(text), role: .user))
            case .assistantText(let text):
                result.append(
                    AnthropicInputMessage(content: .text(text), role: .assistant))
            case .assistantToolCalls(let calls):
                let blocks: [AnthropicContentBlockParam] = calls.map { call in
                    .toolUseBlock(AnthropicToolUseBlockParam(
                        id: call.id,
                        input: call.arguments.mapValues { AIProxyJSONValue.from($0) },
                        name: call.name
                    ))
                }
                result.append(
                    AnthropicInputMessage(content: .blocks(blocks), role: .assistant))
            case .toolResult(let toolUseId, let content, let isError):
                result.append(
                    AnthropicInputMessage(
                        content: .blocks([
                            .toolResultBlock(AnthropicToolResultBlockParam(
                                toolUseId: toolUseId,
                                content: .text(content),
                                isError: isError
                            ))
                        ]),
                        role: .user
                    ))
            }
        }

        return result
    }

    private func buildOpenAIMessages() -> [OpenAIChatCompletionRequestBody.Message] {
        var result: [OpenAIChatCompletionRequestBody.Message] = []

        for msg in internalMessages {
            switch msg {
            case .system(let text):
                result.append(.system(content: .text(text)))
            case .user(let text):
                result.append(.user(content: .text(text)))
            case .assistantText(let text):
                result.append(.assistant(content: .text(text)))
            case .assistantToolCalls(let calls):
                let toolCalls = calls.map { call in
                    OpenAIChatCompletionRequestBody.Message.ToolCall(
                        id: call.id,
                        function: .init(
                            name: call.name,
                            arguments: serializeJSON(call.arguments)
                        )
                    )
                }
                result.append(.assistant(toolCalls: toolCalls))
            case .toolResult(let toolUseId, let content, _):
                result.append(.tool(content: .text(content), toolCallID: toolUseId))
            }
        }

        return result
    }

    private func buildOpenRouterMessages() -> [OpenRouterChatCompletionRequestBody.Message] {
        var result: [OpenRouterChatCompletionRequestBody.Message] = []

        for msg in internalMessages {
            switch msg {
            case .system(let text):
                result.append(.system(content: .text(text)))
            case .user(let text):
                result.append(.user(content: .text(text)))
            case .assistantText(let text):
                result.append(.assistant(content: .text(text)))
            case .assistantToolCalls(let calls):
                // SDK lacks assistant(toolCalls:) — encode deterministic text envelopes
                let formatted = calls.map { call in
                    OpenRouterReplayEnvelope.toolCall(
                        id: call.id,
                        name: call.name,
                        arguments: call.arguments
                    )
                }.joined(separator: "\n")
                result.append(.assistant(content: .text(formatted)))
            case .toolResult(let toolUseId, let content, let isError):
                result.append(.user(content: .text(
                    OpenRouterReplayEnvelope.toolResult(
                        toolCallID: toolUseId,
                        content: content,
                        isError: isError
                    )
                )))
            }
        }

        return result
    }

    // MARK: - RAG Context Injection

    private func injectRAGContext(for query: String) async {
        guard let indexer = context.workspaceIndexer,
            indexer.lastIndexedDate != nil
        else { return }

        let ragContext = await indexer.getRelevantContext(for: query, maxChunks: 3)
        guard !ragContext.isEmpty else { return }

        let contextBlock = """
            <workspace_context>
            The following code snippets from the user's workspace may be relevant:

            \(ragContext)
            </workspace_context>
            """

        if internalMessages.count >= 2 {
            internalMessages.insert(.system(contextBlock), at: 1)
        }
    }

    /// Check if compaction should be suggested and emit a hint.
    private func checkCompactionHint() {
        let threshold = Double(maxTokenBudget) * 0.75
        if Double(estimatedTokensUsed) >= threshold {
            onTextDelta?("\n\n> Tip: Context is getting large (\(estimatedTokensUsed) estimated tokens). Use `/compact` to summarize the conversation.\n\n")
        }
    }

    // MARK: - Token Estimation

    private func updateTokenEstimate() {
        estimatedTokensUsed = 0
        for msg in internalMessages {
            switch msg {
            case .system(let t): estimatedTokensUsed += t.count / 4
            case .user(let t): estimatedTokensUsed += t.count / 4
            case .assistantText(let t): estimatedTokensUsed += t.count / 4
            case .assistantToolCalls(let calls):
                for call in calls {
                    estimatedTokensUsed += call.name.count / 4 + 50
                }
            case .toolResult(_, let content, _):
                estimatedTokensUsed += content.count / 4
            }
        }
    }

    // MARK: - JSON Helpers

    private func parseJSON(_ jsonString: String) -> [String: Any] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["_raw_arguments": trimmed]
        }
        return obj
    }

    private func serializeJSON(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let str = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return str
    }
}

// MARK: - AIProxyJSONValue Helpers

extension AIProxyJSONValue {
    /// Convert Any to AIProxyJSONValue for tool call input serialization.
    static func from(_ value: Any) -> AIProxyJSONValue {
        if let s = value as? String { return .string(s) }
        if let i = value as? Int { return .int(i) }
        if let d = value as? Double { return .double(d) }
        if let b = value as? Bool { return .bool(b) }
        if let arr = value as? [Any] { return .array(arr.map { AIProxyJSONValue.from($0) }) }
        if let dict = value as? [String: Any] {
            return .object(dict.mapValues { AIProxyJSONValue.from($0) })
        }
        return .string(String(describing: value))
    }

    /// Convert AIProxyJSONValue back to an untyped Any.
    var untypedValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null(_): return NSNull()
        case .array(let arr): return arr.map { $0.untypedValue }
        case .object(let dict): return dict.mapValues { $0.untypedValue }
        }
    }
}
