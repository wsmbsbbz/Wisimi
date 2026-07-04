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
            let clamped = Self.clampedSpeechRate(maxSpeechRate)
            if maxSpeechRate != clamped {
                maxSpeechRate = clamped
            } else {
                defaults.set(clamped, forKey: Self.maxSpeechRateKey)
            }
        }
    }

    private static let enabledKey = "TTSMixSettings.isMixEnabled"
    private static let volumeKey = "TTSMixSettings.volume"
    private static let maxSpeechRateKey = "TTSMixSettings.maxSpeechRate"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if defaults.object(forKey: Self.volumeKey) == nil {
            volume = 0.5
        } else {
            volume = Self.clampedVolume(defaults.double(forKey: Self.volumeKey))
        }
        if defaults.object(forKey: Self.maxSpeechRateKey) == nil {
            maxSpeechRate = 1.25
        } else {
            maxSpeechRate = Self.clampedSpeechRate(defaults.double(forKey: Self.maxSpeechRateKey))
        }
    }

    private static func clampedVolume(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func clampedSpeechRate(_ value: Double) -> Double {
        min(max(value, 1), 1.25)
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

        settings.isEnabled = true
        settings.volume = 2
        settings.maxSpeechRate = 0.5
        assert(settings.volume == 1)
        assert(settings.maxSpeechRate == 1)
        settings.maxSpeechRate = 2
        assert(settings.maxSpeechRate == 1.25)

        let restored = TTSMixSettings(defaults: defaults)
        assert(restored.isEnabled == true)
        assert(restored.volume == 1)
        assert(restored.maxSpeechRate == 1.25)
    }
}
#endif
