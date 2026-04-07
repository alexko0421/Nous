import SwiftUI

struct NoteEditor: View {
    @Bindable var vm: NoteViewModel
    var onNavigateToNode: ((NousNode) -> Void)?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        if let note = vm.currentNote {
            editorView(note: note)
        } else {
            NoteListView(vm: vm)
        }
    }

    @ViewBuilder
    private func editorView(note: NousNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // Title
            TextField("Title", text: $vm.title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 8)

            // Metadata row
            HStack(spacing: 8) {
                if let project = vm.currentProject {
                    Text(project.emoji)
                        .font(.system(size: 13))
                }
                Text(Self.dateFormatter.string(from: note.updatedAt))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.45))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            // Content editor
            TextEditor(text: $vm.content)
                .font(.system(size: 14))
                .foregroundColor(AppColor.colaDarkText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 20)
                .onChange(of: vm.content) { _, _ in
                    vm.onContentChanged()
                }

            // Related nodes panel
            if !vm.relatedNodes.isEmpty {
                relatedPanel
            }
        }
        .background(AppColor.colaBeige)
    }

    private var relatedPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.5))
                .padding(.horizontal, 24)

            VStack(spacing: 6) {
                ForEach(vm.relatedNodes.prefix(3), id: \.node.id) { result in
                    Button {
                        onNavigateToNode?(result.node)
                    } label: {
                        HStack {
                            Text(result.node.title)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(AppColor.colaDarkText.opacity(0.85))
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(result.similarity * 100))%")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundColor(AppColor.colaOrange)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 12)
        .background(
            Color.white.opacity(0.4)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 12)
        )
        .padding(.bottom, 16)
    }

}
