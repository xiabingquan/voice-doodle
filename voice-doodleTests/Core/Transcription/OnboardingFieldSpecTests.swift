import Foundation
import Testing
@testable import voice_doodle

/// Pins wizard/settings field visibility per provider: built-in backends
/// (MiMo-7B / MiMo-V2.5 / Doubao) show only the API key; OpenAI Compatible
/// is the only provider with editable baseURL/model.
struct OnboardingFieldSpecTests {
    @Test func openaiCompatibleShowsAllEditableFields() {
        let spec = OnboardingFieldSpec(provider: .openaiCompatible)
        #expect(spec.showsURLField)
        #expect(spec.showsModelField)
        #expect(spec.urlPrompt == ASRBuiltIns.openaiBaseURL.absoluteString)
        #expect(spec.modelPrompt == ASRBuiltIns.openaiModel)
    }

    @Test func mimoBackendsShowOnlyAPIKey() {
        for provider in [ASRProvider.mimo7b, .mimoV25] {
            let spec = OnboardingFieldSpec(provider: provider)
            #expect(!spec.showsURLField)
            #expect(!spec.showsModelField)
        }
    }

    @Test func doubaoShowsOnlyAPIKey() {
        let spec = OnboardingFieldSpec(provider: .doubao)
        #expect(!spec.showsURLField)
        #expect(!spec.showsModelField)
    }

    /// Spec prompts must track the built-in constants (single source).
    @Test func specPromptsTrackBuiltIns() {
        #expect(OnboardingFieldSpec(provider: .mimo7b).urlPrompt == ASRBuiltIns.mimoBaseURL.absoluteString)
        #expect(OnboardingFieldSpec(provider: .mimo7b).modelPrompt == ASRBuiltIns.mimoModel)
        #expect(OnboardingFieldSpec(provider: .mimoV25).urlPrompt == ASRBuiltIns.mimoBaseURL.absoluteString)
        #expect(OnboardingFieldSpec(provider: .mimoV25).modelPrompt == ASRBuiltIns.mimoV25Model)
        #expect(OnboardingFieldSpec(provider: .doubao).urlPrompt == ASRBuiltIns.doubaoWsURL.absoluteString)
        #expect(OnboardingFieldSpec(provider: .doubao).modelPrompt == ASRBuiltIns.doubaoResourceID)
    }

    @Test func displayNamesDistinguishMiMoBackends() {
        #expect(ASRProvider.mimo7b.displayName == "MiMo-7B")
        #expect(ASRProvider.mimoV25.displayName == "MiMo-V2.5")
        #expect(ASRProvider.mimo7b.rawValue == "mimo-7b")
        #expect(ASRProvider.mimoV25.rawValue == "mimo-v25")
    }
}
