//
//  CodeAssistantPanel.swift
//  CodeApp
//
//  Created by Arya Mirsepasi.
//

import MarkdownUI
import SwiftUI
import UIKit
#if os(macOS)
    import AppKit
#endif

struct CodeAssistantPanel: View {

    @ObservedObject var viewModel: CodeAssistantViewModel
    @EnvironmentObject var app: MainApp
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Optional close action so the hosting container can dismiss the panel.
    var onClose: (() -> Void)? = nil

    @State private var showsAttachmentPicker = false
    @State private var showsHistorySheet = false
    @State private var showsModelPicker = false
    @State private var showsCodebaseSearch = false

    private let scrollViewID = "code-assistant-scroll"

    var body: some View {
        VStack(spacing: 0) {
            // Simplified header with essential actions
            header
            
            Divider()
            
            // Main conversation view
            messagesView
            
            Divider()
            
            // Attachments (when present)
            attachmentsView
            
            // Input area
            inputSection
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 24, x: 0, y: 16)
        .sheet(isPresented: $showsAttachmentPicker) {
            AttachmentPickerView(root: app.workSpaceStorage.currentDirectory) { item in
                viewModel.attach(item: item)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showsHistorySheet) {
            ChatHistoryView(viewModel: viewModel)
        }
        .sheet(isPresented: $showsModelPicker) {
            ModelSelectionView(viewModel: viewModel)
        }
        .sheet(isPresented: $showsCodebaseSearch) {
            NavigationStack {
                CodebaseSearchView(indexer: app.workspaceIndexer)
                    .environmentObject(app)
                    .navigationTitle("Codebase Search")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showsCodebaseSearch = false
                            }
                        }
                    }
            }
            .presentationDetents([.large])
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            // Title with streaming indicator
            VStack(alignment: .leading, spacing: 2) {
                Text("Code Assistant")
                    .font(.headline)
                
                HStack(spacing: 6) {
                    if viewModel.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.activeConversationTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Essential header actions
            Button {
                viewModel.startNewConversation()
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            
            Button {
                showsHistorySheet = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)

            Button {
                showsCodebaseSearch = true
            } label: {
                Label("Search", systemImage: "doc.text.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)

            Button {
                showsModelPicker = true
            } label: {
                Label("Model", systemImage: "brain")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty {
                    emptyStateView
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(
                                message: message,
                                onApply: { snippet, languageHint in
                                    prepareApplyPreview(snippet: snippet, languageHint: languageHint)
                                }
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(scrollViewID)
                    }
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).opacity(0.001))
            .onChange(of: viewModel.messages.count) {
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(scrollViewID, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.last?.body ?? "") {
                if viewModel.isStreaming {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(scrollViewID, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("Ready to Assist")
                .font(.title2.weight(.semibold))
            
            Text("Ask questions about your code, request refactoring, or get help with debugging.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var attachmentsView: some View {
        Group {
            if !viewModel.attachments.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.attachments) { attachment in
                                AttachmentChipView(
                                    attachment: attachment,
                                    onRemove: { viewModel.removeAttachment(attachment) })
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private var inputSection: some View {
        VStack(spacing: 8) {
            // Error message (when present)
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // Input controls
            HStack(spacing: 8) {
                // Attachment button
                Menu {
                    Button {
                        if let active = app.activeTextEditor {
                            let item = WorkSpaceStorage.FileItemRepresentable(
                                name: active.url.lastPathComponent,
                                url: active.url.absoluteString,
                                isDirectory: false)
                            viewModel.attach(item: item)
                        } else {
                            viewModel.errorMessage = "Open a file to attach it quickly."
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                viewModel.errorMessage = nil
                            }
                        }
                    } label: {
                        Label("Attach Active File", systemImage: "doc.text.fill")
                    }
                    .disabled(app.activeTextEditor == nil)
                    
                    Button {
                        showsAttachmentPicker = true
                    } label: {
                        Label("Browse Files", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                
                // Text input
                TextField("Ask the assistant…", text: $viewModel.currentInput, axis: .vertical)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                    .onSubmit {
                        sendMessageWithEditorSelection()
                    }
                
                // Token counter badge
                Text(viewModel.formattedTokenCount)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tokenCountColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(tokenCountColor.opacity(0.15))
                    )

                // Send/Stop button
                Button {
                    if viewModel.isStreaming {
                        viewModel.stopStreaming()
                    } else {
                        sendMessageWithEditorSelection()
                    }
                } label: {
                    Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "paperplane.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(viewModel.canSend || viewModel.isStreaming ? Color.accentColor : Color.gray.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSend && !viewModel.isStreaming)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private var tokenCountColor: Color {
        switch viewModel.tokenLevel {
        case .low:
            return .green
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }

    /// Sends the current prompt to the assistant, enriching it with the
    /// editor's current selection so the model can target edits precisely.
    private func sendMessageWithEditorSelection() {
        Task {
            // If there is no active text editor, just send the plain message.
            guard let activeFile = app.activeTextEditor else {
                await MainActor.run {
                    viewModel.sendMessage()
                }
                return
            }

            // Capture a snapshot of the current selection and nearby context.
            let selection = await app.monacoInstance.selectionSnapshot()
            let liveText = await app.monacoInstance.currentModelValue() ?? activeFile.content

            if let selection {
                let selectionText = selection.text

                // Derive a language hint from the active file URL so the model
                // can render the selection with correct syntax highlighting.
                let languageHint = CodeAssistantViewModel.languageHint(for: activeFile.url)

                await MainActor.run {
                    viewModel.selectionContext = CodeAssistantViewModel.SelectionContext(
                        text: selectionText,
                        startLine: selection.startLine,
                        startColumn: selection.startColumn,
                        endLine: selection.endLine,
                        endColumn: selection.endColumn,
                        languageHint: languageHint
                    )
                    viewModel.sendMessage()
                }
            } else {
                // No selection information; fall back to a normal send.
                await MainActor.run {
                    viewModel.selectionContext = nil
                    viewModel.sendMessage()
                }
            }
        }
    }

    /// Shows diff preview using Monaco's built-in diff mode
    private func prepareApplyPreview(snippet: String, languageHint: String?) {
        guard let activeFile = app.activeTextEditor else {
            app.notificationManager.showWarningMessage(
                "Open a file in the editor to apply code.")
            return
        }
        Task {
            let selection = await app.monacoInstance.selectionSnapshot()
            let originalText = await app.monacoInstance.currentModelValue() ?? activeFile.content
            let plan = buildUpdatedText(
                original: originalText,
                selection: selection,
                replacement: snippet
            )
            let updatedText = plan.updated

            // Check if there are actual changes
            guard originalText != updatedText else {
                app.notificationManager.showWarningMessage(
                    "No changes detected. The code may already be applied or couldn't be matched.")
                return
            }

            // Switch Monaco to diff mode
            let originalUrl = "assistant://original/\(activeFile.url.lastPathComponent)"
            let modifiedUrl = activeFile.url.absoluteString
            await app.monacoInstance.switchToDiffMode(
                originalContent: originalText,
                modifiedContent: updatedText,
                originalUrl: originalUrl,
                modifiedUrl: modifiedUrl
            )

            // Show notification with Apply and Cancel buttons
            let app = self.app
            let fileName = activeFile.url.lastPathComponent
            let fileUrl = activeFile.url

            app.notificationManager.postActionNotification(
                title: "Preview changes for \(fileName)",
                level: .info,
                primary: {
                    // Apply: set the updated text and exit diff mode
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
                        // Save the file to persist changes to disk
                        await app.saveCurrentFile()
                        app.notificationManager.postActionNotification(
                            title: "Changes applied",
                            level: .info,
                            primary: {
                                Task {
                                    await app.monacoInstance.undo()
                                }
                            },
                            primaryTitle: "Undo",
                            source: fileName
                        )
                    }
                },
                primaryTitle: "Apply",
                secondary: {
                    // Cancel: just exit diff mode
                    Task {
                        await app.monacoInstance.switchToNormalMode()
                    }
                },
                secondaryTitle: "common.cancel",
                source: fileName
            )
        }
    }

    // MARK: - Smart Code Matcher
    
    /// A sophisticated code matcher that uses LCS-based scoring, structural anchor detection,
    /// and fuzzy line matching to find the optimal replacement region in the original code.
    private struct SmartCodeMatcher {
        /// Finds the best replacement range for AI output in the original content
        func findBestReplacementRange(
            aiOutput: String,
            originalContent: String
        ) -> Range<String.Index>? {
            let originalLinesArray = originalContent.components(separatedBy: .newlines)
            let aiLinesArray = aiOutput.components(separatedBy: .newlines)
            let aiLines = normalizeLines(aiLinesArray)
            let originalLines = normalizeLines(originalLinesArray)
            
            guard !aiLines.isEmpty && !originalLines.isEmpty else {
                return nil
            }
            
            // Phase 0: Try exact first-line match with context expansion
            if let exactRange = findWithExactFirstLineMatch(
                aiLines: aiLines,
                aiLinesArray: aiLinesArray,
                originalLines: originalLines,
                originalLinesArray: originalLinesArray,
                originalContent: originalContent
            ) {
                return exactRange
            }
            
            // Phase 1: Try structural anchor-based matching
            if let anchorRange = findWithStructuralAnchors(
                aiLines: aiLines,
                originalLines: originalLines,
                originalLinesArray: originalLinesArray,
                originalContent: originalContent
            ) {
                return anchorRange
            }
            
            // Phase 2: Try function/block boundary detection
            if let blockRange = findWithBlockBoundaries(
                aiLines: aiLines,
                aiLinesArray: aiLinesArray,
                originalLines: originalLines,
                originalLinesArray: originalLinesArray,
                originalContent: originalContent
            ) {
                return blockRange
            }
            
            // Phase 3: Use LCS-based sliding window search
            if let lcsRange = findWithLCSAlignment(
                aiLines: aiLines,
                originalLines: originalLines,
                originalLinesArray: originalLinesArray,
                originalContent: originalContent
            ) {
                return lcsRange
            }
            
            return nil
        }
        
        /// Normalizes lines by trimming trailing whitespace and collapsing internal whitespace
        private func normalizeLines(_ lines: [String]) -> [String] {
            return lines.map { line in
                // Trim trailing whitespace but preserve leading indentation
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                // Collapse multiple spaces/tabs into single space for comparison
                return trimmed.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        }
        
        /// Try to find exact match for the first non-empty line, then expand to find bounds
        private func findWithExactFirstLineMatch(
            aiLines: [String],
            aiLinesArray: [String],
            originalLines: [String],
            originalLinesArray: [String],
            originalContent: String
        ) -> Range<String.Index>? {
            // Find first significant non-empty line in AI output
            guard let firstSigIndex = aiLines.firstIndex(where: { !$0.isEmpty && $0.count > 3 }) else {
                return nil
            }
            let firstSigLine = aiLines[firstSigIndex]
            
            // Find exact or near-exact matches in original
            var candidates: [(startIdx: Int, similarity: Double)] = []
            for (idx, origLine) in originalLines.enumerated() {
                let similarity = lineSimilarity(firstSigLine, origLine)
                if similarity > 0.9 {
                    candidates.append((idx, similarity))
                }
            }
            
            guard !candidates.isEmpty else { return nil }
            
            // For each candidate, score the full match
            var bestMatch: (start: Int, end: Int)? = nil
            var bestScore: Double = 0.0
            
            for candidate in candidates {
                let adjustedStart = max(0, candidate.startIdx - firstSigIndex)
                let estimatedEnd = min(originalLines.count, adjustedStart + aiLines.count)
                
                // Score this region
                let score = scoreRegionAlignment(
                    aiLines: aiLines,
                    originalLines: originalLines,
                    windowStart: adjustedStart,
                    windowEnd: estimatedEnd
                )
                
                if score > bestScore && score > 0.6 {
                    bestScore = score
                    bestMatch = (adjustedStart, estimatedEnd)
                }
            }
            
            guard let match = bestMatch else { return nil }
            
            return lineRangeToCharacterRange(
                lineStart: match.start,
                lineEnd: match.end,
                originalLines: originalLinesArray,
                in: originalContent
            )
        }
        
        /// Detects if a line is a structural anchor (function signature, class declaration, etc.)
        private func isStructuralAnchor(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Swift-specific anchors
            let swiftAnchors = trimmed.contains("func ") ||
                   trimmed.contains("class ") ||
                   trimmed.contains("struct ") ||
                   trimmed.contains("enum ") ||
                   trimmed.contains("protocol ") ||
                   trimmed.contains("extension ") ||
                   trimmed.contains("init(") ||
                   trimmed.contains("deinit") ||
                   trimmed.hasPrefix("import ") ||
                   trimmed.hasPrefix("@") ||
                   (trimmed.hasPrefix("private ") && (trimmed.contains("func ") || trimmed.contains("var ") || trimmed.contains("let "))) ||
                   (trimmed.hasPrefix("public ") && (trimmed.contains("func ") || trimmed.contains("var ") || trimmed.contains("let "))) ||
                   (trimmed.hasPrefix("internal ") && (trimmed.contains("func ") || trimmed.contains("var "))) ||
                   (trimmed.hasPrefix("fileprivate ") && trimmed.contains("func "))
            
            // JavaScript/TypeScript anchors
            let jsAnchors = trimmed.hasPrefix("function ") ||
                   trimmed.hasPrefix("const ") ||
                   trimmed.hasPrefix("let ") ||
                   trimmed.hasPrefix("export ") ||
                   trimmed.hasPrefix("async ") ||
                   trimmed.contains("=> {")
            
            // Python anchors
            let pythonAnchors = trimmed.hasPrefix("def ") ||
                   trimmed.hasPrefix("class ") ||
                   trimmed.hasPrefix("async def ") ||
                   trimmed.hasPrefix("@")
            
            // C/C++/Java anchors
            let cAnchors = trimmed.hasPrefix("void ") ||
                   trimmed.hasPrefix("int ") ||
                   trimmed.hasPrefix("public ") ||
                   trimmed.hasPrefix("private ") ||
                   trimmed.hasPrefix("protected ") ||
                   trimmed.hasPrefix("#include") ||
                   trimmed.hasPrefix("#define") ||
                   trimmed.hasPrefix("#if")
            
            // Block boundaries (language-agnostic)
            let blockBoundaries = trimmed == "}" ||
                   trimmed == "{" ||
                   trimmed.hasSuffix("{") ||
                   trimmed.hasPrefix("}")
            
            return swiftAnchors || jsAnchors || pythonAnchors || cAnchors || blockBoundaries
        }
        
        /// Detects function or block boundaries for more precise matching
        private func findWithBlockBoundaries(
            aiLines: [String],
            aiLinesArray: [String],
            originalLines: [String],
            originalLinesArray: [String],
            originalContent: String
        ) -> Range<String.Index>? {
            // Find opening signature in AI output (first line with function/class definition)
            var openingLineIdx: Int? = nil

            for (idx, line) in aiLines.enumerated() {
                if openingLineIdx == nil && isBlockOpening(line) {
                    openingLineIdx = idx
                    break
                }
            }
            
            guard let openIdx = openingLineIdx else { return nil }
            
            let openingLine = aiLines[openIdx]
            
            // Find matching opening in original
            var bestOrigStart: Int? = nil
            var bestSimilarity: Double = 0.8
            
            for (idx, origLine) in originalLines.enumerated() {
                let similarity = lineSimilarity(openingLine, origLine)
                if similarity > bestSimilarity {
                    bestSimilarity = similarity
                    bestOrigStart = idx
                }
            }
            
            guard let origStart = bestOrigStart else { return nil }
            
            // Find matching closing brace in original by counting brace depth
            var braceDepth = 0
            var origEnd = origStart
            var foundOpening = false
            
            for idx in origStart..<originalLines.count {
                let line = originalLinesArray[idx]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                braceDepth += line.filter { $0 == "{" }.count
                if braceDepth > 0 { foundOpening = true }
                braceDepth -= line.filter { $0 == "}" }.count
                
                if foundOpening && braceDepth == 0 {
                    origEnd = idx + 1
                    break
                }
                
                // Safety limit
                if idx - origStart > aiLines.count + 20 {
                    origEnd = min(origStart + aiLines.count, originalLines.count)
                    break
                }
            }
            
            if origEnd <= origStart {
                origEnd = min(origStart + aiLines.count, originalLines.count)
            }
            
            return lineRangeToCharacterRange(
                lineStart: origStart,
                lineEnd: origEnd,
                originalLines: originalLinesArray,
                in: originalContent
            )
        }
        
        /// Check if a line opens a block (function, class, etc.)
        private func isBlockOpening(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return (trimmed.contains("func ") || 
                    trimmed.contains("class ") || 
                    trimmed.contains("struct ") ||
                    trimmed.contains("enum ") ||
                    trimmed.contains("extension ") ||
                    trimmed.hasPrefix("def ") ||
                    trimmed.hasPrefix("function ") ||
                    trimmed.contains("=> {")) &&
                   (trimmed.hasSuffix("{") || trimmed.hasSuffix(":"))
        }
        
        /// Finds replacement range using structural anchors
        private func findWithStructuralAnchors(
            aiLines: [String],
            originalLines: [String],
            originalLinesArray: [String],
            originalContent: String
        ) -> Range<String.Index>? {
            // Find structural anchors in AI output
            var anchorIndices: [Int] = []
            for (index, line) in aiLines.enumerated() {
                if isStructuralAnchor(line) && !line.isEmpty {
                    anchorIndices.append(index)
                }
            }
            
            guard !anchorIndices.isEmpty else {
                return nil
            }
            
            // Try to find matching anchors in original
            var bestMatch: (start: Int, end: Int)? = nil
            var bestScore: Double = 0.0
            
            // Prioritize function signatures over closing braces
            let prioritizedAnchors = anchorIndices.sorted { idx1, idx2 in
                let line1 = aiLines[idx1]
                let line2 = aiLines[idx2]
                let isFunc1 = line1.contains("func ") || line1.contains("def ") || line1.contains("function ")
                let isFunc2 = line2.contains("func ") || line2.contains("def ") || line2.contains("function ")
                if isFunc1 && !isFunc2 { return true }
                if !isFunc1 && isFunc2 { return false }
                return idx1 < idx2
            }
            
            // For each anchor in AI output, try to find it in original
            for anchorIndex in prioritizedAnchors.prefix(5) {
                let anchorLine = aiLines[anchorIndex]
                
                // Search for this anchor in original
                for (origIndex, origLine) in originalLines.enumerated() {
                    let similarity = lineSimilarity(anchorLine, origLine)
                    if similarity > 0.80 {
                        // Found matching anchor, adjust for position within AI output
                        let adjustedStart = max(0, origIndex - anchorIndex)
                        let estimatedEnd = min(originalLines.count, adjustedStart + aiLines.count + 2)
                        
                        // Score this potential match
                        let score = scoreRegionAlignment(
                            aiLines: aiLines,
                            originalLines: originalLines,
                            windowStart: adjustedStart,
                            windowEnd: estimatedEnd
                        )
                        
                        // Boost score for function signature matches
                        let boostedScore = anchorLine.contains("func ") ? score * 1.1 : score
                        
                        if boostedScore > bestScore && score > 0.45 {
                            bestScore = boostedScore
                            bestMatch = (adjustedStart, estimatedEnd)
                        }
                    }
                }
            }
            
            guard let match = bestMatch else {
                return nil
            }
            
            return lineRangeToCharacterRange(
                lineStart: match.start,
                lineEnd: match.end,
                originalLines: originalLinesArray,
                in: originalContent
            )
        }
        
        /// Finds replacement range using LCS-based alignment scoring
        private func findWithLCSAlignment(
            aiLines: [String],
            originalLines: [String],
            originalLinesArray: [String],
            originalContent: String
        ) -> Range<String.Index>? {
            let aiLineCount = aiLines.count
            guard aiLineCount > 0 else { return nil }
            
            // Allow matching even if AI output is longer than original
            guard originalLines.count > 0 else { return nil }
            
            var bestMatch: (start: Int, end: Int)? = nil
            var bestScore: Double = 0.0
            let minScore: Double = 0.35 // Lower threshold for more flexibility
            
            // Try different window sizes to handle additions/deletions
            let baseWindowSize = aiLineCount
            let deltas = [-5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 8, 10]
            
            for delta in deltas {
                let windowSize = max(1, min(originalLines.count, baseWindowSize + delta))
                
                // Slide window across original
                let maxStart = max(0, originalLines.count - windowSize)
                for start in 0...maxStart {
                    let end = start + windowSize
                    
                    let score = scoreRegionAlignment(
                        aiLines: aiLines,
                        originalLines: originalLines,
                        windowStart: start,
                        windowEnd: end
                    )
                    
                    if score > bestScore && score >= minScore {
                        bestScore = score
                        bestMatch = (start, end)
                    }
                }
            }
            
            guard let match = bestMatch else {
                return nil
            }
            
            return lineRangeToCharacterRange(
                lineStart: match.start,
                lineEnd: match.end,
                originalLines: originalLinesArray,
                in: originalContent
            )
        }
        
        /// Scores region alignment using LCS-based algorithm
        private func scoreRegionAlignment(
            aiLines: [String],
            originalLines: [String],
            windowStart: Int,
            windowEnd: Int
        ) -> Double {
            guard windowStart >= 0, windowEnd <= originalLines.count, windowStart < windowEnd else {
                return 0.0
            }
            
            let windowLines = Array(originalLines[windowStart..<windowEnd])
            let maxLines = max(aiLines.count, windowLines.count)
            
            guard maxLines > 0 else { return 0.0 }
            
            // Calculate LCS-based similarity
            let lcsLength = computeLCS(aiLines, windowLines)
            let lcsScore = Double(lcsLength) / Double(maxLines)
            
            // Calculate position-aware token similarity
            var tokenScore = 0.0
            var weightedCount = 0.0
            let minCount = min(aiLines.count, windowLines.count)
            
            for i in 0..<minCount {
                let similarity = lineSimilarity(aiLines[i], windowLines[i])
                // Weight earlier lines more heavily (they're more likely to be anchors)
                let weight = i < 3 ? 1.5 : 1.0
                tokenScore += similarity * weight
                weightedCount += weight
            }
            
            let avgTokenScore = weightedCount > 0 ? tokenScore / weightedCount : 0.0
            
            // Bonus for matching structural elements at boundaries
            var boundaryBonus = 0.0
            if !aiLines.isEmpty && !windowLines.isEmpty {
                if lineSimilarity(aiLines[0], windowLines[0]) > 0.8 {
                    boundaryBonus += 0.1
                }
                if aiLines.count > 1 && windowLines.count > 1 {
                    let lastAI = aiLines[aiLines.count - 1]
                    let lastWindow = windowLines[windowLines.count - 1]
                    if lineSimilarity(lastAI, lastWindow) > 0.8 {
                        boundaryBonus += 0.1
                    }
                }
            }
            
            // Combine scores (weighted average with boundary bonus)
            return min(1.0, (lcsScore * 0.5) + (avgTokenScore * 0.5) + boundaryBonus)
        }
        
        /// Computes Longest Common Subsequence length between two arrays
        private func computeLCS(_ array1: [String], _ array2: [String]) -> Int {
            let m = array1.count
            let n = array2.count
            
            guard m > 0 && n > 0 else { return 0 }
            
            var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
            
            for i in 1...m {
                for j in 1...n {
                    // Use fuzzy matching for LCS
                    if lineSimilarity(array1[i - 1], array2[j - 1]) > 0.7 {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }
            
            return dp[m][n]
        }
        
        /// Calculates similarity between two lines (0.0 to 1.0)
        private func lineSimilarity(_ line1: String, _ line2: String) -> Double {
            if line1 == line2 {
                return 1.0
            }
            
            // Both empty counts as match
            if line1.isEmpty && line2.isEmpty {
                return 1.0
            }
            
            // One empty, one not
            if line1.isEmpty || line2.isEmpty {
                return 0.0
            }
            
            // Token-based similarity (Jaccard index)
            let tokens1 = Set(line1.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))
            let tokens2 = Set(line2.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))
            
            guard !tokens1.isEmpty || !tokens2.isEmpty else {
                // Both are only whitespace/punctuation - check raw character similarity
                let trimmed1 = line1.trimmingCharacters(in: .whitespaces)
                let trimmed2 = line2.trimmingCharacters(in: .whitespaces)
                return trimmed1 == trimmed2 ? 1.0 : 0.0
            }
            
            let intersection = tokens1.intersection(tokens2).count
            let union = tokens1.union(tokens2).count
            
            // Base Jaccard similarity
            let jaccard = union > 0 ? Double(intersection) / Double(union) : 0.0
            
            // Bonus for matching token order (important for signatures)
            var orderBonus = 0.0
            let arr1 = Array(tokens1)
            let arr2 = Array(tokens2)
            if arr1.count > 0 && arr2.count > 0 {
                let commonPrefix = zip(arr1, arr2).prefix(while: { $0 == $1 }).count
                orderBonus = Double(commonPrefix) / Double(max(arr1.count, arr2.count)) * 0.2
            }
            
            return min(1.0, jaccard + orderBonus)
        }
        
        /// Converts a line range to a character range in the original text
        private func lineRangeToCharacterRange(
            lineStart: Int,
            lineEnd: Int,
            originalLines: [String],
            in text: String
        ) -> Range<String.Index>? {
            guard lineStart >= 0 && lineEnd <= originalLines.count && lineStart < lineEnd else {
                return nil
            }
            
            // Calculate character offset for start line
            var startOffset = 0
            for i in 0..<lineStart {
                startOffset += originalLines[i].count + 1 // +1 for newline
            }
            
            // Calculate character offset for end line (exclusive)
            var endOffset = startOffset
            for i in lineStart..<lineEnd {
                endOffset += originalLines[i].count
                if i < lineEnd - 1 {
                    endOffset += 1 // +1 for newline between lines
                }
            }
            
            // Include trailing newline if present
            if lineEnd < originalLines.count {
                endOffset += 1
            }
            
            guard startOffset <= text.count && endOffset <= text.count else {
                return nil
            }
            
            let startIndex = text.index(text.startIndex, offsetBy: startOffset, limitedBy: text.endIndex) ?? text.startIndex
            let endIndex = text.index(text.startIndex, offsetBy: endOffset, limitedBy: text.endIndex) ?? text.endIndex
            
            guard startIndex < endIndex else {
                return nil
            }
            
            return startIndex..<endIndex
        }
    }
    
    private func buildUpdatedText(
        original: String,
        selection: EditorSelectionSnapshot?,
        replacement: String
    ) -> (updated: String, mode: AssistantApplyMode) {
        // Strategy 0: Parse SEARCH/REPLACE blocks from AI response (highest priority)
        // This is the most reliable method when AI follows the structured format
        let searchReplaceBlocks = SearchReplaceBlock.parse(from: replacement)

        if !searchReplaceBlocks.isEmpty {
            var currentText = original
            var appliedCount = 0
            
            // Apply all blocks in order
            for block in searchReplaceBlocks {
                if let updatedText = block.apply(to: currentText) {
                    currentText = updatedText
                    appliedCount += 1
                }
            }
            
            // If at least one block was applied successfully, return the result
            if appliedCount > 0 {
                return (currentText, .replaceMatchedCode)
            }
            
            // If blocks were found but couldn't be applied, extract the replacement content
            // and fall through to other strategies
        }
        
        // Extract clean code from replacement (strip SEARCH/REPLACE markers if present)
        let cleanReplacement = extractCleanReplacement(from: replacement)
        
        // Strategy 1: Use explicit selection if available and valid
        if let selection {
            if let range = selectionRange(for: selection, in: original) {
                let updated = original.replacingCharacters(in: range, with: cleanReplacement)
                let mode: AssistantApplyMode = selection.isEmpty ? .insertAtCursor : .replaceSelection
                return (updated, mode)
            }
            // Fallback: try to locate the selected text directly if offsets drifted.
            if !selection.text.isEmpty, let textRange = original.range(of: selection.text) {
                let updated = original.replacingCharacters(in: textRange, with: cleanReplacement)
                let mode: AssistantApplyMode = selection.isEmpty ? .insertAtCursor : .replaceSelection
                return (updated, mode)
            }
        }

        // Strategy 2: Use SmartCodeMatcher for intelligent code matching
        // This is the primary strategy for finding the correct replacement region
        let matcher = SmartCodeMatcher()
        if let matchRange = matcher.findBestReplacementRange(
            aiOutput: cleanReplacement,
            originalContent: original
        ) {
            let updated = original.replacingCharacters(in: matchRange, with: cleanReplacement)
            return (updated, .replaceMatchedCode)
        }

        // Strategy 3: Fallback to legacy anchor-based matching (for edge cases)
        if let matchRange = findBestMatch(replacement: cleanReplacement, in: original, fuzzy: true) {
            let updated = original.replacingCharacters(in: matchRange, with: cleanReplacement)
            return (updated, .replaceMatchedCode)
        }

        // Strategy 4: Empty document - replace entire content
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (cleanReplacement, .replaceDocument)
        }

        // Strategy 5: Fallback - append to document with proper spacing
        let separator = original.hasSuffix("\n") ? "" : "\n\n"
        return (original + separator + cleanReplacement, .appendToDocument)
    }
    
    /// Extract clean replacement code from AI output, stripping any SEARCH/REPLACE markers
    /// if they couldn't be applied properly
    private func extractCleanReplacement(from text: String) -> String {
        // If text contains SEARCH/REPLACE blocks, extract just the REPLACE portions
        let blocks = SearchReplaceBlock.parse(from: text)

        // If we have valid blocks, extract replacement content
        if !blocks.isEmpty {
            // Return all REPLACE contents joined
            return blocks.map(\.replaceText).joined(separator: "\n\n")
        }
        
        // Check if it's a raw code block (```language ... ```)
        let codeBlockPattern = #"```\w*\n([\s\S]*?)\n```"#
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let contentRange = Range(match.range(at: 1), in: text) {
            return String(text[contentRange])
        }
        
        return text
    }

    private func selectionRange(
        for selection: EditorSelectionSnapshot, in text: String
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

    /// Finds the best match for the replacement code in the original text
    /// Returns the range to replace, or nil if no suitable match is found
    private func findBestMatch(
        replacement: String,
        in original: String,
        fuzzy: Bool
    ) -> Range<String.Index>? {
        let replacementLines = replacement.components(separatedBy: .newlines)
        let originalLines = original.components(separatedBy: .newlines)

        guard replacementLines.count > 0 && replacementLines.count <= originalLines.count else {
            return nil
        }

        // First try anchor-based matching
        if let anchorRange = findWithAnchors(replacement: replacement, in: original, fuzzy: fuzzy) {
            return anchorRange
        }

        // Fallback to variable window size matching
        return findWithVariableWindow(replacement: replacement, in: original, fuzzy: fuzzy)
    }
    
    /// Finds matches using leading/trailing anchor lines for precise positioning
    private func findWithAnchors(
        replacement: String,
        in original: String,
        fuzzy: Bool
    ) -> Range<String.Index>? {
        let replacementLines = replacement.components(separatedBy: .newlines)
        let originalLines = original.components(separatedBy: .newlines)
        
        // Detect anchor lines (lines that likely exist unchanged in original)
        let (leadingAnchors, coreLines, trailingAnchors) = extractAnchors(from: replacementLines, in: originalLines, fuzzy: fuzzy)
        
        guard !leadingAnchors.isEmpty || !trailingAnchors.isEmpty else {
            return nil // No anchors found
        }
        
        // Find anchor positions in original
        var startLine: Int? = nil
        var endLine: Int? = nil
        
        if !leadingAnchors.isEmpty {
            startLine = findSequence(leadingAnchors, in: originalLines, fuzzy: fuzzy)
        }
        
        if !trailingAnchors.isEmpty {
            let trailingStart = findSequence(trailingAnchors, in: originalLines, fuzzy: fuzzy)
            if let trailingStart = trailingStart {
                endLine = trailingStart + trailingAnchors.count
            }
        }
        
        // Calculate replacement range based on anchors
        if let start = startLine, let end = endLine {
            let replaceStart = start + leadingAnchors.count
            let replaceEnd = end - trailingAnchors.count
            guard replaceStart <= replaceEnd else { return nil }
            return lineRangeToCharacterRange(lineStart: replaceStart, lineEnd: replaceEnd, in: original)
        } else if let start = startLine {
            let replaceStart = start + leadingAnchors.count
            let replaceEnd = replaceStart + coreLines.count
            return lineRangeToCharacterRange(lineStart: replaceStart, lineEnd: replaceEnd, in: original)
        } else if let end = endLine {
            let replaceEnd = end - trailingAnchors.count
            let replaceStart = replaceEnd - coreLines.count
            guard replaceStart >= 0 else { return nil }
            return lineRangeToCharacterRange(lineStart: replaceStart, lineEnd: replaceEnd, in: original)
        }
        
        return nil
    }
    
    /// Extracts leading anchors, core changes, and trailing anchors from replacement
    private func extractAnchors(
        from replacementLines: [String],
        in originalLines: [String],
        fuzzy: Bool
    ) -> (leading: [String], core: [String], trailing: [String]) {
        let normalize: (String) -> String = { text in
            fuzzy ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            : text
        }
        
        let normalizedReplacement = replacementLines.map(normalize)
        let normalizedOriginal = originalLines.map(normalize)
        let originalSet = Set(normalizedOriginal)
        
        var leadingAnchors: [String] = []
        var trailingAnchors: [String] = []
        
        // Find leading anchors
        for line in normalizedReplacement {
            if originalSet.contains(line) {
                leadingAnchors.append(line)
            } else {
                break
            }
        }
        
        // Find trailing anchors
        for line in normalizedReplacement.reversed() {
            if originalSet.contains(line) && !leadingAnchors.contains(line) {
                trailingAnchors.insert(line, at: 0)
            } else {
                break
            }
        }
        
        // Extract core lines
        let coreStart = leadingAnchors.count
        let coreEnd = replacementLines.count - trailingAnchors.count
        let coreLines = Array(replacementLines[coreStart..<max(coreStart, coreEnd)])
        
        return (leadingAnchors, coreLines, trailingAnchors)
    }
    
    /// Finds a sequence of lines in the original text
    private func findSequence(
        _ sequence: [String],
        in originalLines: [String],
        fuzzy: Bool
    ) -> Int? {
        let normalize: (String) -> String = { text in
            fuzzy ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            : text
        }
        
        let normalizedSequence = sequence.map(normalize)
        let normalizedOriginal = originalLines.map(normalize)
        
        for i in 0...(originalLines.count - sequence.count) {
            let window = Array(normalizedOriginal[i..<(i + sequence.count)])
            if window == normalizedSequence {
                return i
            }
        }
        return nil
    }
    
    /// Variable window size matching for cases without clear anchors
    private func findWithVariableWindow(
        replacement: String,
        in original: String,
        fuzzy: Bool
    ) -> Range<String.Index>? {
        let replacementLines = replacement.components(separatedBy: .newlines)
        let originalLines = original.components(separatedBy: .newlines)
        
        let normalize: (String) -> String = { text in
            fuzzy ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            : text
        }

        let normalizedReplacementLines = replacementLines.map(normalize)
        let normalizedOriginalLines = originalLines.map(normalize)

        var bestMatchRange: Range<Int>?
        var bestMatchScore = 0
        
        // Try different window sizes around the replacement length
        let baseWindowSize = replacementLines.count
        for delta in [-2, -1, 0, 1, 2] {
            let windowSize = max(1, min(originalLines.count, baseWindowSize + delta))
            
            for i in 0...(originalLines.count - windowSize) {
                let windowEnd = i + windowSize
                let windowLines = Array(normalizedOriginalLines[i..<windowEnd])

                // Calculate token-based match score
                let matchScore = calculateTokenMatchScore(
                    window: windowLines,
                    replacement: normalizedReplacementLines,
                    fuzzy: fuzzy
                )

                let threshold = fuzzy ? Double(windowSize) * 0.4 : Double(windowSize) * 0.8
                if matchScore >= threshold && matchScore > Double(bestMatchScore) {
                    bestMatchScore = Int(matchScore)
                    bestMatchRange = i..<windowEnd
                }
            }
        }

        guard let matchRange = bestMatchRange else {
            return nil
        }

        return lineRangeToCharacterRange(
            lineStart: matchRange.lowerBound,
            lineEnd: matchRange.upperBound,
            in: original
        )
    }
    
    /// Calculate token-based match score between window and replacement
    private func calculateTokenMatchScore(
        window: [String],
        replacement: [String],
        fuzzy: Bool
    ) -> Double {
        let maxLines = max(window.count, replacement.count)
        guard maxLines > 0 else { return 0 }
        
        var totalScore = 0.0
        
        for i in 0..<maxLines {
            let windowLine = i < window.count ? window[i] : ""
            let replacementLine = i < replacement.count ? replacement[i] : ""
            
            if windowLine == replacementLine && !windowLine.isEmpty {
                totalScore += 1.0
            } else if !windowLine.isEmpty && !replacementLine.isEmpty {
                totalScore += tokenSimilarity(windowLine, replacementLine)
            }
        }
        
        return totalScore
    }

    /// Converts a line range to a character range in the original text
    private func lineRangeToCharacterRange(
        lineStart: Int,
        lineEnd: Int,
        in text: String
    ) -> Range<String.Index>? {
        let lines = text.components(separatedBy: .newlines)
        guard lineStart >= 0 && lineEnd <= lines.count else {
            return nil
        }

        // Calculate character offset for start line
        var startOffset = 0
        for i in 0..<lineStart {
            startOffset += lines[i].count + 1 // +1 for newline
        }

        // Calculate character offset for end line
        var endOffset = startOffset
        for i in lineStart..<lineEnd {
            endOffset += lines[i].count
            if i < lineEnd - 1 {
                endOffset += 1 // +1 for newline between lines
            }
        }

        // Include trailing newline if present
        if lineEnd < lines.count {
            endOffset += 1
        }

        guard startOffset <= text.count && endOffset <= text.count else {
            return nil
        }

        let startIndex = text.index(text.startIndex, offsetBy: startOffset)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)

        return startIndex..<endIndex
    }

    /// Finds the most similar code block in the original text using similarity scoring
    /// This helps when the AI is suggesting modifications to existing code
    private func findSimilarCodeBlock(
        replacement: String,
        in original: String
    ) -> Range<String.Index>? {
        let replacementLines = replacement.components(separatedBy: .newlines)
        let originalLines = original.components(separatedBy: .newlines)

        // Don't try if replacement is too short or way too long
        guard replacementLines.count >= 2 && replacementLines.count <= originalLines.count else {
            return nil
        }
        
        // First try matching by first/last significant lines (strong anchors)
        if let anchorRange = findBySignificantLines(replacement: replacementLines, in: originalLines) {
            return lineRangeToCharacterRange(
                lineStart: anchorRange.lowerBound,
                lineEnd: anchorRange.upperBound,
                in: original
            )
        }

        // Fallback to similarity-based matching with variable window sizes
        var bestMatchRange: Range<Int>?
        var bestSimilarity: Double = 0.0
        let minSimilarity: Double = 0.35 // Slightly lower threshold for fallback

        // Try different window sizes to handle additions/deletions
        let baseWindowSize = replacementLines.count
        for delta in [-1, 0, 1, 2] {
            let windowSize = max(1, min(originalLines.count, baseWindowSize + delta))
            
            for i in 0...(originalLines.count - windowSize) {
                let windowEnd = i + windowSize
                let windowLines = Array(originalLines[i..<windowEnd])

                // Calculate similarity between this window and the replacement
                let similarity = calculateSimilarity(
                    lines1: windowLines,
                    lines2: replacementLines
                )

                if similarity > bestSimilarity && similarity >= minSimilarity {
                    bestSimilarity = similarity
                    bestMatchRange = i..<windowEnd
                }
            }
        }

        guard let matchRange = bestMatchRange else {
            return nil
        }

        return lineRangeToCharacterRange(
            lineStart: matchRange.lowerBound,
            lineEnd: matchRange.upperBound,
            in: original
        )
    }
    
    /// Attempts to find a match by looking for significant first/last lines
    private func findBySignificantLines(
        replacement: [String],
        in originalLines: [String]
    ) -> Range<Int>? {
        let nonEmptyReplacement = replacement.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard nonEmptyReplacement.count >= 2 else { return nil }
        
        let firstLine = nonEmptyReplacement.first!.trimmingCharacters(in: .whitespaces)
        let lastLine = nonEmptyReplacement.last!.trimmingCharacters(in: .whitespaces)
        
        // Look for function signatures, class declarations, or other significant patterns
        let isSignificantLine = { (line: String) -> Bool in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.contains("func ") || 
                   trimmed.contains("class ") || 
                   trimmed.contains("struct ") || 
                   trimmed.contains("enum ") || 
                   trimmed.contains("protocol ") ||
                   trimmed.contains("extension ") ||
                   trimmed == "}" || 
                   trimmed.hasPrefix("import ") ||
                   trimmed.hasPrefix("@")
        }
        
        if isSignificantLine(firstLine) || isSignificantLine(lastLine) {
            // Find first line in original
            for (i, originalLine) in originalLines.enumerated() {
                let trimmedOriginal = originalLine.trimmingCharacters(in: .whitespaces)
                if tokenSimilarity(trimmedOriginal, firstLine) > 0.8 {
                    // Look for matching last line within reasonable distance
                    let searchEnd = min(originalLines.count, i + replacement.count + 3)
                    for j in (i + 1)..<searchEnd {
                        let trimmedEndOriginal = originalLines[j].trimmingCharacters(in: .whitespaces)
                        if tokenSimilarity(trimmedEndOriginal, lastLine) > 0.8 {
                            return i..<(j + 1)
                        }
                    }
                    // If we found first line but not last, use replacement length as estimate
                    let estimatedEnd = min(originalLines.count, i + replacement.count)
                    return i..<estimatedEnd
                }
            }
        }
        
        return nil
    }

    /// Calculates token-based similarity between two strings (0.0 to 1.0)
    private func tokenSimilarity(_ s1: String, _ s2: String) -> Double {
        // Split on non-alphanumeric characters to get tokens (identifiers, keywords, etc.)
        let tokens1 = Set(s1.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))
        let tokens2 = Set(s2.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))
        
        guard !tokens1.isEmpty || !tokens2.isEmpty else { return 0.0 }
        
        let intersection = tokens1.intersection(tokens2).count
        let union = tokens1.union(tokens2).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }
    
    /// Calculates similarity between two sets of code lines (0.0 to 1.0)
    private func calculateSimilarity(lines1: [String], lines2: [String]) -> Double {
        guard lines1.count == lines2.count, lines1.count > 0 else {
            return 0.0
        }

        var totalSimilarity = 0.0

        for (line1, line2) in zip(lines1, lines2) {
            // Normalize by removing all whitespace for comparison
            let normalized1 = line1.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized2 = line2.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalized1 == normalized2 {
                totalSimilarity += 1.0
            } else if !normalized1.isEmpty && !normalized2.isEmpty {
                // Use token-based similarity instead of character-level
                totalSimilarity += tokenSimilarity(normalized1, normalized2)
            }
        }

        return totalSimilarity / Double(lines1.count)
    }
}

// MARK: - Search/Replace Block Parser

/// Represents a parsed SEARCH/REPLACE edit block from AI output
private struct SearchReplaceBlock: Identifiable {
    let id = UUID()
    let searchText: String
    let replaceText: String
    let language: String?

    /// Check if this block is valid (has non-empty search and replace text)
    var isValid: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Get display preview of the change
    var changePreview: String {
        let searchPreview = searchText.prefix(80) + (searchText.count > 80 ? "..." : "")
        let replacePreview = replaceText.prefix(80) + (replaceText.count > 80 ? "..." : "")
        return "\(searchPreview) → \(replacePreview)"
    }

    /// Parse all SEARCH/REPLACE blocks from AI-generated code
    static func parse(from text: String) -> [SearchReplaceBlock] {
        var blocks: [SearchReplaceBlock] = []

        // Pattern matches code blocks containing SEARCH/REPLACE format
        // Supports both fenced code blocks and raw markers
        // Enhanced with alternative formats and better error handling
        let patterns = [
            // Fenced code block with language: ```swift\n<<<<<<< SEARCH ... >>>>>>> REPLACE\n```
            #"```(\w*)\n<<<<<<< SEARCH\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>> REPLACE\n```"#,
            // Fenced code block without language
            #"```\n<<<<<<< SEARCH\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>> REPLACE\n```"#,
            // Raw markers (not in code block)
            #"<<<<<<< SEARCH\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>> REPLACE"#,
        ]

        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)

            for match in matches {
                var language: String? = nil
                var searchText: String = ""
                var replaceText: String = ""

                if index == 0 {
                    // Pattern with language identifier
                    if match.numberOfRanges >= 4 {
                        if let langRange = Range(match.range(at: 1), in: text) {
                            let lang = String(text[langRange])
                            if !lang.isEmpty {
                                language = lang
                            }
                        }
                        if let searchRange = Range(match.range(at: 2), in: text) {
                            searchText = String(text[searchRange])
                        }
                        if let replaceRange = Range(match.range(at: 3), in: text) {
                            replaceText = String(text[replaceRange])
                        }
                    }
                } else {
                    // Patterns without language identifier
                    if match.numberOfRanges >= 3 {
                        if let searchRange = Range(match.range(at: 1), in: text) {
                            searchText = String(text[searchRange])
                        }
                        if let replaceRange = Range(match.range(at: 2), in: text) {
                            replaceText = String(text[replaceRange])
                        }
                    }
                }

                // Only add if we have valid search text
                if !searchText.isEmpty {
                    blocks.append(SearchReplaceBlock(
                        searchText: searchText,
                        replaceText: replaceText,
                        language: language
                    ))
                }
            }
        }

        return blocks
    }

    /// Apply this search/replace block to the original text
    /// Returns the modified text if the search pattern was found, nil otherwise
    func apply(to original: String) -> String? {
        // Strategy 1: Exact match
        if let range = original.range(of: searchText) {
            return original.replacingCharacters(in: range, with: replaceText)
        }

        // Strategy 2: Normalized whitespace match (preserve original indentation style)
        if let range = findNormalizedMatch(in: original) {
            return original.replacingCharacters(in: range, with: replaceText)
        }

        // Strategy 3: Line-by-line fuzzy match
        if let range = findFuzzyLineMatch(in: original) {
            return original.replacingCharacters(in: range, with: replaceText)
        }

        return nil
    }

    /// Find a match with normalized whitespace (handles tab/space differences)
    private func findNormalizedMatch(in original: String) -> Range<String.Index>? {
        let normalizeWhitespace: (String) -> String = { text in
            text.components(separatedBy: .newlines)
                .map { line in
                    // Normalize leading whitespace to single representation
                    let stripped = line.trimmingCharacters(in: .whitespaces)
                    let leadingCount = line.prefix(while: { $0.isWhitespace }).count
                    return String(repeating: " ", count: leadingCount) + stripped
                }
                .joined(separator: "\n")
        }

        let normalizedOriginal = normalizeWhitespace(original)
        let normalizedSearch = normalizeWhitespace(searchText)

        if let normalizedRange = normalizedOriginal.range(of: normalizedSearch) {
            // Map back to original string indices
            let startOffset = normalizedOriginal.distance(
                from: normalizedOriginal.startIndex,
                to: normalizedRange.lowerBound
            )
            let endOffset = normalizedOriginal.distance(
                from: normalizedOriginal.startIndex,
                to: normalizedRange.upperBound
            )

            // Find corresponding position in original by counting newlines
            let originalLines = original.components(separatedBy: .newlines)
            let normalizedLines = normalizedOriginal.components(separatedBy: .newlines)

            var normalizedCharCount = 0
            var startLineIdx = 0
            var endLineIdx = 0

            // Find start line
            for (idx, line) in normalizedLines.enumerated() {
                if normalizedCharCount + line.count >= startOffset {
                    startLineIdx = idx
                    break
                }
                normalizedCharCount += line.count + 1 // +1 for newline
            }

            // Find end line
            normalizedCharCount = 0
            for (idx, line) in normalizedLines.enumerated() {
                normalizedCharCount += line.count + 1
                if normalizedCharCount >= endOffset {
                    endLineIdx = idx
                    break
                }
            }

            // Calculate original string range
            var startCharIdx = 0
            for i in 0..<startLineIdx {
                startCharIdx += originalLines[i].count + 1
            }

            var endCharIdx = 0
            for i in 0...min(endLineIdx, originalLines.count - 1) {
                endCharIdx += originalLines[i].count
                if i < endLineIdx {
                    endCharIdx += 1
                }
            }

            guard startCharIdx <= original.count && endCharIdx <= original.count else {
                return nil
            }

            let startIndex = original.index(original.startIndex, offsetBy: startCharIdx)
            let endIndex = original.index(original.startIndex, offsetBy: endCharIdx)

            return startIndex..<endIndex
        }

        return nil
    }

    /// Find a fuzzy match based on line-by-line comparison
    private func findFuzzyLineMatch(in original: String) -> Range<String.Index>? {
        let searchLines = searchText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let originalLines = original.components(separatedBy: .newlines)

        guard searchLines.count >= 2, originalLines.count >= searchLines.count else {
            return nil
        }

        // Find first matching line with high confidence
        let firstSearchLine = searchLines[0]
        var bestStartIdx: Int? = nil
        var bestScore: Double = 0.7 // Minimum threshold

        for (idx, originalLine) in originalLines.enumerated() {
            let trimmed = originalLine.trimmingCharacters(in: .whitespaces)
            let similarity = tokenSimilarity(firstSearchLine, trimmed)

            if similarity > bestScore {
                // Check if subsequent lines also match
                var matchScore = similarity

                for i in 1..<min(searchLines.count, originalLines.count - idx) {
                    let searchLine = searchLines[i]
                    let origLine = originalLines[idx + i].trimmingCharacters(in: .whitespaces)
                    let lineSim = tokenSimilarity(searchLine, origLine)

                    if lineSim > 0.6 {
                        matchScore += lineSim
                    }
                }

                let avgScore = matchScore / Double(searchLines.count)
                if avgScore > bestScore {
                    bestScore = avgScore
                    bestStartIdx = idx
                }
            }
        }

        guard let startIdx = bestStartIdx else {
            return nil
        }

        // Find the end index by matching the last few lines
        let lastSearchLine = searchLines.last!
        var endIdx = min(startIdx + searchLines.count, originalLines.count)

        // Refine end position by looking for matching last line
        for i in (startIdx + 1)..<min(startIdx + searchLines.count + 3, originalLines.count) {
            let trimmed = originalLines[i].trimmingCharacters(in: .whitespaces)
            if tokenSimilarity(lastSearchLine, trimmed) > 0.8 {
                endIdx = i + 1
                break
            }
        }

        // Calculate character range
        var startOffset = 0
        for i in 0..<startIdx {
            startOffset += originalLines[i].count + 1
        }

        var endOffset = 0
        for i in 0..<endIdx {
            endOffset += originalLines[i].count
            if i < endIdx - 1 || endIdx < originalLines.count {
                endOffset += 1
            }
        }

        guard startOffset < original.count && endOffset <= original.count else {
            return nil
        }

        let startIndex = original.index(original.startIndex, offsetBy: startOffset)
        let endIndex = original.index(original.startIndex, offsetBy: min(endOffset, original.count))

        return startIndex..<endIndex
    }

    /// Token-based similarity for fuzzy matching
    private func tokenSimilarity(_ s1: String, _ s2: String) -> Double {
        if s1 == s2 { return 1.0 }
        if s1.isEmpty && s2.isEmpty { return 1.0 }
        if s1.isEmpty || s2.isEmpty { return 0.0 }

        let tokens1 = Set(s1.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))
        let tokens2 = Set(s2.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }))

        guard !tokens1.isEmpty || !tokens2.isEmpty else { return 0.0 }

        let intersection = tokens1.intersection(tokens2).count
        let union = tokens1.union(tokens2).count
        return union > 0 ? Double(intersection) / Double(union) : 0.0
    }
}

// MARK: - Model Selection View

private struct ModelSelectionView: View {
    @ObservedObject var viewModel: CodeAssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var modelDraft: String = ""
    @State private var showCustomModelField = false
    @FocusState private var customModelFieldIsFocused: Bool

    private var trimmedDraft: String {
        modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var body: some View {
        NavigationStack {
            List {
                providerSection
                suggestedModelsSection
                selectionSection
                temperatureSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Model")
            .toolbar(content: {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        applyModel()
                        dismiss()
                    }
                }
            })
            .onAppear {
                syncDraftWithSelection()
            }
            .onChange(of: viewModel.selectedProvider) {
                syncDraftWithSelection()
            }
        }
    }
    
    private var providerSection: some View {
        Section(header: Text("AI Provider"), footer: Text("Provider keys are managed in Settings.")) {
            Picker("Provider", selection: $viewModel.selectedProvider) {
                ForEach(CodeAssistantProvider.allCases) { provider in
                    HStack(spacing: 8) {
                        Text(provider.displayName)
                    }
                    .tag(provider)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var suggestedModelsSection: some View {
        Section(
            header: Text("Model Presets"),
            footer: Text(
                "Need something else? Choose Custom to enter any model supported by \(viewModel.selectedProvider.displayName)."
            )
        ) {
            ForEach(viewModel.selectedProvider.suggestedModels, id: \.self) { model in
                Button {
                    selectSuggestedModel(model)
                } label: {
                    HStack {
                        Text(model)
                            .font(.body.monospaced())
                        Spacer()
                        if !showCustomModelField && modelDraft == model {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }

            Button {
                enableCustomModelEntry()
            } label: {
                HStack {
                    Text("Custom Model…")
                    Spacer()
                    if showCustomModelField {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    private var selectionSection: some View {
        Section(
            header: Text(showCustomModelField ? "Custom Model" : "Selected Model"),
            footer: Text("Currently using: \(viewModel.currentModel)")
        ) {
            if showCustomModelField {
                TextField("Model Name", text: $modelDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .focused($customModelFieldIsFocused)
            } else {
                Text(modelDraft)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button {
                applyModel()
                dismiss()
            } label: {
                Label("Use This Model", systemImage: "checkmark.circle.fill")
            }
            .disabled(trimmedDraft.isEmpty)

            Button {
                resetToDefault()
            } label: {
                Label("Reset to Default", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var temperatureSection: some View {
        Section(
            header: Text("Temperature"),
            footer: Text("Lower values (0.0-0.3) produce focused, deterministic outputs. Higher values (0.7-1.0) increase creativity and variety.")
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(String(format: "%.1f", viewModel.temperature))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1) {
                    Text("Temperature")
                } minimumValueLabel: {
                    Text("0")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("1")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func applyModel() {
        viewModel.updateModel(trimmedDraft)
        syncDraftWithSelection()
    }

    private func selectSuggestedModel(_ model: String) {
        modelDraft = model
        showCustomModelField = false
    }

    private func enableCustomModelEntry() {
        showCustomModelField = true
        if viewModel.selectedProvider.suggestedModels.contains(modelDraft) {
            modelDraft = ""
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            customModelFieldIsFocused = true
        }
    }

    private func resetToDefault() {
        modelDraft = viewModel.selectedProvider.defaultModel
        showCustomModelField = false
    }

    private func syncDraftWithSelection() {
        let current = viewModel.currentModel
        modelDraft = current
        showCustomModelField = !viewModel.selectedProvider.suggestedModels.contains(current)
    }
}

// MARK: - Message Bubble View

private struct MessageBubbleView: View {
    let message: CodeAssistantViewModel.Message
    var onApply: (String, String?) -> Void = { _, _ in }

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                header
                if message.isStreaming && message.body.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Markdown(message.body.isEmpty ? "…" : message.body)
                        .markdownBlockStyle(\.codeBlock) { configuration in
                            CopyableCodeBlock(
                                configuration: configuration,
                                onApply: { text in
                                    onApply(text, configuration.language)
                                }
                            )
                        }
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.attachments) { attachment in
                            Text("📎 \(attachment.name) (\(attachment.formattedSize))")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let error = message.errorDescription {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(message.role == .user
                        ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            )
            .frame(maxWidth: 420, alignment: .leading)
            if message.role == .assistant {
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack {
            Label(
                message.role == .user ? "You" : "Assistant",
                systemImage: message.role == .user ? "person.circle" : "sparkles")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(message.createdAt, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
            if message.role == .assistant && !message.body.isEmpty {
                Button {
                    copyMessage()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copyMessage() {
        #if os(iOS)
            UIPasteboard.general.string = message.body
        #elseif os(macOS)
            NSPasteboard.general?.clearContents()
            NSPasteboard.general?.setString(message.body, forType: .string)
        #endif
    }
}

private struct AttachmentChipView: View {
    let attachment: CodeAssistantViewModel.Attachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).font(.caption)
                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(
            Capsule()
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

private struct HistoryChip: View {
    let conversation: CodeAssistantViewModel.Conversation
    var onSelect: () -> Void
    var onDelete: () -> Void
    var fillsWidth: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        Label {
                            Text(conversation.createdAt, style: .date)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        Label("\(conversation.messages.count)", systemImage: "bubble.left.and.bubble.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct SearchReplaceBlockView: View {
    let block: SearchReplaceBlock
    let blockIndex: Int
    let totalBlocks: Int
    var onApplyBlock: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Block \(blockIndex + 1) of \(totalBlocks)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let language = block.language {
                    Text(language.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("SEARCH:")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(block.searchText)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.red.opacity(0.1))
                    )

                Text("REPLACE:")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(block.replaceText)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.green.opacity(0.1))
                    )
            }

            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Apply Block \(blockIndex + 1)", action: onApplyBlock)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

private struct CopyableCodeBlock: View {
    let configuration: CodeBlockConfiguration
    var onApply: (String) -> Void = { _ in }
    @EnvironmentObject private var app: MainApp
    @State private var didCopy = false
    @State private var didQueueApply = false
    @State private var appliedBlockIds: Set<UUID> = []
    @State private var errorBlockIds: [UUID: String] = [:]
    private var plainText: String {
        configuration.content
    }

    private var searchReplaceBlocks: [SearchReplaceBlock] {
        SearchReplaceBlock.parse(from: plainText)
    }

    private var hasMultipleBlocks: Bool {
        searchReplaceBlocks.count > 1
    }

    private var appliedCount: Int {
        appliedBlockIds.count
    }

    private var totalCount: Int {
        searchReplaceBlocks.count
    }

    private var allBlocksApplied: Bool {
        !searchReplaceBlocks.isEmpty && appliedCount == totalCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            codeContentView
            multiBlockSectionView
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var headerView: some View {
        HStack {
            Text(configuration.language?.uppercased() ?? "CODE")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            headerActionButtons
            copyButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    @ViewBuilder
    private var headerActionButtons: some View {
        if hasMultipleBlocks {
            Menu {
                Button {
                    showDiffPreview()
                } label: {
                    Label("Apply All Blocks", systemImage: "checkmark.circle.fill")
                }
                Button {
                    copyToClipboard(plainText)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        } else {
            Button {
                showDiffPreview()
            } label: {
                Label("Apply", systemImage: "doc.text.magnifyingglass")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.mini)
        }
    }

    private var copyButton: some View {
        Button {
            copyToClipboard(plainText)
        } label: {
            Label(
                didCopy ? "Copied" : "Copy",
                systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc"
            )
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.mini)
    }

    private var codeContentView: some View {
        ScrollView(.horizontal) {
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.9))
                }
                .padding()
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var multiBlockSectionView: some View {
        if hasMultipleBlocks {
            Divider()
            blockListView
            blockStatusView
            previewAllButton
        }
    }

    private var blockListView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(searchReplaceBlocks.enumerated()), id: \.element.id) { index, block in
                blockRowView(block: block, index: index)
            }
        }
        .padding(8)
    }

    private func blockRowView(block: SearchReplaceBlock, index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                blockStatusHeader(block: block, index: index)
                Text(block.searchText.prefix(100) + (block.searchText.count > 100 ? "..." : ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                applyBlock(block, at: index)
            } label: {
                Text(errorBlockIds[block.id] == nil ? "Apply" : "Retry")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appliedBlockIds.contains(block.id))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(blockRowBackground(for: block))
    }

    private func blockStatusHeader(block: SearchReplaceBlock, index: Int) -> some View {
        HStack {
            Text("Block \(index + 1)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if appliedBlockIds.contains(block.id) {
                Text("Applied")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if let error = errorBlockIds[block.id] {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func blockRowBackground(for block: SearchReplaceBlock) -> some View {
        let backgroundColor: Color
        if appliedBlockIds.contains(block.id) {
            backgroundColor = Color.green.opacity(0.1)
        } else if errorBlockIds[block.id] != nil {
            backgroundColor = Color.orange.opacity(0.1)
        } else {
            backgroundColor = Color(.tertiarySystemBackground)
        }
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(backgroundColor)
    }

    @ViewBuilder
    private var blockStatusView: some View {
        if appliedCount > 0 {
            Text("\(appliedCount) of \(totalCount) blocks applied")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8)
        }
    }

    private var previewAllButton: some View {
        Button {
            showDiffPreview()
        } label: {
            Label("Preview All Changes", systemImage: "eye")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
    }

    private func copyToClipboard(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #elseif os(macOS)
            NSPasteboard.general?.clearContents()
            NSPasteboard.general?.setString(text, forType: .string)
        #endif
        withAnimation(.easeInOut(duration: 0.2)) {
            didCopy = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                didCopy = false
            }
        }
    }

    private func requestApply() {
        onApply(plainText)
        withAnimation(.easeInOut(duration: 0.2)) {
            didQueueApply = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                didQueueApply = false
            }
        }
    }

    /// Shows the diff preview using Monaco's built-in diff mode
    private func showDiffPreview() {
        Task {
            guard let activeFile = app.activeTextEditor else {
                app.notificationManager.showWarningMessage(
                    "Open a file in the editor to preview changes.")
                return
            }

            let selection = await app.monacoInstance.selectionSnapshot()
            let originalText = await app.monacoInstance.currentModelValue() ?? activeFile.content
            let updatedText = computeUpdatedText(
                original: originalText,
                selection: selection,
                replacement: plainText
            )

            // Check if there are actual changes
            guard originalText != updatedText else {
                app.notificationManager.showWarningMessage(
                    "No changes detected. The code may already be applied or couldn't be matched.")
                return
            }

            // Switch Monaco to diff mode
            let originalUrl = "assistant://original/\(activeFile.url.lastPathComponent)"
            let modifiedUrl = activeFile.url.absoluteString
            await app.monacoInstance.switchToDiffMode(
                originalContent: originalText,
                modifiedContent: updatedText,
                originalUrl: originalUrl,
                modifiedUrl: modifiedUrl
            )

            // Show notification with Apply and Cancel buttons
            let app = self.app
            let fileName = activeFile.url.lastPathComponent
            let fileUrl = activeFile.url

            app.notificationManager.postActionNotification(
                title: "Preview changes for \(fileName)",
                level: .info,
                primary: {
                    // Apply: set the updated text, save, and exit diff mode
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
                        // Save the file to persist changes
                        await app.saveCurrentFile()
                        app.notificationManager.postActionNotification(
                            title: "Changes applied",
                            level: .info,
                            primary: {
                                Task {
                                    await app.monacoInstance.undo()
                                }
                            },
                            primaryTitle: "Undo",
                            source: fileName
                        )
                    }
                },
                primaryTitle: "Apply",
                secondary: {
                    // Cancel: just exit diff mode
                    Task {
                        await app.monacoInstance.switchToNormalMode()
                    }
                },
                secondaryTitle: "common.cancel",
                source: fileName
            )
        }
    }

    /// Computes the updated text by applying code changes
    private func computeUpdatedText(
        original: String,
        selection: EditorSelectionSnapshot?,
        replacement: String
    ) -> String {
        // Strategy 1: Parse and apply SEARCH/REPLACE blocks
        let blocks = SearchReplaceBlock.parse(from: replacement)

        if !blocks.isEmpty {
            var currentText = original
            var appliedCount = 0

            for block in blocks {
                if let updatedText = block.apply(to: currentText) {
                    currentText = updatedText
                    appliedCount += 1
                }
            }

            if appliedCount > 0 {
                return currentText
            }
        }

        // Strategy 2: Use selection if available
        if let selection = selection, !selection.text.isEmpty {
            if let range = original.range(of: selection.text) {
                return original.replacingCharacters(in: range, with: replacement)
            }
        }

        // Strategy 3: Empty document - replace entire content
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return replacement
        }

        // Strategy 4: Fallback - append to document
        let separator = original.hasSuffix("\n") ? "" : "\n\n"
        return original + separator + replacement
    }

    private func applyBlock(_ block: SearchReplaceBlock, at index: Int) {
        Task {
            guard let activeFile = app.activeTextEditor else {
                await MainActor.run {
                    app.notificationManager.showWarningMessage(
                        "Open the target file before applying changes.")
                }
                return
            }

            let liveText = await app.monacoInstance.currentModelValue() ?? activeFile.content

            if let updatedText = block.apply(to: liveText) {
                // Update the editor's content before setting the model
                if let activeEditor = app.activeEditor as? TextEditorInstance {
                    activeEditor.content = updatedText
                }
                await app.monacoInstance.setValueForModel(
                    url: activeFile.url.absoluteString,
                    value: updatedText
                )
                // Save the file to disk
                await app.saveCurrentFile()
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        didQueueApply = true
                        appliedBlockIds.insert(block.id)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            didQueueApply = false
                        }
                    }
                }
                let app = self.app
                app.notificationManager.postActionNotification(
                    title: "Block \(index + 1) applied",
                    level: .info,
                    primary: {
                        Task {
                            await app.monacoInstance.undo()
                        }
                    },
                    primaryTitle: "Undo",
                    source: activeFile.url.lastPathComponent
                )
            } else {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        errorBlockIds[block.id] = "Could not find matching code"
                    }
                }
            }
        }
    }
}

private enum AssistantApplyMode {
    case replaceSelection
    case insertAtCursor
    case replaceDocument
    case appendToDocument
    case replaceMatchedCode  // AI-matched code replacement
}

private struct AttachmentPickerView: View {
    let root: WorkSpaceStorage.FileItemRepresentable
    var onSelect: (WorkSpaceStorage.FileItemRepresentable) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                AttachmentPickerNode(item: root, onSelect: handleSelect)
            }
            .navigationTitle("Select File")
            .toolbar(content: {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            })
        }
    }

    private func handleSelect(_ item: WorkSpaceStorage.FileItemRepresentable) {
        onSelect(item)
        dismiss()
    }
}

private struct AttachmentPickerNode: View {
    let item: WorkSpaceStorage.FileItemRepresentable
    var onSelect: (WorkSpaceStorage.FileItemRepresentable) -> Void

    var body: some View {
        if let children = item.subFolderItems {
            DisclosureGroup {
                if children.isEmpty {
                    Text("Empty Folder")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(children, id: \.id) { element in
                        AttachmentPickerNode(item: element, onSelect: onSelect)
                    }
                }
            } label: {
                Label(item.name, systemImage: "folder")
            }
        } else {
            Button {
                onSelect(item)
            } label: {
                Label(item.name, systemImage: "doc.text")
                    .lineLimit(1)
            }
        }
    }
}

private struct ChatHistoryView: View {
    @ObservedObject var viewModel: CodeAssistantViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    private var filteredHistory: [CodeAssistantViewModel.Conversation] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return viewModel.history
        }
        return viewModel.history.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Recent chats section (top 5)
                if !viewModel.history.isEmpty && searchText.isEmpty {
                    Section(header: Text("Recent")) {
                        ForEach(viewModel.history.prefix(5)) { conversation in
                            chatRow(for: conversation)
                        }
                    }
                }
                
                // All chats section
                if filteredHistory.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: searchText.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(searchText.isEmpty ? "No Chat History" : "No Results")
                            .font(.headline)
                        Text(searchText.isEmpty ? "Start a new conversation to get started." : "Try adjusting your search.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Color.clear)
                } else if searchText.isEmpty && viewModel.history.count > 5 {
                    Section(header: Text("All Chats")) {
                        ForEach(viewModel.history.dropFirst(5)) { conversation in
                            chatRow(for: conversation)
                        }
                    }
                } else if !searchText.isEmpty {
                    Section(header: Text("Search Results")) {
                        ForEach(filteredHistory) { conversation in
                            chatRow(for: conversation)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Chat History")
            .searchable(text: $searchText, prompt: "Search chats")
            .toolbar(content: {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        viewModel.startNewConversation()
                        dismiss()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button(role: .destructive) {
                            viewModel.clearHistory()
                        } label: {
                            Label("Clear All History", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .disabled(viewModel.history.isEmpty)
                }
            })
        }
    }
    
    private func chatRow(for conversation: CodeAssistantViewModel.Conversation) -> some View {
        Button {
            viewModel.loadConversation(conversation)
            dismiss()
        } label: {
            ChatHistoryRow(conversation: conversation)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                viewModel.deleteConversation(conversation)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        #endif
        .contextMenu {
            Button {
                viewModel.loadConversation(conversation)
                dismiss()
            } label: {
                Label("Open Chat", systemImage: "bubble.left.and.bubble.right")
            }
            
            Divider()
            
            Button(role: .destructive) {
                viewModel.deleteConversation(conversation)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct ChatHistoryRow: View {
    let conversation: CodeAssistantViewModel.Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 12) {
                Label(
                    conversation.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Label("\(conversation.messages.count)", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

#if DEBUG
    struct CodeAssistantPanel_Previews: PreviewProvider {

        static var previews: some View {
            CodeAssistantPanel(viewModel: previewViewModel)
                .environmentObject(previewApp)
                .frame(width: 540, height: 760)
                .padding()
                .background(Color(.systemGroupedBackground))
        }

        private static let previewApp: MainApp = MainApp()

        private static let sampleAttachment = CodeAssistantViewModel.Attachment(
            url: URL(fileURLWithPath: "/tmp/Preview.swift"),
            name: "Preview.swift",
            byteCount: 132,
            content: """
            struct PreviewWidget: View {
                var body: some View {
                    Text("Hello, Preview")
                }
            }
            """,
            languageHint: "swift",
            wasTruncated: false
        )

        private static let previewMessages: [CodeAssistantViewModel.Message] = [
            CodeAssistantViewModel.Message(
                role: .user,
                body: "Refactor the assistant layout to feel great on iPad.",
                payload: "Refactor the assistant layout to feel great on iPad.",
                createdAt: Date().addingTimeInterval(-600),
                attachments: [sampleAttachment]
            ),
            CodeAssistantViewModel.Message(
                role: .assistant,
                body: """
                Here is a SwiftUI snippet:
                ```swift
                VStack(spacing: 12) {
                    providerPicker
                    modelSelector
                }
                ```
                Keep paddings generous for compact size classes.
                """,
                payload: """
                Here is a SwiftUI snippet:
                ```swift
                VStack(spacing: 12) {
                    providerPicker
                    modelSelector
                }
                ```
                Keep paddings generous for compact size classes.
                """,
                createdAt: Date().addingTimeInterval(-550)
            )
        ]

        private static let previewHistory: [CodeAssistantViewModel.Conversation] = [
            CodeAssistantViewModel.Conversation(
                id: UUID(),
                title: "Improve Markdown Copy",
                messages: previewMessages,
                createdAt: Date().addingTimeInterval(-3_600)
            ),
            CodeAssistantViewModel.Conversation(
                id: UUID(),
                title: "API key storage",
                messages: [],
                createdAt: Date().addingTimeInterval(-8_000)
            )
        ]

        private static var previewViewModel: CodeAssistantViewModel = {
            let suiteName = "codeassistant.panel.preview"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            let viewModel = CodeAssistantViewModel(defaults: defaults)
            viewModel.activeConversationTitle = "Preview Chat"
            viewModel.history = previewHistory
            viewModel.messages = previewMessages
            viewModel.currentInput = "Add timeline style history chips."
            return viewModel
        }()
    }
#endif
