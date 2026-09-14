import Foundation

nonisolated struct GeneralConfig: Codable, Equatable, Sendable {
    var maxRecordDuration: TimeInterval = Constants.Timing.defaultMaxRecording

    /// Lenient decode: missing fields use the struct defaults (v3 schema).
    init(maxRecordDuration: TimeInterval = Constants.Timing.defaultMaxRecording) {
        self.maxRecordDuration = maxRecordDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxRecordDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .maxRecordDuration)
            ?? Constants.Timing.defaultMaxRecording
    }
}

/// OpenAI-compatible /audio/transcriptions (OpenAI, OpenRouter, Groq…)
nonisolated struct OpenAICompatibleConfig: Codable, Equatable, Sendable {
    var baseURL = ASRBuiltIns.openaiBaseURL
    var apiKey = ""
    var model = ASRBuiltIns.openaiModel
    var prompt = ""
    var language = "zh"
    var extraHeaders: [HTTPHeader] = []
    var requestTimeout: TimeInterval = 60

    init(
        baseURL: URL = ASRBuiltIns.openaiBaseURL,
        apiKey: String = "",
        model: String = ASRBuiltIns.openaiModel,
        prompt: String = "",
        language: String = "zh",
        extraHeaders: [HTTPHeader] = [],
        requestTimeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.language = language
        self.extraHeaders = extraHeaders
        self.requestTimeout = requestTimeout
    }

    /// Lenient decode: missing fields use the struct defaults (v3 schema).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(URL.self, forKey: .baseURL)
            ?? ASRBuiltIns.openaiBaseURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model)
            ?? ASRBuiltIns.openaiModel
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        extraHeaders = try c.decodeIfPresent([HTTPHeader].self, forKey: .extraHeaders) ?? []
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 60
    }
}

/// Xiaomi MiMo-7B ASR (mimo-v2.5-asr) — endpoint/model are built-in;
/// the block carries only apiKey/timeout. No hotwords, no prompt.
nonisolated struct MiMo7BConfig: Codable, Equatable, Sendable {
    var apiKey = ""
    var requestTimeout: TimeInterval = 60

    init(apiKey: String = "", requestTimeout: TimeInterval = 60) {
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
    }

    /// Lenient decode: missing fields use the struct defaults (v3 schema).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 60
    }
}

/// Xiaomi MiMo-V2.5 multimodal ASR — endpoint/model built-in. The system
/// prompt lives here for iteration/debugging; hotwords are appended by the
/// client from the top-level hotwords array. Default timeout is wider than
/// the 7B path because multimodal requests run longer.
nonisolated struct MiMoV25Config: Codable, Equatable, Sendable {
    var apiKey = ""
    var prompt = ASRBuiltIns.mimoV25DefaultPrompt
    var requestTimeout: TimeInterval = 120

    init(
        apiKey: String = "",
        prompt: String = ASRBuiltIns.mimoV25DefaultPrompt,
        requestTimeout: TimeInterval = 120
    ) {
        self.apiKey = apiKey
        self.prompt = prompt
        self.requestTimeout = requestTimeout
    }

    /// Lenient decode: missing fields use the struct defaults (v3 schema).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
            ?? ASRBuiltIns.mimoV25DefaultPrompt
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 120
    }
}

