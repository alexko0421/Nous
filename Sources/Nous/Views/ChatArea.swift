import SwiftUI
import UniformTypeIdentifiers

struct ChatArea: View {
    @Bindable var vm: ChatViewModel
    @Binding var isSidebarVisible: Bool
    @State private var isFileImporterPresented = false
    @State private var attachedFiles: [URL] = []

    var body: some View {
        VStack(spacing: 0) {
            if vm.messages.isEmpty && vm.currentNode == nil {
                WelcomeView(onQuickAction: { vm.inputText = $0 }) {
                    composer
                }
            } else {
                HStack {
                    Text(vm.currentNode?.title ?? "Nous")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.leading, 64)
                .padding(.trailing, 36)
                .padding(.top, 36)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 24) {
                        ForEach(vm.messages) { msg in
                            MessageBubble(text: msg.content, isUser: msg.role == .user)
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

                composer
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.colaBeige)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
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
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .onChange(of: vm.currentNode?.id) { _, _ in
            attachedFiles = []
        }
    }

    private var composer: some View {
        ChatComposer(
            text: $vm.inputText,
            attachments: attachedFiles,
            isGenerating: vm.isGenerating,
            onPickFiles: { isFileImporterPresented = true },
            onRemoveAttachment: removeAttachment,
            onSend: { Task { await handleSend() } }
        )
    }

    private func handleSend() async {
        let query = vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = attachedFiles.map(makeAttachmentContext(from:))
        guard !query.isEmpty || !attachments.isEmpty else { return }
        await vm.send(attachments: attachments)
        attachedFiles = []
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls where !attachedFiles.contains(url) {
            attachedFiles.append(url)
        }
    }

    private func removeAttachment(_ url: URL) {
        attachedFiles.removeAll { $0 == url }
    }

    private func makeAttachmentContext(from url: URL) -> AttachedFileContext {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return AttachedFileContext(
            name: url.lastPathComponent,
            extractedText: extractText(from: url)
        )
    }

    private func extractText(from url: URL) -> String? {
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > 200_000 {
            return nil
        }

        var encoding = String.Encoding.utf8
        guard let text = try? String(contentsOf: url, usedEncoding: &encoding) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
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
