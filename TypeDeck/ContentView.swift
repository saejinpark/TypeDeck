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
            ForEach(model.decks) { deck in
                HStack {
                    Text(deck.name).lineLimit(1)
                    Spacer()
                    Text("\(deck.cards.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(deck.id)
                .contextMenu {
                    Button("편집…") { model.editorTarget = .deck(deck.id) }
                    Button("삭제…", role: .destructive) { pendingDelete = deck }
                }
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
