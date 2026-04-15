import SwiftUI

struct ChatArea: View {
    @Bindable var vm: ChatViewModel
    @Bindable var settingsVM: SettingsViewModel
    @Binding var isSidebarVisible: Bool

    var body: some View {
        VStack(spacing: 0) {
            if vm.messages.isEmpty && vm.currentNode == nil {
                WelcomeView(
                    inputText: $vm.inputText,
                    onSend: { Task { await vm.send() } },
                    onModeSelected: { mode in vm.startWithMode(mode) }
                )
            } else {
                // Header
                HStack {
                    Text(vm.currentNode?.title ?? "Nous")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                        .lineLimit(1)
                    Spacer()
                    if !vm.messages.isEmpty {
                        Button(action: { Task { await vm.exportMarkdown() } }) {
                            Image(systemName: vm.isExporting ? "ellipsis.circle" : "doc.text")
                                .font(.system(size: 14))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                                .symbolEffect(.rotate, isActive: vm.isExporting)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isExporting)
                        .help("Summarize as Markdown")
                    }
                    if vm.usageTracker.sessionCost > 0 {
                        Text(vm.usageTracker.formattedCost)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.4))
                    }
                }
                .padding(.leading, 64)
                .padding(.trailing, 36)
                .padding(.top, 36)
                .padding(.bottom, 12)

                // Chat log
                ScrollView {
                    VStack(spacing: 24) {
                        ForEach(vm.messages) { msg in
                            MessageBubble(text: msg.content, isUser: msg.role == .user)
                        }
                        if vm.isGenerating && vm.currentResponse.isEmpty {
                            ThinkingIndicator()
                        }
                        if vm.isGenerating && !vm.currentResponse.isEmpty {
                            MessageBubble(text: vm.currentResponse, isUser: false)
                        }
                        if !vm.citations.isEmpty {
                            RAGCitationView(citations: vm.citations, onTap: { _ in })
                                .padding(.horizontal, 36)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 10)
                }

                // Input
                HStack(spacing: 12) {
                    TextField("...", text: $vm.inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(AppColor.colaDarkText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .glassEffect(.regular, in: .capsule)
                        .onSubmit { Task { await vm.send() } }

                    Button(action: { Task { await vm.send() } }) {
                        Image(systemName: vm.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(AppColor.colaOrange)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.colaBeige)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay(alignment: .top) {
            // Invisible drag handle at top of window for moving
            WindowDragHandle()
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .overlay(alignment: .topLeading) {
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isSidebarVisible.toggle()
                }
            }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 16))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.5))
            }
            .buttonStyle(.plain)
            .padding(.top, 24)
            .padding(.leading, 24)
        }
    }
}

struct MessageBubble: View {
    let text: String
    let isUser: Bool

    var body: some View {
        HStack {
            if isUser { Spacer() }
            Text(text)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(AppColor.colaDarkText)
                .lineSpacing(4)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isUser ? AppColor.colaBubble : AppColor.colaOrange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            if !isUser { Spacer() }
        }
    }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = WindowDragView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct ThinkingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(AppColor.colaOrange)
                        .frame(width: 8, height: 8)
                        .scaleEffect(dotScale(for: i))
                        .opacity(dotOpacity(for: i))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppColor.colaOrange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func dotScale(for index: Int) -> CGFloat {
        let delay = Double(index) * 0.2
        let progress = max(0, min(1, phase - delay))
        return 0.6 + 0.4 * progress
    }

    private func dotOpacity(for index: Int) -> Double {
        let delay = Double(index) * 0.2
        let progress = max(0, min(1, phase - delay))
        return 0.4 + 0.6 * progress
    }
}
