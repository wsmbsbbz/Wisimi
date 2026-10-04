import AudioToolbox
import CryptoKit
import Foundation

enum TTSProviderID: String, CaseIterable, Identifiable {
    case edge
    case openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .edge: "Edge TTS"
        case .openRouter: "OpenRouter"
        }
    }
}

struct TTSVoice: Identifiable, Hashable {
    let id: String
    let displayName: String
}

struct TTSModelCapabilities {
    let voices: [TTSVoice]
    let expressions: [TTSExpressionPreset]
    let inlineEffects: [TTSInlineEffectPreset]
    let speechRateRange: ClosedRange<Double>?
    let audioFormats: Set<TTSAudioFormat>
    let preferredAudioFormat: TTSAudioFormat

    var supportsVoiceSelection: Bool { voices.count > 1 }
    var supportsExpressionSelection: Bool { expressions.count > 1 }
    var supportsInlineEffectSelection: Bool { inlineEffects.count > 1 }
    var supportsSpeechRate: Bool { speechRateRange != nil }
}

enum TTSExpressionPreset: String, CaseIterable, Identifiable {
    case automatic
    case gentle
    case whisper
    case lively
    case dramatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "自动"
        case .gentle: "温柔"
        case .whisper: "耳语"
        case .lively: "活泼"
        case .dramatic: "剧情化"
        }
    }
}

enum TTSInlineEffectPreset: String, CaseIterable, Identifiable {
    case automatic
    case shortPause
    case longPause
    case breath
    case sigh
    case inhale
    case exhale
    case humming
    case lipSmacking

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: "无"
        case .shortPause: "短停顿（0.5 秒）"
        case .longPause: "长停顿（1 秒）"
        case .breath: "呼吸"
        case .sigh: "叹息"
        case .inhale: "吸气"
        case .exhale: "呼气"
        case .humming: "轻声哼唱"
        case .lipSmacking: "唇音"
        }
    }

    private var minimaxMarker: String? {
        switch self {
        case .automatic: nil
        case .shortPause: "<#0.5#>"
        case .longPause: "<#1#>"
        case .breath: "(breath)"
        case .sigh: "(sighs)"
        case .inhale: "(inhale)"
        case .exhale: "(exhale)"
        case .humming: "(humming)"
        case .lipSmacking: "(lip-smacking)"
        }
    }

    func applyingToMiniMaxText(_ text: String) -> String {
        guard let marker = minimaxMarker, text.count > 1 else { return text }
        let punctuation = CharacterSet(charactersIn: "，。！？；：,.!?;:")
        let interiorIndices = text.indices.dropFirst().dropLast()
        let insertionIndex = interiorIndices.first { index in
            text[index].unicodeScalars.allSatisfy(punctuation.contains)
        }.map(text.index(after:)) ?? text.index(text.startIndex, offsetBy: text.count / 2)
        return String(text[..<insertionIndex]) + marker + String(text[insertionIndex...])
    }
}

enum TTSModelID: String, CaseIterable, Identifiable {
    case edge = "edge/zh-CN-XiaoxiaoNeural"
    case minimaxTurbo = "minimax/speech-2.8-turbo"
    case minimaxHD = "minimax/speech-2.8-hd"
    case geminiFlashPreview = "google/gemini-3.1-flash-tts-preview"

    var id: String { rawValue }
    var provider: TTSProviderID { self == .edge ? .edge : .openRouter }

    var displayName: String {
        switch self {
        case .edge: "Edge 中文晓晓（免费兜底）"
        case .minimaxTurbo: "MiniMax Speech 2.8 Turbo"
        case .minimaxHD: "MiniMax Speech 2.8 HD"
        case .geminiFlashPreview: "Gemini 3.1 Flash TTS（实验性）"
        }
    }

