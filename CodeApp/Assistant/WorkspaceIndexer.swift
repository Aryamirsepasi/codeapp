//
//  WorkspaceIndexer.swift
//  Code App
//
//  Created by Arya Mirsepasi.
//

import AIProxy
import Foundation
import SQLite3

/// Service for indexing and searching code in the workspace using embeddings
/// when available, with lexical fallback for non-embedding providers.
@MainActor
final class WorkspaceIndexer: ObservableObject {

    // MARK: - Published State

    @Published var isIndexing: Bool = false
    @Published var indexingProgress: Double = 0.0
    @Published var indexedFileCount: Int = 0
    @Published var totalFileCount: Int = 0
    @Published var lastIndexedDate: Date?
    @Published var searchResults: [SearchResult] = []

    // MARK: - Types

    struct SearchResult: Identifiable {
        let id = UUID()
        let filePath: String
        let fileName: String
        let content: String
        let similarity: Double
        let lineNumber: Int?
    }

    struct IndexedChunk {
        let filePath: String
        let content: String
        let startLine: Int
        let embedding: [Float]
    }

    // MARK: - Private Properties

    private var db: OpaquePointer?
    private let dbPath: String
    private var indexTask: Task<Void, Never>?

    private static let chunkSize = 500  // ~500 tokens per chunk
    private static let overlapSize = 50  // Overlap between chunks

