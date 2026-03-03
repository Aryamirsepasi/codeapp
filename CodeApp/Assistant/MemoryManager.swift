//
//  MemoryManager.swift
//  CodeApp
//
//  Persistent cross-session memory. Stores facts in MEMORY.md and topic
//  files. Evaluates each assistant turn for persistence-worthy facts via
//  a lightweight LLM call.
//

import AIProxy
import Foundation

@MainActor
final class MemoryManager: ObservableObject {

    @Published var isLoaded = false

    private var memoryDirectory: URL?
    private var memoryIndex: String = ""
    private static let maxMemoryLines = 200

    // MARK: - Configuration

    /// Configure memory storage for a workspace. Creates directories if needed.
    func configure(workspaceRoot: URL) {
        let hash = workspaceRoot.absoluteString.hashForFilename
        let baseDir = getRootDirectory()
            .appendingPathComponent(".codeapp")
            .appendingPathComponent("memory")
            .appendingPathComponent(hash)

        memoryDirectory = baseDir

        // Create directory structure
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? fm.createDirectory(
            at: baseDir.appendingPathComponent("topics"),
            withIntermediateDirectories: true
        )
        try? fm.createDirectory(
            at: baseDir.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )

        // Create MEMORY.md if it doesn't exist
        let memoryFile = baseDir.appendingPathComponent("MEMORY.md")
        if !fm.fileExists(atPath: memoryFile.path) {
            let header = "# Memory\n\nFacts and patterns learned across sessions.\n"
            try? header.data(using: .utf8)?.write(to: memoryFile)
        }
    }

    /// Load the MEMORY.md index content.
    func loadIndex() async -> String {
        guard let dir = memoryDirectory else { return "" }

        let memoryFile = dir.appendingPathComponent("MEMORY.md")
        guard let data = try? Data(contentsOf: memoryFile),
              let content = String(data: data, encoding: .utf8)
        else { return "" }

        // Truncate to max lines
        let lines = content.components(separatedBy: .newlines)
        if lines.count > Self.maxMemoryLines {
            memoryIndex = lines.prefix(Self.maxMemoryLines).joined(separator: "\n")
                + "\n[Memory truncated at \(Self.maxMemoryLines) lines]"
        } else {
            memoryIndex = content
        }

        isLoaded = true
        return memoryIndex
    }

    /// Persist a fact to MEMORY.md or a topic file.
    func persist(fact: String, topic: String?) async {
        guard let dir = memoryDirectory else { return }

        if let topic = topic, !topic.isEmpty {
            // Write to topic file
            let topicFile = dir
                .appendingPathComponent("topics")
                .appendingPathComponent("\(topic.sanitizedFilename).md")

            var existing = ""
            if let data = try? Data(contentsOf: topicFile),
               let content = String(data: data, encoding: .utf8) {
                existing = content
            } else {
                existing = "# \(topic)\n"
            }

            existing += "\n- \(fact)"
            try? existing.data(using: .utf8)?.write(to: topicFile)

            // Add reference in MEMORY.md if not already there
            await addTopicReference(topic: topic)
        } else {
            // Append directly to MEMORY.md
            let memoryFile = dir.appendingPathComponent("MEMORY.md")
            var existing = ""
            if let data = try? Data(contentsOf: memoryFile),
               let content = String(data: data, encoding: .utf8) {
                existing = content
            }
            existing += "\n- \(fact)"
            try? existing.data(using: .utf8)?.write(to: memoryFile)
        }
    }

    /// Evaluate whether an assistant response contains facts worth persisting.
    /// Returns (shouldPersist, fact, topic).
    func evaluateForPersistence(
        turn: String,
        provider: CodeAssistantProvider,
        model: String
    ) async -> (Bool, String, String?) {
        let prompt = """
        Analyze this assistant response from a coding session. Should any facts be saved \
        for future sessions? Only save stable patterns, conventions, architectural decisions, \
        or user preferences — NOT temporary task details.

        Reply with ONLY a JSON object (no markdown):
        {"persist": true/false, "fact": "the fact to save", "topic": "optional topic name or null"}

        If nothing should be saved, reply: {"persist": false, "fact": "", "topic": null}

        RESPONSE TO ANALYZE:
        \(String(turn.prefix(2000)))
        """

        do {
            let result = try await quickLLMCall(prompt: prompt, provider: provider, model: model)
            return parseEvaluationResult(result)
        } catch {
            return (false, "", nil)
        }
    }

