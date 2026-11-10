import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: Deck?
    @State private var pendingCategory: String?
    @State private var categoryName = ""
    @State private var categoryProblem: String?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            PracticeView()
        }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.pdf, .text]) { result in
            if case .success(let url) = result { model.importFile(at: url) }
        }
        .overlay {
            if let status = model.importStatus { ImportProgressPanel(status: status) }
        }
        .alert(categoryPromptTitle,
               isPresented: Binding(get: { model.categoryPrompt != nil }, set: { if !$0 { model.categoryPrompt = nil } })) {
            TextField("예: 정보처리기사", text: $categoryName)
            Button(model.categoryPrompt == .new ? "만들기" : "바꾸기") { commitCategory() }
            Button("취소", role: .cancel) { model.categoryPrompt = nil; model.refocus() }
        } message: {
            Text(model.categoryPrompt == .new ? "공부할 주제마다 카테고리를 만들고 덱으로 정리하세요." : "덱은 그대로 두고 카테고리 이름만 바꿔요.")
        }
        .onChange(of: model.categoryPrompt) {
            if case .rename(let c) = model.categoryPrompt { categoryName = c } else if model.categoryPrompt == .new { categoryName = "" }
        }
        .alert("카테고리", isPresented: Binding(get: { categoryProblem != nil }, set: { if !$0 { categoryProblem = nil } })) {
            Button("확인") { categoryProblem = nil }
        } message: {
            Text(categoryProblem ?? "")
        }
        .alert("자료로 덱을 만들지 못했어요",
               isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) {
            Button("확인") { model.importError = nil; model.refocus() }
        } message: {
            Text(model.importError ?? "")
        }
        .sheet(item: $model.editorTarget, onDismiss: { model.refocus() }) { target in
            DeckEditorView(target: target)
                .id(target)
        }
        .sheet(isPresented: $model.showWelcome, onDismiss: { model.refocus() }) {
            WelcomeView()
        }
        .confirmationDialog(
            "'\(pendingDelete?.name ?? "")' 덱을 삭제할까요?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { deck in
            Button("삭제", role: .destructive) { model.delete(deck.id); model.refocus() }
        } message: { deck in
            Text("되돌릴 수 없어요.")
        }
        .confirmationDialog(
            categoryDeleteTitle,
            isPresented: Binding(get: { pendingCategory != nil }, set: { if !$0 { pendingCategory = nil } }),
            presenting: pendingCategory
        ) { category in
            let empty = !model.decks.contains { $0.category.cleanedCategory == category }
            Button(empty ? "삭제" : "모두 삭제", role: .destructive) { model.deleteCategory(category); model.refocus() }
        } message: { category in
            let list = model.decks.filter { $0.category.cleanedCategory == category }
            if list.isEmpty {
                Text("덱이 없는 카테고리예요.")
            } else {
                Text("되돌릴 수 없어요.")
            }
        }
    }

    private var categoryDeleteTitle: String {
        guard let c = pendingCategory else { return "" }
        let n = model.decks.filter { $0.category.cleanedCategory == c }.count
        let label = c.isEmpty ? Seed.uncategorized : c
        return n == 0 ? "빈 카테고리 '\(label)'를 삭제할까요?" : "'\(label)' 카테고리와 그 안의 덱 \(n)개를 모두 삭제할까요?"
    }

    private var categoryPromptTitle: String {
        switch model.categoryPrompt {
        case .rename(let c): return "'\(c.isEmpty ? Seed.uncategorized : c)' 이름 바꾸기"
        default: return "새 카테고리"
        }
    }

    private func commitCategory() {
        let problem: String?
        switch model.categoryPrompt {
        case .new: problem = model.createCategory(categoryName)
        case .rename(let from): problem = model.renameCategory(from, to: categoryName)
        case nil: problem = nil
        }
        model.categoryPrompt = nil
        if let problem { categoryProblem = problem } else { model.refocus() }
    }

    private func deckRow(_ deck: Deck) -> some View {
        let m = model.mastery(of: deck)
        return HStack {
            Text(deck.name).lineLimit(1)
            Spacer()
            Text(m.mastered > 0 ? "\(m.mastered)/\(m.total)" : "\(m.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        // A thin bar of the memorized share.
        .overlay(alignment: .bottomLeading) {
            GeometryReader { geo in
                Capsule().fill(Palette.accent.opacity(0.75))
                    .frame(width: geo.size.width * share(m), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .offset(y: 3)
            .allowsHitTesting(false)
        }
        .padding(.leading, 18)
        .modifier(HoverActions(actions: [.init(icon: "trash", label: "'\(deck.name)' 덱 삭제") { pendingDelete = deck }]))
        .tag(deck.id)
        .contextMenu {
            Button("편집…") { model.editorTarget = .deck(deck.id) }
            Button("삭제…", role: .destructive) { pendingDelete = deck }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.selectedDeckID }, set: { model.select($0) })) {
            // Headers are plain rows rather than Sections: a sidebar Section keeps its own
            // hover-only collapse state, which fights the state kept here.
            ForEach(model.groups, id: \.category) { group in
                let isOpen = !model.collapsedCategories.contains(group.category)
                CategoryHeader(name: group.category.isEmpty ? Seed.uncategorized : group.category,
                               count: group.decks.count,
                               isOpen: isOpen,
                               hasCurrent: group.decks.contains { $0.id == model.selectedDeckID },
                               onAdd: { model.editorTarget = .newIn(group.category) },
                               onDelete: { pendingCategory = group.category }) {
                    withAnimation(.easeOut(duration: 0.15)) { model.toggleCategory(group.category) }
                }
                .padding(.top, 6)
                .selectionDisabled()
                .contextMenu {
                    Button("이 카테고리에 새 덱") { model.editorTarget = .newIn(group.category) }
                    Button("자료로 덱 만들기…") { model.startImport(into: group.category) }
                    Button("이름 바꾸기…") { model.categoryPrompt = .rename(group.category) }
                    Divider()
                    Button("카테고리 삭제…", role: .destructive) { pendingCategory = group.category }
                }
                if isOpen && group.decks.isEmpty {
                    Button { model.editorTarget = .newIn(group.category) } label: {
                        HStack {
                            Text("덱이 없어요").foregroundStyle(.secondary)
                            Spacer()
                            Label("덱 만들기", systemImage: "plus").foregroundStyle(Palette.accent)
                        }
                        .font(.callout)
                        .padding(.leading, 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                }
                if isOpen {
                    ForEach(Seed.compact(group.decks)) { block in
                        switch block {
                        case .grid(let prefix, let items):
                            DeckGrid(prefix: prefix, items: items, selectedID: model.selectedDeckID,
                                     mastery: { model.mastery(of: $0) },
                                     select: { model.select($0) },
                                     edit: { model.editorTarget = .deck($0) },
                                     delete: { pendingDelete = $0 })
                                .padding(.leading, 18)
                                .selectionDisabled()
                        case .row(let deck):
                            deckRow(deck)
                        }
                    }
                }
            }
        }
        // Delete key on the selected deck.
        .onDeleteCommand {
            if let deck = model.selectedDeck { pendingDelete = deck }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text("TypeDeck")
                    .font(.system(size: 15, weight: .heavy))
                    .tracking(-0.3)
                Spacer()
                Menu {
                    Button("새 덱") { model.editorTarget = .new }
                    Button("새 카테고리…") { model.categoryPrompt = .new }
                    Button("자료로 덱 만들기…") { model.startImport(into: nil) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("새 덱, 새 카테고리, 자료로 덱 만들기")
                .accessibilityLabel("새로 만들기")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
        }
    }
}

/// Sidebar category row: the whole row toggles, and the chevron is always visible
/// (the system disclosure only shows it on hover).
private struct CategoryHeader: View {
    let name: String
    let count: Int
    let isOpen: Bool
    let hasCurrent: Bool
    var onAdd: (() -> Void)?
    var onDelete: (() -> Void)?
    let toggle: () -> Void

    var body: some View {
        let header = Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Text(name)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(hasCurrent ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)개")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(isOpen ? "접기" : "펼치기")
        .accessibilityLabel("\(name) 카테고리, 덱 \(count)개")
        .accessibilityValue(isOpen ? "펼쳐짐" : "접힘")
        header.modifier(HoverActions(actions: [
            onAdd.map { HoverActions.Item(icon: "plus", label: "'\(name)'에 새 덱 만들기", action: $0) },
            onDelete.map { HoverActions.Item(icon: "trash", label: "'\(name)' 카테고리 삭제", action: $0) },
        ].compactMap { $0 }))
    }
}

/// Decks that differ only by number: the shared name once, then a grid of numbers.
private struct DeckGrid: View {
    let prefix: String
    let items: [(deck: Deck, label: String)]
    let selectedID: String?
    let mastery: (Deck) -> (mastered: Int, total: Int)
    let select: (String) -> Void
    let edit: (String) -> Void
    let delete: (Deck) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(prefix)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 4)], spacing: 4) {
                ForEach(items, id: \.deck.id) { item in
                    let selected = item.deck.id == selectedID
                    let m = mastery(item.deck)
                    let done = m.total > 0 && m.mastered == m.total
                    Button { select(item.deck.id) } label: {
                        Text(item.label)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .foregroundStyle(selected ? Color.white : Palette.ink)
                            // Fills from the bottom with the memorized share.
                            .background(alignment: .bottom) {
                                GeometryReader { geo in
                                    Rectangle().fill(Palette.accent.opacity(0.22))
                                        .frame(height: geo.size.height * share(m))
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Palette.accent : Color.clear))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected || done ? Palette.accent : Palette.line))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(item.deck.name) · 외움 \(m.mastered)/\(m.total)")
                    .accessibilityLabel(item.deck.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("편집…") { edit(item.deck.id) }
                        Button("삭제…", role: .destructive) { delete(item.deck) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Memorized share of a deck, 0...1.
private func share(_ m: (mastered: Int, total: Int)) -> CGFloat {
    m.total > 0 ? CGFloat(m.mastered) / CGFloat(m.total) : 0
}

/// Small buttons that show over the trailing edge of a sidebar row while it is hovered.
private struct HoverActions: ViewModifier {
    struct Item {
        let icon: String
        let label: String
        let action: () -> Void
    }
    let actions: [Item]
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if hovering {
                    HStack(spacing: 2) {
                        ForEach(actions.indices, id: \.self) { i in
                            Button(action: actions[i].action) {
                                Image(systemName: actions[i].icon)
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 22, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(actions[i].label)
                            .accessibilityLabel(actions[i].label)
                        }
                    }
                    .padding(.horizontal, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.secondary)
                }
            }
            .onHover { hovering = $0 }
    }
}

private struct ImportProgressPanel: View {
    @Environment(AppModel.self) private var model
    let status: AppModel.ImportStatus

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                Label("PDF로 덱 만들기", systemImage: "apple.intelligence")
                    .font(.headline)
                Text(status.fileName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: status.progress)
                Text(status.phase)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack {
                    Text("기기 안에서 처리되고 밖으로 보내지 않아요.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("취소") { model.cancelImport() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(22)
            .frame(width: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
        }
    }
}