    var capabilities: TTSModelCapabilities {
        switch self {
        case .edge:
            TTSModelCapabilities(
                voices: [TTSVoice(id: "zh-CN-XiaoxiaoNeural", displayName: "晓晓")],
                expressions: [.automatic],
                inlineEffects: [.automatic],
                speechRateRange: 1...1.25,
                audioFormats: [.mp3],
                preferredAudioFormat: .mp3
            )
        case .minimaxTurbo, .minimaxHD:
            TTSModelCapabilities(
                voices: [
                    TTSVoice(id: "female-shaonv", displayName: "少女声"),
                    TTSVoice(id: "Chinese (Mandarin)_Soft_Girl", displayName: "轻柔女声"),
                    TTSVoice(id: "Chinese (Mandarin)_BashfulGirl", displayName: "害羞女声"),
                    TTSVoice(id: "Chinese (Mandarin)_Warm_Girl", displayName: "温暖女声"),
                    TTSVoice(id: "Chinese (Mandarin)_Laid_BackGirl", displayName: "慵懒女声"),
                    TTSVoice(id: "English_Whispering_girl", displayName: "耳语女声（实验性）")
                ],
                expressions: [.automatic],
                inlineEffects: TTSInlineEffectPreset.allCases,
                speechRateRange: 0.5...2,
                audioFormats: [.mp3],
                preferredAudioFormat: .mp3
            )
        case .geminiFlashPreview:
            TTSModelCapabilities(
                voices: [
                    TTSVoice(id: "Kore", displayName: "Kore（沉稳）"),
                    TTSVoice(id: "Aoede", displayName: "Aoede（轻柔）"),
                    TTSVoice(id: "Leda", displayName: "Leda（明亮）"),
                    TTSVoice(id: "Zephyr", displayName: "Zephyr（自然）")
                ],
                expressions: [.automatic, .whisper, .lively],
                inlineEffects: [.automatic],
                speechRateRange: nil,
                audioFormats: [.pcm],
                preferredAudioFormat: .pcm
            )
        }
    }

    var voices: [TTSVoice] { capabilities.voices }

    var defaultVoiceID: String { voices[0].id }

    var supportedExpressions: Set<TTSExpressionPreset> { Set(capabilities.expressions) }
    var supportedInlineEffects: Set<TTSInlineEffectPreset> { Set(capabilities.inlineEffects) }

    var supportsSpeechRate: Bool { capabilities.supportsSpeechRate }
    var speechRateRange: ClosedRange<Double>? { capabilities.speechRateRange }

    func normalizedSpeechRate(_ speechRate: Double) -> Double {
        guard let range = speechRateRange else { return 1 }
        return min(max(speechRate, range.lowerBound), range.upperBound)
    }

    func normalizedVoiceID(_ voiceID: String) -> String {
        voices.contains(where: { $0.id == voiceID }) ? voiceID : defaultVoiceID
    }

    var adapterMappingVersion: Int {
        switch self {
        case .edge: 1
        case .minimaxTurbo, .minimaxHD: 2
        case .geminiFlashPreview: 2
        }
    }
}

enum TTSAudioFormat: String {
    case mp3
    case pcm
}

struct TTSSynthesisConfiguration: Equatable {
    var model: TTSModelID
    var voiceID: String
    var speechRate: Double
    var expression: TTSExpressionPreset
    var inlineEffect: TTSInlineEffectPreset

    var normalized: Self {
        Self(model: model, voiceID: model.normalizedVoiceID(voiceID),
             speechRate: model.normalizedSpeechRate(speechRate),
             expression: model.supportedExpressions.contains(expression) ? expression : .automatic,
             inlineEffect: model.supportedInlineEffects.contains(inlineEffect) ? inlineEffect : .automatic)
    }

    func request(text: String) -> TTSSynthesisRequest {
        TTSSynthesisRequest(model: model, voiceID: voiceID, text: text, speechRate: speechRate,
                            expression: expression, inlineEffect: inlineEffect)
    }
}

struct TTSSynthesisRequest: Hashable {
    let model: TTSModelID
    let voiceID: String
    let text: String
    let speechRate: Double
    let expression: TTSExpressionPreset
    var inlineEffect: TTSInlineEffectPreset = .automatic
    var format: TTSAudioFormat = .mp3

    var normalizedExpression: TTSExpressionPreset {
        model.supportedExpressions.contains(expression) ? expression : .automatic
    }

