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
    var cards: [Card]
}

struct DeckFile: Codable {
    var version = 1
    var decks: [Deck]
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
        var cards: [Card] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let sep = separators.first(where: { line.contains($0) }),
                  let range = line.range(of: sep) else { continue }
            let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty && !value.isEmpty { cards.append(Card(key, value)) }
        }
        return cards
    }

    static func serialize(_ cards: [Card]) -> String {
        cards.map { card in
            card.key.contains("=") || card.key.contains(":")
                ? "\(card.key)\t\(card.value)"
                : "\(card.key) = \(card.value)"
        }.joined(separator: "\n")
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
    }

    enum Outcome { case none, reveal, shake }

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

    convenience init(cards: [Card], shuffle: Bool = true, reverse: Bool = false) {
        var rng = SystemRandomNumberGenerator()
        self.init(cards: cards, shuffle: shuffle, reverse: reverse, using: &rng)
    }

    init<R: RandomNumberGenerator>(cards: [Card], shuffle: Bool, reverse: Bool, using rng: inout R) {
        items = cards.enumerated().map { i, card in
            Item(id: i,
                 q: reverse ? card.value : card.key,
                 a: Core.normalize(reverse ? card.key : card.value))
        }
        let order = Array(items.indices)
        queue = shuffle ? order.shuffled(using: &rng) : order
    }

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
        if typed == card.a {
            complete(at: now)
            return true
        }
        if Core.diff(answer: card.a, typed: typed, composing: composing)
            .contains(where: { $0.state == .bad || $0.state == .extra }) {
            hadError = true
        }
        return false
    }

    /// Like `input`, but text that runs past the answer completes the card and carries over.
    func feed(_ text: String, composing: Bool, at now: TimeInterval) -> (advanced: Int, rest: String) {
        var t = Core.normalize(text)
        var advanced = 0
        while let card = current, !composing, t.count > card.a.count, t.hasPrefix(card.a) {
            input(card.a, composing: false, at: now)
            advanced += 1
            t = String(t.dropFirst(card.a.count))
        }
        if finished { return (advanced, "") }
        if advanced > 0 && t.isEmpty { return (advanced, "") }
        if input(t, composing: composing, at: now) { return (advanced + 1, "") }
        return (advanced, t)
    }

    /// Return key. Reveals the answer the first time.
    func submit() -> Outcome {
        guard !finished else { return .none }
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
