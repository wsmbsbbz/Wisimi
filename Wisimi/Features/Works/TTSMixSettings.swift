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

    @Published private(set) var configuration: TTSSynthesisConfiguration

    var maxSpeechRate: Double {
        get { configuration.speechRate }
        set { update { $0.speechRate = newValue } }
    }
    var model: TTSModelID {
        get { configuration.model }
        set { update { $0.model = newValue } }
    }
    var voiceID: String {
        get { configuration.voiceID }
        set { update { $0.voiceID = newValue } }
    }
    var expressionPreset: TTSExpressionPreset {
        get { configuration.expression }
        set { update { $0.expression = newValue } }
    }
    var inlineEffectPreset: TTSInlineEffectPreset {
        get { configuration.inlineEffect }
        set { update { $0.inlineEffect = newValue } }
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
        let restoredModel = defaults.string(forKey: Self.modelKey).flatMap(TTSModelID.init(rawValue:)) ?? .edge
        configuration = TTSSynthesisConfiguration(
            model: restoredModel,
            voiceID: defaults.string(forKey: Self.voiceKey) ?? restoredModel.defaultVoiceID,
            speechRate: defaults.object(forKey: Self.maxSpeechRateKey) == nil ? 1.25 : defaults.double(forKey: Self.maxSpeechRateKey),
            expression: defaults.string(forKey: Self.expressionKey).flatMap(TTSExpressionPreset.init(rawValue:)) ?? .automatic,
            inlineEffect: defaults.string(forKey: Self.inlineEffectKey).flatMap(TTSInlineEffectPreset.init(rawValue:)) ?? .automatic
        ).normalized
        isOpenRouterConfigured = resolvedTokenStore.isConfigured
    }

    var provider: TTSProviderID { model.provider }
    var selectedVoice: TTSVoice { model.voices.first(where: { $0.id == voiceID }) ?? model.voices[0] }
    var connectionTestModel: TTSModelID { model.provider == .openRouter ? model : .minimaxTurbo }
    var connectionTestVoice: TTSVoice {
        connectionTestModel.voices.first(where: { $0.id == voiceID }) ?? connectionTestModel.voices[0]
    }

    func synthesisRequest(text: String) -> TTSSynthesisRequest {
        configuration.request(text: text)
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

    private func update(_ change: (inout TTSSynthesisConfiguration) -> Void) {
        var candidate = configuration
        change(&candidate)
        candidate = candidate.normalized
        guard candidate != configuration else { return }
        configuration = candidate
        defaults.set(candidate.model.rawValue, forKey: Self.modelKey)
        defaults.set(candidate.voiceID, forKey: Self.voiceKey)
        defaults.set(candidate.speechRate, forKey: Self.maxSpeechRateKey)
        defaults.set(candidate.expression.rawValue, forKey: Self.expressionKey)
        defaults.set(candidate.inlineEffect.rawValue, forKey: Self.inlineEffectKey)
    }

    private static func clampedVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

#if DEBUG
@MainActor
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