    var normalizedVoiceID: String { model.normalizedVoiceID(voiceID) }
    var normalizedInlineEffect: TTSInlineEffectPreset {
        model.supportedInlineEffects.contains(inlineEffect) ? inlineEffect : .automatic
    }
    var effectiveSpeechRate: Double { model.normalizedSpeechRate(speechRate) }
    var effectiveFormat: TTSAudioFormat {
        model.capabilities.audioFormats.contains(format) ? format : model.capabilities.preferredAudioFormat
    }
    var cacheFileExtension: String { effectiveFormat == .pcm ? "wav" : "mp3" }

    var cacheURL: URL {
        TTSCache.url(for: self)
    }
}

enum TTSCache {
    private static let schemaVersion = 4

    static func fingerprint(for request: TTSSynthesisRequest) -> String {
        let components = [
            "schema:\(schemaVersion)",
            "provider:\(request.model.provider.rawValue)",
            "model:\(request.model.rawValue)",
            "mapping:\(request.model.adapterMappingVersion)",
            "voice:\(request.normalizedVoiceID)",
            "text:\(request.text)",
            "rate:\(String(format: "%.2f", request.effectiveSpeechRate))",
            "expression:\(request.normalizedExpression.rawValue)",
            "inline-effect:\(request.normalizedInlineEffect.rawValue)",
            "transport-format:\(request.effectiveFormat.rawValue)",
            "cache-container:\(request.cacheFileExtension)"
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(components.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func url(for request: TTSSynthesisRequest, directory: URL? = nil) -> URL {
        (directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("wisimi-tts-v2", isDirectory: true))
            .appendingPathComponent("\(fingerprint(for: request)).\(request.cacheFileExtension)")
    }

    static func containsValidAudio(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            return false
        }

        var audioFile: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        if let audioFile {
            AudioFileClose(audioFile)
        }
        return status == noErr
    }

    static func removeIfInvalid(at url: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path), !containsValidAudio(at: url) else { return }
        try? manager.removeItem(at: url)
    }
}

@MainActor
protocol TTSProviderSynthesizing {
    func synthesize(_ request: TTSSynthesisRequest, credential: String?, to outputURL: URL) async throws
}

enum TTSSynthesisError: LocalizedError, Equatable {
    case missingCredential
    case invalidCredential
    case insufficientCredit
    case rateLimited
    case upstream(statusCode: Int)
    case unsupportedConfiguration
    case modelUnavailable
    case invalidVoice
    case unsupportedAudioFormat
    case invalidInput
    case invalidResponse
    case emptyAudio
    case timeout
    case transport

    var isTransient: Bool {
        switch self {
        case .rateLimited, .upstream, .timeout, .transport: true
        default: false
        }
    }

    var disablesOpenRouterSession: Bool {
        self == .invalidCredential || self == .insufficientCredit
    }

    var errorDescription: String? {
        switch self {
        case .missingCredential: "尚未配置 OpenRouter Token，本次已使用 Edge TTS"
        case .invalidCredential: "OpenRouter Token 无效，请替换后重试"
        case .insufficientCredit: "OpenRouter 余额不足，本次已使用 Edge TTS"
        case .rateLimited: "OpenRouter 请求过于频繁，本次已使用 Edge TTS"
        case .upstream: "OpenRouter 上游模型暂时不可用，本次已使用 Edge TTS"
        case .unsupportedConfiguration: "客户端阻止了当前模型不支持的 TTS 配置"
        case .modelUnavailable: "OpenRouter 当前无法使用所选模型"
        case .invalidVoice: "OpenRouter 拒绝了当前音色，请重新选择音色"
        case .unsupportedAudioFormat: "所选模型暂不支持当前音频格式"
        case .invalidInput: "OpenRouter 拒绝了当前合成文本"
        case .invalidResponse: "OpenRouter 返回了无法识别的响应"
        case .emptyAudio: "TTS 服务未返回有效音频"
        case .timeout: "TTS 请求超时"
        case .transport: "TTS 网络请求失败"
        }
    }
}

struct TTSFallbackNotice: Equatable {
    let message: String
}

struct OpenRouterPlaybackSession {
    private(set) var consecutiveTransientFailures = 0
    private(set) var isCircuitOpen = false

    mutating func recordSuccess() {
        consecutiveTransientFailures = 0
    }

