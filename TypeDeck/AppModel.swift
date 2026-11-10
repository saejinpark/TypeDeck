import Foundation
import Observation

enum PracticeMode: String, CaseIterable, Identifiable {
    case copy, recall, choice
    var id: String { rawValue }
    var title: String {
        switch self {
        case .copy: return "따라치기"
        case .recall: return "외워치기"
        case .choice: return "5지선다"
        }
    }
}

/// A deck that is not saved yet, such as one made from a PDF.
struct DeckDraft: Hashable {
    let id = UUID()
    var name: String
    var category: String
    var cards: [Card]
    var note: String
}

enum EditorTarget: Identifiable, Hashable {
    case new
    case deck(String)
    case draft(DeckDraft)
    var id: String {
        switch self {
        case .new: return "new"
        case .deck(let id): return id
        case .draft(let d): return d.id.uuidString
        }
    }
}

@Observable
final class AppModel {
    private(set) var decks: [Deck] = []
    private(set) var session: Session?
    private(set) var selectedDeckID: String?

    var mode: PracticeMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            if (oldValue == .choice) != (mode == .choice) { startSession() }
        }
    }
    static let choiceCount = 5
    var collapsedCategories: Set<String> {
        didSet { defaults.set(Array(collapsedCategories), forKey: Keys.collapsed) }
    }
    var reverse: Bool {
        didSet { defaults.set(reverse, forKey: Keys.reverse); startSession() }
    }
    var shuffle: Bool {
        didSet { defaults.set(shuffle, forKey: Keys.shuffle); startSession() }
    }

    var editorTarget: EditorTarget?

    // MARK: PDF import state
    struct ImportStatus: Equatable {
        var fileName: String
        var phase: String
        var progress: Double
    }
    var showPDFImporter = false
    private(set) var importStatus: ImportStatus?
    var importError: String?
    @ObservationIgnored private var importTask: Task<Void, Never>?
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
        static let seedVersion = "seedVersion", collapsed = "collapsedCategories"
    }

    init(storeURL: URL? = AppModel.defaultStoreURL, defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.storeURL = storeURL
        self.defaults = defaults
        seed = Self.loadDecks(from: bundle.url(forResource: "decks", withExtension: "json")) ?? []
        mode = PracticeMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .copy
        reverse = defaults.bool(forKey: Keys.reverse)
        shuffle = defaults.object(forKey: Keys.shuffle) as? Bool ?? true
        collapsedCategories = Set(defaults.stringArray(forKey: Keys.collapsed) ?? [])
        if let stored = Self.loadDecks(from: storeURL) {
            decks = Seed.migrate(stored, from: defaults.integer(forKey: Keys.seedVersion), seed: seed)
        } else {
            decks = seed
        }
        defaults.set(Seed.version, forKey: Keys.seedVersion)
        let saved = defaults.string(forKey: Keys.deck)
        selectedDeckID = decks.contains { $0.id == saved } ? saved : decks.first?.id
        save()
        startSession()
    }

    var categories: [String] { Seed.group(decks).map(\.category).filter { !$0.isEmpty } }

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

    func upsert(id: String?, name: String, category: String, cards: [Card]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let i = decks.firstIndex(where: { $0.id == id }) {
            decks[i].name = name.isEmpty ? decks[i].name : name
            decks[i].category = category
            decks[i].cards = cards
            save()
            if id == selectedDeckID { startSession() }
        } else {
            let deck = Deck(id: "d" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36),
                            name: name.isEmpty ? "새 덱" : name, category: category, cards: cards)
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
        session = sessionCards.isEmpty ? nil : Session(cards: sessionCards, shuffle: shuffle, reverse: reverse,
                                                        choices: mode == .choice ? Self.choiceCount : 0)
        resetToken += 1
        refocus()
    }

    func refocus() { focusToken += 1 }

    func keystroke() {
        session?.keystroke(at: now)
    }

    /// Returns the text to keep in the input when the card was completed, nil otherwise.
    func handleText(_ text: String, composing: Bool) -> String? {
        guard let session, !session.finished, mode != .choice else { return "" }
        lastInput = Date()
        let result = session.feed(text, composing: composing, at: now)
        return result.advanced > 0 ? result.rest : nil
    }

    /// Number keys in multiple choice. Returns false when the key should be typed instead.
    func handleChoiceKey(_ number: Int) -> Bool {
        guard mode == .choice, let session, !session.finished else { return false }
        choose(number - 1)
        return true
    }

    func choose(_ index: Int) {
        guard let session else { return }
        lastInput = Date()
        if session.choose(index, at: now) == .wrong { shakeToken += 1 }
    }

    /// Returns true when the input buffer should be cleared because the card advanced.
    @discardableResult
    func handle(_ command: TypingInputView.Command) -> Bool {
        guard let session else { return false }
        lastInput = Date()
        switch command {
        case .submit:
            if session.finished { startSession(); return false }
            switch session.submit(at: now) {
            case .advance: return true
            case .shake: shakeToken += 1
            default: break
            }
        case .skip:
            if session.finished {
                if !session.missed.isEmpty { startSession(onlyMissed: true) }
                return false
            }
            session.skip(at: now)
            return true
        case .clear:
            session.input("", composing: false, at: now)
        }
        return false
    }

    // MARK: PDF -> deck

    /// Reads a PDF, asks Apple Intelligence for cards and opens them in the editor as a draft.
    func importPDF(at url: URL) {
        importTask?.cancel()
        let fileName = url.deletingPathExtension().lastPathComponent
        importStatus = ImportStatus(fileName: fileName, phase: "PDF 읽는 중", progress: 0)
        importTask = Task { @MainActor [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let pdf = try await PDFTextExtractor.extract(from: url) { page, total in
                    await MainActor.run {
                        self?.importStatus?.phase = "페이지 읽는 중 \(page)/\(total)"
                        self?.importStatus?.progress = 0.2 * Double(page) / Double(max(total, 1))
                    }
                }
                guard !pdf.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.noText }
                let draft = try await Self.makeDraft(from: pdf, fileName: fileName) { done, total in
                    await MainActor.run {
                        self?.importStatus?.phase = "Apple Intelligence가 카드를 만드는 중 \(done)/\(total)"
                        self?.importStatus?.progress = 0.2 + 0.8 * Double(done - 1) / Double(max(total, 1))
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.importStatus = nil
                self.editorTarget = .draft(draft)
            } catch is CancellationError {
                self?.importStatus = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.importStatus = nil
                self.importError = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importStatus = nil
    }

    private static func makeDraft(from pdf: PDFTextExtractor.Result, fileName: String,
                                  progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> DeckDraft {
        let name = pdf.title ?? fileName
        let ocrNote = pdf.ocrPages > 0 ? " 스캔된 \(pdf.ocrPages)쪽은 문자 인식으로 읽었어요." : ""
        if let reason = DeckGenerator.unavailableReason {
            // Without Apple Intelligence, fall back to lines that already look like "key = value".
            let parsed = Core.parseCardsDetailed(pdf.text).cards
            guard !parsed.isEmpty else { throw ImportError.unavailable(reason) }
            return DeckDraft(name: name, category: "PDF", cards: parsed,
                             note: "\(reason) 대신 구분자가 있는 줄 \(parsed.count)개를 카드로 만들었어요.\(ocrNote)")
        }
        let chunks = PDFTextExtractor.chunks(pdf.text)
        let output = try await DeckGenerator.cards(from: chunks, progress: progress)
        guard !output.cards.isEmpty else { throw ImportError.noCards }
        let failed = output.failedChunks > 0 ? " 처리하지 못한 구간이 \(output.failedChunks)개 있어요." : ""
        return DeckDraft(name: name, category: "PDF", cards: output.cards,
                         note: "Apple Intelligence가 \(output.cards.count)장을 만들었어요. 저장하기 전에 확인해 주세요.\(ocrNote)\(failed)")
    }
}