/// Volcengine Doubao ASR — WebSocket, raw PCM, one-shot. `wsURL` = WebSocket
/// endpoint (`…/sauc/bigmodel_nostream`), `resourceID` = X-Api-Resource-Id.
nonisolated struct DoubaoConfig: Codable, Equatable, Sendable {
    var wsURL = ASRBuiltIns.doubaoWsURL
    var apiKey = ""
    var resourceID = ASRBuiltIns.doubaoResourceID
    var requestTimeout: TimeInterval = 60
    /// Text-post flags — config.json-only, no UI; all default ON. DDC =
    /// filler-word smoothing; the server defaults it off, so it is written
    /// explicitly into the start frame.
    var enablePunc = true
    var enableITN = true
    var enableDDC = true

    init(
        wsURL: URL = ASRBuiltIns.doubaoWsURL,
        apiKey: String = "",
        resourceID: String = ASRBuiltIns.doubaoResourceID,
        requestTimeout: TimeInterval = 60,
        enablePunc: Bool = true,
        enableITN: Bool = true,
        enableDDC: Bool = true
    ) {
        self.wsURL = wsURL
        self.apiKey = apiKey
        self.resourceID = resourceID
        self.requestTimeout = requestTimeout
        self.enablePunc = enablePunc
        self.enableITN = enableITN
        self.enableDDC = enableDDC
    }

    /// Lenient decode: missing fields use the struct defaults (v3 schema).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wsURL = try c.decodeIfPresent(URL.self, forKey: .wsURL)
            ?? ASRBuiltIns.doubaoWsURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        resourceID = try c.decodeIfPresent(String.self, forKey: .resourceID) ?? ASRBuiltIns.doubaoResourceID
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 60
        enablePunc = try c.decodeIfPresent(Bool.self, forKey: .enablePunc) ?? true
        enableITN = try c.decodeIfPresent(Bool.self, forKey: .enableITN) ?? true
        enableDDC = try c.decodeIfPresent(Bool.self, forKey: .enableDDC) ?? true
    }
}

/// config.json v3: one ASR group. No implicit fallbacks — whatever sits in
/// the active provider's block is what runs.
nonisolated struct ASRConfig: Codable, Equatable, Sendable {
    /// Fresh installs default to the MiMo-V2.5 route.
    static let defaultProvider: ASRProvider = .mimoV25

    var provider: ASRProvider = defaultProvider
    var openaiCompatible: OpenAICompatibleConfig = OpenAICompatibleConfig()
    var mimo7b: MiMo7BConfig = MiMo7BConfig()
    var mimoV25: MiMoV25Config = MiMoV25Config()
    var doubao: DoubaoConfig = DoubaoConfig()

    init(
        provider: ASRProvider = ASRConfig.defaultProvider,
        openaiCompatible: OpenAICompatibleConfig = OpenAICompatibleConfig(),
        mimo7b: MiMo7BConfig = MiMo7BConfig(),
        mimoV25: MiMoV25Config = MiMoV25Config(),
        doubao: DoubaoConfig = DoubaoConfig()
    ) {
        self.provider = provider
        self.openaiCompatible = openaiCompatible
        self.mimo7b = mimo7b
        self.mimoV25 = mimoV25
        self.doubao = doubao
    }

    /// Lenient decode: missing blocks use the struct defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(ASRProvider.self, forKey: .provider)
            ?? ASRConfig.defaultProvider
        openaiCompatible = try c.decodeIfPresent(OpenAICompatibleConfig.self, forKey: .openaiCompatible)
            ?? OpenAICompatibleConfig()
        mimo7b = try c.decodeIfPresent(MiMo7BConfig.self, forKey: .mimo7b) ?? MiMo7BConfig()
        mimoV25 = try c.decodeIfPresent(MiMoV25Config.self, forKey: .mimoV25) ?? MiMoV25Config()
        doubao = try c.decodeIfPresent(DoubaoConfig.self, forKey: .doubao) ?? DoubaoConfig()
    }
}

