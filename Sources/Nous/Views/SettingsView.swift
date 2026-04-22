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
    let userMemoryService: UserMemoryService
    let telemetry: GovernanceTelemetryStore
    var onBack: (() -> Void)? = nil

    @AppStorage("nous.username")   private var username       = "ALEX"
    @AppStorage("nous.appearance") private var appearanceMode = "system"

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
                    Button(action: { selectedTab = section }) {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 18, alignment: .center)
                            Text(section.rawValue)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                            Spacer()
                        }
                        .foregroundColor(selectedTab == section ? AppColor.colaOrange : AppColor.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedTab == section ? AppColor.colaOrange.opacity(0.10) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .frame(width: 180)
            .padding(.horizontal, 8)
            .background(AppColor.surfaceSecondary.opacity(0.5))

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
                        userMemoryService: userMemoryService,
                        telemetry: telemetry
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
                pageHeader(title: "General", subtitle: "Choose the model provider Nous should use by default.")

                settingsCard {
                    sectionLabel("Default provider")
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LLM provider")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                            Text("Nous uses this for all chat and judge tasks.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(AppColor.secondaryText)
                        }
                        Spacer()
                        Picker("LLM Provider", selection: $vm.selectedProvider) {
                            Text("Local MLX").tag(LLMProvider.local)
                            Text("Google Gemini").tag(LLMProvider.gemini)
                            Text("Anthropic Claude").tag(LLMProvider.claude)
                            Text("OpenAI").tag(LLMProvider.openai)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: vm.selectedProvider) { _, _ in vm.savePreferences() }
                    }
                }

                if vm.selectedProvider != .local {
                    settingsCard {
                        sectionLabel("Credentials")
                        VStack(alignment: .leading, spacing: 8) {
                            Text(apiKeyTitle)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText)
                            Text("Stored locally in macOS Keychain.")
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
                pageHeader(title: "Models", subtitle: "Track local models and knowledge base size on this Mac.")

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
        case .gemini: return "Gemini API Key"
        case .claude: return "Claude API Key"
        case .openai: return "OpenAI API Key"
        case .local:  return "API Key"
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
    private var appearancePicker: some View {
        HStack(spacing: 2) {
            ForEach([("sun.max", "Light", "light"), ("moon", "Dark", "dark"), ("circle.lefthalf.filled", "Auto", "system")], id: \.2) { icon, label, value in
                Button(action: { appearanceMode = value }) {
                    HStack(spacing: 5) {
                        Image(systemName: icon).font(.system(size: 11, weight: .medium))
                        Text(label).font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundColor(appearanceMode == value ? .white : AppColor.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(appearanceMode == value ? AppColor.colaOrange : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AppColor.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AppColor.panelStroke, lineWidth: 1))
    }
}