    mutating func recordFailure(_ error: TTSSynthesisError) {
        if error.disablesOpenRouterSession {
            isCircuitOpen = true
        } else if error.isTransient {
            consecutiveTransientFailures += 1
            if consecutiveTransientFailures >= 3 {
                isCircuitOpen = true
            }
        }
    }

    mutating func reset() {
        consecutiveTransientFailures = 0
        isCircuitOpen = false
    }
}

enum OpenRouterRetryPolicy {
    static let maximumAttempts = 2
}

#if DEBUG
enum TTSModelsSelfCheck {
    static func run() {
        assert(TTSModelID.allCases.count == 4)
        assert(TTSModelID.minimaxTurbo.provider == .openRouter)
        assert(TTSModelID.geminiFlashPreview.displayName.contains("实验性"))
        assert(!TTSModelID.minimaxTurbo.supportedExpressions.contains(.whisper))
        assert(TTSModelID.minimaxTurbo.speechRateRange == (0.5...2))
        assert(TTSModelID.minimaxHD.speechRateRange == (0.5...2))
        assert(!TTSModelID.geminiFlashPreview.supportsSpeechRate)
        assert(TTSModelID.geminiFlashPreview.capabilities.preferredAudioFormat == .pcm)
        assert(TTSModelID.edge.capabilities.supportsVoiceSelection == false)
        assert(TTSModelID.minimaxTurbo.capabilities.supportsVoiceSelection)
        assert(TTSModelID.minimaxTurbo.capabilities.supportsExpressionSelection == false)
        assert(TTSModelID.minimaxTurbo.capabilities.supportsInlineEffectSelection)
        assert(TTSModelID.minimaxTurbo.voices.count == 6)
        assert(TTSModelID.minimaxTurbo.voices.allSatisfy { !$0.id.lowercased().hasPrefix("male-") })
        assert(!TTSModelID.minimaxTurbo.voices.contains { $0.id == "female-yujie" })
        assert(TTSModelID.minimaxTurbo.supportedInlineEffects.contains(.lipSmacking))
        assert(TTSModelID.geminiFlashPreview.capabilities.supportsExpressionSelection)

        let base = TTSSynthesisRequest(model: .minimaxTurbo, voiceID: "female-shaonv", text: "你好", speechRate: 1, expression: .automatic)
        let gemini = TTSSynthesisRequest(model: .geminiFlashPreview, voiceID: "Kore", text: "你好", speechRate: 1, expression: .automatic)
        assert(base.effectiveFormat == .mp3)
        assert(base.cacheURL.pathExtension == "mp3")
        assert(gemini.effectiveFormat == .pcm)
        assert(gemini.cacheURL.pathExtension == "wav")
        assert(TTSCache.fingerprint(for: base) == TTSCache.fingerprint(for: base))
        assert(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: .minimaxHD, voiceID: base.voiceID, text: base.text, speechRate: base.speechRate, expression: base.expression)))
        assert(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: base.model, voiceID: "Chinese (Mandarin)_Soft_Girl", text: base.text, speechRate: base.speechRate, expression: base.expression)))
        assert(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: base.model, voiceID: base.voiceID, text: base.text, speechRate: 1.2, expression: base.expression)))
        assert(TTSCache.fingerprint(for: base) != TTSCache.fingerprint(for: TTSSynthesisRequest(model: base.model, voiceID: base.voiceID, text: base.text, speechRate: base.speechRate, expression: base.expression, inlineEffect: .breath)))

        let invalidAudio = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-audio-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: invalidAudio) }
        try? Data("not audio".utf8).write(to: invalidAudio)
        assert(!TTSCache.containsValidAudio(at: invalidAudio))
        TTSCache.removeIfInvalid(at: invalidAudio)
        assert(!FileManager.default.fileExists(atPath: invalidAudio.path))

        var session = OpenRouterPlaybackSession()
        session.recordFailure(.rateLimited)
        session.recordFailure(.timeout)
        assert(!session.isCircuitOpen)
        session.recordFailure(.upstream(statusCode: 503))
        assert(session.isCircuitOpen)
        session.reset()
        assert(!session.isCircuitOpen && session.consecutiveTransientFailures == 0)
        session.recordFailure(.invalidCredential)
        assert(session.isCircuitOpen)
        assert(OpenRouterRetryPolicy.maximumAttempts == 2)
    }
}
#endif
