import SwiftUI

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel
    @AppStorage("nous.user.name") private var userName: String = "ALEX"

    var body: some View {
        TabView {
            generalSection
                .tabItem {
                    Label("General", systemImage: "person.crop.circle")
                }
            
            aiSection
                .tabItem {
                    Label("AI Models", systemImage: "brain")
                }
            
            storageSection
                .tabItem {
                    Label("Data", systemImage: "internaldrive")
                }
        }
        .frame(minWidth: 450, minHeight: 400)
        .background(AppColor.colaBeige.opacity(0.5))
    }

    private var generalSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("General Settings")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .padding(.bottom, 10)

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("User Profile")
                        
                        HStack(spacing: 16) {
                            Circle()
                                .fill(AppColor.colaOrange.opacity(0.15))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text(String(userName.prefix(1)))
                                        .font(.system(size: 20, weight: .bold, design: .rounded))
                                        .foregroundColor(AppColor.colaOrange)
                                )
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Display Name")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppColor.colaDarkText)
                                
                                TextField("Enter your name", text: $userName)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 14))
                                    .foregroundColor(AppColor.colaDarkText.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .onSubmit { vm.savePreferences() }
                            }
                        }
                    }
                }
                
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("App Identity")
                        Text("Nous is your personal second brain.")
                            .font(.system(size: 13))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                        
                        Text("Version 1.0.0 (Build 2026)")
                            .font(.system(size: 11))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.4))
                    }
                }
            }
            .padding(24)
        }
    }

    private var aiSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("AI & Intelligence")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .padding(.bottom, 10)

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Inference Provider")
                        
                        HStack(spacing: 10) {
                            ForEach(LLMProvider.allCases, id: \.self) { provider in
                                providerButton(provider)
                            }
                        }
                    }
                }

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        switch vm.selectedProvider {
                        case .local:
                            localModelSection
                        case .gemini:
                            apiKeySection(label: "Gemini API Key", placeholder: "AIza…", binding: $vm.geminiApiKey)
                        case .claude:
                            apiKeySection(label: "Claude API Key", placeholder: "sk-ant-…", binding: $vm.claudeApiKey)
                        case .openai:
                            apiKeySection(label: "OpenAI API Key", placeholder: "sk-…", binding: $vm.openaiApiKey)
                        }
                    }
                }
                
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Embedding Model")
                        modelRow(
                            name: vm.embeddingModelId,
                            isLoaded: vm.isEmbeddingLoaded,
                            progress: vm.embeddingDownloadProgress,
                            onLoad: { Task { await vm.loadEmbeddingModel() } }
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    private var storageSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Data & Storage")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .padding(.bottom, 10)

                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Knowledge Graph (Galaxy)")
                        HStack {
                            Image(systemName: "cylinder.split.1x2")
                                .foregroundColor(AppColor.colaOrange)
                            Text("\(vm.vectorCount) semantic vectors")
                                .font(.system(size: 14, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.75))
                            Spacer()
                            Text(vm.databaseSize)
                                .font(.system(size: 13))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.45))
                        }
                    }
                }
                
                Button(role: .destructive, action: {}) {
                    Label("Clear Global Index", systemImage: "trash")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .opacity(0.5)
            }
            .padding(24)
        }
        .onAppear {
            vm.updateStats()
        }
    }

    // MARK: - Provider button

    @ViewBuilder
    private func providerButton(_ provider: LLMProvider) -> some View {
        let selected = vm.selectedProvider == provider
        Button {
            vm.selectedProvider = provider
            vm.savePreferences()
        } label: {
            Text(providerShortName(provider))
                .font(.system(size: 13, weight: selected ? .semibold : .regular, design: .rounded))
                .foregroundColor(selected ? .white : AppColor.colaDarkText.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? AppColor.colaOrange : Color.white.opacity(0.6))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            selected ? AppColor.colaOrange : AppColor.colaDarkText.opacity(0.1),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func providerShortName(_ provider: LLMProvider) -> String {
        switch provider {
        case .local:  return "Local"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        }
    }

    // MARK: - Local model section

    @ViewBuilder
    private var localModelSection: some View {
        sectionLabel("Local Model")
        modelRow(
            name: vm.localModelId,
            isLoaded: vm.isLLMLoaded,
            progress: vm.llmDownloadProgress,
            onLoad: {
                Task { await vm.loadLocalLLM() }
            }
        )
    }

    // MARK: - API key section

    @ViewBuilder
    private func apiKeySection(label: String, placeholder: String, binding: Binding<String>) -> some View {
        sectionLabel(label)
        SecureField(placeholder, text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(AppColor.colaDarkText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppColor.colaDarkText.opacity(0.08), lineWidth: 1)
            )
            .onSubmit { vm.savePreferences() }
    }

    // MARK: - Model row

    @ViewBuilder
    private func modelRow(
        name: String,
        isLoaded: Bool,
        progress: Double,
        onLoad: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !isLoaded && progress > 0 {
                    ProgressView(value: progress)
                        .tint(AppColor.colaOrange)
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer()

            if isLoaded {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
                    .labelStyle(.iconOnly)
            } else {
                Button(action: onLoad) {
                    Text(progress > 0 ? "Downloading…" : "Download")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AppColor.colaOrange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(progress > 0)
            }
        }
    }

    // MARK: - Reusable card

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .background(Color.white.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppColor.colaDarkText.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 2)
    }

    // MARK: - Section label

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(AppColor.colaDarkText.opacity(0.45))
            .textCase(.uppercase)
            .tracking(0.6)
    }
}
