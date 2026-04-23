import SwiftUI

// MARK: - Welcome Home Screen
struct WelcomeView: View {
    @Binding var inputText: String
    let attachments: [AttachedFileContext]
    let onPickAttachment: () -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onSend: () -> Void
    let onQuickActionSelected: (QuickActionMode) -> Void
    
    @AppStorage("nous.username") private var userName: String = "ALEX"
    
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
    
    private var displayName: String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Alex" : trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
    }
    
    let quickActions = QuickActionMode.allCases

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }
    
    var body: some View {
        ZStack {
            backgroundLayer
            
            VStack {
                Spacer(minLength: 0)
                
                VStack(spacing: 30) {
                    VStack(spacing: 20) {
                        NOUSLogoView(logoColor: AppColor.colaOrange)
                            .frame(width: 200)

                        Text("\(greeting), \(displayName)")
                            .font(.system(size: 34, weight: .medium, design: .rounded))
                            .foregroundColor(AppColor.colaDarkText)
                            .multilineTextAlignment(.center)
                    }
                    
                    VStack(spacing: 16) {
                        if !attachments.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(attachments) { attachment in
                                        AttachmentChip(attachment: attachment) {
                                            onRemoveAttachment(attachment.id)
                                        }
                                    }
                                }
                            }
                        }

                        composerRow

                        HStack(spacing: 10) {
                            ForEach(quickActions, id: \.rawValue) { action in
                                Button(action: {
                                    onQuickActionSelected(action)
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: action.icon)
                                            .font(.system(size: 11, weight: .medium))

                                        Text(action.label)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                    }
                                    .foregroundColor(AppColor.secondaryText)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(Color(AppColor.glassTint))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(AppColor.panelStroke, lineWidth: 0.5)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: 520)
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 44) // Reduced from 92 to lower the UI slightly, keeping it comfortably above center
                
                Spacer(minLength: 0)
            }
        }
    }
    
    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [AppColor.welcomeGradientStart, AppColor.welcomeGradientEnd],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            circleActionButton(systemImage: "plus", action: onPickAttachment)
                .frame(width: 34, height: 34)

            HStack(spacing: 6) {
                TextField("What are we thinking about tonight?", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .onSubmit { onSend() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                NativeGlassPanel(
                    cornerRadius: 18,
                    tintColor: AppColor.glassTint
                ) { EmptyView() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 3)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .frame(width: 34, height: 34)
            .background(
                NativeGlassPanel(
                    cornerRadius: 17,
                    tintColor: canSend 
                        ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.88)
                        : NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.18)
                ) { EmptyView() }
            )
            .overlay(
                Circle()
                    .stroke(canSend ? Color.white.opacity(0.18) : AppColor.panelStroke, lineWidth: 1)
            )
            .disabled(!canSend)
        }
    }

    private func circleActionButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppColor.secondaryText)
                .frame(width: 32, height: 32)
                .background(
                    NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.glassTint) { EmptyView() }
                )
                .overlay(
                    Circle()
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
