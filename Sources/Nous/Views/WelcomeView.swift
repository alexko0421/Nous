import SwiftUI

// MARK: - Welcome Home Screen
struct WelcomeView: View {
    @Binding var inputText: String
    let onSend: () -> Void
    var onModeSelected: ((ConversationMode) -> Void)?
    
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }
    
    let quickActions: [(icon: String, label: String)] = [
        ("building.2", "Business"),
        ("safari", "Direction"),
        ("brain", "Brain Storm"),
        ("heart.text.square", "Mental Health"),
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // ── NOUS Logo (ColaOS Style) ──
            VStack(spacing: 4) {
                Text("NOUS")
                    .font(.system(size: 72, weight: .semibold, design: .rounded))
                    .foregroundColor(AppColor.colaOrange)
                    .padding(.bottom, 4)

                // Greeting
                Text("\(greeting), Alex")
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)
            }
            .padding(.bottom, 40)
            
            // ── Large Input Box (Claude-style) ──
            VStack(alignment: .leading, spacing: 0) {
                // Text field area
                HStack(alignment: .top) {
                    TextField("How can I help you today?", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(AppColor.colaDarkText)
                        .lineLimit(1...5)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .onSubmit { onSend() }
                }
                
                // Bottom toolbar
                HStack {
                    Button(action: {}) {
                        Image(systemName: "plus")
                            .font(.system(size: 16))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                    
                    // Mic button
                    Button(action: {}) {
                        Image(systemName: "mic")
                            .font(.system(size: 15))
                            .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 48)
            .padding(.bottom, 20)
            
            // ── Quick Action Chips ──
            HStack(spacing: 10) {
                ForEach(quickActions, id: \.label) { action in
                    Button(action: {
                        let mode: ConversationMode = switch action.label {
                        case "Business": .business
                        case "Direction": .direction
                        case "Brain Storm": .brainstorm
                        case "Mental Health": .mentalHealth
                        default: .general
                        }
                        onModeSelected?(mode)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: action.icon)
                                .font(.system(size: 11))
                            Text(action.label)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(AppColor.colaDarkText.opacity(0.65))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 20)
            
            Spacer()
        }
    }
}