/// config.json v3: `asr` group + top-level `general`. The active provider
/// block is used verbatim. Unknown top-level keys are ignored on decode and
/// dropped on the next write.
nonisolated struct AppConfig: Codable, Equatable, Sendable {
    var version: Int
    var asr: ASRConfig
    var general: GeneralConfig
    /// Hotword table, file-authoritative. Consumed per backend mechanism:
    /// Doubao API corpus, MiMo-V2.5 prompt section; MiMo-7B and
    /// openai-compatible never receive it. Preset TXT seeds first launch only.
    var hotwords: [String]

    init(
        version: Int = 3,
        asr: ASRConfig = ASRConfig(),
        general: GeneralConfig = GeneralConfig(),
        hotwords: [String] = HotwordPreset.load()
    ) {
        self.version = version
        self.asr = asr
        self.general = general
        self.hotwords = hotwords
    }

    enum CodingKeys: String, CodingKey {
        case version, asr, general, hotwords
    }

    /// Resolves the active provider block into the runtime carrier shape.
    /// MiMo/Doubao endpoints/models come from `ASRBuiltIns`; their blocks
    /// supply only apiKey/timeout (+ prompt for MiMo-V2.5). OpenAI Compatible
    /// is the editable gateway.
    var resolvedTranscription: TranscriptionConfig {
        switch asr.provider {
        case .openaiCompatible:
            return TranscriptionConfig(
                baseURL: asr.openaiCompatible.baseURL,
                apiKey: asr.openaiCompatible.apiKey,
                model: asr.openaiCompatible.model,
                prompt: asr.openaiCompatible.prompt,
                extraHeaders: asr.openaiCompatible.extraHeaders,
                requestTimeout: asr.openaiCompatible.requestTimeout,
                maxRecordDuration: general.maxRecordDuration,
                provider: .openaiCompatible,
                language: asr.openaiCompatible.language
            ).normalized
        case .mimo7b:
            return TranscriptionConfig(
                baseURL: ASRBuiltIns.mimoBaseURL,
                apiKey: asr.mimo7b.apiKey,
                model: ASRBuiltIns.mimoModel,
                requestTimeout: asr.mimo7b.requestTimeout,
                maxRecordDuration: general.maxRecordDuration,
                provider: .mimo7b,
                language: "zh"
            ).normalized
        case .mimoV25:
            return TranscriptionConfig(
                baseURL: ASRBuiltIns.mimoBaseURL,
                apiKey: asr.mimoV25.apiKey,
                model: ASRBuiltIns.mimoV25Model,
                requestTimeout: asr.mimoV25.requestTimeout,
                maxRecordDuration: general.maxRecordDuration,
                provider: .mimoV25,
                language: "",
                hotwords: hotwords,
                mimoV25Prompt: asr.mimoV25.prompt
            ).normalized
        case .doubao:
            return TranscriptionConfig(
                baseURL: ASRBuiltIns.doubaoWsURL,
                apiKey: asr.doubao.apiKey,
                model: ASRBuiltIns.doubaoResourceID,
                requestTimeout: asr.doubao.requestTimeout,
                maxRecordDuration: general.maxRecordDuration,
                provider: .doubao,
                language: "",
                doubaoEnablePunc: asr.doubao.enablePunc,
                doubaoEnableITN: asr.doubao.enableITN,
                doubaoEnableDDC: asr.doubao.enableDDC,
                hotwords: hotwords
            ).normalized
        }
    }

    /// Write-back: copies runtime-carrier fields into the active provider
    /// block. Built-in endpoints/models are never written back — only
    /// apiKey/timeout (+ V2.5 prompt) are. Hotwords are written back only by
    /// the backends that consume them.
    mutating func applyResolvedTranscription(_ t: TranscriptionConfig) {
        general.maxRecordDuration = t.maxRecordDuration
        switch asr.provider {
        case .openaiCompatible:
            asr.openaiCompatible.baseURL = t.baseURL
            asr.openaiCompatible.apiKey = t.apiKey
            asr.openaiCompatible.model = t.model
            asr.openaiCompatible.prompt = t.prompt
            asr.openaiCompatible.language = t.language
            asr.openaiCompatible.extraHeaders = t.extraHeaders
            asr.openaiCompatible.requestTimeout = t.requestTimeout
        case .mimo7b:
            asr.mimo7b.apiKey = t.apiKey
            asr.mimo7b.requestTimeout = t.requestTimeout
        case .mimoV25:
            asr.mimoV25.apiKey = t.apiKey
            asr.mimoV25.prompt = t.mimoV25Prompt
            asr.mimoV25.requestTimeout = t.requestTimeout
            hotwords = t.hotwords
        case .doubao:
            asr.doubao.apiKey = t.apiKey
            asr.doubao.requestTimeout = t.requestTimeout
            hotwords = t.hotwords
        }
    }

    /// Encodes current v3 fields only.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(asr, forKey: .asr)
        try c.encode(general, forKey: .general)
        try c.encode(hotwords, forKey: .hotwords)
    }

    /// Lenient decode of the current shape: missing groups take struct
    /// defaults; unknown keys (including any legacy layout) are ignored.
    /// The version is pinned to the current schema on every decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = 3
        asr = try c.decodeIfPresent(ASRConfig.self, forKey: .asr) ?? ASRConfig()
        general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        hotwords = try c.decodeIfPresent([String].self, forKey: .hotwords) ?? []
    }
}
