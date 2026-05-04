import SwiftUI

enum WelcomeActionMenuHitRegion {
    static let composerHeight: CGFloat = 34
    static let actionMenuHeight: CGFloat = 62
    static let actionMenuGap: CGFloat = 8

    static var expandedHeight: CGFloat {
        composerHeight + max(
            ActionMenuPopoutMetrics.reservedTopPadding,
            actionMenuGap + actionMenuHeight
        )
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
    @FocusState private var isComposerFocused: Bool
    @Namespace private var composerPrimaryActionNamespace
    private let composerActionMotion = ComposerPrimaryActionMotion()
    
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

    private var shouldSeparateComposerPrimaryAction: Bool {
        ComposerSeparationPolicy.shouldSeparate(
            inputText: inputText,
            hasAttachments: !attachments.isEmpty,
            isGenerating: false
        )
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
                ZStack(alignment: .leading) {
                    RotatingComposerPromptLabel(
                        inputText: inputText,
                        isFocused: isComposerFocused
                    )

                    TextField("", text: $inputText, axis: .vertical)
                        .focused($isComposerFocused)
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .background(
                NativeGlassPanel(
                    cornerRadius: 18,
                    tintColor: AppColor.controlGlassTint
                ) { EmptyView() }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.panelStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 3)

            if shouldSeparateComposerPrimaryAction {
                primaryActionButton(isSeparated: true)
                    .transition(.scale(scale: 0.72, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(
            .timingCurve(0.68, -0.6, 0.32, 1.6, duration: 0.42),
            value: shouldSeparateComposerPrimaryAction
        )
    }

    private var welcomeComposerControls: some View {
        composerRow
            .frame(minHeight: WelcomeActionMenuHitRegion.composerHeight)
            .overlay(alignment: .bottomLeading) {
                ActionMenuCapsule(
                    isExpanded: isActionMenuExpanded,
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
                .offset(y: -ActionMenuPopoutMetrics.sourceOffsetFromRowBottom)
            }
        .padding(.top, isActionMenuExpanded ? ActionMenuPopoutMetrics.reservedTopPadding : 0)
        .frame(
            minHeight: isActionMenuExpanded
                ? WelcomeActionMenuHitRegion.expandedHeight
                : WelcomeActionMenuHitRegion.composerHeight,
            alignment: .bottomLeading
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isActionMenuExpanded)
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
                            : AppColor.controlGlassTint
                    ) { EmptyView() }
                )
                .overlay(
                    Circle()
                        .stroke(AppColor.panelStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func primaryActionButton(isSeparated: Bool) -> some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(isSeparated ? .white : AppColor.secondaryText)
                .opacity(composerActionMotion.iconOpacity(isSeparated: isSeparated))
        }
        .buttonStyle(.plain)
        .frame(width: 34, height: 34)
        .background(
            primaryActionBackground(isSeparated: isSeparated)
        )
        .overlay(
            primaryActionStroke(isSeparated: isSeparated)
        )
        .shadow(
            color: AppColor.colaOrange.opacity(composerActionMotion.glowOpacity(
                isSeparated: isSeparated,
                canAct: canSend
            )),
            radius: isSeparated ? 8 : 0,
            x: 0,
            y: isSeparated ? 2 : 0
        )
        .matchedGeometryEffect(id: "welcomePrimaryAction", in: composerPrimaryActionNamespace)
        .disabled(!canSend)
        .help("Send")
    }

    private func primaryActionBackground(isSeparated: Bool) -> some View {
        Group {
            if isSeparated {
                ZStack {
                    Circle()
                        .fill(AppColor.colaOrange.opacity(composerActionMotion.fillOpacity(
                            isSeparated: isSeparated,
                            canAct: canSend
                        )))

                    NativeGlassPanel(
                        cornerRadius: 17,
                        tintColor: primaryActionTint(isSeparated: isSeparated)
                    ) { EmptyView() }
                    .opacity(canSend ? 0.52 : 0.9)
                }
            } else {
                Circle()
                    .fill(Color.clear)
            }
        }
    }

    private func primaryActionStroke(isSeparated: Bool) -> some View {
        Group {
            if isSeparated {
                Circle()
                    .stroke(canSend ? Color.white.opacity(0.18) : AppColor.panelStroke, lineWidth: 1)
            } else {
                Circle()
                    .stroke(Color.clear, lineWidth: 1)
            }
        }
    }

    private func primaryActionTint(isSeparated: Bool) -> NSColor {
        let alpha = composerActionMotion.tintAlpha(isSeparated: isSeparated, canAct: canSend)
        return NSColor(red: 243/255, green: 131/255, blue: 53/255, alpha: alpha)
    }

}
struct QuickActionButton: View {
    let action: QuickActionMode
    let perform: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: action.icon)
                    .font(.system(size: 10.5, weight: .semibold))

                Text(action.label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundColor(isHovered ? AppColor.colaDarkText.opacity(0.92) : AppColor.secondaryText)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(height: 30)
            .background(
                NativeGlassPanel(cornerRadius: 16, tintColor: AppColor.controlGlassTint) {
                    if isHovered {
                        Capsule()
                            .fill(AppColor.colaOrange.opacity(0.035))
                    }
                }
                .clipShape(Capsule())
            )
            .overlay(
                Capsule()
                    .stroke(
                        isHovered ? AppColor.colaOrange.opacity(0.18) : AppColor.panelStroke.opacity(0.68),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
