import Combine
import Foundation

@MainActor
final class TTSMixSettings: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    @Published var volume: Double {
        didSet {
            let clamped = Self.clampedVolume(volume)
            if volume != clamped {
                volume = clamped
            } else {
                defaults.set(clamped, forKey: Self.volumeKey)
            }
        }
    }

    @Published var maxSpeechRate: Double {
        didSet {
            let clamped = model.normalizedSpeechRate(maxSpeechRate)
            if maxSpeechRate != clamped {
                maxSpeechRate = clamped
            } else {
                defaults.set(clamped, forKey: Self.maxSpeechRateKey)
            }
        }
    }

    @Published var model: TTSModelID {
        didSet {
            defaults.set(model.rawValue, forKey: Self.modelKey)
            normalizeCapabilities()
        }
    }

    @Published var voiceID: String {
        didSet {
            if !model.voices.contains(where: { $0.id == voiceID }) {
                voiceID = model.defaultVoiceID
            } else {
                defaults.set(voiceID, forKey: Self.voiceKey)
            }
        }
    }

    @Published var expressionPreset: TTSExpressionPreset {
        didSet {
            if !model.supportedExpressions.contains(expressionPreset) {
                expressionPreset = .automatic
            } else {
                defaults.set(expressionPreset.rawValue, forKey: Self.expressionKey)
            }
        }
    }

    @Published var inlineEffectPreset: TTSInlineEffectPreset {
        didSet {
            if !model.supportedInlineEffects.contains(inlineEffectPreset) {
                inlineEffectPreset = .automatic
            } else {
                defaults.set(inlineEffectPreset.rawValue, forKey: Self.inlineEffectKey)
            }
        }
    }

    @Published private(set) var isOpenRouterConfigured: Bool
    @Published private(set) var connectionTestState: OpenRouterConnectionTestState = .idle
    @Published private(set) var credentialRevision = 0
    @Published var runtimeNotice: String?

    private static let enabledKey = "TTSMixSettings.isMixEnabled"
    private static let volumeKey = "TTSMixSettings.volume"
    private static let maxSpeechRateKey = "TTSMixSettings.maxSpeechRate"
    private static let modelKey = "TTSMixSettings.model"
    private static let voiceKey = "TTSMixSettings.voice"
    private static let expressionKey = "TTSMixSettings.expression"
    private static let inlineEffectKey = "TTSMixSettings.inlineEffect"
    private let defaults: UserDefaults
    private let tokenStore: OpenRouterTokenStore
    private let openRouterClient: OpenRouterTTSClient

    init(
        defaults: UserDefaults = .standard,
        tokenStore: OpenRouterTokenStore? = nil,
        openRouterClient: OpenRouterTTSClient? = nil
    ) {
        self.defaults = defaults
        let resolvedTokenStore = tokenStore ?? OpenRouterTokenStore()
        self.tokenStore = resolvedTokenStore
        self.openRouterClient = openRouterClient ?? OpenRouterTTSClient()
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if defaults.object(forKey: Self.volumeKey) == nil {
            volume = 0.5
        } else {
            volume = Self.clampedVolume(defaults.double(forKey: Self.volumeKey))
        }
        if defaults.object(forKey: Self.maxSpeechRateKey) == nil {
            maxSpeechRate = 1.25
        } else {
            maxSpeechRate = Self.clampedPersistedSpeechRate(defaults.double(forKey: Self.maxSpeechRateKey))
        }
        let restoredModel = defaults.string(forKey: Self.modelKey).flatMap(TTSModelID.init(rawValue:)) ?? .edge
        model = restoredModel
        let storedVoice = defaults.string(forKey: Self.voiceKey)
        voiceID = storedVoice.flatMap { candidate in
            restoredModel.voices.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? restoredModel.defaultVoiceID
        let storedExpression = defaults.string(forKey: Self.expressionKey).flatMap(TTSExpressionPreset.init(rawValue:)) ?? .automatic
        expressionPreset = restoredModel.supportedExpressions.contains(storedExpression) ? storedExpression : .automatic
        let storedInlineEffect = defaults.string(forKey: Self.inlineEffectKey).flatMap(TTSInlineEffectPreset.init(rawValue:)) ?? .automatic
        inlineEffectPreset = restoredModel.supportedInlineEffects.contains(storedInlineEffect) ? storedInlineEffect : .automatic
        isOpenRouterConfigured = resolvedTokenStore.isConfigured
        maxSpeechRate = restoredModel.normalizedSpeechRate(maxSpeechRate)
    }

    var provider: TTSProviderID { model.provider }
    var selectedVoice: TTSVoice { model.voices.first(where: { $0.id == voiceID }) ?? model.voices[0] }
    var connectionTestModel: TTSModelID { model.provider == .openRouter ? model : .minimaxTurbo }
    var connectionTestVoice: TTSVoice {
        connectionTestModel.voices.first(where: { $0.id == voiceID }) ?? connectionTestModel.voices[0]
    }

    func synthesisRequest(text: String) -> TTSSynthesisRequest {
        TTSSynthesisRequest(
            model: model,
            voiceID: model.normalizedVoiceID(voiceID),
            text: text,
            speechRate: model.supportsSpeechRate ? maxSpeechRate : 1,
            expression: model.supportedExpressions.contains(expressionPreset) ? expressionPreset : .automatic,
            inlineEffect: model.supportedInlineEffects.contains(inlineEffectPreset) ? inlineEffectPreset : .automatic
        )
    }

    func openRouterToken() -> String? {
        try? tokenStore.load()
    }

    func testOpenRouterConnection(candidateToken: String? = nil) async {
        let normalizedCandidate = candidateToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = normalizedCandidate?.isEmpty == false ? normalizedCandidate : openRouterToken() else {
            connectionTestState = .failure("请先输入 OpenRouter Token")
            return
        }

        connectionTestState = .testing
        let testModel = connectionTestModel
        let voice = connectionTestVoice.id
        let request = TTSSynthesisRequest(
            model: testModel,
            voiceID: voice,
            text: "晚安，做个好梦。",
            speechRate: 1,
            expression: .automatic
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisimi-openrouter-test-\(UUID().uuidString).\(request.cacheFileExtension)")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        do {
            try await openRouterClient.synthesize(request, credential: token, to: outputURL)
            if normalizedCandidate?.isEmpty == false {
                try tokenStore.save(token)
                isOpenRouterConfigured = true
                credentialRevision += 1
            }
            if model == .edge {
                model = .minimaxTurbo
            }
            connectionTestState = .success("连接成功，已验证短中文音频合成")
            runtimeNotice = nil
            credentialRevision += 1
        } catch {
            connectionTestState = .failure(error.localizedDescription)
        }
    }

    func deleteOpenRouterToken() {
        do {
            try tokenStore.delete()
            isOpenRouterConfigured = false
            model = .edge
            connectionTestState = .idle
            runtimeNotice = "OpenRouter Token 已删除，已切换到 Edge TTS"
            credentialRevision += 1
        } catch {
            connectionTestState = .failure(error.localizedDescription)
        }
    }

    private func normalizeCapabilities() {
        if !model.voices.contains(where: { $0.id == voiceID }) {
            voiceID = model.defaultVoiceID
        }
        if !model.supportedExpressions.contains(expressionPreset) {
            expressionPreset = .automatic
        }
        if !model.supportedInlineEffects.contains(inlineEffectPreset) {
            inlineEffectPreset = .automatic
        }
        maxSpeechRate = model.normalizedSpeechRate(maxSpeechRate)
    }

    private static func clampedVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func clampedPersistedSpeechRate(_ value: Double) -> Double {
        min(max(value, 0.5), 2)
    }
}

