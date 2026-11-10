import SwiftUI

/// Chooses which built-in TOEIC decks to add: the welcome sheet on first launch, or
/// "기본 덱 추가" later.
struct DeckPickerView: View {
    @Environment(AppModel.self) private var model
    let mode: DeckPickerMode
    @State private var chosen: Set<String> = []
    @State private var categories: [Seed.Category] = []

    private var firstRun: Bool { mode == .welcome }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text(firstRun ? "TypeDeck에 오신 걸 환영해요" : "기본 덱 추가")
                        .font(.title2.weight(.bold))
                    Text(firstRun
                         ? "카드에 나온 단어의 뜻을 치면 바로 다음 카드로 넘어가요. 토익 영단어 덱을 넣어 드릴까요? 나중에 사이드바 아래 '기본 덱 추가'에서 언제든 넣을 수 있어요."
                         : "넣을 토익 덱을 고르세요. 이미 있는 덱은 그대로 두고 빠진 덱만 넣어요.")
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
                Button(firstRun ? "빈 상태로 시작" : "취소") {
                    if firstRun { model.addBuiltIn(categories: [], firstRun: true) } else { model.deckPicker = nil }
                }
                .keyboardShortcut(firstRun ? nil : .cancelAction)
                Button(okTitle) { model.addBuiltIn(categories: chosen, firstRun: firstRun) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!firstRun && chosen.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(firstRun)
        .onAppear {
            categories = Seed.categories(seed: model.seed, decks: model.decks)
            chosen = Set(categories.filter { !$0.missing.isEmpty }.map(\.category))
        }
    }

    private var okTitle: String {
        if firstRun { return chosen.isEmpty ? "빈 상태로 시작" : "선택한 덱으로 시작" }
        return "추가"
    }

    private func row(_ c: Seed.Category) -> some View {
        let complete = c.missing.isEmpty
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
                    Text("덱 \(c.decks.count)개 · \(c.words.formatted())단어")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if complete {
                    Text("모두 있음").font(.caption).foregroundStyle(.secondary)
                } else if c.missing.count < c.decks.count {
                    Text("\(c.missing.count)개 빠짐").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Palette.accent.opacity(0.12) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Palette.accent : Color.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .disabled(complete)
        .opacity(complete ? 0.55 : 1)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
