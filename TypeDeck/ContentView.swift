import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var restoreNote: String?
    @State private var pendingDelete: Deck?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            PracticeView()
        }
        .fileImporter(isPresented: $model.showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { model.importPDF(at: url) }
        }
        .overlay {
            if let status = model.importStatus { ImportProgressPanel(status: status) }
        }
        .alert("PDF로 덱을 만들지 못했어요",
               isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })) {
            Button("확인") { model.importError = nil; model.refocus() }
        } message: {
            Text(model.importError ?? "")
        }
        .sheet(item: $model.editorTarget, onDismiss: { model.refocus() }) { target in
            DeckEditorView(target: target)
                .id(target)
        }
        .confirmationDialog(
            "'\(pendingDelete?.name ?? "")' 덱을 삭제할까요?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { deck in
            Button("삭제", role: .destructive) { model.delete(deck.id) }
        } message: { _ in
            Text("되돌릴 수 없어요.")
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.selectedDeckID }, set: { model.select($0) })) {
            // Headers are plain rows rather than Sections: a sidebar Section keeps its own
            // hover-only collapse state, which fights the state kept here.
            ForEach(Seed.group(model.decks), id: \.category) { group in
                let isOpen = !model.collapsedCategories.contains(group.category)
                CategoryHeader(name: group.category.isEmpty ? Seed.uncategorized : group.category,
                               count: group.decks.count,
                               isOpen: isOpen,
                               hasCurrent: group.decks.contains { $0.id == model.selectedDeckID }) {
                    withAnimation(.easeOut(duration: 0.15)) { model.toggleCategory(group.category) }
                }
                .padding(.top, 6)
                .selectionDisabled()
                .contextMenu {
                    Button("모두 펼치기") { model.setAllCategories(open: true) }
                    Button("모두 접기") { model.setAllCategories(open: false) }
                }
                if isOpen {
                    ForEach(group.decks) { deck in
                        HStack {
                            Text(deck.name).lineLimit(1)
                            Spacer()
                            Text("\(deck.cards.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.leading, 18)
                        .tag(deck.id)
                        .contextMenu {
                            Button("편집…") { model.editorTarget = .deck(deck.id) }
                            Button("삭제…", role: .destructive) { pendingDelete = deck }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if Seed.group(model.decks).count > 1 {
                HStack {
                    Text("덱")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.allCategoriesCollapsed ? "모두 펼치기" : "모두 접기") {
                        withAnimation(.easeOut(duration: 0.15)) {
                            model.setAllCategories(open: model.allCategoriesCollapsed)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("모든 카테고리를 한 번에 접거나 펼칩니다 (⌥⌘← / ⌥⌘→)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.editorTarget = .new
                } label: {
                    Label("새 덱", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.large)
                Button {
                    model.showPDFImporter = true
                } label: {
                    Label("PDF로 덱 만들기", systemImage: "apple.intelligence")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("Apple Intelligence가 PDF 내용으로 카드를 만들어요 (⇧⌘O)")
                HStack {
                    Button("기본 덱 복원") {
                        let n = model.restoreDefaults()
                        restoreNote = n == 0 ? "기본 덱이 모두 있어요" : "\(n)개 덱을 되살렸어요"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { restoreNote = nil }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    if let restoreNote {
                        Text(restoreNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
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
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
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
