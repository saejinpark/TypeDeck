import AppKit
import SwiftUI

/// Rows of the deck editor. The last row is always empty; typing into it adds a card.
struct EditorRows: Equatable {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var q = ""
        var a = ""
        var isBlank: Bool { q.trimmingCharacters(in: .whitespaces).isEmpty && a.trimmingCharacters(in: .whitespaces).isEmpty }
        var isComplete: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty && !a.trimmingCharacters(in: .whitespaces).isEmpty }
        var isIncomplete: Bool { !isBlank && !isComplete }
    }

    private(set) var rows: [Row]

    init(cards: [Card] = []) {
        rows = cards.map { Row(q: $0.key, a: $0.value) }
        normalize()
    }

    var cards: [Card] {
        rows.filter(\.isComplete).map {
            Card($0.q.trimmingCharacters(in: .whitespaces), $0.a.trimmingCharacters(in: .whitespaces))
        }
    }

    var incompleteCount: Int { rows.filter(\.isIncomplete).count }
    var firstIncomplete: Row? { rows.first(where: \.isIncomplete) }

    func index(of id: UUID) -> Int? { rows.firstIndex { $0.id == id } }

    mutating func set(_ id: UUID, q: String? = nil, a: String? = nil) {
        guard let i = index(of: id) else { return }
        if let q { rows[i].q = q }
        if let a { rows[i].a = a }
        normalize()
    }

    mutating func remove(_ id: UUID) {
        guard let i = index(of: id) else { return }
        if i == rows.count - 1 { rows[i] = Row() } else { rows.remove(at: i) }
        normalize()
    }

    /// Inserts pasted cards at the given row (replacing it when empty).
    /// Returns the inserted count, the skipped line count and the row to focus next.
    mutating func paste(_ text: String, at id: UUID) -> (added: Int, skipped: Int, next: UUID?) {
        let (cards, skipped) = Core.parseCardsDetailed(text)
        guard !cards.isEmpty, var i = index(of: id) else { return (0, skipped, nil) }
        if rows[i].isBlank { rows.remove(at: i) } else { i += 1 }
        rows.insert(contentsOf: cards.map { Row(q: $0.key, a: $0.value) }, at: i)
        normalize()
        let next = rows[min(i + cards.count, rows.count - 1)].id
        return (cards.count, skipped, next)
    }

    /// Keeps exactly one empty row at the end.
    private mutating func normalize() {
        while rows.count > 1 && rows[rows.count - 1].isBlank && rows[rows.count - 2].isBlank {
            rows.removeLast()
        }
        if rows.last?.isBlank != true { rows.append(Row()) }
    }
}

