import Foundation
import Observation

/// One key/value pair with an optional note (메모). Stored in JSON as `[key, value]` or
/// `[key, value, note]`, the same format the web app uses.
struct Card: Hashable, Codable {
    var key: String
    var value: String
    var note: String = ""

    init(_ key: String, _ value: String, note: String = "") {
        self.key = key
        self.value = value
        self.note = note
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        key = try c.decode(String.self)
        value = try c.decode(String.self)
        note = c.isAtEnd ? "" : (try c.decodeIfPresent(String.self) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(key)
        try c.encode(value)
        if !note.isEmpty { try c.encode(note) }
    }
}

struct Deck: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// One level of grouping in the sidebar. Empty means uncategorized.
    var category: String = ""
    var cards: [Card]
    /// Built-in decks only: the seed version that brought this deck (nil means 3).
    var since: Int?

    init(id: String, name: String, category: String = "", cards: [Card], since: Int? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.cards = cards
        self.since = since
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        cards = try c.decode([Card].self, forKey: .cards)
        since = try c.decodeIfPresent(Int.self, forKey: .since)
    }

    /// A built-in deck as it is stored in the user's list: `since` only matters in the seed.
    var userCopy: Deck {
        var d = self
        d.since = nil
        return d
    }
}

struct DeckFile: Codable {
    var decks: [Deck]
    /// The user's categories in sidebar order, including empty ones. Missing in older files.
    var categories: [String]?
}

/// Learning record of one card: clean first tries in a row, and how often it was practiced.
struct CardRecord: Codable, Equatable {
    var streak = 0
    var seen = 0
}

enum Mastery {
    /// A card counts as memorized after this many clean first tries in a row.
    static let threshold = 3
    /// deck id → card key → record. Keyed by the card's key, so it survives reordering and edits
    /// of the value.
    typealias Progress = [String: [String: CardRecord]]

    static func key(_ card: Card) -> String { Core.normalize(card.key).trimmingCharacters(in: .whitespaces) }

    /// Notes one first try of a card. A miss starts the streak over.
    static func record(_ progress: inout Progress, deckID: String, card: Card, clean: Bool) {
        var rec = progress[deckID]?[key(card)] ?? CardRecord()
        rec.seen += 1
        rec.streak = clean ? rec.streak + 1 : 0
        progress[deckID, default: [:]][key(card)] = rec
    }

    static func isMastered(_ progress: Progress, deckID: String, card: Card) -> Bool {
        (progress[deckID]?[key(card)]?.streak ?? 0) >= threshold
    }

    /// How many of a deck's cards are memorized.
    static func count(_ progress: Progress, deck: Deck) -> (mastered: Int, total: Int) {
        (deck.cards.filter { isMastered(progress, deckID: deck.id, card: $0) }.count, deck.cards.count)
    }
}

enum Seed {
    static let version = 6

    /// Adds built-in decks that are newer than the stored data. A built-in deck's `since` is the
    /// seed version that brought it, so a deck the user deleted never comes back on an update.
    static func migrate(_ decks: [Deck], from version: Int, seed: [Deck]) -> [Deck] {
        guard version < Self.version else { return decks }
        let have = Set(decks.map(\.id))
        let added = seed.filter { ($0.since ?? 0) > version && !have.contains($0.id) }
        return added.map(\.userCopy) + decks
    }

    static let uncategorized = "미분류"

    struct Category: Identifiable {
        let category: String
        let decks: [Deck]
        let cardCount: Int
        var id: String { category }
    }

    /// Built-in decks grouped by category, with the number of cards in each category.
    static func categories(seed: [Deck]) -> [Category] {
        group(seed).map { g in
            Category(category: g.category, decks: g.decks, cardCount: g.decks.reduce(0) { $0 + $1.cards.count })
        }
    }

    /// Adds built-in decks. Built-in decks keep the seed's order and come before the user's own
    /// decks, which keep theirs.
    static func adding(_ add: [Deck], to decks: [Deck], seed: [Deck]) -> [Deck] {
        var byID: [String: Deck] = [:]
        for d in decks { byID[d.id] = d }
        for d in add where byID[d.id] == nil { byID[d.id] = d.userCopy }
        let seedIDs = Set(seed.map(\.id))
        return seed.compactMap { byID[$0.id] } + decks.filter { !seedIDs.contains($0.id) }
    }

