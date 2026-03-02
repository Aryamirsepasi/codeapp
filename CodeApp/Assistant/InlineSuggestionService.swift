//
//  InlineSuggestionService.swift
//  Code App
//
//  Created by Arya Mirsepasi.
//

import AIProxy
import Combine
import Foundation

/// Service that provides inline code completion suggestions (ghost text)
/// using a fast LLM model for low-latency responses.
@MainActor
final class InlineSuggestionService: ObservableObject {

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledDefaultsKey)
        }
    }

    @Published var currentSuggestion: String? {
        didSet {
            Task {
                if let suggestion = currentSuggestion {
                    await monacoInstance?.showGhostText(suggestion)
                } else {
                    await monacoInstance?.hideGhostText()
                }
            }
        }
    }
    @Published var isLoading: Bool = false

    private static let enabledDefaultsKey = "inlineSuggestion.enabled"
    private static let debounceInterval: TimeInterval = 0.5  // 500ms debounce
    private static let contextLines = 10  // Lines of context before/after cursor

    private var debounceTask: Task<Void, Never>?
    private var currentRequestTask: Task<Void, Never>?

    /// The Monaco implementation to interface with the editor
    weak var monacoInstance: MonacoImplementation?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    /// Called when the editor content changes. Debounces and triggers completion request.
    func onContentChange(
        prefix: String,
        suffix: String,
        languageId: String,
        cursorLine: Int,
        cursorColumn: Int
    ) {
        guard isEnabled else { return }

        // Cancel any pending debounce
        debounceTask?.cancel()

        // Clear current suggestion while typing
        currentSuggestion = nil

        // Debounce the request
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.debounceInterval * 1_000_000_000))

            guard !Task.isCancelled else { return }

            await requestCompletion(
                prefix: prefix,
                suffix: suffix,
                languageId: languageId
            )
        }
    }

    /// Cancels any pending suggestion request
    func cancelPendingSuggestion() {
        debounceTask?.cancel()
        currentRequestTask?.cancel()
        currentSuggestion = nil
        isLoading = false
    }

    /// Accepts the current suggestion and inserts it into the editor
    func acceptSuggestion() async {
        guard let suggestion = currentSuggestion, let monaco = monacoInstance else { return }
        await monaco.insertTextAtCurrentCursor(text: suggestion)
        currentSuggestion = nil
    }

    /// Dismisses the current suggestion without inserting
    func dismissSuggestion() {
        currentSuggestion = nil
    }

    private func requestCompletion(
        prefix: String,
        suffix: String,
        languageId: String
    ) async {
        // Cancel previous request
        currentRequestTask?.cancel()

        // Get API key - prefer OpenAI for gpt-4o-mini (fast and cheap)
        let apiKey = CodeAssistantSettings.apiKey(for: .openAI)
        guard !apiKey.isEmpty else {
            // Fall back to Anthropic haiku
            await requestCompletionAnthropic(prefix: prefix, suffix: suffix, languageId: languageId)
            return
        }

        isLoading = true

        currentRequestTask = Task {
            defer { isLoading = false }

            do {
                let service = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)

                let prompt = buildFillInMiddlePrompt(prefix: prefix, suffix: suffix, languageId: languageId)

                let requestBody = OpenAIChatCompletionRequestBody(
                    model: "gpt-4o-mini",
                    messages: [
                        .system(content: .text("You are a code completion assistant. Complete the code at the cursor position. Return ONLY the code to insert, no explanations or markdown. Keep completions short (1-3 lines max).")),
                        .user(content: .text(prompt))
                    ],
                    maxTokens: 100,
                    temperature: 0.0  // Deterministic for consistent completions
                )

                let response = try await service.chatCompletionRequest(body: requestBody, secondsToWait: 60)

                guard !Task.isCancelled else { return }

                if let completion = response.choices.first?.message.content {
                    let cleaned = cleanCompletion(completion)
                    if !cleaned.isEmpty {
                        currentSuggestion = cleaned
                    }
                }
            } catch {
                // Silent failure - don't interrupt user
                print("[InlineSuggestion] Error: \(error.localizedDescription)")
            }
        }
    }

    private func requestCompletionAnthropic(
        prefix: String,
        suffix: String,
        languageId: String
    ) async {
        let apiKey = CodeAssistantSettings.apiKey(for: .anthropic)
        guard !apiKey.isEmpty else { return }

        isLoading = true

        currentRequestTask = Task {
            defer { isLoading = false }

            do {
                let service = AIProxy.anthropicDirectService(unprotectedAPIKey: apiKey)

                let prompt = buildFillInMiddlePrompt(prefix: prefix, suffix: suffix, languageId: languageId)

                let body = AnthropicMessageRequestBody(
                    maxTokens: 100,
                    messages: [
                        AnthropicInputMessage(
                            content: .text("You are a code completion assistant. Complete the code at the cursor position. Return ONLY the code to insert, no explanations or markdown. Keep completions short (1-3 lines max).\n\n\(prompt)"),
                            role: .user
                        )
                    ],
                    model: "claude-3-5-haiku-latest",
                    temperature: 0.0
                )

                let response = try await service.messageRequest(body: body, secondsToWait: 60)

                guard !Task.isCancelled else { return }

                for content in response.content {
                    if case let .textBlock(textBlock) = content {
                        let cleaned = cleanCompletion(textBlock.text)
                        if !cleaned.isEmpty {
                            currentSuggestion = cleaned
                        }
                        break
                    }
                }
            } catch {
                print("[InlineSuggestion] Error: \(error.localizedDescription)")
            }
        }
    }

    private func buildFillInMiddlePrompt(prefix: String, suffix: String, languageId: String) -> String {
        """
        Complete the \(languageId) code at <CURSOR>. Return only the completion text.

        ```\(languageId)
        \(prefix)<CURSOR>\(suffix)
        ```
        """
    }

    private func cleanCompletion(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove markdown code blocks if present
        if cleaned.hasPrefix("```") {
            if let endIndex = cleaned.range(of: "\n") {
                cleaned = String(cleaned[endIndex.upperBound...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove backticks
        if cleaned.hasPrefix("`") && cleaned.hasSuffix("`") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }

        return cleaned
    }
}
