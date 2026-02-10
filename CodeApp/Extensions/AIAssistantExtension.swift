//
//  AIAssistantExtension.swift
//  CodeApp
//
//  Created by Arya Mirsepasi.
//

import SwiftUI

private let AI_ASSISTANT_EXTENSION_ID = "AI_ASSISTANT"

extension Notification.Name {
    static let codeAssistantToggleRequested = Notification.Name("codeassistant.toggleRequested")
    static let quickCommandToggleRequested = Notification.Name("quickcommand.toggleRequested")
}

class AIAssistantExtension: CodeAppExtension {
    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        // AI Assistant panel toggle button
        let toolbarItem = AppToolbarItem(
            extenionID: AI_ASSISTANT_EXTENSION_ID,
            icon: "sparkles",
            onClick: {
                NotificationCenter.default.post(name: .codeAssistantToggleRequested, object: nil)
            },
            shouldDisplay: { _ in true }
        )
        contribution.toolBar.registerItem(item: toolbarItem)

        // Quick Command (Cmd+K) button
        let quickCommandItem = AppToolbarItem(
            extenionID: AI_ASSISTANT_EXTENSION_ID + "_QUICK",
            icon: "bolt.fill",
            onClick: {
                NotificationCenter.default.post(name: .quickCommandToggleRequested, object: nil)
            },
            shouldDisplay: { _ in true }
        )
        contribution.toolBar.registerItem(item: quickCommandItem)
    }
}