    private let supportedExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "cpp", "c", "cc",
        "js", "ts", "tsx", "jsx", "vue", "svelte",
        "py", "rb", "php", "java", "kt", "scala",
        "go", "rs", "cs", "fs",
        "html", "css", "scss", "less", "sass",
        "json", "yaml", "yml", "toml", "xml",
        "md", "txt", "sql", "sh", "bash", "zsh"
    ]

    // MARK: - Initialization

    init() {
        // Store database in app's documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dbPath = documentsPath.appendingPathComponent("workspace_index.sqlite").path
        setupDatabase()
        loadLastIndexedDate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func setupDatabase() {
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[WorkspaceIndexer] Failed to open database")
            return
        }

        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_path TEXT NOT NULL,
            content TEXT NOT NULL,
            start_line INTEGER,
            embedding BLOB,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS idx_file_path ON chunks(file_path);

        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        );
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, createTableSQL, nil, nil, &errMsg) != SQLITE_OK {
            print("[WorkspaceIndexer] Failed to create tables: \(String(cString: errMsg!))")
            sqlite3_free(errMsg)
        }
    }

    private func loadLastIndexedDate() {
        let query = "SELECT value FROM metadata WHERE key = 'last_indexed'"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let dateStr = sqlite3_column_text(stmt, 0) {
                    let formatter = ISO8601DateFormatter()
                    lastIndexedDate = formatter.date(from: String(cString: dateStr))
                }
            }
        }
        sqlite3_finalize(stmt)
    }

    private func saveLastIndexedDate() {
        let formatter = ISO8601DateFormatter()
        let dateStr = formatter.string(from: Date())
        let query = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('last_indexed', ?)"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, dateStr, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        lastIndexedDate = Date()
    }

    // MARK: - Indexing

    func indexWorkspace(at url: URL) {
        indexTask?.cancel()

        indexTask = Task {
            await performIndexing(at: url)
        }
    }

    func cancelIndexing() {
        indexTask?.cancel()
        isIndexing = false
    }

    private func performIndexing(at url: URL) async {
        isIndexing = true
        indexingProgress = 0.0

        // Clear existing index
        clearIndex()

        // Scan for files
        let files = scanFiles(at: url)
        totalFileCount = files.count
        indexedFileCount = 0

        guard !files.isEmpty else {
            isIndexing = false
            return
        }

        let embeddingService: OpenAIService?
        if let apiKey = embeddingAPIKey() {
            embeddingService = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)
        } else {
            embeddingService = nil
            print("[WorkspaceIndexer] Embeddings unavailable for selected lightweight provider; indexing with lexical fallback")
        }

        for (index, file) in files.enumerated() {
            guard !Task.isCancelled else { break }

            do {
                let content = try String(contentsOf: file, encoding: .utf8)
                let chunks = splitIntoChunks(content: content, filePath: file.path)

                for chunk in chunks {
                    guard !Task.isCancelled else { break }

                    if let service = embeddingService {
                        let embedding = await generateEmbedding(for: chunk.content, service: service)
                        saveChunk(chunk: chunk, embedding: embedding)
                    } else {
                        saveChunk(chunk: chunk, embedding: nil)
                    }
                }

                await MainActor.run {
                    indexedFileCount = index + 1
                    indexingProgress = Double(index + 1) / Double(files.count)
                }
            } catch {
                print("[WorkspaceIndexer] Error indexing \(file.path): \(error)")
            }
        }

        saveLastIndexedDate()

        await MainActor.run {
            isIndexing = false
            indexingProgress = 1.0
        }
    }

    private func scanFiles(at url: URL) -> [URL] {
        var files: [URL] = []

        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            // Skip common non-code directories
            let pathComponents = fileURL.pathComponents
            let skipDirs = ["node_modules", ".git", "Pods", "build", "DerivedData", ".build", "vendor"]
            if pathComponents.contains(where: { skipDirs.contains($0) }) {
                continue
            }

            // Check file extension
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }

            // Skip large files (> 100KB)
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 100_000 {
                continue
            }

            files.append(fileURL)
        }

        return files
    }

    private func splitIntoChunks(content: String, filePath: String) -> [(content: String, startLine: Int, filePath: String)] {
        let lines = content.components(separatedBy: .newlines)
        var chunks: [(content: String, startLine: Int, filePath: String)] = []

        var currentChunk: [String] = []
        var currentStartLine = 1
        var charCount = 0

        for (index, line) in lines.enumerated() {
            currentChunk.append(line)
            charCount += line.count + 1  // +1 for newline

            // Approximate token count (chars / 4)
            if charCount / 4 >= Self.chunkSize {
                let chunkContent = currentChunk.joined(separator: "\n")
                chunks.append((chunkContent, currentStartLine, filePath))

                // Start new chunk with overlap
                let overlapLines = min(Self.overlapSize / 20, currentChunk.count)
                currentChunk = Array(currentChunk.suffix(overlapLines))
                currentStartLine = index + 1 - overlapLines + 1
                charCount = currentChunk.joined(separator: "\n").count
            }
        }

        // Add remaining content
        if !currentChunk.isEmpty {
            let chunkContent = currentChunk.joined(separator: "\n")
            chunks.append((chunkContent, currentStartLine, filePath))
        }

        return chunks
    }

    private func generateEmbedding(
        for text: String,
        service: OpenAIService
    ) async -> [Float]? {
        do {
            let body = OpenAIEmbeddingRequestBody(
                input: .text(text),
                model: "text-embedding-3-small"
            )
            let response: OpenAIEmbeddingResponseBody = try await service.embeddingRequest(body: body, secondsToWait: 60)
            guard let vector = response.embeddings.first?.vector else {
                return nil
            }
            return vector.map { Float($0) }
        } catch {
            print("[WorkspaceIndexer] Embedding error: \(error)")
            return nil
        }
    }

    private func saveChunk(chunk: (content: String, startLine: Int, filePath: String), embedding: [Float]?) {
        let query = "INSERT INTO chunks (file_path, content, start_line, embedding) VALUES (?, ?, ?, ?)"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }

        sqlite3_bind_text(stmt, 1, (chunk.filePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (chunk.content as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(chunk.startLine))

        if let embedding {
            // Convert embedding to blob
            _ = embedding.withUnsafeBytes { buffer in
                let data = Data(buffer)
                _ = data.withUnsafeBytes { dataBuffer in
                    sqlite3_bind_blob(stmt, 4, dataBuffer.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func clearIndex() {
        let query = "DELETE FROM chunks"
        sqlite3_exec(db, query, nil, nil, nil)
    }

    // MARK: - Search

    func search(query: String, limit: Int = 10) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }

        if let apiKey = embeddingAPIKey() {
            let service = AIProxy.openAIDirectService(unprotectedAPIKey: apiKey)
            if let queryEmbedding = await generateEmbedding(for: query, service: service) {
                await semanticSearch(queryEmbedding: queryEmbedding, limit: limit)
                return
            }
        }

        await lexicalSearch(query: query, limit: limit)
    }

    private func embeddingAPIKey() -> String? {
        let lightweight = CodeAssistantSettings.lightweightModelSettings()
        guard lightweight.provider == .openAI else {
            return nil
        }
        let key = CodeAssistantSettings.apiKey(for: .openAI)
        return key.isEmpty ? nil : key
    }

    private func semanticSearch(queryEmbedding: [Float], limit: Int) async {
        var results: [SearchResult] = []

        let selectQuery = "SELECT file_path, content, start_line, embedding FROM chunks"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, selectQuery, -1, &stmt, nil) == SQLITE_OK else { return }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let filePathPtr = sqlite3_column_text(stmt, 0),
                  let contentPtr = sqlite3_column_text(stmt, 1) else {
                continue
            }

            let filePath = String(cString: filePathPtr)
            let content = String(cString: contentPtr)
            let startLine = Int(sqlite3_column_int(stmt, 2))

            guard let blobPtr = sqlite3_column_blob(stmt, 3) else { continue }
            let blobSize = sqlite3_column_bytes(stmt, 3)
            let data = Data(bytes: blobPtr, count: Int(blobSize))
            let chunkEmbedding = data.withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }

            let similarity = cosineSimilarity(queryEmbedding, chunkEmbedding)

            results.append(SearchResult(
                filePath: filePath,
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                content: String(content.prefix(500)),
                similarity: similarity,
                lineNumber: startLine
            ))
        }

        sqlite3_finalize(stmt)

        results.sort { $0.similarity > $1.similarity }
        await MainActor.run {
            searchResults = Array(results.prefix(limit))
        }
    }

    private func lexicalSearch(query: String, limit: Int) async {
        let normalizedQuery = query.lowercased()
        let terms = tokenize(query: query)
        guard !terms.isEmpty else {
            searchResults = []
            return
        }

        var scored: [(result: SearchResult, score: Double)] = []

        let selectQuery = "SELECT file_path, content, start_line FROM chunks"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, selectQuery, -1, &stmt, nil) == SQLITE_OK else { return }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let filePathPtr = sqlite3_column_text(stmt, 0),
                  let contentPtr = sqlite3_column_text(stmt, 1) else {
                continue
            }

            let filePath = String(cString: filePathPtr)
            let content = String(cString: contentPtr)
            let startLine = Int(sqlite3_column_int(stmt, 2))
            let haystack = content.lowercased()

            var score = 0.0
            for term in terms {
                let occurrences = haystack.components(separatedBy: term).count - 1
                guard occurrences > 0 else { continue }
                let weighted = Double(occurrences) * (term.count >= 4 ? 1.25 : 1.0)
                score += weighted
            }
            if haystack.contains(normalizedQuery) {
                score += 3.0
            }
            guard score > 0 else { continue }

            let result = SearchResult(
                filePath: filePath,
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                content: String(content.prefix(500)),
                similarity: score,
                lineNumber: startLine
            )
            scored.append((result: result, score: score))
        }

        sqlite3_finalize(stmt)

        scored.sort { $0.score > $1.score }
        let maxScore = scored.first?.score ?? 1.0
        let normalized = scored.prefix(limit).map { item in
            SearchResult(
                filePath: item.result.filePath,
                fileName: item.result.fileName,
                content: item.result.content,
                similarity: min(1.0, item.score / maxScore),
                lineNumber: item.result.lineNumber
            )
        }

        await MainActor.run {
            searchResults = normalized
        }
    }

    private func tokenize(query: String) -> [String] {
        query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? Double(dotProduct / denominator) : 0
    }

    // MARK: - Context Building

    /// Retrieves relevant context for a query to include in AI prompts.
    func getRelevantContext(for query: String, maxChunks: Int = 5) async -> String {
        await search(query: query, limit: maxChunks)

        var contextParts: [String] = []

        for result in searchResults {
            let header = "// File: \(result.fileName)" + (result.lineNumber.map { " (line \($0))" } ?? "")
            contextParts.append("\(header)\n\(result.content)")
        }

        return contextParts.joined(separator: "\n\n---\n\n")
    }
}
