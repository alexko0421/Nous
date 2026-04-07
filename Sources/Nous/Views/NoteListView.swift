import SwiftUI

struct NoteListView: View {
    @Bindable var vm: NoteViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Text("Notes")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText)

                Spacer()

                Button {
                    try? vm.createNote()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppColor.colaOrange)
                        .frame(width: 32, height: 32)
                        .background(AppColor.colaOrange.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // List
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(vm.notes) { note in
                        NoteCard(note: note)
                            .onTapGesture {
                                vm.openNote(note)
                            }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(AppColor.colaBeige)
        .onAppear {
            vm.loadNotes()
        }
    }
}

// MARK: - Note Card

private struct NoteCard: View {
    let note: NousNode

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(AppColor.colaDarkText)
                .lineLimit(1)

            if !note.content.isEmpty {
                Text(String(note.content.prefix(80)))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(AppColor.colaDarkText.opacity(0.6))
                    .lineLimit(2)
            }

            Text(Self.dateFormatter.string(from: note.updatedAt))
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(AppColor.colaDarkText.opacity(0.4))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
