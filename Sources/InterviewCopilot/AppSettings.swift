import SwiftUI
import Foundation

/// Persisted user settings (provider choice, API keys, model). Stored in
/// `UserDefaults`. Keys are per-provider so you can keep both configured and
/// just flip the provider.
@MainActor
final class AppSettings: ObservableObject {
    enum ProviderKind: String, CaseIterable, Identifiable {
        case openai, anthropic, gemini, deepseek, grok, ollama
        var id: String { rawValue }
        var label: String {
            switch self {
            case .openai: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .gemini: return "Gemini"
            case .deepseek: return "DeepSeek"
            case .grok: return "Grok"
            case .ollama: return "Ollama"
            }
        }
        var defaultModel: String {
            switch self {
            case .openai: return "gpt-4o-mini"
            case .anthropic: return "claude-sonnet-4-6"
            case .gemini: return "gemini-2.0-flash"
            case .deepseek: return "deepseek-v4-flash"
            case .grok: return "grok-4"
            case .ollama: return "llama3.2"
            }
        }
        /// Ollama runs locally and needs no API key; everything else does.
        var requiresKey: Bool { self != .ollama }
    }

    /// Which AI reads Screen / Scroll captures. DeepSeek can't read images, so
    /// Auto uses the answer provider, or GPT when that's DeepSeek.
    enum ScreenProvider: String, CaseIterable, Identifiable {
        case auto, openai, anthropic, gemini
        var id: String { rawValue }
        var kind: ProviderKind? {
            switch self {
            case .auto: return nil
            case .openai: return .openai
            case .anthropic: return .anthropic
            case .gemini: return .gemini
            }
        }
    }

    enum TranscriptionEngine: String, CaseIterable, Identifiable {
        case apple, deepgram
        var id: String { rawValue }
        var label: String {
            switch self {
            case .apple: return "Apple (on-device)"
            case .deepgram: return "Deepgram (accurate)"
            }
        }
    }

    private let d = UserDefaults.standard

