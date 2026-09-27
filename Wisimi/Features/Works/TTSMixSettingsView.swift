import SwiftUI

struct TTSMixSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: TTSMixSettings
    @State private var path: [TTSMixSettingsRoute]

    init(settings: TTSMixSettings) {
        self.settings = settings
        #if DEBUG
        let startsAtCredentials = ProcessInfo.processInfo.environment["WISIMI_DEBUG_SCREEN"] == "openrouter-credentials"
        _path = State(initialValue: startsAtCredentials ? [.openRouterCredentials] : [])
        #else
        _path = State(initialValue: [])
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Toggle("开启混音", isOn: $settings.isEnabled)
                } footer: {
                    Text("开启后会预先生成当前字幕和接下来的五条旁白；付费服务不可用时会回退到 Edge TTS。")
                }

                TTSModelSettingsSection(settings: settings)
                TTSVoiceSettingsSection(settings: settings)
                TTSInlineEffectSettingsSection(settings: settings)
                TTSAudioControlsSection(settings: settings)
                OpenRouterCredentialSummarySection(settings: settings)

                if let runtimeNotice = settings.runtimeNotice {
                    Section("播放状态") {
                        Label(runtimeNotice, systemImage: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("TTS 播放状态：\(runtimeNotice)")
                    }
                }
            }
            .navigationTitle("混音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(for: TTSMixSettingsRoute.self) { route in
                switch route {
                case .openRouterCredentials:
                    OpenRouterCredentialsView(settings: settings)
                }
            }
        }
    }
}

private struct TTSModelSettingsSection: View {
    @ObservedObject var settings: TTSMixSettings

