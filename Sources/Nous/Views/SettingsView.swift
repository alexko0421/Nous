import SwiftUI

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel
    @State private var showMemoryInspector = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Title ──
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .padding(.top, 4)

                // ── LLM Provider ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("LLM Provider")

                        HStack(spacing: 10) {
                            ForEach(LLMProvider.allCases, id: \.self) { provider in
                                providerButton(provider)
                            }
                        }
                    }
                }

                // ── Provider-specific config ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        switch vm.selectedProvider {
                        case .local:
                            localModelSection
                        case .gemini:
                            apiKeySection(
                                label: "Gemini API Key",
                                placeholder: "AIza…",
                                binding: $vm.geminiApiKey
                            )
                        case .claude:
                            apiKeySection(
                                label: "Claude API Key",
                                placeholder: "sk-ant-…",
                                binding: $vm.claudeApiKey
                            )
                        case .openai:
                            apiKeySection(
                                label: "OpenAI API Key",
                                placeholder: "sk-…",
                                binding: $vm.openaiApiKey
                            )
                        }
                    }
                }

                // ── Embedding model ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Embedding Model")
                        modelRow(
                            name: vm.embeddingModelId,
                            isLoaded: vm.isEmbeddingLoaded,
                            progress: vm.embeddingDownloadProgress,
                            onLoad: {
                                Task { await vm.loadEmbeddingModel() }
                            }
                        )
                    }
                }

                // ── Vector DB stats ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Vector Database")
                        HStack {
                            Image(systemName: "cylinder.split.1x2")
                                .foregroundColor(AppColor.colaOrange)
                            Text("\(vm.vectorCount) vectors indexed")
                                .font(.system(size: 14, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.75))
                            Spacer()
                            Text(vm.databaseSize)
                                .font(.system(size: 13))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.45))
                        }
                    }
                }

                // ── Memory (debug) ──
                settingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionLabel("Memory (debug)")
                        HStack {
                            Text("Inspect what Nous has learned across scopes.")
                                .font(.system(size: 13, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.7))
                            Spacer()
                            Button("Open") { showMemoryInspector = true }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(AppColor.colaOrange)
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(AppColor.colaBeige)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .onAppear {
            vm.updateStats()
        }
        .sheet(isPresented: $showMemoryInspector) {
            MemoryDebugInspector(nodeStore: vm.nodeStore)
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
