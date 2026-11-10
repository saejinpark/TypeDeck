import SwiftUI

/// First-launch welcome: explains the app and offers the built-in decks as optional sample data.
struct DeckPickerView: View {
    @Environment(AppModel.self) private var model
    let mode: DeckPickerMode
    @State private var chosen: Set<String> = []
    @State private var categories: [Seed.Category] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text("TypeDeck에 오신 걸 환영해요")
                        .font(.title2.weight(.bold))
                    Text("외울 것을 카드로 만들어 손으로 치면서 익혀요. 키를 보고 값을 치면 바로 다음 카드로 넘어가요. 자격증, 외국어, 용어처럼 공부할 주제마다 카테고리를 만들고 덱으로 정리하세요.\n\n먼저 써 볼 수 있게 예시 덱을 넣어 둘까요?")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 6) {
                ForEach(categories) { c in
                    row(c)
                }
            }
            HStack {
                Spacer()
                Button("빈 상태로 시작") { model.finishWelcome(sampleCategories: []) }
                Button(chosen.isEmpty ? "빈 상태로 시작" : "예시 넣고 시작") {
                    model.finishWelcome(sampleCategories: chosen)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled()
        .onAppear {
            categories = Seed.categories(seed: model.seed, decks: model.decks)
            chosen = Set(categories.map(\.category))
        }
    }

    private func row(_ c: Seed.Category) -> some View {
        let on = chosen.contains(c.category)
        return Button {
            if on { chosen.remove(c.category) } else { chosen.insert(c.category) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17))
                    .foregroundStyle(on ? Palette.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.category.isEmpty ? Seed.uncategorized : c.category)
                        .font(.system(size: 14, weight: .semibold))
                    Text("덱 \(c.decks.count)개 · \(c.words.formatted())장" + (c.decks.contains { $0.cards.contains { !$0.note.isEmpty } } ? " · 해설 포함" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Palette.accent.opacity(0.12) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Palette.accent : Color.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
