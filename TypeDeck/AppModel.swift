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

/// The first-launch sheet that offers the TOEIC sample decks.
enum DeckPickerMode: String, Identifiable {
    case welcome
    var id: String { rawValue }
}

/// The name field shown to create or rename a category.
enum CategoryPrompt: Identifiable, Equatable {
    case new
    case rename(String)
    var id: String {
        switch self {
        case .new: return "new"
        case .rename(let c): return "rename:" + c
        }
    }
}

enum EditorTarget: Identifiable, Hashable {
    case new
    /// A new deck that starts in this category.
    case newIn(String)
    case deck(String)
    case draft(DeckDraft)
    var id: String {
        switch self {
        case .new: return "new"
        case .newIn(let c): return "new:" + c
        case .deck(let id): return id
        case .draft(let d): return d.id.uuidString
        }
    }
}

@Observable
final class AppModel {
    private(set) var decks: [Deck] = []
    /// The user's categories in sidebar order, including empty ones.
    private(set) var categoryOrder: [String] = []
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
    /// Category that a deck made from a file goes into; nil means the current deck's.
    var importCategory: String?
    var deckPicker: DeckPickerMode?
    var categoryPrompt: CategoryPrompt?
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
        seed = Self.loadFile(from: bundle.url(forResource: "decks", withExtension: "json"))?.decks ?? []
        mode = PracticeMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .copy
        reverse = defaults.bool(forKey: Keys.reverse)
        shuffle = defaults.object(forKey: Keys.shuffle) as? Bool ?? true
        collapsedCategories = Set(defaults.stringArray(forKey: Keys.collapsed) ?? [])
        let storedVersion = defaults.integer(forKey: Keys.seedVersion)
        let stored = Self.loadFile(from: storeURL)
        if let stored {
            decks = Seed.migrate(stored.decks, from: storedVersion, seed: seed)
            categoryOrder = Seed.sync(stored.categories ?? [], with: decks)
            defaults.set(Seed.version, forKey: Keys.seedVersion)
        } else {
            // First launch: nothing is stored until the welcome sheet is answered.
            decks = []
            deckPicker = .welcome
        }
        let saved = defaults.string(forKey: Keys.deck)
        selectedDeckID = decks.contains { $0.id == saved } ? saved : decks.first?.id
        // Before seed 3 there were only a few decks; now only the current deck's category starts open.
        if storedVersion < 3 { collapsedCategories = Seed.collapsed(except: selectedDeckID, in: decks) }
        reveal(selectedDeckID)
        if stored != nil { save() }
        startSession()
    }

    var categories: [String] { Seed.sync(categoryOrder, with: decks) }
    /// Sidebar groups, including empty categories.
    var groups: [(category: String, decks: [Deck])] { Seed.group(decks, order: categoryOrder) }

    static var defaultStoreURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("TypeDeck", isDirectory: true).appendingPathComponent("decks.json")
    }

    private static func loadFile(from url: URL?) -> DeckFile? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DeckFile.self, from: data)
    }

    private func save() {
        guard let storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            categoryOrder = Seed.sync(categoryOrder, with: decks)
            try encoder.encode(DeckFile(decks: decks, categories: categoryOrder)).write(to: storeURL, options: .atomic)
        } catch {
            NSLog("TypeDeck: could not save decks: \(error)")
        }
    }

    var selectedDeck: Deck? { decks.first { $0.id == selectedDeckID } }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Decks

    // MARK: Sidebar categories

    var allCategoriesCollapsed: Bool {
        groups.allSatisfy { collapsedCategories.contains($0.category) }
    }

    /// Creates an empty category. Returns a message when the name cannot be used.
    @discardableResult
    func createCategory(_ name: String) -> String? {
        let name = Seed.clean(name)
        if let problem = check(name, except: nil) { return problem }
        categoryOrder = categories + [name]
        collapsedCategories.remove(name)
        save()
        return nil
    }

    /// Renames a category; onto an existing name the two are merged.
    @discardableResult
    func renameCategory(_ from: String, to: String) -> String? {
        let name = Seed.clean(to)
        guard name != from else { return nil }
        if name.isEmpty { return "이름을 입력해 주세요." }
        if name == Seed.uncategorized { return "'\(Seed.uncategorized)'는 쓸 수 없는 이름이에요." }
        let r = Seed.rename(from, to: name, decks: decks, order: categoryOrder)
        decks = r.decks
        categoryOrder = r.order
        if collapsedCategories.remove(from) != nil { collapsedCategories.insert(name) }
        save()
        return nil
    }

    private func check(_ name: String, except: String?) -> String? {
        if name.isEmpty { return "이름을 입력해 주세요." }
        if name == Seed.uncategorized { return "'\(Seed.uncategorized)'는 쓸 수 없는 이름이에요." }
        if name != except && categories.contains(name) { return "'\(name)' 카테고리가 이미 있어요." }
        return nil
    }

    /// Opens the file picker for a deck made from a PDF or a text/CSV file.
    func startImport(into category: String?) {
        importCategory = category
        showPDFImporter = true
    }

    func toggleCategory(_ category: String) {
        if collapsedCategories.contains(category) {
            collapsedCategories.remove(category)
        } else {
            collapsedCategories.insert(category)
        }
    }

    func setAllCategories(open: Bool) {
        collapsedCategories = open ? [] : Set(groups.map(\.category))
    }

    /// Opens the category holding `id` so the selected deck is visible.
    func reveal(_ id: String?) {
        guard let deck = decks.first(where: { $0.id == id }) else { return }
        let category = deck.category.cleanedCategory
        if collapsedCategories.contains(category) { collapsedCategories.remove(category) }
    }

    func select(_ id: String?) {
        guard id != selectedDeckID else { refocus(); return }
        selectedDeckID = id
        reveal(id)
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
            reveal(id)
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

    /// Deletes a category and every deck in it ("" is the uncategorized group).
    func deleteCategory(_ category: String) {
        let ids = Set(decks.filter { $0.category.cleanedCategory == category }.map(\.id))
        decks.removeAll { ids.contains($0.id) }
        categoryOrder.removeAll { $0 == category }
        collapsedCategories.remove(category)
        save()
        if let id = selectedDeckID, ids.contains(id) {
            selectedDeckID = nil
            select(decks.first?.id)
        }
    }

    /// Finishes the first launch with the chosen sample categories (none means start empty).
    /// The samples are only offered here. Returns how many decks were added.
    @discardableResult
    func finishWelcome(sampleCategories: Set<String>) -> Int {
        let add = Seed.categories(seed: seed, decks: decks).filter { sampleCategories.contains($0.category) }.flatMap(\.missing)
        decks = Seed.adding(add, to: decks, seed: seed)
        save()
        defaults.set(Seed.version, forKey: Keys.seedVersion)
        selectedDeckID = nil
        select(decks.first?.id)
        collapsedCategories = Seed.collapsed(except: selectedDeckID, in: decks)
        deckPicker = nil
        refocus()
        return add.count
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
    /// The category a deck made from a file goes into.
    private var draftCategory: String { importCategory ?? selectedDeck?.category ?? "" }

    /// Makes a draft deck from a picked file: PDFs go through Apple Intelligence, text, CSV and
    /// TSV files are read line by line. The draft opens in the editor.
    func importFile(at url: URL) {
        if url.pathExtension.lowercased() == "pdf" { importPDF(at: url); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var encoding = String.Encoding.utf8
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, usedEncoding: &encoding)) else {
            importError = "파일을 읽지 못했어요. 텍스트(UTF-8) 파일인지 확인해 주세요."
            return
        }
        let fileName = url.lastPathComponent
        let parsed = Core.parseImport(text, fileName: fileName)
        guard !parsed.cards.isEmpty else {
            importError = "'\(fileName)'에서 카드를 찾지 못했어요. 한 줄에 \"키 = 값\"이나 탭, CSV 두 열로 적힌 파일을 써 주세요."
            return
        }
        let skipped = parsed.skipped > 0 ? " 나눌 수 없는 \(parsed.skipped)줄은 건너뛰었어요." : ""
        editorTarget = .draft(DeckDraft(name: url.deletingPathExtension().lastPathComponent, category: draftCategory,
                                        cards: parsed.cards, note: "'\(fileName)'에서 \(parsed.cards.count)장을 불러왔어요.\(skipped)"))
    }

    func importPDF(at url: URL) {
        importTask?.cancel()
        let fileName = url.deletingPathExtension().lastPathComponent
        let category = draftCategory
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
                let draft = try await Self.makeDraft(from: pdf, fileName: fileName, category: category) { done, total in
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

    private static func makeDraft(from pdf: PDFTextExtractor.Result, fileName: String, category: String,
                                  progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> DeckDraft {
        let name = pdf.title ?? fileName
        let ocrNote = pdf.ocrPages > 0 ? " 스캔된 \(pdf.ocrPages)쪽은 문자 인식으로 읽었어요." : ""
        if let reason = DeckGenerator.unavailableReason {
            // Without Apple Intelligence, fall back to lines that already look like "key = value".
            let parsed = Core.parseCardsDetailed(pdf.text).cards
            guard !parsed.isEmpty else { throw ImportError.unavailable(reason) }
            return DeckDraft(name: name, category: category, cards: parsed,
                             note: "\(reason) 대신 구분자가 있는 줄 \(parsed.count)개를 카드로 만들었어요.\(ocrNote)")
        }
        let chunks = PDFTextExtractor.chunks(pdf.text)
        let output = try await DeckGenerator.cards(from: chunks, progress: progress)
        guard !output.cards.isEmpty else { throw ImportError.noCards }
        let failed = output.failedChunks > 0 ? " 처리하지 못한 구간이 \(output.failedChunks)개 있어요." : ""
        return DeckDraft(name: name, category: category, cards: output.cards,
                         note: "Apple Intelligence가 \(output.cards.count)장을 만들었어요. 저장하기 전에 확인해 주세요.\(ocrNote)\(failed)")
    }
}
