import SwiftUI

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel
    let userMemoryService: UserMemoryService
    let telemetry: GovernanceTelemetryStore
    
    enum SettingsTab: String, CaseIterable {
        case profile = "Profile"
        case general = "General"
        case models = "Models"
        case memory = "Memory"
        
        var icon: String {
            switch self {
            case .profile: return "person.crop.circle"
            case .general: return "gearshape"
            case .models: return "cpu"
            case .memory: return "brain.head.profile"
            }
        }
    }
    
    @State private var selectedTab: SettingsTab = .profile
    @AppStorage("nous.username") private var username = "ALEX"

    var body: some View {
        HStack(spacing: 0) {
            // Custom sidebar
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(AppColor.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button(action: {
                        selectedTab = tab
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 16)
                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .medium, design: .rounded))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundColor(selectedTab == tab ? .white : AppColor.colaDarkText.opacity(0.85))
                        .background(selectedTab == tab ? AppColor.colaOrange : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                }

                Spacer()
            }
            .frame(width: 180)
            .background(AppColor.surfaceSecondary.opacity(0.3))
            
            Divider()
                .opacity(0.5)

            // Content area
            Group {
                switch selectedTab {
                case .profile:
                    profileTab
                case .general:
                    generalTab
                case .models:
                    modelsTab
                case .memory:
                    memoryTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColor.colaBeige)
        }
        .onAppear {
            vm.updateStats()
        }
    }
    
    private var profileTab: some View {
        Form {
            Section {
                TextField("Display Name", text: $username)
                    .textFieldStyle(.roundedBorder)
            } footer: {
                Text("This name is used in the sidebar and as your primary identity when Nous stores personal memories about you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.colaBeige)
    }
    
    private var generalTab: some View {
        Form {
            Section {
                Picker("LLM Provider:", selection: $vm.selectedProvider) {
                    Text("Local MLX").tag(LLMProvider.local)
                    Text("Google Gemini").tag(LLMProvider.gemini)
                    Text("Anthropic Claude").tag(LLMProvider.claude)
                    Text("OpenAI").tag(LLMProvider.openai)
                }
                .pickerStyle(.menu)
                .onChange(of: vm.selectedProvider) { _, _ in
                    vm.savePreferences()
                }
            }
            
            if vm.selectedProvider != .local {
                Section {
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
                } footer: {
                    Text("Your API key is stored securely in macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.colaBeige)
    }
    
    private var modelsTab: some View {
        Form {
            Section {
                modelRow(
                    label: "Local LLM:",
                    name: vm.localModelId,
                    isLoaded: vm.isLLMLoaded,
                    progress: vm.llmDownloadProgress,
                    onLoad: { Task { await vm.loadLocalLLM() } }
                )
                
                modelRow(
                    label: "Embedder:",
                    name: vm.embeddingModelId,
                    isLoaded: vm.isEmbeddingLoaded,
                    progress: vm.embeddingDownloadProgress,
                    onLoad: { Task { await vm.loadEmbeddingModel() } }
                )
            } footer: {
                Text("Models run entirely on-device. Data never leaves your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section {
                LabeledContent("Vector Database:") {
                    Text("\(vm.vectorCount) vectors, \(vm.databaseSize)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppColor.colaBeige)
    }

    private var memoryTab: some View {
        MemoryDebugInspector(nodeStore: vm.nodeStore, userMemoryService: userMemoryService, telemetry: telemetry)
            .background(AppColor.colaBeige)
    }
    
    @ViewBuilder
    private func modelRow(
        label: String,
        name: String,
        isLoaded: Bool,
        progress: Double,
        onLoad: @escaping () -> Void
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .leading)
                
                if !isLoaded && progress > 0 {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else if isLoaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .help("Model is loaded in memory")
                } else {
                    Button("Download", action: onLoad)
                }
            }
        }
    }
}
