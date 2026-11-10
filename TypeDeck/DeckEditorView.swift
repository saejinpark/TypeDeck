import SwiftUI

struct DeckEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var name = ""
    @State private var text = ""
    @State private var confirmDelete = false

    private var deckID: String? {
        if case .deck(let id) = target { return id }
        return nil
    }

    var body: some View {
        let count = Core.parseCards(text).count
        VStack(alignment: .leading, spacing: 14) {
            Text(deckID == nil ? "새 덱" : "덱 편집").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Text("이름").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("덱 이름", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("카드").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(count)장").font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                }
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("한 줄에 카드 하나: 키 = 값\n대한민국 = 서울\n404 = Not Found\n\n탭, =, : 로 나눠도 됩니다.\n스프레드시트 두 열을 그대로 붙여 넣어도 돼요.")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }
            HStack {
                if deckID != nil {
                    Button("덱 삭제", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") {
                    model.upsert(id: deckID, name: name, cards: Core.parseCards(text))
                    dismiss()
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560, height: 520)
        .onAppear {
            if let id = deckID, let deck = model.decks.first(where: { $0.id == id }) {
                name = deck.name
                text = Core.serialize(deck.cards)
            }
        }
        .confirmationDialog("'\(name)' 덱을 삭제할까요?", isPresented: $confirmDelete) {
            Button("삭제", role: .destructive) {
                if let id = deckID { model.delete(id) }
                dismiss()
            }
        } message: {
            Text("되돌릴 수 없어요.")
        }
    }
}