#if DEBUG
enum TTSMixSettingsSelfCheck {
    static func run() {
        let suite = "TTSMixSettingsSelfCheck-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            assertionFailure("Could not create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = TTSMixSettings(defaults: defaults)
        assert(settings.isEnabled == false)
        assert(settings.volume == 0.5)
        assert(settings.maxSpeechRate == 1.25)
        assert(settings.model == .edge)
        assert(settings.voiceID == TTSModelID.edge.defaultVoiceID)
        assert(settings.expressionPreset == .automatic)
        assert(settings.inlineEffectPreset == .automatic)

        settings.isEnabled = true
        settings.volume = 2
        settings.maxSpeechRate = 0.5
        assert(settings.volume == 1)
        assert(settings.maxSpeechRate == 1)
        settings.maxSpeechRate = 2
        assert(settings.maxSpeechRate == 1.25)
        settings.model = .minimaxHD
        settings.maxSpeechRate = 0.5
        settings.inlineEffectPreset = .breath
        assert(settings.maxSpeechRate == 0.5)
        assert(settings.synthesisRequest(text: "晚安，请休息").inlineEffect == .breath)
        settings.maxSpeechRate = 3
        assert(settings.maxSpeechRate == 2)
        settings.model = .geminiFlashPreview
        settings.expressionPreset = .gentle
        assert(settings.expressionPreset == .automatic)
        assert(settings.inlineEffectPreset == .automatic)
        assert(settings.synthesisRequest(text: "晚安").speechRate == 1)
        assert(settings.synthesisRequest(text: "晚安").voiceID == TTSModelID.geminiFlashPreview.defaultVoiceID)

        let restored = TTSMixSettings(defaults: defaults)
        assert(restored.isEnabled == true)
        assert(restored.volume == 1)
        assert(restored.maxSpeechRate == 1)
        assert(restored.model == .geminiFlashPreview)
        assert(restored.voiceID == TTSModelID.geminiFlashPreview.defaultVoiceID)
    }
}
#endif

enum OpenRouterConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}
