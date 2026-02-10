//
//  CodebaseSearchView.swift
//  Code App
//
//  Created by Claude.
//

import SwiftUI

/// View for semantic search across the codebase
struct CodebaseSearchView: View {

    @EnvironmentObject var app: MainApp
    @ObservedObject var indexer: WorkspaceIndexer

    @State private var searchQuery: String = ""
    @State private var isSearching: Bool = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Codebase Search")
                    .font(.headline)
                Spacer()
                if indexer.isIndexing {
                    ProgressView(value: indexer.indexingProgress)
                        .frame(width: 60)
                    Text("\(indexer.indexedFileCount)/\(indexer.totalFileCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            // Search input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search codebase...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .onSubmit {
                        performSearch()
                    }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        indexer.searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))

            Divider()

            // Index status & actions
            HStack {
                if let lastIndexed = indexer.lastIndexedDate {
                    Text("Indexed: \(lastIndexed, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not indexed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if indexer.isIndexing {
                    Button("Cancel") {
                        indexer.cancelIndexing()
                    }
                    .font(.caption)
                } else {
                    Button {
                        startIndexing()
                    } label: {
                        Label("Index", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground))

            Divider()

            // Results
            if indexer.searchResults.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)

                    if indexer.lastIndexedDate == nil {
                        Text("Index your workspace to enable semantic search")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Button {
                            startIndexing()
                        } label: {
                            Label("Index Workspace", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                    } else if searchQuery.isEmpty {
                        Text("Search your codebase using natural language")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No results found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
            } else {
                List {
                    ForEach(indexer.searchResults) { result in
                        SearchResultRow(result: result) {
                            openFile(result)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func startIndexing() {
        guard let workspaceURL = app.workSpaceStorage.currentDirectory._url else {
            app.notificationManager.showWarningMessage("No workspace open")
            return
        }
        indexer.indexWorkspace(at: workspaceURL)
    }

    private func performSearch() {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isSearching = true

        Task {
            await indexer.search(query: searchQuery)
            await MainActor.run {
                isSearching = false
            }
        }
    }

    private func openFile(_ result: WorkspaceIndexer.SearchResult) {
        let url = URL(fileURLWithPath: result.filePath)
        app.openFile(url: url)

        // Scroll to line if available
        if let line = result.lineNumber {
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)  // Wait for file to load
                await app.monacoInstance.scrollToLine(line: line)
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: WorkspaceIndexer.SearchResult
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(result.fileName)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(String(format: "%.0f%%", result.similarity * 100))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(similarityColor(result.similarity).opacity(0.2))
                        )
                }

                Text(result.content.prefix(200) + (result.content.count > 200 ? "..." : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                if let line = result.lineNumber {
                    Text("Line \(line)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func similarityColor(_ similarity: Double) -> Color {
        if similarity > 0.8 {
            return .green
        } else if similarity > 0.6 {
            return .yellow
        } else {
            return .orange
        }
    }
}
