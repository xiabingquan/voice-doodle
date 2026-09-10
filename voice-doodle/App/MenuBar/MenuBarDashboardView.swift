import AppKit
import SwiftUI

/// The dashboard window content — one page. Provider-bound values live in
/// config.json, not here. `DashboardForm` observes `ConfigStore`/`AppStatus`
/// directly (AppState publishes nothing). Panel height is content-driven.
struct MenuBarDashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        DashboardForm(
            store: appState.configStore,
            status: appState.status,
            appState: appState
        )
        .frame(width: UITokens.Metric.dashboardWidth)
    }
}

private struct DashboardForm: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var status: AppStatus
    let appState: AppState
    @StateObject private var recorderModel = ShortcutRecorderModel()
    @StateObject private var testModel = APITestModel()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    providerRow
                } header: {
                    SectionHeader(title: "转录", symbol: "waveform")
                } footer: {
                    transcriptionFooter
                }

                Section {
                    ShortcutRecorderView(
                        model: recorderModel,
                        currentKind: appState.preferences.triggerConfig.kind
                    ) { kind in
                        appState.updateTrigger(kind)
                    }
                } header: {
                    SectionHeader(title: "触发键", symbol: "keyboard")
                }

                Section {
                    PermissionSection(status: status, appState: appState)
                } header: {
                    SectionHeader(title: "权限", symbol: "lock.shield")
                } footer: {
                    configLinkFooter
                }
            }
            .formStyle(.grouped)
            .frame(width: UITokens.Metric.dashboardWidth)

            Divider()

            HStack {
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .padding(UITokens.Space.lg)
        }
        .onChange(of: recorderModel.isRecording) { recording in
            // Capture monitors race the main event tap unless it is stopped.
            appState.setTriggerCaptureActive(recording)
        }
        .onAppear { appState.refreshReadiness() }
    }

    /// Backend picker plus the connectivity test in one row. The test
    /// control renders every phase inside a fixed-width slot so nothing in
    /// the row jumps; outcomes auto-revert to the link after ~1s.
    private var providerRow: some View {
        HStack(spacing: UITokens.Space.sm) {
            ProviderPicker(selection: Binding(
                get: { store.config.asr.provider },
                set: { appState.setProvider($0) }
            ))
            Spacer(minLength: 0)
            Button {
                testModel.run(appState: appState, snapshot: { store.freshResolvedTranscription() })
            } label: {
                testSlot
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .disabled(testModel.phase == .running)
            .help(testHoverText)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    /// Fixed-size slot: every phase renders in place, content centered —
    /// appearance changes never reflow the row.
    private var testSlot: some View {
        ZStack {
            testSlotContent
        }
        .frame(width: 30, height: 18)
    }

    @ViewBuilder private var testSlotContent: some View {
        switch testModel.phase {
        case .idle:
            Text("测试")
                .font(UITokens.Typography.secondary)
                .foregroundStyle(UITokens.Palette.accent)
        case .running:
            TranscribeSpinnerView(
                colors: [
                    Color.gray.opacity(0.3),
                    UITokens.Palette.secondary,
                    Color.gray.opacity(0.3)
                ],
                size: 14
            )
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(UITokens.Typography.rowTitle)
                .foregroundStyle(UITokens.Palette.ok)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(UITokens.Typography.rowTitle)
                .foregroundStyle(UITokens.Palette.error)
        }
    }

    private var testHoverText: String {
        switch testModel.phase {
        case .idle: return "测试转录后端连通性"
        case .running: return "测试中…"
        case .succeeded: return "连接成功"
        case .failed: return "测试失败，查看 log 获取完整错误"
        }
    }

    /// Config-integrity notices only (wizard incomplete, config load
    /// errors). Backend availability is verified via the inline connectivity
    /// test; menu-bar readiness gating for `configOK` is separate.
    private var transcriptionFooter: some View {
        VStack(alignment: .leading, spacing: UITokens.Space.xs) {
            if !status.wizardCompleted {
                SeverityBanner(severity: .warning, message: "请先完成设置向导")
            }
            if let loadError = store.loadError {
                SeverityBanner(severity: .error, message: loadError)
                    .lineLimit(3)
            }
        }
    }

    /// Bottom-right, under the last permission row. Quiet advanced actions:
    /// caption size, accent colour, pointing-hand cursor on hover.
    private var configLinkFooter: some View {
        HStack(spacing: UITokens.Space.md) {
            Spacer()
            quietLink("设置向导") { appState.onOpenOnboarding?() }
            quietLink("打开 config.json") { appState.configStore.openInEditor() }
            quietLink("查看config示例") { appState.configStore.openConfigTemplate() }
            quietLink("查看 log") { LogFile.open() }
        }
    }

    private func quietLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .controlSize(.small)
            .font(UITokens.Typography.secondary)
            .foregroundStyle(UITokens.Palette.accent)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

}

/// Permission rows. The whole row is the hit target; clicking fires one TCC
/// request first (first install: unrequested apps are absent from the
/// privacy lists), then opens the matching System Settings pane.
private struct PermissionSection: View {
    @ObservedObject var status: AppStatus
    let appState: AppState

    var body: some View {
        permissionRow(
            name: "麦克风",
            state: status.micOK ? .granted : .denied,
            action: { Permissions.micRowAction(appState: appState) }
        )
        permissionRow(
            name: "辅助功能",
            state: status.axOK ? .granted : .denied,
            action: { Permissions.axRowAction(appState: appState) }
        )
    }

    private func permissionRow(
        name: String,
        state: PermissionState,
        action: @escaping () -> Void
    ) -> some View {
        PressableRow(title: name, action: action) {
            HStack(spacing: UITokens.Space.xs) {
                StatusBadge(state: state, font: UITokens.Typography.rowTitle)
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(UITokens.Palette.secondary)
            }
        }
    }
}
