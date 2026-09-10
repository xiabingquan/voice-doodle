import Foundation

/// Which ASR backend is active. Stored in config.json under `asr.provider`
/// (v3); the dashboard and the wizard both render it via ProviderPicker.
nonisolated enum ASRProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Xiaomi MiMo ASR — chat-completions shaped, wav-only (see MiMoClient)
    case mimo
    /// OpenAI-compatible /audio/transcriptions (OpenAI, OpenRouter, Groq…)
    case openaiCompatible = "openai-compatible"
    /// Volcengine Doubao bigmodel ASR — WebSocket one-shot, raw PCM
    case doubao

    var id: String { rawValue }

    /// Human-readable label for pickers. The raw value stays the on-disk key.
    var displayName: String {
        switch self {
        case .openaiCompatible: return "OpenAI Compatible"
        case .mimo: return "MiMo"
        case .doubao: return "Doubao"
        }
    }
}

/// Provider endpoints/models are built-in constants, not user configuration:
/// MiMo/Doubao expose only the API key. OpenAI Compatible is the only
/// editable gateway.
enum ASRBuiltIns {
    static let openaiBaseURL = URL(string: "https://api.openai.com/v1")!
    static let openaiModel = "whisper-1"
    static let mimoBaseURL = URL(string: "https://api.xiaomimimo.com/v1")!
    static let mimoModel = "mimo-v2.5-asr"
    static let doubaoWsURL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")!
    static let doubaoResourceID = "volc.seedasr.sauc.duration"
}

/// Field visibility per provider — wizard pages and shared provider
/// metadata. OpenAI Compatible alone exposes editable gateway/model;
/// MiMo/Doubao are built-in, so the UI shows the API Key only.
struct OnboardingFieldSpec {
    let showsURLField: Bool
    let showsModelField: Bool
    let urlPrompt: String
    let modelPrompt: String

    init(provider: ASRProvider) {
        switch provider {
        case .openaiCompatible:
            showsURLField = true
            showsModelField = true
            urlPrompt = ASRBuiltIns.openaiBaseURL.absoluteString
            modelPrompt = ASRBuiltIns.openaiModel
        case .mimo:
            showsURLField = false
            showsModelField = false
            urlPrompt = ASRBuiltIns.mimoBaseURL.absoluteString
            modelPrompt = ASRBuiltIns.mimoModel
        case .doubao:
            showsURLField = false
            showsModelField = false
            urlPrompt = ASRBuiltIns.doubaoWsURL.absoluteString
            modelPrompt = ASRBuiltIns.doubaoResourceID
        }
    }
}

nonisolated struct TranscriptionConfig: Codable, Equatable, Sendable {
    var baseURL: URL
    var apiKey: String
    var model: String
    var prompt: String
    var extraHeaders: [HTTPHeader]
    var requestTimeout: TimeInterval
    var maxRecordDuration: TimeInterval
    var provider: ASRProvider
    /// ASR language hint (MiMo asr_options.language; OpenAI path sends zh fixed).
    var language: String
    /// Doubao text-post parameters: config.json-only, no UI surface. All
    /// three are written explicitly so intent is visible and hand-editable.
    var doubaoEnablePunc: Bool
    var doubaoEnableITN: Bool
    var doubaoEnableDDC: Bool
    /// Doubao request-level hotword direct-pass; other providers ignore it.
    var hotwords: [String]

    init(
        baseURL: URL = ASRBuiltIns.openaiBaseURL,
        apiKey: String = "",
        model: String = ASRBuiltIns.openaiModel,
        prompt: String = "",
        extraHeaders: [HTTPHeader] = [],
        requestTimeout: TimeInterval = 60,
        maxRecordDuration: TimeInterval = Constants.Timing.defaultMaxRecording,
        provider: ASRProvider = .openaiCompatible,
        language: String = "zh",
        doubaoEnablePunc: Bool = true,
        doubaoEnableITN: Bool = true,
        doubaoEnableDDC: Bool = true,
        hotwords: [String] = []
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.extraHeaders = extraHeaders
        self.requestTimeout = requestTimeout
        self.maxRecordDuration = maxRecordDuration
        self.provider = provider
        self.language = language
        self.doubaoEnablePunc = doubaoEnablePunc
        self.doubaoEnableITN = doubaoEnableITN
        self.doubaoEnableDDC = doubaoEnableDDC
        self.hotwords = hotwords
    }

    var isConfigured: Bool {
        !apiKey.isEmpty && !model.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case baseURL, apiKey, model, prompt, extraHeaders, requestTimeout, maxRecordDuration, provider, language
        case doubaoEnablePunc, doubaoEnableITN, doubaoEnableDDC, hotwords
    }

    /// Lenient decode: missing fields use struct defaults (v3 schema family).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(URL.self, forKey: .baseURL) ?? ASRBuiltIns.openaiBaseURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ASRBuiltIns.openaiModel
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        extraHeaders = try c.decodeIfPresent([HTTPHeader].self, forKey: .extraHeaders) ?? []
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 60
        maxRecordDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxRecordDuration)
            ?? Constants.Timing.defaultMaxRecording
        provider = try c.decodeIfPresent(ASRProvider.self, forKey: .provider) ?? .openaiCompatible
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        doubaoEnablePunc = try c.decodeIfPresent(Bool.self, forKey: .doubaoEnablePunc) ?? true
        doubaoEnableITN = try c.decodeIfPresent(Bool.self, forKey: .doubaoEnableITN) ?? true
        doubaoEnableDDC = try c.decodeIfPresent(Bool.self, forKey: .doubaoEnableDDC) ?? true
        hotwords = try c.decodeIfPresent([String].self, forKey: .hotwords) ?? []
    }

    /// Strips trailing slashes on save; request paths join via appendingPathComponent.
    var normalized: TranscriptionConfig {
        var copy = self
        if let url = URL(vdBase: baseURL.absoluteString) { copy.baseURL = url }
        return copy
    }
}