    @Published var provider: ProviderKind {
        didSet { d.set(provider.rawValue, forKey: "provider") }
    }
    @Published var openAIKey: String {
        didSet { d.set(openAIKey, forKey: "openAIKey") }
    }
    @Published var anthropicKey: String {
        didSet { d.set(anthropicKey, forKey: "anthropicKey") }
    }
    @Published var geminiKey: String {
        didSet { d.set(geminiKey, forKey: "geminiKey") }
    }
    @Published var openAIModel: String {
        didSet { d.set(openAIModel, forKey: "openAIModel") }
    }
    @Published var anthropicModel: String {
        didSet { d.set(anthropicModel, forKey: "anthropicModel") }
    }
    @Published var geminiModel: String {
        didSet { d.set(geminiModel, forKey: "geminiModel") }
    }
    @Published var deepseekKey: String {
        didSet { d.set(deepseekKey, forKey: "deepseekKey") }
    }
    @Published var deepseekModel: String {
        didSet { d.set(deepseekModel, forKey: "deepseekModel") }
    }
    @Published var grokKey: String {
        didSet { d.set(grokKey, forKey: "grokKey") }
    }
    @Published var grokModel: String {
        didSet { d.set(grokModel, forKey: "grokModel") }
    }
    @Published var ollamaModel: String {
        didSet { d.set(ollamaModel, forKey: "ollamaModel") }
    }
    /// Base URL of the local (or remote) Ollama server.
    @Published var ollamaHost: String {
        didSet { d.set(ollamaHost, forKey: "ollamaHost") }
    }
    @Published var transcription: TranscriptionEngine {
        didSet { d.set(transcription.rawValue, forKey: "transcription") }
    }
    @Published var deepgramKey: String {
        didSet { d.set(deepgramKey, forKey: "deepgramKey") }
    }
    /// Transcribe your own mic (green "Me" lines) for follow-up context.
    /// Off = interviewer-only, which halves transcription cost.
    @Published var screenProvider: ScreenProvider {
        didSet { d.set(screenProvider.rawValue, forKey: "screenProvider") }
    }
    @Published var transcribeMic: Bool {
        didSet { d.set(transcribeMic, forKey: "transcribeMic") }
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        let geminiEnv = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"]

        // Default provider: prefer whatever the user seems to have a key for,
        // otherwise OpenAI.
        let storedProvider = d.string(forKey: "provider")
            .flatMap(ProviderKind.init(rawValue:))
        provider = storedProvider
            ?? (env["OPENAI_API_KEY"] != nil ? .openai
                : env["ANTHROPIC_API_KEY"] != nil ? .anthropic
                : geminiEnv != nil ? .gemini : .openai)

        // Keys: stored value wins, else fall back to the env var.
        openAIKey = d.string(forKey: "openAIKey") ?? env["OPENAI_API_KEY"] ?? ""
        anthropicKey = d.string(forKey: "anthropicKey")
            ?? env["ANTHROPIC_API_KEY"] ?? ""
        geminiKey = d.string(forKey: "geminiKey") ?? geminiEnv ?? ""
        deepseekKey = d.string(forKey: "deepseekKey")
            ?? env["DEEPSEEK_API_KEY"] ?? ""

        openAIModel = d.string(forKey: "openAIModel") ?? ProviderKind.openai.defaultModel
        anthropicModel = d.string(forKey: "anthropicModel")
            ?? ProviderKind.anthropic.defaultModel
        geminiModel = d.string(forKey: "geminiModel")
            ?? ProviderKind.gemini.defaultModel
        deepseekModel = d.string(forKey: "deepseekModel")
            ?? ProviderKind.deepseek.defaultModel
        grokKey = d.string(forKey: "grokKey")
            ?? env["XAI_API_KEY"] ?? env["GROK_API_KEY"] ?? ""
        grokModel = d.string(forKey: "grokModel") ?? ProviderKind.grok.defaultModel
        ollamaModel = d.string(forKey: "ollamaModel") ?? ProviderKind.ollama.defaultModel
        ollamaHost = d.string(forKey: "ollamaHost")
            ?? env["OLLAMA_HOST"] ?? "http://localhost:11434"

        let dgKey = d.string(forKey: "deepgramKey") ?? env["DEEPGRAM_API_KEY"] ?? ""
        deepgramKey = dgKey
        // Default to Deepgram when a key is present (it's the reliable path),
        // otherwise Apple.
        transcription = d.string(forKey: "transcription")
            .flatMap(TranscriptionEngine.init(rawValue:))
            ?? (dgKey.isEmpty ? .apple : .deepgram)
        transcribeMic = (d.object(forKey: "transcribeMic") as? Bool) ?? true
        screenProvider = d.string(forKey: "screenProvider")
            .flatMap(ScreenProvider.init(rawValue:)) ?? .auto
    }

