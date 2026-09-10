import AppKit
import SwiftUI

/// First-run setup wizard — pages: ① permissions ② provider + API key ③
/// completion check. Opening resets `onboardingCompleted`; only Finish/Skip
/// sets it true. Observes ConfigStore/AppStatus directly.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    var onClose: () -> Void = {}

    var body: some View {
        OnboardingForm(
            store: appState.configStore,
            status: appState.status,
            appState: appState,
            onClose: onClose
        )
        .frame(width: UITokens.Metric.onboardingWidth, height: UITokens.Metric.onboardingHeight)
    }
}

private struct OnboardingForm: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var status: AppStatus
    let appState: AppState
    var onClose: () -> Void

    @State private var step = 0
    /// Set on the mic badge's denied→granted flip while the wizard is open.
    @State private var micJustGranted = false
    @State private var lastMicOK = false

    private static let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            // Skip stays visible on every page (completion included): hiding it
            // collapses the top bar and shifts the indicator upward.
            HStack {
                Spacer()
                Button("跳过") { finish() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(UITokens.Space.lg)

            stepIndicator
                .padding(.bottom, UITokens.Space.md)

            Group {
                switch step {
                case 0: permissionsPage
                case 1: providerPage
                default: completionPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: UITokens.Space.sm) {
                Spacer()
                if step > 0 && step < Self.pageCount - 1 {
                    Button("上一步") { step -= 1 }
                }
                if step < Self.pageCount - 1 {
                    Button("下一步") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                } else if status.configOK {
                    Button("开始使用") { finish() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    // Config incomplete: the Start button is greyed out; a
                    // blue Back button returns to the previous step to fix
                    // it.
                    Button("上一步") { step -= 1 }
                        .tint(UITokens.Palette.accent)
                        .keyboardShortcut(.defaultAction)
                    Button("开始使用") { finish() }
                        .disabled(true)
                }
            }
            .padding(UITokens.Space.lg)
        }
        .onAppear {
            lastMicOK = status.micOK
            appState.refreshReadiness()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshReadiness()
        }
        .onChange(of: status.micOK) { micOK in
            if micOK && !lastMicOK {
                micJustGranted = true
            }
            lastMicOK = micOK
        }
    }

    // MARK: - Pages

    /// Top-centre step indicator: 1 2 3 — item 3 is the completion page;
    /// only the CURRENT page lights up regardless of setup validity.
    private var stepIndicator: some View {
        HStack(spacing: UITokens.Space.lg) {
            ForEach(1...Self.pageCount, id: \.self) { n in
                let lit = n - 1 == step
                Text("\(n)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(lit ? Color.white : UITokens.Palette.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(lit ? UITokens.Palette.accent : UITokens.Palette.separator.opacity(0.35))
                    )
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Completion page reflects real config validity: backend has API key +
    /// model → complete with checkmark; otherwise incomplete with a warning
    /// naming what is missing.
    private var completionPage: some View {
        let ok = status.configOK
        return VStack(spacing: UITokens.Space.md) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: UITokens.Metric.welcomeIcon))
                .foregroundStyle(ok ? UITokens.Palette.ok : UITokens.Palette.warning)
            Text(ok ? "设置完成" : "设置未完成")
                .font(UITokens.Typography.display)
            if !ok {
                Text("转录 API Key 未填写")
                    .font(UITokens.Typography.secondary)
                    .foregroundStyle(UITokens.Palette.secondary)
            }
        }
    }

    /// One page, two items. The open-System-Settings button fires one TCC
    /// request first (registration) — otherwise the app is absent from the
    /// System Settings privacy lists.
    private var permissionsPage: some View {
        VStack(spacing: UITokens.Space.md) {
            Text("权限").font(UITokens.Typography.stepTitle)
            VStack(alignment: .leading, spacing: UITokens.Space.md) {
                permissionRow(name: "麦克风", ok: status.micOK) {
                    Permissions.micRowAction(appState: appState)
                }
                if micJustGranted {
                    Text("若录音仍不可用，退出并重新打开 Voice Doodle")
                        .font(UITokens.Typography.secondary)
                        .foregroundStyle(UITokens.Palette.secondary)
                }
                permissionRow(name: "辅助功能", ok: status.axOK) {
                    Permissions.axRowAction(appState: appState)
                }
            }
            .padding(.horizontal, UITokens.Space.onboardingInset)
        }
    }

    private func permissionRow(name: String, ok: Bool, action: @escaping () -> Void) -> some View {
        let state: PermissionState = ok ? .granted : .denied
        return HStack {
            Text(name)
            Spacer()
            Image(systemName: state.symbolName)
                .foregroundStyle(state.tint)
            Button("打开系统设置", action: action)
        }
    }

    private var providerPage: some View {
        let provider = store.config.asr.provider
        let spec = OnboardingFieldSpec(provider: provider)
        return VStack(spacing: UITokens.Space.md) {
            Text("转录服务").font(UITokens.Typography.stepTitle)
            VStack(alignment: .leading, spacing: UITokens.Space.sm) {
                // Switching persists immediately (setProvider writes only
                // asr.provider); Skip does not roll back written config.
                ProviderPicker(selection: Binding(
                    get: { provider },
                    set: { appState.setProvider($0) }
                ))
                VStack(alignment: .leading, spacing: UITokens.Space.sm) {
                    if spec.showsURLField {
                        field("baseURL") {
                            TextField("baseURL", text: urlBinding, prompt: Text(spec.urlPrompt))
                        }
                    }
                    field("API Key") {
                        KeyTextField(title: "API Key", key: appState.transcriptionBinding(\.apiKey))
                    }
                    if spec.showsModelField {
                        field("model") {
                            TextField("model", text: appState.transcriptionBinding(\.model), prompt: Text(spec.modelPrompt))
                        }
                    }
                }
                // Rebuild the field area on provider switch so KeyTextField
                // draft state never carries into the newly selected provider.
                .id(provider)
            }
            .padding(.horizontal, UITokens.Space.onboardingInset)
        }
    }

    // MARK: - Pieces

    /// Labelled control. Wizard steps use plain stacks, not Form chrome.
    private func field<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UITokens.Space.xs / 2) {
            Text(label)
                .font(UITokens.Typography.secondary)
                .foregroundStyle(UITokens.Palette.secondary)
            content()
        }
    }

    // MARK: - Bindings

    /// baseURL parses on write via the shared URL helper; other fields go
    /// through AppState's keyPath bindings.
    private var urlBinding: Binding<String> {
        Binding(
            get: { store.config.resolvedTranscription.baseURL.absoluteString },
            set: { newValue in
                appState.updateTranscription { config in
                    if let url = URL(vdBase: newValue) { config.baseURL = url }
                }
            }
        )
    }

    private func finish() {
        appState.preferences.onboardingCompleted = true
        appState.refreshReadiness()
        onClose()
    }
}
