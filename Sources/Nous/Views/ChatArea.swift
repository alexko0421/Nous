import SwiftUI

struct ChatMessage: Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

struct ChatArea: View {
    @Binding var isSidebarVisible: Bool
    @State private var inputText: String = ""
    @State private var messages: [ChatMessage] = []
    
    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                // ── Welcome / Home Screen ──
                WelcomeView(inputText: $inputText, onSend: sendMessage)
            } else {
                // ── Header (only shown in conversation) ──
                HStack {
                    Text("Nous")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(AppColor.colaDarkText)
                    Spacer()
                }
                .padding(.leading, 64)
                .padding(.trailing, 36)
                .padding(.top, 24)
                .padding(.bottom, 12)
                
                // ── Chat Log ──
                ScrollView {
                    VStack(spacing: 24) {
                        ForEach(messages) { msg in
                            MessageBubble(text: msg.text, isUser: msg.isUser)
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.bottom, 10)
                }
                
                // ── Input box (conversation mode) ──
                HStack(spacing: 12) {
                    TextField("...", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(AppColor.colaDarkText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .glassEffect(.regular, in: .capsule)
                        .onSubmit { sendMessage() }
                    
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
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
    
    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(text: trimmed, isUser: true))
        inputText = ""
        // Simulated reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            messages.append(ChatMessage(text: "I hear you. Let me think about that...", isUser: false))
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
                .font(.system(size: 13, weight: .regular, design: .default))
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