    var trimmedDeepgramKey: String {
        deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var currentKey: String { key(for: provider) }
    var currentModel: String { model(for: provider) }

    func key(for kind: ProviderKind) -> String {
        let raw: String
        switch kind {
        case .openai: raw = openAIKey
        case .anthropic: raw = anthropicKey
        case .gemini: raw = geminiKey
        case .deepseek: raw = deepseekKey
        case .grok: raw = grokKey
        case .ollama: raw = ""   // local server, no key
        }
        // Pasted keys often carry a trailing newline/space; a newline in an HTTP
        // header value makes Foundation drop the header entirely → 401.
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func model(for kind: ProviderKind) -> String {
        let m: String
        switch kind {
        case .openai: m = openAIModel
        case .anthropic: m = anthropicModel
        case .gemini: m = geminiModel
        case .deepseek: m = deepseekModel
        case .grok: m = grokModel
        case .ollama: m = ollamaModel
        }
        let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.defaultModel : trimmed
    }

    /// Ollama's OpenAI-compatible chat endpoint, derived from `ollamaHost`.
    var ollamaChatURL: URL {
        let host = ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let base = host.isEmpty ? "http://localhost:11434" : host
        return URL(string: "\(base)/v1/chat/completions")
            ?? URL(string: "http://localhost:11434/v1/chat/completions")!
    }
}

extension AppSettings.ProviderKind {
    /// Compact name for the overlay's pickers.
    var shortLabel: String {
        switch self {
        case .openai: return "GPT"
        case .anthropic: return "Claude"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .grok: return "Grok"
        case .ollama: return "Ollama"
        }
    }
}

// MARK: - Settings window UI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title3.bold())

            Picker("AI provider", selection: $settings.provider) {
                ForEach(AppSettings.ProviderKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)

            if settings.provider == .openai {
                field("OpenAI API key", systemImage: "key.fill") {
                    SecureField("sk-…", text: $settings.openAIKey)
                }
                field("Model", systemImage: "cpu") {
                    TextField(AppSettings.ProviderKind.openai.defaultModel,
                              text: $settings.openAIModel)
                }
                Text("Uses the Chat Completions API. Try gpt-4o-mini (fast) or gpt-4o.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.provider == .anthropic {
                field("Anthropic API key", systemImage: "key.fill") {
                    SecureField("sk-ant-…", text: $settings.anthropicKey)
                }
                field("Model", systemImage: "cpu") {
                    TextField(AppSettings.ProviderKind.anthropic.defaultModel,
                              text: $settings.anthropicModel)
                }
                Text("Try claude-sonnet-4-6 (fast) or claude-opus-4-8 (best).")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.provider == .gemini {
                field("Gemini API key", systemImage: "key.fill") {
                    SecureField("AIza…", text: $settings.geminiKey)
                }
                field("Model", systemImage: "cpu") {
                    TextField(AppSettings.ProviderKind.gemini.defaultModel,
                              text: $settings.geminiModel)
                }
                Text("Free key at aistudio.google.com/apikey. " +
                     "Try gemini-2.0-flash or gemini-2.5-flash.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.provider == .deepseek {
                field("DeepSeek API key", systemImage: "key.fill") {
                    SecureField("sk-…", text: $settings.deepseekKey)
                }
                field("Model", systemImage: "cpu") {
                    TextField(AppSettings.ProviderKind.deepseek.defaultModel,
                              text: $settings.deepseekModel)
                }
                Text("Very cheap & fast. Key from platform.deepseek.com. " +
                     "Try deepseek-v4-flash (default) or deepseek-reasoner.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if settings.provider == .grok {
                field("xAI API key", systemImage: "key.fill") {
                    SecureField("xai-…", text: $settings.grokKey)
                }
                field("Model", systemImage: "cpu") {
                    TextField(AppSettings.ProviderKind.grok.defaultModel,
                              text: $settings.grokModel)
                }
                Text("OpenAI-compatible. Key from console.x.ai. " +
                     "Try grok-4 (multimodal, reads screens) or grok-3.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                field("Ollama host", systemImage: "desktopcomputer") {
                    TextField("http://localhost:11434", text: $settings.ollamaHost)
                }
                field("Model", systemImage: "cpu") {
                    TextField(AppSettings.ProviderKind.ollama.defaultModel,
                              text: $settings.ollamaModel)
                }
                Text("Runs locally — no API key. Install from ollama.com, then " +
                     "`ollama pull llama3.2`. For Screen/Scroll, pull a vision " +
                     "model (e.g. llama3.2-vision or llava) and set it here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            Text("Transcription").font(.headline)
            Picker("Engine", selection: $settings.transcription) {
                ForEach(AppSettings.TranscriptionEngine.allCases) { e in
                    Text(e.label).tag(e)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Transcribe my mic too (for follow-up context)",
                   isOn: $settings.transcribeMic)
                .font(.system(size: 12))
                .help("Off = transcribe only the interviewer, halving Deepgram cost.")

            if settings.transcription == .deepgram {
                field("Deepgram API key", systemImage: "waveform") {
                    SecureField("Token…", text: $settings.deepgramKey)
                }
                Text("Realtime, high-accuracy speech-to-text. Key from deepgram.com.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Apple's built-in recognizer. Free & private, but less " +
                     "accurate; needs the language installed for on-device.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, systemImage: String,
                                      @ViewBuilder _ content: () -> Content)
        -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption).foregroundStyle(.secondary)
            content().textFieldStyle(.roundedBorder)
        }
    }
}
