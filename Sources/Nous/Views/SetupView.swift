import SwiftUI

// MARK: - Setup Step

private enum SetupStep {
    case welcome, embedding, llm, done
}

// MARK: - SetupView

struct SetupView: View {
    @Binding var isSetupComplete: Bool
    let embeddingService: EmbeddingService
    let settingsVM: SettingsViewModel

    @State private var step: SetupStep = .welcome

    var body: some View {
        ZStack {
            AppColor.colaBeige
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))

            Group {
                switch step {
                case .welcome:
                    WelcomeStepView(step: $step)
                case .embedding:
                    EmbeddingStepView(step: $step, embeddingService: embeddingService)
                case .llm:
                    LLMStepView(step: $step, settingsVM: settingsVM)
                case .done:
                    DoneStepView(isSetupComplete: $isSetupComplete)
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
        }
        .frame(width: 500, height: 400)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
    }
}

// MARK: - Welcome Step

private struct WelcomeStepView: View {
    @Binding var step: SetupStep

    var body: some View {
        VStack(spacing: 24) {
            Text("NOUS")
                .font(.custom("FredokaOne-Regular", size: 56))
                .foregroundColor(AppColor.colaOrange)

            VStack(spacing: 8) {
                Text("Welcome to Nous")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)

                Text("Your personal knowledge universe.\nLet's set up your AI models.")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            OrangeCapsuleButton(title: "Get Started") {
                step = .embedding
            }
        }
        .padding(40)
    }
}

// MARK: - Embedding Step

private struct EmbeddingStepView: View {
    @Binding var step: SetupStep
    let embeddingService: EmbeddingService

    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Downloading Embedding Model")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)

                Text("~274 MB download")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.55))
            }

            if isDownloading || embeddingService.isLoading {
                VStack(spacing: 10) {
                    ProgressView(value: embeddingService.downloadProgress)
                        .progressViewStyle(.linear)
                        .tint(AppColor.colaOrange)
                        .frame(width: 300)

                    Text("\(Int(embeddingService.downloadProgress * 100))%")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if !isDownloading && !embeddingService.isLoading {
                OrangeCapsuleButton(title: embeddingService.isLoaded ? "Continue" : "Download") {
                    if embeddingService.isLoaded {
                        step = .llm
                    } else {
                        startDownload()
                    }
                }
            } else {
                // Show a disabled-looking button while downloading
                Text("Downloading…")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(AppColor.colaOrange.opacity(0.5))
                    .clipShape(Capsule())
            }

            Button("Skip for now") {
                step = .llm
            }
            .font(.system(size: 13, design: .rounded))
            .foregroundColor(AppColor.colaDarkText.opacity(0.45))
            .buttonStyle(.plain)
        }
        .padding(40)
    }

    private func startDownload() {
        isDownloading = true
        errorMessage = nil
        Task {
            do {
                try await embeddingService.loadModel()
                await MainActor.run {
                    isDownloading = false
                    step = .llm
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - LLM Step

private struct LLMStepView: View {
    @Binding var step: SetupStep
    let settingsVM: SettingsViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Choose Your AI")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)

            VStack(spacing: 10) {
                ProviderCard(
                    title: "Local Model (Llama 3.2 3B)",
                    subtitle: "Runs on your Mac, no internet needed"
                ) {
                    settingsVM.selectedProvider = .local
                    settingsVM.savePreferences()
                    step = .done
                }

                ProviderCard(
                    title: "Claude API",
                    subtitle: "Anthropic's powerful Claude models"
                ) {
                    settingsVM.selectedProvider = .claude
                    settingsVM.savePreferences()
                    step = .done
                }

                ProviderCard(
                    title: "OpenAI API",
                    subtitle: "GPT-4 and other OpenAI models"
                ) {
                    settingsVM.selectedProvider = .openai
                    settingsVM.savePreferences()
                    step = .done
                }
            }
            .frame(maxWidth: 360)

            Button("Skip for now") {
                step = .done
            }
            .font(.system(size: 13, design: .rounded))
            .foregroundColor(AppColor.colaDarkText.opacity(0.45))
            .buttonStyle(.plain)
        }
        .padding(40)
    }
}

// MARK: - Provider Card

private struct ProviderCard: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                    Text(subtitle)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColor.colaOrange)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(isHovered ? AppColor.colaOrange.opacity(0.08) : AppColor.colaBubble)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isHovered ? AppColor.colaOrange.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Done Step

private struct DoneStepView: View {
    @Binding var isSetupComplete: Bool

    var body: some View {
        VStack(spacing: 24) {
            Text("🎉")
                .font(.system(size: 56))

            Text("You're all set!")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)

            OrangeCapsuleButton(title: "Enter Nous") {
                UserDefaults.standard.set(true, forKey: "nous.setup.complete")
                isSetupComplete = true
            }
        }
        .padding(40)
    }
}

// MARK: - Shared Components

private struct OrangeCapsuleButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(AppColor.colaOrange)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
