import SwiftUI

// Top-level enum so ContentView can bind to it
enum SettingsSection: String, CaseIterable {
    case profile = "Profile"
    case general = "General"
    case models  = "Models"
    case memory  = "Memory"

    var icon: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .general: return "gearshape"
        case .models:  return "cpu"
        case .memory:  return "brain.head.profile"
        }
    }
}

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel
    @Binding var selectedTab: SettingsSection
    let skillStore: SkillStore
    let userMemoryService: UserMemoryService
    let telemetry: GovernanceTelemetryStore
    let galaxyRelationTelemetry: GalaxyRelationTelemetry
    var onBack: (() -> Void)? = nil

    @AppStorage("nous.username")   private var username       = "ALEX"
    @AppStorage("nous.appearance") private var appearanceMode = "system"
    @Namespace private var toggleAnimation
    @Namespace private var navAnimation

    var body: some View {
        HStack(spacing: 0) {
            // ── Left nav column ───────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                // Back button
                Button(action: { onBack?() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(AppColor.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.top, 16)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

                ForEach(SettingsSection.allCases, id: \.self) { section in
                    navButton(section: section)
                }

                Spacer()
            }
            .frame(width: 180)
            .padding(.horizontal, 8)
            .background(
                NativeGlassPanel(cornerRadius: 0, tintColor: AppColor.glassTint) { EmptyView() }
            )

            Divider()

            // ── Right content area ────────────────────────────────
            Group {
                switch selectedTab {
                case .profile: profileContent
                case .general: generalContent
                case .models:  modelsContent
                case .memory:
                    MemoryDebugInspector(
                        nodeStore: vm.nodeStore,
                        skillStore: skillStore,
                        userMemoryService: userMemoryService,
                        telemetry: telemetry,
                        galaxyRelationTelemetry: galaxyRelationTelemetry
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AppColor.colaBeige)
            .onAppear { vm.updateStats() }
            .onChange(of: selectedTab) { _, _ in vm.updateStats() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.colaBeige)
    }

    // MARK: - Profile
    private var profileContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(title: "Profile", subtitle: "Keep the identity Nous uses in memory simple and stable.")

                settingsCard {
                    sectionLabel("Identity")
                    HStack(spacing: 16) {
                        Circle()
                            .fill(AppColor.colaOrange.opacity(0.14))
                            .frame(width: 54, height: 54)
                            .overlay(
                                Text(username.first.map(String.init)?.uppercased() ?? "A")
                                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                                    .foregroundColor(AppColor.colaOrange)
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Display name")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                            Text("Used in the sidebar and in long-term memory summaries.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Spacer()
                    }
                    fieldShell {
                        TextField("Display Name", text: $username)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText)
                    }
                    helperCopy("Keep this stable. Changing it too often makes memory history harder to read.")
                }

                settingsCard {
                    sectionLabel("Appearance")
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Theme")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                            Text("Controls the light or dark appearance of the Nous interface.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Spacer()
                        appearancePicker
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: - General
    private var generalContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(title: "General", subtitle: "Choose the default AI and the privacy-sensitive automation Nous is allowed to run.")

                settingsCard {
                    sectionLabel("Default provider")
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LLM provider")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                            Text("Nous uses this for foreground chat and judge tasks.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Spacer()
                        Picker("LLM Provider", selection: $vm.selectedProvider) {
                            Text("Local MLX").tag(LLMProvider.local)
                            Text("Google Gemini").tag(LLMProvider.gemini)
                            Text("Anthropic Claude").tag(LLMProvider.claude)
                            Text("OpenAI").tag(LLMProvider.openai)
                            Text("OpenRouter").tag(LLMProvider.openrouter)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: vm.selectedProvider) { _, _ in vm.savePreferences() }
                    }

                    if vm.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Weekly reflections always run on Gemini 2.5 Pro. Add a Gemini API key below — even when the foreground provider is something else.")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(AppColor.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                }

                if vm.selectedProvider != .local {
                    settingsCard {
                        sectionLabel("Credentials")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(apiKeyTitle)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                            Text(vm.credentialStorageDescription)
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        fieldShell {
                            Group {
                                switch vm.selectedProvider {
                                case .gemini:
                                    SecureField("Gemini API Key", text: $vm.geminiApiKey)
                                        .onSubmit { vm.savePreferences() }
                                case .claude:
                                    SecureField("Claude API Key", text: $vm.claudeApiKey)
                                        .onSubmit { vm.savePreferences() }
                                case .openai:
                                    SecureField("OpenAI API Key", text: $vm.openaiApiKey)
                                        .onSubmit { vm.savePreferences() }
                                case .openrouter:
                                    SecureField("OpenRouter API Key", text: $vm.openrouterApiKey)
                                        .onSubmit { vm.savePreferences() }
                                case .local:
                                    EmptyView()
                                }
                            }
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText)
                        }
                        helperCopy("Leave empty to keep Nous fully local.")
                    }
                }

                settingsCard {
                    sectionLabel("Privacy-sensitive automation")
                    toggleRow(
                        title: "Finder export",
                        subtitle: "Write notes and conversations as Markdown in Documents for Finder browsing. Assistant thinking only exports if the toggle below is on. Turning this off removes the generated export folder.",
                        isOn: preferenceBinding(\.finderSyncEnabled)
                    )
                    toggleRow(
                        title: "Background AI maintenance",
                        subtitle: "Allow launch-time chat-title repair and weekly reflections. With cloud providers, this can send existing chats to the active model. Off by default.",
                        isOn: preferenceBinding(\.backgroundAnalysisEnabled)
                    )
                    toggleRow(
                        title: "Store assistant thinking",
                        subtitle: "Keep assistant reasoning traces in local chat history and Finder export. Turning this off clears previously stored thinking from SQLite. Off by default.",
                        isOn: preferenceBinding(\.assistantThinkingEnabled)
                    )
                    toggleRow(
                        title: "Gemini history cache",
                        subtitle: "Let Gemini create short-lived cached transcript prefixes on Google's servers for long chats. Only applies when Gemini is active and lasts up to 5 minutes. Off by default.",
                        isOn: preferenceBinding(\.geminiHistoryCacheEnabled)
                    )
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: - Models
    private var modelsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(title: "Models", subtitle: "Inspect the exact models Nous runs and track the local model state on this Mac.")

                settingsCard {
                    sectionLabel("Actual models")
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(vm.runtimeModelSummaries) { summary in
                            runtimeModelRow(summary)
                        }
                    }
                }

                settingsCard {
                    sectionLabel("Voice Mode")
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OpenAI Realtime API Key")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText)
                        Text("Voice Mode uses OpenAI Realtime separately from the default chat provider.")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(AppColor.secondaryText)
                    }
                    fieldShell {
                        SecureField("OpenAI API Key", text: $vm.openaiApiKey)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText)
                            .onSubmit { vm.savePreferences() }
                    }
                    helperCopy("Gemini and OpenRouter keys do not start the realtime voice session.")
                }

                settingsCard {
                    sectionLabel("On-device models")
                    modelRow(label: "Local LLM",  name: vm.localModelId,     isLoaded: vm.isLLMLoaded,       progress: vm.llmDownloadProgress,       onLoad: { Task { await vm.loadLocalLLM() } })
                    modelRow(label: "Embedder",    name: vm.embeddingModelId, isLoaded: vm.isEmbeddingLoaded, progress: vm.embeddingDownloadProgress, onLoad: { Task { await vm.loadEmbeddingModel() } })
                }

                settingsCard {
                    sectionLabel("Knowledge base")
                    HStack(spacing: 12) {
                        statTile(title: "Vectors",  value: "\(vm.vectorCount)")
                        statTile(title: "Database", value: vm.databaseSize)
                    }
                    helperCopy("Local models keep memory private. Vector count reflects nodes with embeddings in SQLite.")
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    // MARK: - Helpers
    private var apiKeyTitle: String {
        switch vm.selectedProvider {
        case .gemini:     return "Gemini API Key"
        case .claude:     return "Claude API Key"
        case .openai:     return "OpenAI API Key"
        case .openrouter: return "OpenRouter API Key"
        case .local:      return "API Key"
        }
    }

    @ViewBuilder
    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            Text(subtitle)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) { content() }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.surfaceSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(AppColor.panelStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func fieldShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppColor.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppColor.panelStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(AppColor.secondaryText)
            .textCase(.uppercase)
            .tracking(0.8)
    }

    @ViewBuilder
    private func helperCopy(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .rounded))
            .foregroundColor(AppColor.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func runtimeModelRow(_ summary: SettingsViewModel.RuntimeModelSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.label)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
            Text(summary.model)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(AppColor.colaOrange)
                .textSelection(.enabled)
            Text(summary.detail)
                .font(.system(size: 12, design: .rounded))
                .foregroundColor(AppColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppColor.panelStroke, lineWidth: 1))
    }

    private func preferenceBinding(_ keyPath: ReferenceWritableKeyPath<SettingsViewModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { vm[keyPath: keyPath] },
            set: { newValue in
                vm[keyPath: keyPath] = newValue
                vm.savePreferences()
            }
        )
    }

    @ViewBuilder
    private func statTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColor.secondaryText)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                Text(subtitle)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func modelRow(label: String, name: String, isLoaded: Bool, progress: Double, onLoad: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                    Text(name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(AppColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if !isLoaded && progress > 0 {
                    ProgressView(value: progress).controlSize(.small).frame(width: 72)
                } else if isLoaded {
                    Label("Loaded", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.green)
                } else {
                    Button("Download", action: onLoad)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppColor.colaOrange)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func navButton(section: SettingsSection) -> some View {
        let active = selectedTab == section
        NavHoverButton {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                selectedTab = section
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18, alignment: .center)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: active ? .semibold : .medium, design: .rounded))
                Spacer()
            }
            .foregroundColor(active ? AppColor.colaOrange : AppColor.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if active {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppColor.colaOrange.opacity(0.10))
                            .matchedGeometryEffect(id: "navHighlight", in: navAnimation)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var appearancePicker: some View {
        ZStack {
            NativeGlassPanel(
                cornerRadius: 16,
                tintColor: AppColor.glassTint
            ) { EmptyView() }
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )

            HStack(spacing: 2) {
                appearanceButton(icon: "sun.max", label: "Light", value: "light")
                appearanceButton(icon: "moon", label: "Dark", value: "dark")
                appearanceButton(icon: "circle.lefthalf.filled", label: "Auto", value: "system")
            }
            .padding(3)
        }
        .fixedSize()
        .frame(height: 32)
    }

    @ViewBuilder
    private func appearanceButton(icon: String, label: String, value: String) -> some View {
        let active = (appearanceMode == value)
        Button(action: { 
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75, blendDuration: 0)) {
                appearanceMode = value 
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 12, weight: active ? .semibold : .medium, design: .rounded))
            }
            .foregroundColor(active ? AppColor.colaDarkText : AppColor.secondaryText)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                ZStack {
                    if active {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(AppColor.teaPillColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .matchedGeometryEffect(id: "appearancePill", in: toggleAnimation)
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NavHoverButton

private struct NavHoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
