import AppKit
import SwiftUI

/// Rows of the deck editor. The last row is always empty; typing into it adds a card.
struct EditorRows: Equatable {
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var q = ""
        var a = ""
        /// 메모; kept with the card but not needed for it to be complete.
        var n = ""
        var isBlank: Bool { q.trimmingCharacters(in: .whitespaces).isEmpty && a.trimmingCharacters(in: .whitespaces).isEmpty }
        var isComplete: Bool { !q.trimmingCharacters(in: .whitespaces).isEmpty && !a.trimmingCharacters(in: .whitespaces).isEmpty }
        var isIncomplete: Bool { !isBlank && !isComplete }
    }

    private(set) var rows: [Row]

    init(cards: [Card] = []) {
        rows = cards.map { Row(q: $0.key, a: $0.value, n: $0.note) }
        normalize()
    }

    var cards: [Card] {
        rows.filter(\.isComplete).map {
            Card($0.q.trimmingCharacters(in: .whitespaces), $0.a.trimmingCharacters(in: .whitespaces),
                 note: $0.n.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var incompleteCount: Int { rows.filter(\.isIncomplete).count }
    var firstIncomplete: Row? { rows.first(where: \.isIncomplete) }

    func index(of id: UUID) -> Int? { rows.firstIndex { $0.id == id } }

    mutating func set(_ id: UUID, q: String? = nil, a: String? = nil, n: String? = nil) {
        guard let i = index(of: id) else { return }
        if let q { rows[i].q = q }
        if let a { rows[i].a = a }
        if let n { rows[i].n = n }
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
        rows.insert(contentsOf: cards.map { Row(q: $0.key, a: $0.value, n: $0.note) }, at: i)
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
    enum Field: Hashable {
        case category, name, key(UUID), value(UUID), note(UUID), text
        /// The card row the field sits in.
        var row: UUID? {
            switch self {
            case .key(let id), .value(let id), .note(let id): return id
            default: return nil
            }
        }
    }

    @State private var name = ""
    @State private var category = ""
    @State private var rows = EditorRows()
    @State private var text = ""
    @State private var mode = Mode.rows
    @State private var note = ""
    @State private var dirty = false
    @State private var warnedIncomplete = false
    /// A row field to move to that may be far down the list, where its row is not built yet: the
    /// list scrolls there first, then the field takes focus.
    @State private var reveal: Field?
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var confirmClearRecord = false
    @FocusState private var focus: Field?
    /// Share of the row width given to the key column; the divider between the columns sets it.
    @AppStorage("editorKeyRatio") private var keyRatio = ColumnLayout.defaultRatio
    @State private var dragStartRatio: Double?
    @State private var dividerHover = false
    /// Rows whose 메모 field is open.
    @State private var openNotes: Set<UUID> = []

    private var deckID: String? {
        if case .deck(let id) = target { return id }
        return nil
    }

    private var currentCards: [Card] { mode == .rows ? rows.cards : Core.parseCards(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Picker("편집 방식", selection: Binding(get: { mode }, set: switchMode)) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("카테고리").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("예: 정보처리기사", text: Binding(get: { category }, set: { if $0 != category { category = $0; dirty = true } }),
                                  prompt: Text("비우면 미분류"))
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .category)
                            .onSubmit { focus = .name }
                        if !model.categories.isEmpty {
                            Menu {
                                ForEach(model.categories, id: \.self) { c in
                                    Button(c) { category = c; dirty = true }
                                }
                            } label: { Image(systemName: "chevron.down") }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("기존 카테고리 고르기")
                        }
                    }
                }
                .frame(width: 200)
                VStack(alignment: .leading, spacing: 6) {
                    Text("이름").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("덱 이름", text: Binding(get: { name }, set: { if $0 != name { name = $0; dirty = true } }))
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                        // Return after the name goes to the empty row at the end, where new cards are typed.
                        .onSubmit { if let last = rows.rows.last { reveal = .key(last.id) } }
                }
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
                    if let id = deckID, model.hasRecord(id) {
                        Button("학습 기록 지우기") { confirmClearRecord = true }
                            .buttonStyle(.link)
                            .help("이 덱의 외운 기록을 지웁니다")
                    }
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
        .confirmationDialog("'\(name)'의 학습 기록을 지울까요?", isPresented: $confirmClearRecord) {
            Button("기록 지우기", role: .destructive) { if let id = deckID { model.clearRecord(id) } }
        } message: {
            Text("외운 카드가 모두 0부터 다시 시작해요.")
        }
        .confirmationDialog("저장하지 않은 변경이 있어요. 닫을까요?", isPresented: $confirmDiscard) {
            Button("저장하지 않고 닫기", role: .destructive) { dismiss() }
        }
    }

    private var title: String {
        switch target {
        case .new: return "새 덱"
        case .deck: return "덱 편집"
        case .newIn: return "새 덱"
        case .draft: return "자료로 만든 덱"
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
            EditorColumns(keyRatio: keyRatio) {
                Text("")
                Text("키").lineLimit(1)
                (Text("값 ") + Text("여러 개면 쉼표로 구분").foregroundStyle(.tertiary)).lineLimit(1)
                Text("")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.panel)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy, so a long imported deck only builds the rows on screen.
                    LazyVStack(spacing: 4) {
                        ForEach(Array(rows.rows.enumerated()), id: \.element.id) { i, row in
                            rowView(row, index: i)
                                .id(row.id)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
                .onChange(of: focus) {
                    if let id = focus?.row { proxy.scrollTo(id) }
                }
                // A task rather than onChange, so a request made while the list was being built
                // (opening the editor, switching back from text) is still carried out.
                .task(id: reveal) {
                    guard let field = reveal, let id = field.row else { return }
                    proxy.scrollTo(id, anchor: .center)
                    try? await Task.sleep(for: .milliseconds(30))
                    focus = field
                    reveal = nil
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
        .overlay(alignment: .topLeading) {
            // Reading the width here does not feed back into the list's own layout.
            GeometryReader { geo in columnDivider(ColumnLayout(width: geo.size.width, keyRatio: keyRatio)) }
        }
    }

    /// The draggable line between the key and value columns. Double-click resets it.
    private func columnDivider(_ columns: ColumnLayout) -> some View {
        let active = dividerHover || dragStartRatio != nil
        return Rectangle()
            .fill(active ? Palette.accent : Palette.line)
            .frame(width: active ? 2 : 1)
            .frame(width: 11)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: columns.dividerX - 5.5)
            .pointerStyle(.columnResize)
            .onHover { dividerHover = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = dragStartRatio ?? keyRatio
                        dragStartRatio = start
                        keyRatio = ColumnLayout.clamp(start + g.translation.width / max(columns.available, 1))
                    }
                    .onEnded { _ in dragStartRatio = nil }
            )
            .onTapGesture(count: 2) { keyRatio = ColumnLayout.defaultRatio }
            .help("끌어서 키와 값 칸 너비 조절 · 두 번 클릭하면 처음대로")
            .accessibilityLabel("키와 값 칸 너비 조절")
    }

    private func rowView(_ row: EditorRows.Row, index i: Int) -> some View {
        let isLast = i == rows.rows.count - 1
        let flagged = row.isIncomplete && focus != .key(row.id) && focus != .value(row.id)
        let noteOpen = openNotes.contains(row.id) && !isLast
        return VStack(alignment: .leading, spacing: 4) {
            rowColumns(row, index: i, isLast: isLast, flagged: flagged, noteOpen: noteOpen)
            if noteOpen { noteEditor(row) }
        }
    }

    private func noteEditor(_ row: EditorRows.Row) -> some View {
        TextEditor(text: Binding(get: { row.n }, set: { value in
            guard value != row.n else { return }
            rows.set(row.id, n: value)
            dirty = true
        }))
        .font(.system(size: 13))
        .lineSpacing(3)
        .scrollContentBackground(.hidden)
        .padding(6)
        .frame(minHeight: 72, maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focus == .note(row.id) ? Palette.accent : Palette.line,
                                                                 lineWidth: focus == .note(row.id) ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if row.n.isEmpty {
                Text("메모 (뜻풀이, 예문, 외우는 요령, 문법 설명…) · 연습할 때 카드 아래에 나와요")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .focused($focus, equals: .note(row.id))
        .padding(.leading, ColumnLayout.number + ColumnLayout.spacing)
        .padding(.trailing, ColumnLayout.actions + ColumnLayout.spacing)
        .padding(.bottom, 4)
    }

    private func toggleNote(_ id: UUID) {
        if openNotes.contains(id) {
            openNotes.remove(id)
            focus = .value(id)
        } else {
            openNotes.insert(id)
            DispatchQueue.main.async { focus = .note(id) }
        }
    }

    private func rowColumns(_ row: EditorRows.Row, index i: Int, isLast: Bool, flagged: Bool, noteOpen: Bool) -> some View {
        EditorColumns(keyRatio: keyRatio) {
            Text(isLast ? "+" : "\(i + 1)")
                .font(.system(size: isLast ? 15 : 12, weight: .semibold))
                .foregroundStyle(isLast ? Palette.accent : Palette.muted)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            cell(row, field: .key(row.id),
                 prompt: isLast ? (i == 0 ? "키 (예: 대한민국)" : "새 카드 키") : "키",
                 text: Binding(get: { row.q }, set: { update(row.id, q: $0) }),
                 flagged: flagged && row.q.trimmingCharacters(in: .whitespaces).isEmpty)
                .onSubmit { focus = .value(row.id) }
            cell(row, field: .value(row.id),
                 prompt: isLast ? (i == 0 ? "값 (여러 개면 쉼표로: 지원하다, 신청하다)" : "값 (쉼표로 여러 개)") : "값",
                 text: Binding(get: { row.a }, set: { update(row.id, a: $0) }),
                 flagged: flagged && row.a.trimmingCharacters(in: .whitespaces).isEmpty)
                .onSubmit { moveDown(from: row.id, column: .value(row.id), viaReturn: true) }
            HStack(spacing: 0) {
                Button {
                    toggleNote(row.id)
                } label: {
                    Image(systemName: "text.alignleft").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(noteOpen ? Palette.accent.opacity(0.15) : .clear))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(!row.n.isEmpty || noteOpen ? Palette.accent : Palette.muted)
                .help(row.n.isEmpty ? "메모 쓰기" : "메모 보기")
                .accessibilityLabel("메모")
                Button {
                    remove(row.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.muted)
                .help("카드 삭제")
            }
            .frame(maxWidth: .infinity)
            .opacity(isLast ? 0 : 1)
            .disabled(isLast)
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
            reveal = .key(next)
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
            if next == .text { focus = .text } else { reveal = .key(rows.rows[rows.rows.count - 1].id) }
        }
    }

    // MARK: Load, save, close

    private func load() {
        switch target {
        case .deck(let id):
            if let deck = model.decks.first(where: { $0.id == id }) {
                name = deck.name
                category = deck.category
                rows = EditorRows(cards: deck.cards)
            }
        case .new:
            category = model.selectedDeck?.category ?? ""
        case .newIn(let c):
            category = c
        case .draft(let draft):
            name = draft.name
            category = draft.category
            rows = EditorRows(cards: draft.cards)
            note = draft.message
            dirty = true
        }
        DispatchQueue.main.async {
            if deckID == nil { focus = .name } else { reveal = .key(rows.rows[rows.rows.count - 1].id) }
        }
    }

    private func save() {
        if mode == .rows, let row = rows.firstIncomplete, !warnedIncomplete {
            warnedIncomplete = true
            note = "키나 값이 빈 카드는 저장되지 않아요. 한 번 더 저장하면 빼고 저장합니다."
            reveal = row.q.trimmingCharacters(in: .whitespaces).isEmpty ? .key(row.id) : .value(row.id)
            return
        }
        model.upsert(id: deckID, name: name, category: category, cards: currentCards)
        dismiss()
    }

    private func requestClose() {
        if dirty { confirmDiscard = true } else { dismiss() }
    }
}

/// Widths of the editor's key and value columns. Both always get at least a usable width, so a
/// long placeholder can no longer squeeze the key column away.
struct ColumnLayout {
    static let number: CGFloat = 30
    /// The 메모 and delete buttons at the end of a row.
    static let actions: CGFloat = 52
    static let spacing: CGFloat = 6
    static let inset: CGFloat = 10
    static let defaultRatio = 0.4
    static let minRatio = 0.15
    static let maxRatio = 0.8

    let width: CGFloat
    let keyRatio: Double

    static func clamp(_ ratio: Double) -> Double { min(max(ratio, minRatio), maxRatio) }

    /// Width shared by the key and value columns.
    var available: CGFloat { max(0, width - 2 * Self.inset - Self.number - Self.actions - 3 * Self.spacing) }
    var key: CGFloat { (available * Self.clamp(keyRatio)).rounded() }
    var value: CGFloat { available - key }
    /// Middle of the gap between the two columns, from the list's leading edge.
    var dividerX: CGFloat { Self.inset + Self.number + Self.spacing + key + Self.spacing / 2 }
}

/// Lays out an editor row (number, key, value, remove) using whatever width it is offered,
/// split by `keyRatio`. It never asks its content how wide to be, so a long placeholder
/// cannot squeeze the key column, and the width does not depend on the content.
struct EditorColumns: Layout {
    var keyRatio: Double

    private func frames(width: CGFloat) -> [CGFloat] {
        let c = ColumnLayout(width: width + 2 * ColumnLayout.inset, keyRatio: keyRatio)
        return [ColumnLayout.number, c.key, c.value, ColumnLayout.actions]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 560
        let widths = frames(width: width)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, w) in zip(subviews, frames(width: bounds.width)) {
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + ColumnLayout.spacing
        }
    }
}