    /// Every category except the one holding `deckID`: the sidebar starts with only that one open.
    static func collapsed(except deckID: String?, in decks: [Deck]) -> Set<String> {
        let open = decks.first { $0.id == deckID }?.category.cleanedCategory ?? ""
        return Set(decks.map { $0.category.cleanedCategory }).subtracting([open])
    }

    /// Groups decks by category in order of first appearance; uncategorized decks go last.
    /// Longest last word (in characters) that still counts as a short label, like "01".
    static let gridLabelMax = 4

    /// Decks that share a name part form a grid from this many on.
    static let gridMin = 2

    /// One piece of a category's deck list in the sidebar.
    enum DeckBlock: Identifiable {
        /// Decks that differ only by a short label, shown as a grid under `prefix`.
        case grid(prefix: String, items: [(deck: Deck, label: String)])
        case row(Deck)

        var id: String {
            switch self {
            case .grid(let prefix, _): return "grid:" + prefix
            case .row(let deck): return deck.id
            }
        }
    }

    /// Splits a deck name into a shared part and a short label: the last word ("기초 Day 01" →
    /// "기초 Day", "01"), or a number stuck to the end ("정보처리기사1회" → "정보처리기사", "1회").
    static func splitDeckName(_ name: String) -> (prefix: String, label: String)? {
        let words = name.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1, let last = words.last, last.count <= gridLabelMax {
            return (words.dropLast().joined(separator: " "), last)
        }
        let text = name.trimmingCharacters(in: .whitespaces)
        guard let m = text.firstMatch(of: /^(.*\D)(\d+\D{0,2})$/) else { return nil }
        let prefix = String(m.1).trimmingCharacters(in: .whitespaces)
        let label = String(m.2)
        guard !prefix.isEmpty, label.count <= gridLabelMax else { return nil }
        return (prefix, label)
    }

    /// Lays out a category's decks for the sidebar. Decks whose names differ only in a short
    /// label ("회차 01", "회차 02" ...) form a grid of labels under the shared part, in number
    /// order; a category can hold several such grids. Each grid sits where its first deck was,
    /// and other decks stay as rows in their order.
    static func compact(_ decks: [Deck]) -> [DeckBlock] {
        let named = decks.map { ($0, splitDeckName($0.name)) }
        var counts: [String: Int] = [:]
        for (_, split) in named { if let split { counts[split.prefix, default: 0] += 1 } }
        var blocks: [DeckBlock] = []
        var gridIndex: [String: Int] = [:]
        var items: [String: [(deck: Deck, label: String)]] = [:]
        for (deck, split) in named {
            guard let split, counts[split.prefix, default: 0] >= gridMin else { blocks.append(.row(deck)); continue }
            if gridIndex[split.prefix] == nil {
                gridIndex[split.prefix] = blocks.count
                blocks.append(.grid(prefix: split.prefix, items: []))
            }
            items[split.prefix, default: []].append((deck, split.label))
        }
        for (prefix, index) in gridIndex {
            let sorted = items[prefix, default: []].sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            blocks[index] = .grid(prefix: prefix, items: sorted)
        }
        return blocks
    }