struct DeckEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    enum Mode: String, CaseIterable { case rows = "표", text = "텍스트" }
    enum Field: Hashable { case name, key(UUID), value(UUID), text }

    @State private var name = ""
    @State private var rows = EditorRows()
    @State private var text = ""
    @State private var mode = Mode.rows
    @State private var note = ""
    @State private var dirty = false
    @State private var warnedIncomplete = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?

    private var deckID: String? {
        if case .deck(let id) = target { return id }
        return nil
    }

    private var currentCards: [Card] { mode == .rows ? rows.cards : Core.parseCards(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(deckID == nil ? "새 덱" : "덱 편집").font(.title3.bold())
                Spacer()
                Picker("편집 방식", selection: Binding(get: { mode }, set: switchMode)) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("이름").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("덱 이름", text: Binding(get: { name }, set: { if $0 != name { name = $0; dirty = true } }))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onSubmit { if let first = rows.rows.first { focus = .key(first.id) } }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("카드").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(countLabel).font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                    Spacer()
                    if mode == .rows {
                        Text("return 다음 칸 · 여러 줄 붙여넣기 가능").font(.caption).foregroundStyle(.secondary)
                        Button("클립보드에서 붙여넣기") { pasteFromClipboard() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                if mode == .rows { rowsList } else { textEditor }
            }
            if !note.isEmpty {
                Text(note).font(.callout.weight(.medium)).foregroundStyle(Palette.accent)
            }
            HStack {
                if deckID != nil {
                    Button("덱 삭제", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("취소") { requestClose() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .help("저장 (⌘↩ 또는 ⌘S)")
                Button("") { save() }
                    .keyboardShortcut("s")
                    .hidden()
                    .frame(width: 0)
                Button("") { paste() }
                    .keyboardShortcut("v")
                    .hidden()
                    .frame(width: 0)
            }
        }
        .padding(22)
        .frame(width: 640, height: 600)
        .onAppear(perform: load)
        .confirmationDialog("'\(name)' 덱을 삭제할까요?", isPresented: $confirmDelete) {
            Button("삭제", role: .destructive) {
                if let id = deckID { model.delete(id) }
                dismiss()
            }
        } message: {
            Text("되돌릴 수 없어요.")
        }
        .confirmationDialog("저장하지 않은 변경이 있어요. 닫을까요?", isPresented: $confirmDiscard) {
            Button("저장하지 않고 닫기", role: .destructive) { dismiss() }
        }
    }

    private var countLabel: String {
        let n = currentCards.count
        let incomplete = mode == .rows ? rows.incompleteCount : 0
        return "\(n)장" + (incomplete > 0 ? " · 미완성 \(incomplete)" : "")
    }

    // MARK: Rows

    private var rowsList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("").frame(width: 30)
                Text("키").frame(maxWidth: .infinity, alignment: .leading)
                Text("값").frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                Text("").frame(width: 26)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.panel)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(rows.rows.enumerated()), id: \.element.id) { i, row in
                            rowView(row, index: i)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
                .onChange(of: focus) {
                    if case .key(let id) = focus { proxy.scrollTo(id) }
                    if case .value(let id) = focus { proxy.scrollTo(id) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    }

    private func rowView(_ row: EditorRows.Row, index i: Int) -> some View {
        let isLast = i == rows.rows.count - 1
        let flagged = row.isIncomplete && focus != .key(row.id) && focus != .value(row.id)
        return HStack(spacing: 6) {
            Text(isLast ? "+" : "\(i + 1)")
                .font(.system(size: isLast ? 15 : 12, weight: .semibold))
                .foregroundStyle(isLast ? Palette.accent : Palette.muted)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
            cell(row, field: .key(row.id),
                 prompt: isLast ? (i == 0 ? "키 (예: 대한민국)" : "새 카드 키") : "키",
                 text: Binding(get: { row.q }, set: { update(row.id, q: $0) }),
                 flagged: flagged && row.q.trimmingCharacters(in: .whitespaces).isEmpty)
                .onSubmit { focus = .value(row.id) }
            cell(row, field: .value(row.id),
                 prompt: isLast && i == 0 ? "값 (예: 서울)" : "값",
                 text: Binding(get: { row.a }, set: { update(row.id, a: $0) }),
                 flagged: flagged && row.a.trimmingCharacters(in: .whitespaces).isEmpty)
                .layoutPriority(1)
                .onSubmit { moveDown(from: row.id, column: .value(row.id), viaReturn: true) }
            Button {
                remove(row.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.muted)
            .frame(width: 26)
            .opacity(isLast ? 0 : 1)
            .disabled(isLast)
            .help("카드 삭제")
        }
    }

    private func cell(_ row: EditorRows.Row, field: Field, prompt: String, text: Binding<String>, flagged: Bool) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(flagged ? Palette.bad.opacity(0.12) : Palette.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(focus == field ? Palette.accent : (flagged ? Palette.bad : Palette.line),
                                  lineWidth: focus == field ? 2 : 1)
            )
            .focused($focus, equals: field)
            .onKeyPress(.downArrow) { moveDown(from: row.id, column: field, viaReturn: false); return .handled }
            .onKeyPress(.upArrow) { moveUp(from: row.id, column: field); return .handled }
            .onKeyPress(.delete) { backspace(in: row.id, field: field) ? .handled : .ignored }
    }

    private func column(_ field: Field, for id: UUID) -> Field {
        if case .value = field { return .value(id) }
        return .key(id)
    }

    private func moveDown(from id: UUID, column field: Field, viaReturn: Bool) {
        guard let i = rows.index(of: id) else { return }
        if i + 1 < rows.rows.count {
            let next = rows.rows[i + 1].id
            focus = viaReturn ? .key(next) : column(field, for: next)
        } else if viaReturn {
            focus = .key(id)
        }
    }

    private func moveUp(from id: UUID, column field: Field) {
        guard let i = rows.index(of: id), i > 0 else { return }
        focus = column(field, for: rows.rows[i - 1].id)
    }

    /// Backspace in an empty field: value -> its key, empty row -> removed, previous row's value.
    private func backspace(in id: UUID, field: Field) -> Bool {
        guard let i = rows.index(of: id) else { return false }
        let row = rows.rows[i]
        switch field {
        case .value where row.a.isEmpty:
            focus = .key(id)
            return true
        case .key where row.isBlank && i > 0:
            let prev = rows.rows[i - 1].id
            if i < rows.rows.count - 1 { remove(id) }
            focus = .value(prev)
            return true
        default:
            return false
        }
    }

    private func update(_ id: UUID, q: String? = nil, a: String? = nil) {
        let pasted = q ?? a ?? ""
        if pasted.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            // A multi-line paste landed in a single field: turn it into cards.
            applyPaste(pasted, at: id)
            return
        }
        // macOS text fields write their value back when they lose focus; that is not an edit.
        guard let i = rows.index(of: id), q.map({ $0 != rows.rows[i].q }) ?? true, a.map({ $0 != rows.rows[i].a }) ?? true else { return }
        rows.set(id, q: q, a: a)
        dirty = true
    }

    private func remove(_ id: UUID) {
        let i = rows.index(of: id) ?? 0
        rows.remove(id)
        dirty = true
        focus = .key(rows.rows[min(i, rows.rows.count - 1)].id)
    }

    private func applyPaste(_ text: String, at id: UUID) {
        let result = rows.paste(text, at: id)
        if result.added == 0 {
            note = result.skipped > 0 ? "\"키 = 값\"이나 탭으로 나뉜 줄을 찾지 못했어요." : ""
            return
        }
        dirty = true
        note = "\(result.added)장을 붙여 넣었어요." + (result.skipped > 0 ? " 나눌 수 없는 \(result.skipped)줄은 건너뛰었어요." : "")
        if let next = result.next {
            DispatchQueue.main.async { focus = .key(next) }
        }
    }

    /// ⌘V: several lines or tab-separated text in a card field become cards; anything else
    /// is pasted normally.
    private func paste() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let isCardField: Bool
        switch focus {
        case .key?, .value?: isCardField = true
        default: isCardField = false
        }
        if isCardField && text.contains(where: { $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
            pasteFromClipboard()
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            note = "클립보드에 텍스트가 없어요."
            return
        }
        let target: UUID
        switch focus {
        case .key(let id)?, .value(let id)?: target = id
        default: target = rows.rows[rows.rows.count - 1].id
        }
        applyPaste(text, at: target)
    }

    // MARK: Text mode

    private var textEditor: some View {
        TextEditor(text: Binding(get: { text }, set: { if $0 != text { text = $0; dirty = true } }))
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
            .focused($focus, equals: .text)
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

    private func switchMode(_ next: Mode) {
        guard next != mode else { return }
        if next == .text {
            text = Core.serialize(rows.cards)
        } else {
            rows = EditorRows(cards: Core.parseCards(text))
        }
        mode = next
        note = ""
        DispatchQueue.main.async {
            focus = next == .text ? .text : .key(rows.rows[rows.rows.count - 1].id)
        }
    }

    // MARK: Load, save, close

    private func load() {
        if let id = deckID, let deck = model.decks.first(where: { $0.id == id }) {
            name = deck.name
            rows = EditorRows(cards: deck.cards)
        }
        DispatchQueue.main.async {
            focus = deckID == nil ? .name : .key(rows.rows[rows.rows.count - 1].id)
        }
    }

    private func save() {
        if mode == .rows, let row = rows.firstIncomplete, !warnedIncomplete {
            warnedIncomplete = true
            note = "키나 값이 빈 카드는 저장되지 않아요. 한 번 더 저장하면 빼고 저장합니다."
            focus = row.q.trimmingCharacters(in: .whitespaces).isEmpty ? .key(row.id) : .value(row.id)
            return
        }
        model.upsert(id: deckID, name: name, cards: currentCards)
        dismiss()
    }

    private func requestClose() {
        if dirty { confirmDiscard = true } else { dismiss() }
    }
}
