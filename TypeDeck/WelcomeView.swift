import SwiftUI

/// First-launch welcome: explains the app and offers the built-in decks as optional sample data.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
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
            AccuracyNotice()
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
            categories = Seed.categories(seed: model.seed)
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
                    Text("덱 \(c.decks.count)개 · \(c.cardCount.formatted())장")
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

/// This app drills cards into memory, so a wrong card does real harm. Said plainly on first launch.
struct AccuracyNotice: View {
    static let title = "틀린 내용을 외우지 않도록"
    static let lines = [
        "손으로 반복해 치면서 머리에 새기는 앱이라, 틀린 카드를 외우면 나중에 바로잡기가 훨씬 어려워요.",
        "예시 덱은 AI(Claude)가 만들고 검토한 자료예요. 틀린 곳이 있을 수 있으니 시험 대비라면 교재나 사전과 대조해 주세요.",
        "PDF로 만든 카드는 AI가 만든 초안이에요. 원문과 한 장씩 대조한 뒤 저장하세요.",
        "직접 만드는 카드는 교재, 공식 기출문제, 사전처럼 믿을 수 있는 자료에서 옮겨 적으세요.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(Self.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
            ForEach(Self.lines, id: \.self) { line in
                Text("· " + line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.accent.opacity(0.35)))
    }
}