    /// Save full session history for archival.
    func saveSessionHistory(messages: [CodeAssistantViewModel.Message], sessionId: UUID) async {
        guard let dir = memoryDirectory else { return }

        let sessionFile = dir
            .appendingPathComponent("sessions")
            .appendingPathComponent("\(sessionId.uuidString).json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: sessionFile)
    }

    // MARK: - Private

    private func addTopicReference(topic: String) async {
        guard let dir = memoryDirectory else { return }

        let memoryFile = dir.appendingPathComponent("MEMORY.md")
        guard let data = try? Data(contentsOf: memoryFile),
              var content = String(data: data, encoding: .utf8)
        else { return }

        let reference = "See: topics/\(topic.sanitizedFilename).md"
        if !content.contains(reference) {
            content += "\n- \(reference)"
            try? content.data(using: .utf8)?.write(to: memoryFile)
        }
    }

    private func quickLLMCall(
        prompt: String, provider: CodeAssistantProvider, model: String
    ) async throws -> String {
        switch provider {
        case .anthropic:
            let apiKey = CodeAssistantSettings.apiKey(for: .anthropic)
            guard !apiKey.isEmpty else { return "" }
            let service = AIProxy.anthropicDirectService(unprotectedAPIKey: apiKey)
            let body = AnthropicMessageRequestBody(
                maxTokens: 256,
                messages: [AnthropicInputMessage(content: .text(prompt), role: .user)],
                model: model,
                temperature: 0.0
            )
            var result = ""
            let stream = try await service.streamingMessageRequest(body: body, secondsToWait: 30)
            for try await event in stream {
                if case .contentBlockDelta(let delta) = event,
                   case .textDelta(let textDelta) = delta.delta {
                    result += textDelta.text
                }
            }
            return result

        case .openAI:
            let apiKey = CodeAssistantSettings.apiKey(for: .openAI)
            guard !apiKey.isEmpty else { return "" }
            let service = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)
            let requestBody = OpenAIChatCompletionRequestBody(
                model: model,
                messages: [.user(content: .text(prompt))],
                temperature: 0.0
            )
            var result = ""
            let stream = try await service.streamingChatCompletionRequest(
                body: requestBody, secondsToWait: 30
            )
            for try await chunk in stream {
                if let delta = chunk.choices.first?.delta.content {
                    result += delta
                }
            }
            return result

        case .openRouter:
            let apiKey = CodeAssistantSettings.apiKey(for: .openRouter)
            guard !apiKey.isEmpty else { return "" }
            let service = AIProxy.openRouterDirectService(unprotectedAPIKey: apiKey)
            let requestBody = OpenRouterChatCompletionRequestBody(
                messages: [.user(content: .text(prompt))],
                models: [model],
                temperature: 0.0
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

    private func parseEvaluationResult(_ json: String) -> (Bool, String, String?) {
        // Strip markdown fences if present
        var cleaned = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let lines = cleaned.components(separatedBy: .newlines)
            cleaned = lines.dropFirst().dropLast().joined(separator: "\n")
        }

        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (false, "", nil) }

        let persist = obj["persist"] as? Bool ?? false
        let fact = obj["fact"] as? String ?? ""
        let topic = obj["topic"] as? String

        guard persist, !fact.isEmpty else { return (false, "", nil) }
        return (true, fact, topic)
    }
}

// MARK: - String Helpers

private extension String {
    /// Produce a filesystem-safe hash of the string.
    var hashForFilename: String {
        var hash: UInt64 = 5381
        for byte in self.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    /// Sanitize string for use as a filename.
    var sanitizedFilename: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return self.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .lowercased()
    }
}