    /// Category names are trimmed and inner runs of spaces collapsed.
    static func clean(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Groups decks by category. `order` is the user's category list, which may hold empty
    /// categories; categories only found on decks follow it, and uncategorized decks go last.
    static func group(_ decks: [Deck], order list: [String] = []) -> [(category: String, decks: [Deck])] {
        var order: [String] = []
        var groups: [String: [Deck]] = [:]
        for name in list.map(clean) where !name.isEmpty && groups[name] == nil {
            order.append(name)
            groups[name] = []
        }
        for deck in decks {
            let name = clean(deck.category)
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(deck)
        }
        let named = order.filter { !$0.isEmpty }.map { ($0, groups[$0]!) }
        return named + (groups[""].map { [("", $0)] } ?? [])
    }

    /// The category list with every category used by a deck, keeping the existing order.
    static func sync(_ order: [String], with decks: [Deck]) -> [String] {
        group(decks, order: order).map(\.category).filter { !$0.isEmpty }
    }

    /// Renames a category on every deck and in the list. Renaming onto an existing category
    /// merges the two, keeping the target's place.
    static func rename(_ from: String, to: String, decks: [Deck], order: [String]) -> (decks: [Deck], order: [String]) {
        let target = clean(to)
        let nextDecks = decks.map { d -> Deck in
            var d = d
            if clean(d.category) == from { d.category = target }
            return d
        }
        let list = sync(order, with: decks)
        let nextOrder = list.contains(target) ? list.filter { $0 != from } : list.map { $0 == from ? target : $0 }
        return (nextDecks, sync(nextOrder, with: nextDecks))
    }
}

enum CharState: Equatable {
    case ok, bad, composing, todo, extra
}

struct CharDiff: Equatable {
    /// The character to draw: the answer's character, or what was typed for composing/extra.
    let shown: Character
    let state: CharState
}

enum Core {
    static func normalize(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    private static let separators = ["\t", " = ", " : ", "=", ":"]

    /// Parses "key = value" lines. Tab, " = ", " : ", "=", ":" are tried in that order.
    static func parseCards(_ text: String) -> [Card] {
        parseCardsDetailed(text).cards
    }

    /// Like parseCards, but also counts the non-empty lines that had no usable separator.
    /// Reads cards from an imported file. CSV and TSV take the first column as the key and the
    /// rest as meanings (a comma inside quotes stays in the value); anything else uses the same
    /// separators as pasting.
    static func parseImport(_ text: String, fileName: String) -> (cards: [Card], skipped: Int) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ext == "csv" || ext == "tsv" else { return parseCardsDetailed(text) }
        let sep: Character = ext == "tsv" ? "\t" : ","
        var cards: [Card] = []
        var skipped = 0
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for fields in csvRecords(body, separator: sep) where fields.contains(where: { !$0.isEmpty }) {
            let key = fields.first ?? ""
            let value = fields.count > 1 ? fields[1] : ""
            let note = fields.dropFirst(2).filter { !$0.isEmpty }.joined(separator: "\n")
            if !key.isEmpty && !value.isEmpty { cards.append(Card(key, value, note: note)) } else { skipped += 1 }
        }
        return (cards, skipped)
    }