    var body: some View {
        Section {
            Picker("模型", selection: $settings.model) {
                ForEach(TTSModelID.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .accessibilityLabel("TTS 模型")
            .accessibilityValue(settings.model.displayName)
        } header: {
            Text("旁白模型")
        } footer: {
            if settings.model.provider == .openRouter && !settings.isOpenRouterConfigured {
                Text("尚未配置 OpenRouter Token，播放时会使用 Edge TTS。")
            }
            Text(capabilityText)
        }
    }

    private var capabilityText: String {
        switch settings.model {
        case .edge:
            "免费兜底，使用固定晓晓音色并支持基础语速调整。"
        case .minimaxTurbo:
            "生成较快，支持 6 种 ASMR 女音、语速和句内声音效果。"
        case .minimaxHD:
            "优先保证音质，支持 6 种 ASMR 女音、语速和句内声音效果。"
        case .geminiFlashPreview:
            "实验性模型，支持精选音色和有限的表达设置。"
        }
    }
}

private struct TTSVoiceSettingsSection: View {
    @ObservedObject var settings: TTSMixSettings

    var body: some View {
        if settings.model.capabilities.supportsVoiceSelection || settings.model.capabilities.supportsExpressionSelection {
            Section {
                if settings.model.capabilities.supportsVoiceSelection {
                    Picker("音色", selection: $settings.voiceID) {
                        ForEach(settings.model.capabilities.voices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .accessibilityLabel("TTS 音色")
                    .accessibilityValue(settings.selectedVoice.displayName)
                }

                if settings.model.capabilities.supportsExpressionSelection {
                    Picker("表达", selection: $settings.expressionPreset) {
                        ForEach(settings.model.capabilities.expressions) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .accessibilityLabel("表达预设")
                    .accessibilityValue(settings.expressionPreset.displayName)
                }
            } header: {
                Text(settings.model.capabilities.supportsExpressionSelection ? "音色与表达" : "音色")
            } footer: {
                if settings.model.capabilities.supportsExpressionSelection {
                    Text("只显示当前模型已经验证可用的表达选项。")
                }
            }
        }
    }
}

private struct TTSInlineEffectSettingsSection: View {
    @ObservedObject var settings: TTSMixSettings

    var body: some View {
        if settings.model.capabilities.supportsInlineEffectSelection {
            Section {
                Picker("句内效果", selection: $settings.inlineEffectPreset) {
                    ForEach(settings.model.capabilities.inlineEffects) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
                .accessibilityLabel("MiniMax 句内效果")
                .accessibilityValue(settings.inlineEffectPreset.displayName)
            } header: {
                Text("ASMR 表达")
            } footer: {
                Text("效果会插入自然停顿处，不会改变屏幕上显示的字幕。")
            }
        }
    }
}

private struct TTSAudioControlsSection: View {
    @ObservedObject var settings: TTSMixSettings

    var body: some View {
        Section {
            TTSValueSliderRow(
                title: "旁白音量",
                valueText: volumeText,
                value: $settings.volume,
                range: 0...1,
                step: 0.01
            )

            if let speechRateRange = settings.model.speechRateRange {
                TTSValueSliderRow(
                    title: "生成语速",
                    valueText: speechRateText,
                    value: $settings.maxSpeechRate,
                    range: speechRateRange,
                    step: 0.05
                )
            }
        } header: {
            Text("声音")
        } footer: {
            if settings.model == .minimaxTurbo || settings.model == .minimaxHD {
                Text("MiniMax 语速可在 0.5x～2.0x 之间调整。")
            }
        }
    }

    private var volumeText: String {
        "\(Int((settings.volume * 100).rounded()))%"
    }

    private var speechRateText: String {
        "\(String(format: "%.2f", settings.maxSpeechRate))x"
    }
}

private struct TTSValueSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(title, value: valueText)
                .monospacedDigit()

            Slider(value: $value, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
        }
    }
}

private struct OpenRouterCredentialSummarySection: View {
    @ObservedObject var settings: TTSMixSettings

    var body: some View {
        Section {
            NavigationLink(value: TTSMixSettingsRoute.openRouterCredentials) {
                HStack(spacing: 12) {
                    Label("OpenRouter 凭据", systemImage: statusImage)
                    Spacer(minLength: 8)
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
            }
            .accessibilityLabel("OpenRouter 凭据")
            .accessibilityValue(settings.isOpenRouterConfigured ? "已配置" : "未配置")
            .accessibilityHint("打开凭据管理")
        } footer: {
            Text("Token 只保存在本机 Keychain，可随时测试、替换或删除。")
        }
    }

    private var statusText: String {
        settings.isOpenRouterConfigured ? "已保存 ••••••••" : "未配置"
    }

    private var statusImage: String {
        settings.isOpenRouterConfigured ? "checkmark.shield" : "exclamationmark.shield"
    }

    private var statusColor: Color {
        settings.isOpenRouterConfigured ? .green : .secondary
    }
}

private enum TTSMixSettingsRoute: Hashable {
    case openRouterCredentials
}

private struct OpenRouterCredentialsView: View {
    @ObservedObject var settings: TTSMixSettings
    @State private var tokenDraft = ""
    @State private var isPaidTestConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @FocusState private var isTokenFocused: Bool

    var body: some View {
        Form {
            Section("配置状态") {
                LabeledContent("OpenRouter") {
                    Label(statusText, systemImage: statusImage)
                        .foregroundStyle(statusColor)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("OpenRouter 配置状态")
                .accessibilityValue(settings.isOpenRouterConfigured ? "已配置" : "未配置")
            }

            Section {
                SecureField(tokenPlaceholder, text: $tokenDraft)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isTokenFocused)
                    .accessibilityLabel("OpenRouter Token")
                    .accessibilityHint(settings.isOpenRouterConfigured ? "留空会使用已保存的 Token" : "输入具有消费限额的 OpenRouter Token")

                Button(testButtonTitle, action: prepareConnectionTest)
                    .disabled(isConnectionTestDisabled)
                    .accessibilityHint("会合成一句简短中文，可能产生少量 OpenRouter 费用")
            } header: {
                Text(settings.isOpenRouterConfigured ? "测试或替换" : "配置 Token")
            } footer: {
                Text("建议使用独立且设置消费限额的 Key。连接测试会生成一句短中文并产生极少量费用。")
            }

            if settings.connectionTestState != .idle {
                Section("连接测试") {
                    OpenRouterConnectionStatusRow(state: settings.connectionTestState)
                }
            }

            if settings.isOpenRouterConfigured {
                Section {
                    Button("删除 Token", role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                } footer: {
                    Text("删除后会立即切换到免费的 Edge TTS。")
                }
            }
        }
        .navigationTitle("OpenRouter 凭据")
        .navigationBarTitleDisplayMode(.inline)
        .alert("将进行一次付费测试", isPresented: $isPaidTestConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("继续测试", action: runConnectionTest)
        } message: {
            Text("将使用 \(settings.connectionTestModel.displayName) 的 \(settings.connectionTestVoice.displayName)音色合成“晚安，做个好梦。”，并可能扣除少量 credits。")
        }
        .confirmationDialog("删除 OpenRouter Token？", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("删除 Token", role: .destructive, action: deleteToken)
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后付费模型将不可用，旁白会回退到 Edge TTS。")
        }
    }

    private var statusText: String {
        settings.isOpenRouterConfigured ? "已保存 ••••••••" : "未配置"
    }

    private var statusImage: String {
        settings.isOpenRouterConfigured ? "checkmark.shield" : "exclamationmark.shield"
    }

    private var statusColor: Color {
        settings.isOpenRouterConfigured ? .green : .secondary
    }

    private var tokenPlaceholder: String {
        settings.isOpenRouterConfigured ? "输入新 Token 以替换（可留空）" : "输入 OpenRouter Token"
    }

    private var testButtonTitle: String {
        let tokenIsEmpty = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !tokenIsEmpty || !settings.isOpenRouterConfigured {
            return "保存并测试"
        }
        return "测试已保存的 Token"
    }

    private var isConnectionTestDisabled: Bool {
        if case .testing = settings.connectionTestState { return true }
        return tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !settings.isOpenRouterConfigured
    }

    private func prepareConnectionTest() {
        isTokenFocused = false
        isPaidTestConfirmationPresented = true
    }

    private func runConnectionTest() {
        let candidate = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await settings.testOpenRouterConnection(candidateToken: candidate.isEmpty ? nil : candidate)
            if case .success = settings.connectionTestState {
                tokenDraft = ""
            }
        }
    }

    private func deleteToken() {
        settings.deleteOpenRouterToken()
        tokenDraft = ""
    }
}

private struct OpenRouterConnectionStatusRow: View {
    let state: OpenRouterConnectionTestState

    var body: some View {
        switch state {
        case .idle:
            Text("未开始测试")
                .foregroundStyle(.secondary)
        case .testing:
            HStack(spacing: 10) {
                ProgressView()
                Text("正在测试短中文音频合成…")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在测试 OpenRouter 连接")
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("连接成功：\(message)")
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("连接失败：\(message)")
        }
    }
}
