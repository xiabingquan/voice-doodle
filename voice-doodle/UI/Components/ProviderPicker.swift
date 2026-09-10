import SwiftUI

/// Native provider popup — shared by the wizard provider page and the
/// dashboard transcription row. Writes go through AppState.setProvider,
/// which changes only `asr.provider`.
struct ProviderPicker: View {
    @Binding var selection: ASRProvider

    var body: some View {
        Picker("后端", selection: $selection) {
            ForEach(ASRProvider.allCases) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
    }
}
