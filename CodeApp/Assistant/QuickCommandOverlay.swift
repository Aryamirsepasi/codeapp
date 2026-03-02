//
//  QuickCommandOverlay.swift
//  Code App
//
//  Created by Arya Mirsepasi.
//

import AIProxy
import SwiftUI

/// Quick command overlay (Cmd+K style) for inline AI interactions
struct QuickCommandOverlay: View {

    @EnvironmentObject var app: MainApp
    @ObservedObject var viewModel: CodeAssistantViewModel

    @Binding var isPresented: Bool
    @State private var commandInput: String = ""
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            commandPanel
        }
        .background(backgroundOverlay)
        .onAppear {
            isFocused = true
            captureSelectionContext()
        }
    }
    
    private var commandPanel: some View {
        VStack(spacing: 12) {
            headerView
            inputFieldView
            contextIndicatorView
            errorMessageView
            keyboardHintsView
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
    
    private var headerView: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("Quick Command")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var inputFieldView: some View {
        HStack(spacing: 8) {
            TextField("Describe what you want to do...", text: $commandInput, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    executeCommand()
                }
                .disabled(isProcessing)

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    executeCommand()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(commandInput.isEmpty ? Color.secondary : Color.purple)
                }
                .buttonStyle(.plain)
                .disabled(commandInput.isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.5), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private var contextIndicatorView: some View {
        if let activeFile = app.activeTextEditor {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                Text(activeFile.url.lastPathComponent)
                    .font(.caption)
                if let selection = viewModel.selectionContext, !selection.text.isEmpty {
                    Text("• Selection active")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private var errorMessageView: some View {
        if let error = errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
    
    private var keyboardHintsView: some View {
        HStack(spacing: 16) {
            Label("Submit", systemImage: "return")
            Label("Cancel", systemImage: "escape")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    
    private var backgroundOverlay: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture {
                dismiss()
            }
    }

    private func captureSelectionContext() {
        Task {
            guard let activeFile = app.activeTextEditor else { return }

            let selection = await app.monacoInstance.selectionSnapshot()

            if let selection, !selection.text.isEmpty {
                let languageHint = CodeAssistantViewModel.languageHint(for: activeFile.url)

                await MainActor.run {
                    viewModel.selectionContext = CodeAssistantViewModel.SelectionContext(
                        text: selection.text,
                        startLine: selection.startLine,
                        startColumn: selection.startColumn,
                        endLine: selection.endLine,
                        endColumn: selection.endColumn,
                        languageHint: languageHint
                    )
                }
            }
        }
    }

    private func executeCommand() {
        guard !commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isProcessing else { return }

        isProcessing = true
        errorMessage = nil

        Task {
            do {
                let result = try await processQuickCommand(commandInput)

                await MainActor.run {
                    isProcessing = false

                    if !result.isEmpty {
                        // Apply the result using Monaco diff mode
                        applyResult(result)
                    }

                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func processQuickCommand(_ command: String) async throws -> String {
        // Build prompt with context
        var prompt = command

        if let selection = viewModel.selectionContext, !selection.text.isEmpty {
            prompt = """
            \(command)

            Selected code (lines \(selection.startLine)-\(selection.endLine)):
            ```\(selection.languageHint ?? "text")
            \(selection.text)
            ```
            """
        }

        // Get API key - prefer OpenAI
        let apiKey = CodeAssistantSettings.apiKey(for: viewModel.selectedProvider)
        guard !apiKey.isEmpty else {
            throw CodeAssistantViewModel.AssistantError.missingAPIKey(provider: viewModel.selectedProvider)
        }

        let systemPrompt = """
        You are a quick code assistant. Respond ONLY with the modified code, no explanations.
        If asked to modify code, return the complete modified version.
        If no code is selected, provide a brief code snippet.
        Do not use markdown code fences in your response.
        """

        switch viewModel.selectedProvider {
        case .openAI:
            let service = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)
            let body = OpenAIChatCompletionRequestBody(
                model: viewModel.currentModel,
                messages: [
                    .system(content: .text(systemPrompt)),
                    .user(content: .text(prompt))
                ],
                temperature: viewModel.temperature
            )
            let response = try await service.chatCompletionRequest(body: body, secondsToWait: 60)
            return response.choices.first?.message.content ?? ""

        case .anthropic:
            let service = AIProxy.anthropicDirectService(unprotectedAPIKey: apiKey)
            let body = AnthropicMessageRequestBody(
                maxTokens: 2048,
                messages: [
                    AnthropicInputMessage(
                        content: .text("\(systemPrompt)\n\n\(prompt)"),
                        role: .user
                    )
                ],
                model: viewModel.currentModel,
                temperature: viewModel.temperature
            )
            let response = try await service.messageRequest(body: body)
            for content in response.content {
                if case let .textBlock(textBlock) = content {
                    return textBlock.text
                }
            }
            return ""

        case .openRouter:
            let service = AIProxy.openRouterDirectService(unprotectedAPIKey: apiKey)
            let body = OpenRouterChatCompletionRequestBody(
                messages: [
                    .system(content: .text(systemPrompt)),
                    .user(content: .text(prompt))
                ],
                models: [viewModel.currentModel],
                temperature: viewModel.temperature
            )
            let response = try await service.chatCompletionRequest(body: body)
            return response.choices.first?.message.content ?? ""
        }
    }

    private func applyResult(_ result: String) {
        Task {
            guard let activeFile = app.activeTextEditor else { return }

            let originalText = await app.monacoInstance.currentModelValue() ?? activeFile.content
            let selection = await app.monacoInstance.selectionSnapshot()
            let updatedText = updatedQuickCommandText(
                original: originalText,
                selection: selection,
                replacement: result
            )

            // Clear selection context
            viewModel.selectionContext = nil

            guard originalText != updatedText else {
                app.notificationManager.showWarningMessage("No changes to apply")
                return
            }

            // Show diff preview
            let originalUrl = "quickcmd://original/\(activeFile.url.lastPathComponent)"
            let modifiedUrl = activeFile.url.absoluteString

            await app.monacoInstance.switchToDiffMode(
                originalContent: originalText,
                modifiedContent: updatedText,
                originalUrl: originalUrl,
                modifiedUrl: modifiedUrl
            )

            let fileName = activeFile.url.lastPathComponent
            let fileUrl = activeFile.url

            app.notificationManager.postActionNotification(
                title: "Quick command changes for \(fileName)",
                level: .info,
                primary: {
                    Task {
                        await MainActor.run {
                            activeFile.content = updatedText
                            if activeFile.isSaved {
                                activeFile.currentVersionId += 1
                            }
                        }
                        await app.monacoInstance.switchToNormalMode()
                        await app.monacoInstance.setValueForModel(
                            url: fileUrl.absoluteString,
                            value: updatedText
                        )
                        app.notificationManager.postActionNotification(
                            title: "Changes applied",
                            level: .info,
                            primary: { Task { await app.monacoInstance.undo() } },
                            primaryTitle: "Undo",
                            source: fileName
                        )
                    }
                },
                primaryTitle: "Apply",
                secondary: { Task { await app.monacoInstance.switchToNormalMode() } },
                secondaryTitle: "common.cancel",
                source: fileName
            )
        }
    }

    private func updatedQuickCommandText(
        original: String,
        selection: EditorSelectionSnapshot?,
        replacement: String
    ) -> String {
        if let selection, let range = selectionRange(for: selection, in: original) {
            return original.replacingCharacters(in: range, with: replacement)
        }

        if let selectionContext = viewModel.selectionContext,
           !selectionContext.text.isEmpty,
           let range = original.range(of: selectionContext.text) {
            return original.replacingCharacters(in: range, with: replacement)
        }

        let separator = original.hasSuffix("\n") || original.isEmpty ? "" : "\n"
        return original + separator + replacement
    }

    private func selectionRange(
        for selection: EditorSelectionSnapshot,
        in text: String
    ) -> Range<String.Index>? {
        let lower = max(0, min(selection.startOffset, selection.endOffset))
        let upper = min(text.utf16.count, max(selection.startOffset, selection.endOffset))
        guard lower <= text.utf16.count, upper <= text.utf16.count else {
            return nil
        }
        let startIndex = String.Index(utf16Offset: lower, in: text)
        let endIndex = String.Index(utf16Offset: upper, in: text)
        guard startIndex <= endIndex else { return nil }
        return startIndex..<endIndex
    }

    private func dismiss() {
        viewModel.selectionContext = nil
        isPresented = false
    }
}