    /// Splits CSV text into records; quotes may wrap a field, "" is a literal quote, and a quoted
    /// field may span lines (a long 메모 with line breaks).
    private static func csvRecords(_ text: String, separator: Character) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var cur = ""
        var quoted = false
        var chars = Array(text)[...]
        func endField() { fields.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
        while let ch = chars.popFirst() {
            if quoted {
                if ch == "\"" && chars.first == "\"" { cur.append("\""); chars.removeFirst() }
                else if ch == "\"" { quoted = false }
                else { cur.append(ch) }
            } else if ch == "\"" && cur.trimmingCharacters(in: .whitespaces).isEmpty {
                quoted = true
                cur = ""
            } else if ch == separator {
                endField()
            } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                endField()
                records.append(fields)
                fields = []
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty || !fields.isEmpty { endField(); records.append(fields) }
        return records
    }

    static func parseCardsDetailed(_ text: String) -> (cards: [Card], skipped: Int) {
        var cards: [Card] = []
        var skipped = 0
        var noteLines: [[String]] = []
        var attached = false // whether "> " lines go to the last card
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") {
                guard attached else { skipped += 1; continue }
                var rest = line.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                noteLines[noteLines.count - 1].append(String(rest))
                continue
            }
            if line.isEmpty { attached = false; continue }
            if line.hasPrefix("#") { continue }
            attached = false
            guard let sep = separators.first(where: { line.contains($0) }),
                  let range = line.range(of: sep) else { skipped += 1; continue }
            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty {
                cards.append(Card(key, value))
                noteLines.append([])
                attached = true
            } else {
                skipped += 1
            }
        }
        for i in cards.indices {
            cards[i].note = noteLines[i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (cards, skipped)
    }

    static func serialize(_ cards: [Card]) -> String {
        cards.map { card in
            let line = card.key.contains("=") || card.key.contains(":")
                ? "\(card.key)\t\(card.value)"
                : "\(card.key) = \(card.value)"
            let notes = card.note.isEmpty ? [] : card.note.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
            return ([line] + notes).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// The meanings of an answer like "지원하다, 신청하다". All of them are typed, in order. A
    /// sentence (ending in . ? or !) is one meaning, and a comma between two digits ("1,000")
    /// does not split.
    static func meanings(_ answer: String) -> [String] {
        let s = normalize(answer).trimmingCharacters(in: .whitespaces)
        if s.range(of: #"[.?!][\s"')\]]*$"#, options: .regularExpression) != nil { return [s] }
        let chars = Array(s)
        var parts: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            let between = i > 0 && i < chars.count - 1 && chars[i - 1].isNumber && chars[i + 1].isNumber
            if ch == "," && !between {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        let clean = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return clean.count > 1 ? clean : [s]
    }

    /// What is typed for an answer: its meanings joined by ", ", and where the space of each ", "
    /// sits (it fills in once the comma is typed).
    struct TypingTarget: Equatable {
        let text: String
        /// Character positions of the space after each separating comma.
        let auto: Set<Int>

        init(_ answer: String) {
            let parts = Core.meanings(answer)
            var auto: Set<Int> = []
            var at = 0
            for (k, p) in parts.enumerated() {
                at += p.count
                if k < parts.count - 1 { auto.insert(at + 1); at += 2 }
            }
            text = parts.joined(separator: ", ")
            self.auto = auto
        }
    }

    /// Lines the typed text up with the target. The user ends a meaning by typing the comma, and
    /// the space after it fills in (typing it is fine too). Nothing is filled in before the comma,
    /// so the card never gives away where a meaning ends. Returns the text as it reads on the
    /// card, and how many typed characters spelled out the whole target (nil until they do).
    static func fillSeparators(_ target: TypingTarget, typed: String) -> (shown: String, used: Int?) {
        let t = Array(target.text)
        let u = Array(typed)
        var shown = ""
        var i = 0
        var used: Int?
        for (j, ch) in u.enumerated() {
            shown.append(ch)
            i += 1
            if ch == ",", target.auto.contains(i), j + 1 >= u.count || u[j + 1] != " " {
                shown.append(" ")
                i += 1
            }
            if used == nil && i == t.count && shown == target.text { used = j + 1 }
        }
        return (shown, used)
    }

    static func diff(answer: String, typed: String, composing: Bool) -> [CharDiff] {
        let a = Array(answer)
        let t = Array(typed)
        var out: [CharDiff] = []
        out.reserveCapacity(max(a.count, t.count))
        for i in 0..<max(a.count, t.count) {
            let isLastTyped = i == t.count - 1
            if i < t.count && i < a.count {
                if composing && isLastTyped {
                    out.append(CharDiff(shown: t[i], state: .composing))
                } else {
                    out.append(CharDiff(shown: a[i], state: t[i] == a[i] ? .ok : .bad))
                }
            } else if i < a.count {
                out.append(CharDiff(shown: a[i], state: .todo))
            } else {
                out.append(CharDiff(shown: t[i], state: composing && isLastTyped ? .composing : .extra))
            }
        }
        return out
    }
}

/// One round through a deck. Missed cards come back a few cards later.
@Observable
final class Session {
    struct Item: Identifiable, Equatable {
        let id: Int
        let q: String
        /// The answer as typed: its meanings joined by ", ".
        let a: String
        let target: Core.TypingTarget
        /// 메모 shown with the card; empty when the card has none.
        var note: String = ""
    }

    enum Outcome { case none, reveal, shake }

    static let requeueGap = 4
    static let maxRequeues = 3

    private(set) var items: [Item]
    private(set) var queue: [Int]
    private(set) var pos = 0
    private(set) var typed = ""
    /// `typed` with the ", " between meanings filled in.
    private(set) var shown = ""
    private(set) var composing = false
    private(set) var revealed = false
    private(set) var hadError = false
    private(set) var keystrokes = 0
    private(set) var activeTime: TimeInterval = 0
    private(set) var streak = 0
    private(set) var bestStreak = 0
    /// First-attempt result per card, in the order they were first finished.
    private(set) var firstResults: [(id: Int, clean: Bool)] = []

    private var cardStart: TimeInterval?
    private var requeues: [Int: Int] = [:]
    /// The card finished most recently, for showing its 메모.
    private(set) var lastDone: Item?
    /// Told each card's first try in this round (item id, clean), for the learning record.
    @ObservationIgnored var onResult: ((Int, Bool) -> Void)?

    /// Replaces the 메모 of item `id` (after it was edited during practice).
    func setNote(_ note: String, forItem id: Int) {
        guard items.indices.contains(id) else { return }
        items[id].note = note
        if lastDone?.id == id { lastDone?.note = note }
    }

    convenience init(cards: [Card], shuffle: Bool = true, reverse: Bool = false) {
        var rng = SystemRandomNumberGenerator()
        self.init(cards: cards, shuffle: shuffle, reverse: reverse, using: &rng)
    }

    init<R: RandomNumberGenerator>(cards: [Card], shuffle: Bool, reverse: Bool, using rng: inout R) {
        let built = cards.enumerated().map { i, card in
            let target = Core.TypingTarget(reverse ? card.key : card.value)
            return Item(id: i, q: reverse ? card.value : card.key, a: target.text, target: target, note: card.note)
        }
        let order = Array(built.indices)
        items = built
        queue = shuffle ? order.shuffled(using: &rng) : order
    }

    var finished: Bool { pos >= queue.count }
    var current: Item? { finished ? nil : items[queue[pos]] }
    var remaining: Int { queue.count - pos }

    func keystroke(at now: TimeInterval) {
        guard !finished else { return }
        keystrokes += 1
        if cardStart == nil { cardStart = now }
    }

    /// Feeds the full input text. Returns true when the card was completed.
    @discardableResult
    func input(_ text: String, composing: Bool, at now: TimeInterval) -> Bool {
        guard let card = current else { return false }
        typed = Core.normalize(text)
        self.composing = composing
        shown = Core.fillSeparators(card.target, typed: typed).shown
        if !typed.isEmpty && cardStart == nil { cardStart = now }
        if shown == card.a {
            complete(at: now)
            return true
        }
        if Core.diff(answer: card.a, typed: shown, composing: composing)
            .contains(where: { $0.state == .bad || $0.state == .extra }) {
            hadError = true
        }
        return false
    }

    /// Like `input`, but text that runs past the answer completes the card and carries over.
    func feed(_ text: String, composing: Bool, at now: TimeInterval) -> (advanced: Int, rest: String) {
        var t = Core.normalize(text)
        var advanced = 0
        while let card = current, !composing,
              let used = Core.fillSeparators(card.target, typed: t).used, used < t.count {
            if cardStart == nil { cardStart = now }
            complete(at: now)
            advanced += 1
            t = String(t.dropFirst(used))
        }
        if finished { return (advanced, "") }
        if advanced > 0 && t.isEmpty { return (advanced, "") }
        if input(t, composing: composing, at: now) { return (advanced + 1, "") }
        return (advanced, t)
    }

    /// Return key. Reveals the answer the first time.
    func submit() -> Outcome {
        guard current != nil else { return .none }
        if revealed { return .shake }
        revealed = true
        return .reveal
    }

    /// Tab key. Gives up on the card for now.
    func skip(at now: TimeInterval) {
        guard !finished else { return }
        revealed = true
        complete(at: now)
    }

    private func complete(at now: TimeInterval) {
        guard let card = current else { return }
        lastDone = card
        let clean = !hadError && !revealed
        if !firstResults.contains(where: { $0.id == card.id }) {
            firstResults.append((card.id, clean))
            onResult?(card.id, clean)
        }
        if let start = cardStart { activeTime += max(0, now - start) }
        if clean {
            streak += 1
            bestStreak = max(bestStreak, streak)
        } else {
            streak = 0
            let n = requeues[card.id, default: 0]
            if n < Self.maxRequeues {
                requeues[card.id] = n + 1
                queue.insert(card.id, at: min(pos + 1 + Self.requeueGap, queue.count))
            }
        }
        pos += 1
        typed = ""
        shown = ""
        composing = false
        revealed = false
        hadError = false
        cardStart = nil
    }

    var missed: [Item] {
        firstResults.filter { !$0.clean }.map { items[$0.id] }
    }

    var accuracy: Double? {
        guard !firstResults.isEmpty else { return nil }
        return Double(firstResults.filter(\.clean).count) / Double(firstResults.count)
    }

    /// Keystrokes per minute (Korean "타수").
    var kpm: Double? {
        guard activeTime >= 1 else { return nil }
        return Double(keystrokes) / activeTime * 60
    }
}

extension String {
    /// This string as a category name (see `Seed.clean`).
    var cleanedCategory: String { Seed.clean(self) }
}
