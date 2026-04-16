import SwiftUI

// MARK: - Welcome Home Screen
struct WelcomeView: View {
    @Binding var inputText: String
    let attachments: [AttachedFileContext]
    let onPickAttachment: () -> Void
    let onRemoveAttachment: (UUID) -> Void
    let onSend: () -> Void
    let onQuickActionSelected: (QuickActionMode) -> Void
    
    @AppStorage("nous.user.name") private var userName: String = "Alex"
    
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
        return trimmed.isEmpty ? "Alex" : trimmed.capitalized
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
                    VStack(spacing: 4) {
                        Text("NOUS")
                            .font(.system(size: 64, weight: .semibold, design: .rounded))
                            .foregroundColor(AppColor.colaOrange)

                        Text("\(greeting), \(displayName)")
                            .font(.system(size: 26, weight: .medium, design: .rounded))
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
                                            .fill(AppColor.surfaceSecondary)
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(AppColor.panelStroke, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: 520)
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 92)
                
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
            
            Circle()
                .fill(AppColor.colaOrange.opacity(0.10))
                .frame(width: 340, height: 340)
                .blur(radius: 140)
                .offset(x: -220, y: 220)
            
            Circle()
                .fill(AppColor.ambientHighlight)
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(x: 250, y: -200)
        }
    }
    
    private var composerRow: some View {
        HStack(spacing: 10) {
            circleActionButton(systemImage: "plus", action: onPickAttachment)
                .frame(width: 34, height: 34)

            HStack(spacing: 6) {
                TextField("What are we thinking about tonight?", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(1...3)
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
                    Circle()
                        .fill(AppColor.surfaceSecondary)
                )
                .overlay(
                    Circle()
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
