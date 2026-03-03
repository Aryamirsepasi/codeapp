//
//  CompactionService.swift
//  CodeApp
//
//  Conversation compaction service. Summarizes all messages via a single
//  LLM call and returns a condensed summary that preserves key decisions,
//  code changes, file paths, and current task state.
//

import AIProxy
import Foundation

@MainActor
final class CompactionService {

    /// Compact the conversation by sending all messages to the LLM for summarization.
    func compact(
        messages: [CodeAssistantViewModel.Message],
        provider: CodeAssistantProvider,
        model: String,
        instructions: String
    ) async throws -> String {
        let conversationText = messages.map { msg in
            let role = msg.role.rawValue.uppercased()
            return "[\(role)] \(msg.payload.isEmpty ? msg.body : msg.payload)"
        }.joined(separator: "\n\n")

        let prompt = """
        You are summarizing a coding assistant conversation for context compaction.
        Preserve the following in your summary:
        - Key decisions made
        - Code changes made (file paths and what was changed)
        - Current task state and any unfinished work
        - Important facts learned about the codebase
        - User preferences or conventions discovered

        Be concise but complete. Use bullet points. Do NOT include raw code — just describe changes.

        \(instructions.isEmpty ? "" : "Additional context:\n\(instructions)\n")

        CONVERSATION:
        \(conversationText)

        SUMMARY:
        """

        switch provider {
        case .anthropic:
            return try await compactViaAnthropic(prompt: prompt, model: model)
        case .openAI:
            return try await compactViaOpenAI(prompt: prompt, model: model)
        case .openRouter:
            return try await compactViaOpenRouter(prompt: prompt, model: model)
        }
    }

    /// Check if compaction should be suggested based on token usage.
    func shouldSuggestCompaction(estimatedTokens: Int, budget: Int) -> Bool {
        let threshold = Double(budget) * 0.75
        return Double(estimatedTokens) >= threshold
    }

    // MARK: - Provider Implementations

    private func compactViaAnthropic(prompt: String, model: String) async throws -> String {
        let apiKey = CodeAssistantSettings.apiKey(for: .anthropic)
        guard !apiKey.isEmpty else {
            throw CodeAssistantViewModel.AssistantError.missingAPIKey(provider: .anthropic)
        }

        let service = AIProxy.anthropicDirectService(unprotectedAPIKey: apiKey)
        let body = AnthropicMessageRequestBody(
            maxTokens: 4096,
            messages: [AnthropicInputMessage(content: .text(prompt), role: .user)],
            model: model,
            system: .text("You are a conversation summarizer. Be concise and structured."),
            temperature: 0.1
        )

        var result = ""
        let stream = try await service.streamingMessageRequest(body: body, secondsToWait: 120)
        for try await event in stream {
            if case .contentBlockDelta(let delta) = event,
               case .textDelta(let textDelta) = delta.delta {
                result += textDelta.text
            }
        }
        return result
    }

    private func compactViaOpenAI(prompt: String, model: String) async throws -> String {
        let apiKey = CodeAssistantSettings.apiKey(for: .openAI)
        guard !apiKey.isEmpty else {
            throw CodeAssistantViewModel.AssistantError.missingAPIKey(provider: .openAI)
        }

        let service = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)
        let requestBody = OpenAIChatCompletionRequestBody(
            model: model,
            messages: [
                .system(content: .text("You are a conversation summarizer. Be concise and structured.")),
                .user(content: .text(prompt)),
            ],
            temperature: 0.1
        )

        var result = ""
        let stream = try await service.streamingChatCompletionRequest(
            body: requestBody, secondsToWait: 120
        )
        for try await chunk in stream {
            if let delta = chunk.choices.first?.delta.content {
                result += delta
            }
        }
        return result
    }

    private func compactViaOpenRouter(prompt: String, model: String) async throws -> String {
        let apiKey = CodeAssistantSettings.apiKey(for: .openRouter)
        guard !apiKey.isEmpty else {
            throw CodeAssistantViewModel.AssistantError.missingAPIKey(provider: .openRouter)
        }

        let service = AIProxy.openRouterDirectService(unprotectedAPIKey: apiKey)
        let requestBody = OpenRouterChatCompletionRequestBody(
            messages: [
                .system(content: .text("You are a conversation summarizer. Be concise and structured.")),
                .user(content: .text(prompt)),
            ],
            models: [model],
            temperature: 0.1
        )

        var result = ""
        let stream = try await service.streamingChatCompletionRequest(body: requestBody)
        for try await chunk in stream {
            if let delta = chunk.choices.first?.delta.content {
                result += delta
            }
        }
        return result
    }
}
