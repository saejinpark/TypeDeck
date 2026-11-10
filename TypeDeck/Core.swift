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
}

struct DeckFile: Codable {
    var version = 1
    var decks: [Deck]
    /// The user's categories in sidebar order, including empty ones. Missing in older files.
    var categories: [String]?
}

enum Seed {
    static let version = 5
    /// Seed version that first shipped a built-in deck without a `since` (the TOEIC decks).
    static let defaultSince = 3
    /// Built-in decks from earlier versions that were removed: the original sample decks (v2), the
    /// three 50-word TOEIC decks that became the TOEIC day decks (v3) and the TOEFL decks (v4).
    static let retiredIDs: Set<String> = ["proverbs", "http-status", "git", "js-methods", "elements", "capitals",
                                          "toeic-1", "toeic-2", "toeic-3", "toefl-1", "toefl-2", "toefl-3"]

    /// Drops retired built-in decks and adds built-in decks that are newer than the stored data
    /// (`since` is the seed version that brought a deck). A deck the user deleted is never brought
    /// back, because it is not newer than the version they deleted it in.
    static func migrate(_ decks: [Deck], from version: Int, seed: [Deck]) -> [Deck] {
        guard version < Self.version else { return decks }
        let kept = decks.filter { !retiredIDs.contains($0.id) }
        let missing = seed.filter { s in (s.since ?? defaultSince) > version && !kept.contains { $0.id == s.id } }
        return missing + kept
    }

    static let uncategorized = "미분류"

    struct Category: Identifiable {
        let category: String
        let decks: [Deck]
        let words: Int
        /// Built-in decks of this category that are not in the user's list.
        let missing: [Deck]
        var id: String { category }
    }

    /// Built-in decks grouped by category, with the ones not yet in `decks` and the word count.
    static func categories(seed: [Deck], decks: [Deck]) -> [Category] {
        let have = Set(decks.map(\.id))
        return group(seed).map { g in
            Category(category: g.category, decks: g.decks, words: g.decks.reduce(0) { $0 + $1.cards.count },
                     missing: g.decks.filter { !have.contains($0.id) })
        }
    }

    /// Adds built-in decks. Built-in decks keep the seed's order and come before the user's own
    /// decks, which keep theirs.
    static func adding(_ add: [Deck], to decks: [Deck], seed: [Deck]) -> [Deck] {
        var byID: [String: Deck] = [:]
        for d in decks { byID[d.id] = d }
        for d in add where byID[d.id] == nil { byID[d.id] = d }
        let seedIDs = Set(seed.map(\.id))
        return seed.compactMap { byID[$0.id] } + decks.filter { !seedIDs.contains($0.id) }
    }

    /// Every category except the one holding `deckID`: the sidebar starts with only that one open.
    static func collapsed(except deckID: String?, in decks: [Deck]) -> Set<String> {
        let open = decks.first { $0.id == deckID }?.category.cleanedCategory ?? ""
        return Set(decks.map { $0.category.cleanedCategory }).subtracting([open])
    }

    /// Groups decks by category in order of first appearance; uncategorized decks go last.
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

    /// Splits an answer like "지원하다, 신청하다" into the answers that are accepted. Any one of
    /// them completes the card. A comma between two digits ("1,000") does not split.
    static func alternatives(_ answer: String) -> [String] {
        let s = normalize(answer).trimmingCharacters(in: .whitespaces)
        // A sentence is one answer: its commas are part of it.
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
        var seen: Set<String> = []
        let clean = parts.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return clean.count > 1 ? clean : [s]
    }

    /// The accepted answer the typed text is heading for: the one sharing the longest prefix.
    static func pickTarget(_ alts: [String], typed: String) -> String {
        guard alts.count > 1 else { return alts.first ?? "" }
        let t = Array(typed)
        var best = alts[0]
        var bestLen = -1
        for alt in alts {
            let a = Array(alt)
            var k = 0
            while k < t.count && k < a.count && a[k] == t[k] { k += 1 }
            if k > bestLen { best = alt; bestLen = k }
        }
        return best
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
        let a: String
        /// Accepted answers: `a` split on commas.
        let alts: [String]
        /// 메모 shown with the card; empty when the card has none.
        var note: String = ""
    }

    enum Outcome { case none, advance, reveal, shake }

    static let requeueGap = 4
    static let maxRequeues = 3

    private(set) var items: [Item]
    private(set) var queue: [Int]
    private(set) var pos = 0
    private(set) var typed = ""
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
            let answer = Core.normalize(reverse ? card.key : card.value)
            return Item(id: i, q: reverse ? card.value : card.key, a: answer, alts: Core.alternatives(answer), note: card.note)
        }
        let order = Array(built.indices)
        items = built
        queue = shuffle ? order.shuffled(using: &rng) : order
    }

    /// The accepted answer the current input is compared with.
    var target: String { current.map { Core.pickTarget($0.alts, typed: typed) } ?? "" }

    /// True when `text` is an accepted answer and no longer accepted answer starts with it,
    /// so the card can finish without waiting for Return.
    private func isComplete(_ text: String, _ card: Item) -> Bool {
        card.alts.contains(text) && !card.alts.contains { $0 != text && $0.hasPrefix(text) }
    }

    /// The input is an accepted answer, but a longer one starts with it, so Return finishes it.
    var awaitingReturn: Bool { current.map { !typed.isEmpty && $0.alts.contains(typed) } ?? false }

    var finished: Bool { pos >= queue.count }
    var current: Item? { finished ? nil : items[queue[pos]] }
    var remaining: Int { queue.count - pos }

    func upcoming(_ n: Int) -> [Item] {
        queue.dropFirst(pos + 1).prefix(n).map { items[$0] }
    }

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
        if !typed.isEmpty && cardStart == nil { cardStart = now }
        if isComplete(typed, card) {
            complete(at: now)
            return true
        }
        if Core.diff(answer: target, typed: typed, composing: composing)
            .contains(where: { $0.state == .bad || $0.state == .extra }) {
            hadError = true
        }
        return false
    }

    /// Like `input`, but text that runs past the answer completes the card and carries over.
    func feed(_ text: String, composing: Bool, at now: TimeInterval) -> (advanced: Int, rest: String) {
        var t = Core.normalize(text)
        var advanced = 0
        func overflowing() -> String? {
            guard let card = current, !composing else { return nil }
            return card.alts.sorted { $0.count > $1.count }.first { t.count > $0.count && t.hasPrefix($0) }
        }
        while let alt = overflowing() {
            if cardStart == nil { cardStart = now }
            complete(at: now)
            advanced += 1
            t = String(t.dropFirst(alt.count))
        }
        if finished { return (advanced, "") }
        if advanced > 0 && t.isEmpty { return (advanced, "") }
        if input(t, composing: composing, at: now) { return (advanced + 1, "") }
        return (advanced, t)
    }

    /// Return key. Accepts an answer that is complete but also starts a longer one ("지원" when
    /// "지원하다" is accepted too). Otherwise reveals the answer the first time.
    func submit(at now: TimeInterval) -> Outcome {
        guard let card = current else { return .none }
        if !typed.isEmpty && !composing && card.alts.contains(typed) {
            complete(at: now)
            return .advance
        }
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
