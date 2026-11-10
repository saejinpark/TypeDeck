import Foundation
import Observation

enum PracticeMode: String, CaseIterable, Identifiable {
    case copy, recall
    var id: String { rawValue }
    var title: String { self == .copy ? "따라치기" : "외워치기" }
}

enum EditorTarget: Identifiable, Hashable {
    case new
    case deck(String)
    var id: String {
        switch self {
        case .new: return "new"
        case .deck(let id): return id
        }
    }
}

@Observable
final class AppModel {
    private(set) var decks: [Deck] = []
    private(set) var session: Session?
    private(set) var selectedDeckID: String?

    var mode: PracticeMode {
        didSet { defaults.set(mode.rawValue, forKey: Keys.mode) }
    }
    var reverse: Bool {
        didSet { defaults.set(reverse, forKey: Keys.reverse); startSession() }
    }
    var shuffle: Bool {
        didSet { defaults.set(shuffle, forKey: Keys.shuffle); startSession() }
    }

    var editorTarget: EditorTarget?
    /// Bumped to pull keyboard focus back to the typing view.
    private(set) var focusToken = 0
    /// Bumped to clear whatever is in the typing view's buffer.
    private(set) var resetToken = 0
    private(set) var shakeToken = 0
    private(set) var lastInput = Date()
    var isTypingFocused = false

    let seed: [Deck]
    private var sessionCards: [Card] = []
    private let storeURL: URL?
    private let defaults: UserDefaults

    private enum Keys {
        static let deck = "selectedDeckID", mode = "mode", reverse = "reverse", shuffle = "shuffle"
    }

    init(storeURL: URL? = AppModel.defaultStoreURL, defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.storeURL = storeURL
        self.defaults = defaults
        seed = Self.loadDecks(from: bundle.url(forResource: "decks", withExtension: "json")) ?? []
        mode = PracticeMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .copy
        reverse = defaults.bool(forKey: Keys.reverse)
        shuffle = defaults.object(forKey: Keys.shuffle) as? Bool ?? true
        decks = Self.loadDecks(from: storeURL) ?? seed
        let saved = defaults.string(forKey: Keys.deck)
        selectedDeckID = decks.contains { $0.id == saved } ? saved : decks.first?.id
        startSession()
    }

    static var defaultStoreURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("TypeDeck", isDirectory: true).appendingPathComponent("decks.json")
    }

    private static func loadDecks(from url: URL?) -> [Deck]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DeckFile.self, from: data).decks
    }

    private func save() {
        guard let storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(DeckFile(decks: decks)).write(to: storeURL, options: .atomic)
        } catch {
            NSLog("TypeDeck: could not save decks: \(error)")
        }
    }

    var selectedDeck: Deck? { decks.first { $0.id == selectedDeckID } }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Decks

    func select(_ id: String?) {
        guard id != selectedDeckID else { refocus(); return }
        selectedDeckID = id
        defaults.set(id, forKey: Keys.deck)
        startSession()
    }

    func upsert(id: String?, name: String, cards: [Card]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let i = decks.firstIndex(where: { $0.id == id }) {
            decks[i].name = name.isEmpty ? decks[i].name : name
            decks[i].cards = cards
            save()
            if id == selectedDeckID { startSession() }
        } else {
            let deck = Deck(id: "d" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36),
                            name: name.isEmpty ? "새 덱" : name, cards: cards)
            decks.append(deck)
            save()
            selectedDeckID = nil
            select(deck.id)
        }
    }

    func delete(_ id: String) {
        decks.removeAll { $0.id == id }
        save()
        if selectedDeckID == id {
            selectedDeckID = nil
            select(decks.first?.id)
        }
    }

    /// Adds back any built-in deck that was deleted. Returns how many were added.
    @discardableResult
    func restoreDefaults() -> Int {
        let missing = seed.filter { s in !decks.contains { $0.id == s.id } }
        decks.append(contentsOf: missing)
        save()
        if selectedDeck == nil { select(decks.first?.id) }
        return missing.count
    }

    // MARK: Practice

    func startSession(onlyMissed: Bool = false) {
        if onlyMissed, let session {
            sessionCards = session.missed.map { sessionCards[$0.id] }
        } else {
            sessionCards = selectedDeck?.cards ?? []
        }
        session = sessionCards.isEmpty ? nil : Session(cards: sessionCards, shuffle: shuffle, reverse: reverse)
        resetToken += 1
        refocus()
    }

    func refocus() { focusToken += 1 }

    func keystroke() {
        session?.keystroke(at: now)
    }

    /// Returns the text to keep in the input when the card was completed, nil otherwise.
    func handleText(_ text: String, composing: Bool) -> String? {
        guard let session, !session.finished else { return "" }
        lastInput = Date()
        let result = session.feed(text, composing: composing, at: now)
        return result.advanced > 0 ? result.rest : nil
    }

    func handle(_ command: TypingInputView.Command) {
        guard let session else { return }
        lastInput = Date()
        switch command {
        case .submit:
            if session.finished { startSession(); return }
            if session.submit() == .shake { shakeToken += 1 }
        case .skip:
            if session.finished {
                if !session.missed.isEmpty { startSession(onlyMissed: true) }
                return
            }
            session.skip(at: now)
        case .clear:
            session.input("", composing: false, at: now)
        }
    }
}
