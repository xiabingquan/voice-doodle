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
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ASRBuiltIns.openaiModel
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        extraHeaders = try c.decodeIfPresent([HTTPHeader].self, forKey: .extraHeaders) ?? []
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 60
    }
}

/// Xiaomi MiMo ASR — chat-completions shaped, wav-only.
nonisolated struct MiMoConfig: Codable, Equatable, Sendable {
    var baseURL = ASRBuiltIns.mimoBaseURL
    var apiKey = ""
    var model = ASRBuiltIns.mimoModel
    var language = "zh"
    var requestTimeout: TimeInterval = 60

    init(
        baseURL: URL = ASRBuiltIns.mimoBaseURL,
        apiKey: String = "",
        model: String = ASRBuiltIns.mimoModel,
        language: String = "zh",
        requestTimeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.requestTimeout = requestTimeout
    }

    /// Lenient decode: missing fields use the struct defaults (v3 schema).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(URL.self, forKey: .baseURL)
            ?? ASRBuiltIns.mimoBaseURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ASRBuiltIns.mimoModel
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "zh"
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 60
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

/// config.json v3: one ASR group. **No implicit fallbacks** — whatever sits
/// in the active provider's block is what runs.
nonisolated struct ASRConfig: Codable, Equatable, Sendable {
    var provider: ASRProvider = .openaiCompatible
    var openaiCompatible: OpenAICompatibleConfig = OpenAICompatibleConfig()
    var mimo: MiMoConfig = MiMoConfig()
    var doubao: DoubaoConfig = DoubaoConfig()

    init(
        provider: ASRProvider = .openaiCompatible,
        openaiCompatible: OpenAICompatibleConfig = OpenAICompatibleConfig(),
        mimo: MiMoConfig = MiMoConfig(),
        doubao: DoubaoConfig = DoubaoConfig()
    ) {
        self.provider = provider
        self.openaiCompatible = openaiCompatible
        self.mimo = mimo
        self.doubao = doubao
    }

    /// Lenient decode: missing blocks use the struct defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(ASRProvider.self, forKey: .provider) ?? .openaiCompatible
        openaiCompatible = try c.decodeIfPresent(OpenAICompatibleConfig.self, forKey: .openaiCompatible)
            ?? OpenAICompatibleConfig()
        mimo = try c.decodeIfPresent(MiMoConfig.self, forKey: .mimo) ?? MiMoConfig()
        doubao = try c.decodeIfPresent(DoubaoConfig.self, forKey: .doubao) ?? DoubaoConfig()
    }
}

/// config.json v3: `asr` group + top-level `general`. The active provider
/// block is used verbatim. Legacy `refine`/`postProcess` keys are ignored
/// on decode and dropped on the next write.
nonisolated struct AppConfig: Codable, Equatable, Sendable {
    var version: Int
    var asr: ASRConfig
    var general: GeneralConfig

    init(
        version: Int = 3,
        asr: ASRConfig = ASRConfig(),
        general: GeneralConfig = GeneralConfig()
    ) {
        self.version = version
        self.asr = asr
        self.general = general
    }

    enum CodingKeys: String, CodingKey {
        case version, asr, general
        // Legacy keys, decode-only — never encoded.
        case provider, openaiCompatible, mimo, doubao
        case refine, postProcess
        case transcription
    }

    /// Resolves the active provider block into the runtime carrier shape.
    /// MiMo/Doubao endpoints/models come from `ASRBuiltIns`; their blocks
    /// supply only apiKey/timeout. OpenAI Compatible is the editable gateway.
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
        case .mimo:
            return TranscriptionConfig(
                baseURL: ASRBuiltIns.mimoBaseURL,
                apiKey: asr.mimo.apiKey,
                model: ASRBuiltIns.mimoModel,
                extraHeaders: [],
                requestTimeout: asr.mimo.requestTimeout,
                maxRecordDuration: general.maxRecordDuration,
                provider: .mimo,
                language: "zh"
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
                doubaoEnableDDC: asr.doubao.enableDDC
            ).normalized
        }
    }

    /// Write-back: copies runtime-carrier fields into the active provider
    /// block. Built-in endpoints/models are never written back — only
    /// apiKey/timeout are; fields the block lacks are dropped.
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
        case .mimo:
            asr.mimo.apiKey = t.apiKey
            asr.mimo.requestTimeout = t.requestTimeout
        case .doubao:
            asr.doubao.apiKey = t.apiKey
            asr.doubao.requestTimeout = t.requestTimeout
        }
    }

    /// Encodes v3 fields only; v1/v2 legacy keys exist for decode migration.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(asr, forKey: .asr)
        try c.encode(general, forKey: .general)
    }

    /// Three-tier decode, all deterministic: v3 `asr` key → lenient v3;
    /// v2 flat provider blocks → promoted wholesale under `asr`; otherwise
    /// v1 flat `transcription` routed into v3 shape.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1

        if decodedVersion >= 3, c.contains(.asr) {
            version = decodedVersion
            asr = try c.decodeIfPresent(ASRConfig.self, forKey: .asr) ?? ASRConfig()
            general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
            return
        }

        if decodedVersion >= 2,
           c.contains(.openaiCompatible) || c.contains(.mimo) || c.contains(.doubao) {
            var lifted = ASRConfig()
            lifted.provider = try c.decodeIfPresent(ASRProvider.self, forKey: .provider) ?? .openaiCompatible
            lifted.openaiCompatible = try c.decodeIfPresent(OpenAICompatibleConfig.self, forKey: .openaiCompatible)
                ?? OpenAICompatibleConfig()
            lifted.mimo = try c.decodeIfPresent(MiMoConfig.self, forKey: .mimo) ?? MiMoConfig()
            lifted.doubao = try c.decodeIfPresent(DoubaoConfig.self, forKey: .doubao) ?? DoubaoConfig()
            version = 3
            asr = lifted
            general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
            return
        }

        // v1 → v3: the flat transcription block lands in
        // asr.openaiCompatible; the v1 apiKey belongs to the active provider;
        // other blocks take struct defaults.
        self = AppConfig.migrate(fromV1: try AppConfigV1(from: decoder))
    }

    static func migrate(fromV1 v1: AppConfigV1) -> AppConfig {
        var config = AppConfig()
        config.asr.provider = v1.transcription.provider
        config.general.maxRecordDuration = v1.transcription.maxRecordDuration
        config.asr.openaiCompatible = OpenAICompatibleConfig(
            baseURL: v1.transcription.baseURL,
            apiKey: v1.transcription.provider == .openaiCompatible ? v1.transcription.apiKey : "",
            model: v1.transcription.model,
            prompt: v1.transcription.prompt,
            language: v1.transcription.language,
            extraHeaders: v1.transcription.extraHeaders,
            requestTimeout: v1.transcription.requestTimeout
        )
        if v1.transcription.provider == .mimo {
            config.asr.mimo.apiKey = v1.transcription.apiKey
        }
        if v1.transcription.provider == .doubao {
            config.asr.doubao.apiKey = v1.transcription.apiKey
        }
        // Legacy refine/postProcess data is dropped.
        return config
    }
}

/// v1 flat schema — used only for the one-shot migration. The legacy
/// `postProcess` block is intentionally not decoded (dropped in migration).
nonisolated struct AppConfigV1: Decodable {
    var transcription: TranscriptionConfig
}
