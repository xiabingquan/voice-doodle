import SwiftUI

/// Secure key entry: masked display when saved, inline write-to-store. The
/// field auto-focuses after clicking the edit control.
struct KeyTextField: View {
    let title: String
    @Binding var key: String
    var placeholder: String = ""

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        HStack {
            if editing {
                SecureField(placeholder, text: $draft)
                    .focused($draftFocused)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { draftFocused = true }
                    .onSubmit { commit() }
                Button("写入") { commit() }
                Button("取消") { editing = false }
            } else {
                Text(APIKeyMasking.masked(key))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("修改") {
                    draft = ""
                    editing = true
                }
                if !key.isEmpty {
                    Button("清除") { key = "" }
                }
            }
        }
    }

    private func commit() {
        key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
    }
}
