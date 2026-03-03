//
//  CodeUITests.swift
//  CodeUITests
//
//  Created by Ken Chung on 1/2/2023.
//

import SwiftUI
import XCTest

@testable import CodeUI

final class CodeUITests: XCTestCase {

    override func setUpWithError() throws {
        // Clean all UserDefaults
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
    }

    //  https://github.com/thebaselab/codeapp/issues/746
    @MainActor
    func testAppendAndFocusNewEditor() throws {
        let app = MainApp()

        let editorOne = EditorInstance(view: AnyView(EmptyView()), title: "editorOne")
        let editorTwo = EditorInstance(view: AnyView(EmptyView()), title: "editorTwo")

        app.appendAndFocusNewEditor(editor: editorOne)
        app.appendAndFocusNewEditor(editor: editorTwo)

        XCTAssertEqual(app.editors.count, 1)
    }

    @MainActor
    func testAppendAndFocusNewEditor_alwaysInNewTab() throws {
        let app = MainApp()

        let editorOne = EditorInstance(view: AnyView(EmptyView()), title: "editorOne")
        let editorTwo = EditorInstance(view: AnyView(EmptyView()), title: "editorTwo")

        app.appendAndFocusNewEditor(editor: editorOne)
        app.appendAndFocusNewEditor(editor: editorTwo, alwaysInNewTab: true)

        XCTAssertEqual(app.editors.count, 2)
    }

    @MainActor
    func testAppendAndFocusNewEditor_alwaysInNewTabWithUserOption() throws {
        UserDefaults.standard.set(true, forKey: "alwaysOpenInNewTab")

        let app = MainApp()

        let editorOne = EditorInstance(view: AnyView(EmptyView()), title: "editorOne")
        let editorTwo = EditorInstance(view: AnyView(EmptyView()), title: "editorTwo")

        app.appendAndFocusNewEditor(editor: editorOne)
        app.appendAndFocusNewEditor(editor: editorTwo)

        XCTAssertEqual(app.editors.count, 2)

        UserDefaults.standard.removeObject(forKey: "alwaysOpenInNewTab")
    }

    func testParseRemoteURL_userExtension() throws {
        let url = URL(string: "git@github.com:thebaselab/codeapp.git")!
        let parsed = LocalGitCredentialsHelper.parseRemoteURL(url: url)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.host, "github.com")
        XCTAssertEqual(parsed!.scheme, "ssh")
        XCTAssertEqual(parsed!.path, "/thebaselab/codeapp.git")
    }

    func testParseRemoteURL_noUserExtension() throws {
        let url = URL(string: "git@github.com:/codeapp.git")!
        let parsed = LocalGitCredentialsHelper.parseRemoteURL(url: url)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.host, "github.com")
        XCTAssertEqual(parsed!.scheme, "ssh")
        XCTAssertEqual(parsed!.path, "/codeapp.git")
    }

    func testAgentContextResolveURLRejectsTraversalAndOutsidePaths() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = WorkSpaceStorage(url: root)
        let context = AgentContext(
            workSpaceStorage: storage,
            workspaceRoot: root,
            monacoInstance: nil,
            activeFileURL: nil,
            workspaceIndexer: nil
        )

        let insidePath = root.appendingPathComponent("Sources/file.swift").path
        let resolvedInside = try context.resolveURL(for: insidePath)
        XCTAssertEqual(resolvedInside.standardizedFileURL.path, insidePath)

        XCTAssertThrowsError(try context.resolveURL(for: "../outside.swift")) { error in
            guard let pathError = error as? AgentContext.PathResolutionError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            guard case .pathTraversal = pathError else {
                return XCTFail("Expected pathTraversal, got \(pathError)")
            }
        }

        XCTAssertThrowsError(try context.resolveURL(for: "/tmp/outside.swift")) { error in
            guard let pathError = error as? AgentContext.PathResolutionError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            guard case .outsideWorkspace = pathError else {
                return XCTFail("Expected outsideWorkspace, got \(pathError)")
            }
        }
    }

    @MainActor
    func testCreateFileAliasCreatesFileWithParentDirectories() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = WorkSpaceStorage(url: root)
        let context = AgentContext(
            workSpaceStorage: storage,
            workspaceRoot: root,
            monacoInstance: nil,
            activeFileURL: nil,
            workspaceIndexer: nil
        )

        let result = await ToolRegistry.default.execute(
            name: "create_file",
            arguments: [
                "path": "nested/deep/new.txt",
                "content": "hello",
            ],
            context: context
        )

        XCTAssertFalse(result.isError)
        let outputURL = root.appendingPathComponent("nested/deep/new.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let written = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(written, "hello")
    }

    @MainActor
    func testSearchFilesReturnsRelativePaths() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("Sample.swift")
        try "let token = \"needle-value\"\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let storage = WorkSpaceStorage(url: root)
        let context = AgentContext(
            workSpaceStorage: storage,
            workspaceRoot: root,
            monacoInstance: nil,
            activeFileURL: nil,
            workspaceIndexer: nil
        )

        let result = await ToolRegistry.default.execute(
            name: "search_files",
            arguments: ["pattern": "needle-value"],
            context: context
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Sample.swift:1:"))
        XCTAssertFalse(result.content.contains(root.path + "/Sample.swift"))
    }

    func testToolAccumulatorHandlesMissingIndexAndDelayedName() throws {
        var accumulator = StreamedToolCallAccumulator()
        accumulator.append(
            index: nil,
            id: nil,
            name: nil,
            arguments: "{\"path\":\"foo.txt\","
        )
        accumulator.append(
            index: nil,
            id: nil,
            name: "create_file",
            arguments: "\"content\":\"hello\"}"
        )

        let toolCalls = accumulator.makeToolCalls(parseJSON: parseJSONObject)
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolCalls.first?.name, "create_file")
        XCTAssertEqual(toolCalls.first?.arguments["path"] as? String, "foo.txt")
        XCTAssertEqual(toolCalls.first?.arguments["content"] as? String, "hello")
    }

    func testOpenRouterDefaultModelMigration() throws {
        let suiteName = "CodeUITests.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("deepseek/deepseek-r1", forKey: "codeassistant.model.openRouter")
        defaults.set("deepseek/deepseek-r1", forKey: "codeassistant.lightweight.model.openRouter")

        CodeAssistantSettings.migrateOpenRouterDefaultIfNeeded(defaults: defaults)

        XCTAssertEqual(
            defaults.string(forKey: "codeassistant.model.openRouter"),
            CodeAssistantProvider.openRouter.defaultModel
        )
        XCTAssertEqual(
            defaults.string(forKey: "codeassistant.lightweight.model.openRouter"),
            CodeAssistantProvider.openRouter.defaultLightweightModel
        )

        defaults.set("custom/model", forKey: "codeassistant.model.openRouter")
        CodeAssistantSettings.migrateOpenRouterDefaultIfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "codeassistant.model.openRouter"), "custom/model")
    }

    private func makeTempDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeUITests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func parseJSONObject(_ jsonString: String) -> [String: Any] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return obj
    }
}
