import SwiftUI

/// Records a new trigger combo (logic in ShortcutRecorderModel).
struct ShortcutRecorderView: View {
    @ObservedObject var model: ShortcutRecorderModel
    let currentKind: TriggerKind
    let onCapture: (TriggerKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UITokens.Space.sm) {
            HStack(spacing: UITokens.Space.sm) {
                Text(model.isRecording ? "请按下快捷键…（ESC 取消）" : TriggerDescriptor.describe(currentKind))
                    .foregroundStyle(model.isRecording ? UITokens.Palette.warning : UITokens.Palette.primary)
                Spacer()
                if model.isRecording {
                    Button("取消") { model.cancel() }
                } else {
                    Button("录制") { model.beginRecording() }
                    Button("恢复默认") { model.restoreDefault() }
                }
            }
            if let warning = model.conflictWarning {
                SeverityBanner(severity: .warning, message: warning)
            }
        }
        .onAppear {
            model.onCapture = onCapture
        }
    }
}
