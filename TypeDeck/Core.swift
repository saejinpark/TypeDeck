import Foundation
import Observation

/// One key/value pair. Stored in JSON as a two-element array, the same format the web app uses.
struct Card: Hashable, Codable {
    var key: String
    var value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        key = try c.decode(String.self)
        value = try c.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(key)
        try c.encode(value)
    }
}

struct Deck: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    /// One level of grouping in the sidebar. Empty means uncategorized.
    var category: String = ""
    var cards: [Card]

    init(id: String, name: String, category: String = "", cards: [Card]) {
        self.id = id
        self.name = name
        self.category = category
        self.cards = cards
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        cards = try c.decode([Card].self, forKey: .cards)
    }
}

struct DeckFile: Codable {
    var version = 1
    var decks: [Deck]
}

enum Seed {
    static let version = 4
    /// The last seed version that brought new built-in decks. Later versions only retire decks.
    static let decksAdded = 3
    /// Built-in decks from earlier versions that were removed: the original sample decks (v2), the
    /// three 50-word TOEIC decks that became the TOEIC day decks (v3) and the TOEFL decks (v4).
    static let retiredIDs: Set<String> = ["proverbs", "http-status", "git", "js-methods", "elements", "capitals",
                                          "toeic-1", "toeic-2", "toeic-3", "toefl-1", "toefl-2", "toefl-3"]

    /// Drops retired built-in decks, once per seed version. Built-in decks are only added for data
    /// older than `decksAdded`, so a deck the user deleted does not come back on an update.
    static func migrate(_ decks: [Deck], from version: Int, seed: [Deck]) -> [Deck] {
        guard version < Self.version else { return decks }
        let kept = decks.filter { !retiredIDs.contains($0.id) }
        guard version < decksAdded else { return kept }
        let missing = seed.filter { s in !kept.contains { $0.id == s.id } }
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
        let open = decks.first { $0.id == deckID }?.category.trimmingCharacters(in: .whitespaces) ?? ""
        return Set(decks.map { $0.category.trimmingCharacters(in: .whitespaces) }).subtracting([open])
    }

    /// Groups decks by category in order of first appearance; uncategorized decks go last.
    static func group(_ decks: [Deck]) -> [(category: String, decks: [Deck])] {
        var order: [String] = []
        var groups: [String: [Deck]] = [:]
        for deck in decks {
            let name = deck.category.trimmingCharacters(in: .whitespaces)
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(deck)
        }
        let named = order.filter { !$0.isEmpty }.map { ($0, groups[$0]!) }
        return named + (groups[""].map { [("", $0)] } ?? [])
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
    static func parseCardsDetailed(_ text: String) -> (cards: [Card], skipped: Int) {
        var cards: [Card] = []
        var skipped = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let sep = separators.first(where: { line.contains($0) }),
                  let range = line.range(of: sep) else { skipped += 1; continue }
            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty { cards.append(Card(key, value)) } else { skipped += 1 }
        }
        return (cards, skipped)
    }

    static func serialize(_ cards: [Card]) -> String {
        cards.map { card in
            card.key.contains("=") || card.key.contains(":")
                ? "\(card.key)\t\(card.value)"
                : "\(card.key) = \(card.value)"
        }.joined(separator: "\n")
    }

    /// Splits an answer like "지원하다, 신청하다" into the answers that are accepted. Any one of
    /// them completes the card. A comma between two digits ("1,000") does not split.
    static func alternatives(_ answer: String) -> [String] {
        let s = normalize(answer).trimmingCharacters(in: .whitespaces)
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
    }

    enum Outcome { case none, advance, reveal, shake }

    static let requeueGap = 4
    static let maxRequeues = 3

    let items: [Item]
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

    /// Multiple choice: options per card, 0 when typing. Reverse is ignored with choices.
    let choiceCount: Int
    private(set) var choices: [String] = []
    private(set) var wrongPicks: Set<Int> = []
    @ObservationIgnored private var rng: AnyRandom

    convenience init(cards: [Card], shuffle: Bool = true, reverse: Bool = false, choices: Int = 0) {
        var rng = SystemRandomNumberGenerator()
        self.init(cards: cards, shuffle: shuffle, reverse: reverse, choices: choices, using: &rng)
    }

    init<R: RandomNumberGenerator>(cards: [Card], shuffle: Bool, reverse: Bool, choices: Int = 0, using rng: inout R) {
        let reverse = choices > 1 ? false : reverse
        choiceCount = choices > 1 ? choices : 0
        self.rng = AnyRandom(rng)
        items = cards.enumerated().map { i, card in
            let answer = Core.normalize(reverse ? card.key : card.value)
            return Item(id: i, q: reverse ? card.value : card.key, a: answer, alts: Core.alternatives(answer))
        }
        let order = Array(items.indices)
        queue = shuffle ? order.shuffled(using: &rng) : order
        self.choices = buildChoices()
    }

    /// The answer plus distractors drawn from other cards' answers, shuffled.
    private func buildChoices() -> [String] {
        guard choiceCount > 0, let card = current else { return [] }
        // Options that share a meaning with the answer would also be right, so they are left out.
        let own = Set(card.alts)
        var seen: Set<String> = [card.a]
        var pool: [String] = []
        for item in items where !seen.contains(item.a) && own.isDisjoint(with: item.alts) {
            seen.insert(item.a)
            pool.append(item.a)
        }
        pool.shuffle(using: &rng)
        var options = [card.a] + pool.prefix(choiceCount - 1)
        options.shuffle(using: &rng)
        return options
    }

    var answerIndex: Int? { current.flatMap { choices.firstIndex(of: $0.a) } }

    enum ChoiceResult { case none, advance, wrong }

    /// Picks option `index`.
    @discardableResult
    func choose(_ index: Int, at now: TimeInterval) -> ChoiceResult {
        guard let card = current, choices.indices.contains(index) else { return .none }
        if cardStart == nil { cardStart = now }
        if choices[index] == card.a {
            complete(at: now)
            return .advance
        }
        hadError = true
        wrongPicks.insert(index)
        return .wrong
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
        wrongPicks = []
        choices = buildChoices()
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

/// Type-erased random number generator, so a session can keep the one it was given.
struct AnyRandom: RandomNumberGenerator {
    private var base: any RandomNumberGenerator
    init(_ base: any RandomNumberGenerator) { self.base = base }
    mutating func next() -> UInt64 { base.next() }
}
