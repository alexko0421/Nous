import SwiftUI

enum WelcomeActionMenuHitRegion {
    static let composerHeight: CGFloat = 34
    static let actionMenuHeight: CGFloat = 62
    static let actionMenuGap: CGFloat = 8

    static var expandedHeight: CGFloat {
        composerHeight + actionMenuGap + actionMenuHeight
    }
}

// MARK: - Welcome Home Screen
struct WelcomeView: View {
    @Binding var inputText: String
    let attachments: [AttachedFileContext]
    let onPickAttachment: () -> Void
    let onPickPhoto: () -> Void
    let onVoice: () -> Void
    let canPickPhoto: Bool
    let isVoiceActive: Bool
    let onRemoveAttachment: (UUID) -> Void
    let onSend: () -> Void
    let onImageDrop: ([NSItemProvider]) -> Bool
    let onQuickActionSelected: (QuickActionMode) -> Void
    
    @AppStorage("nous.username") private var userName: String = "ALEX"
    @State private var isImageDropTargeted = false
    @State private var isActionMenuExpanded = false
    
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

                        welcomeComposerControls
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .onDrop(
                            of: AttachmentDropSupport.acceptedTypeIdentifiers,
                            isTargeted: $isImageDropTargeted,
                            perform: onImageDrop
                        )
                        .overlay {
                            if isImageDropTargeted {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(AppColor.colaOrange.opacity(0.55), lineWidth: 1.5)
                            }
                        }

                        HStack(spacing: 10) {
                            ForEach(quickActions, id: \.rawValue) { action in
                                QuickActionButton(action: action) {
                                    onQuickActionSelected(action)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 520)
                }
                .padding(.horizontal, 48)
                .padding(.bottom, 24)

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
            circleActionButton(
                systemImage: isVoiceActive ? "mic.fill" : (isActionMenuExpanded ? "xmark" : "plus"),
                isVoiceActive: isVoiceActive,
                action: {
                    if isVoiceActive {
                        onVoice()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isActionMenuExpanded.toggle()
                        }
                    }
                }
            )
            .frame(width: 34, height: 34)

            HStack(spacing: 6) {
                TextField("What are we thinking about tonight?", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .onSubmit { onSend() }
                    .onChange(of: inputText) { _, _ in
                        if isActionMenuExpanded {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isActionMenuExpanded = false
                            }
                        }
                    }
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

    private var welcomeComposerControls: some View {
        VStack(alignment: .leading, spacing: WelcomeActionMenuHitRegion.actionMenuGap) {
            if isActionMenuExpanded {
                ActionMenuCapsule(
                    onFile: {
                        onPickAttachment()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isActionMenuExpanded = false }
                    },
                    onPhoto: {
                        onPickPhoto()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isActionMenuExpanded = false }
                    },
                    onVoice: {
                        onVoice()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isActionMenuExpanded = false }
                    },
                    canPickPhoto: canPickPhoto
                )
                .frame(height: WelcomeActionMenuHitRegion.actionMenuHeight)
                .transition(
                    .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.9, anchor: .bottomLeading))
                )
            }

            composerRow
                .frame(minHeight: WelcomeActionMenuHitRegion.composerHeight)
        }
        .frame(
            minHeight: isActionMenuExpanded
                ? WelcomeActionMenuHitRegion.expandedHeight
                : WelcomeActionMenuHitRegion.composerHeight,
            alignment: .bottomLeading
        )
    }

    private func circleActionButton(systemImage: String, isVoiceActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isVoiceActive ? AppColor.colaOrange : AppColor.secondaryText)
                .frame(width: 32, height: 32)
                .rotationEffect(.degrees(isActionMenuExpanded && !isVoiceActive ? 90 : 0))
                .background(
                    NativeGlassPanel(
                        cornerRadius: 16,
                        tintColor: isVoiceActive
                            ? NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: 0.22)
                            : AppColor.glassTint
                    ) { EmptyView() }
                )
                .overlay(
                    Circle()
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
struct QuickActionButton: View {
    let action: QuickActionMode
    let perform: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: action.icon)
                    .font(.system(size: 11, weight: .medium))

                Text(action.label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundColor(isHovered ? AppColor.colaDarkText : AppColor.secondaryText)
            .padding(.horizontal, 12) // Slightly reduced from 14
            .padding(.vertical, 7)    // Slightly reduced from 8
            .background(
                NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.glassTint) {
                    if isHovered {
                        Capsule()
                            .fill(AppColor.colaDarkText.opacity(0.04))
                    }
                }
                .clipShape(Capsule())
            )
            .overlay(
                Capsule()
                    .stroke(isHovered ? AppColor.colaOrange.opacity(0.3) : AppColor.panelStroke, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
