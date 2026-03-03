//
//  CodeAssistantConfiguration.swift
//  CodeApp
//
//  Created by Arya Mirsepasi.
//

import Foundation

enum CodeAssistantProvider: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case openRouter

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        case .openRouter:
            return "OpenRouter"
        }
    }

    var iconName: String {
        switch self {
        case .openAI:
            return "openai"
        case .anthropic:
            return "anthropic"
        case .openRouter:
            return "o.circle"
        }
    }
    
    var isSystemIcon: Bool {
        switch self {
        case .openAI, .anthropic:
            return false
        case .openRouter:
            return true
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI:
            return "gpt-5"
        case .anthropic:
            return "claude-sonnet-4-6"
        case .openRouter:
            return "openai/gpt-4.1-mini"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .openAI:
            return ["gpt-5", "gpt-5-mini", "gpt-4.1"]
        case .anthropic:
            return [
                "claude-sonnet-4-6",
                "claude-haiku-4-5",
                "claude-opus-4-6",
            ]
        case .openRouter:
            return [
                "openai/gpt-4.1-mini",
                "deepseek/deepseek-chat",
                "deepseek/deepseek-r1",
                "google/gemini-2.0-flash-exp:free",
            ]
        }
    }

    var defaultLightweightModel: String {
        switch self {
        case .openAI:
            return "gpt-5-mini"
        case .anthropic:
            return "claude-haiku-4-5"
        case .openRouter:
            return "openai/gpt-4.1-mini"
        }
    }
}

struct LightweightModelSettings: Equatable {
    var provider: CodeAssistantProvider
    var modelOverrides: [CodeAssistantProvider: String]

    func model(for provider: CodeAssistantProvider? = nil) -> String {
        let selected = provider ?? self.provider
        return modelOverrides[selected] ?? selected.defaultLightweightModel
    }
}

enum CodeAssistantSettings {
    private static let openRouterLegacyDefaultModel = "deepseek/deepseek-r1"
    private static let openRouterModelMigrationKey = "codeassistant.model.openrouter.migrated.v1"
    private static let lightweightProviderDefaultsKey = "codeassistant.lightweight.provider"

    private static func keychainKey(for provider: CodeAssistantProvider) -> String {
        switch provider {
        case .openAI:
            return "codeassistant.openai.apiKey"
        case .anthropic:
            return "codeassistant.anthropic.apiKey"
        case .openRouter:
            return "codeassistant.openrouter.apiKey"
        }
    }

    static func apiKey(for provider: CodeAssistantProvider) -> String {
        KeychainAccessor.shared.getObjectString(for: keychainKey(for: provider)) ?? ""
    }

    static func persist(apiKey: String, for provider: CodeAssistantProvider) {
        let key = keychainKey(for: provider)
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = KeychainAccessor.shared.removeObjectForKey(for: key)
        } else {
            KeychainAccessor.shared.storeObject(for: key, value: apiKey)
        }
    }

    static func lightweightModelSettings(defaults: UserDefaults = .standard) -> LightweightModelSettings {
        let provider: CodeAssistantProvider
        if
            let raw = defaults.string(forKey: lightweightProviderDefaultsKey),
            let parsed = CodeAssistantProvider(rawValue: raw)
        {
            provider = parsed
        } else {
            provider = .openAI
        }

        var overrides: [CodeAssistantProvider: String] = [:]
        for candidate in CodeAssistantProvider.allCases {
            let key = lightweightModelDefaultsKey(for: candidate)
            let stored = defaults.string(forKey: key)
            overrides[candidate] = stored?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? stored
                : candidate.defaultLightweightModel
        }

        return LightweightModelSettings(provider: provider, modelOverrides: overrides)
    }

    static func persistLightweightProvider(
        _ provider: CodeAssistantProvider,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(provider.rawValue, forKey: lightweightProviderDefaultsKey)
    }

    static func persistLightweightModel(
        _ model: String,
        for provider: CodeAssistantProvider,
        defaults: UserDefaults = .standard
    ) {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalValue = normalized.isEmpty ? provider.defaultLightweightModel : normalized
        defaults.set(finalValue, forKey: lightweightModelDefaultsKey(for: provider))
    }

    static func migrateOpenRouterDefaultIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: openRouterModelMigrationKey) else { return }

        let openRouterModelKey = codeAssistantModelDefaultsKey(for: .openRouter)
        let openRouterLightweightKey = lightweightModelDefaultsKey(for: .openRouter)

        if defaults.string(forKey: openRouterModelKey) == openRouterLegacyDefaultModel {
            defaults.set(CodeAssistantProvider.openRouter.defaultModel, forKey: openRouterModelKey)
        }

        if defaults.string(forKey: openRouterLightweightKey) == openRouterLegacyDefaultModel {
            defaults.set(
                CodeAssistantProvider.openRouter.defaultLightweightModel,
                forKey: openRouterLightweightKey
            )
        }

        defaults.set(true, forKey: openRouterModelMigrationKey)
    }

    private static func codeAssistantModelDefaultsKey(for provider: CodeAssistantProvider) -> String {
        "codeassistant.model.\(provider.rawValue)"
    }

    private static func lightweightModelDefaultsKey(for provider: CodeAssistantProvider) -> String {
        "codeassistant.lightweight.model.\(provider.rawValue)"
    }
}
