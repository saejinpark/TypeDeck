import Foundation
import Testing
@testable import TypeDeck

struct CoreTests {
    @Test func parsesSupportedSeparators() {
        let cards = Core.parseCards("a = 1\nb\t2\n# comment\n\nc: 3\nd=4\nno separator\ne = x = y\nf : git log --oneline")
        #expect(cards == [Card("a", "1"), Card("b", "2"), Card("c", "3"), Card("d", "4"), Card("e", "x = y"), Card("f", "git log --oneline")])
    }

    @Test func serializeRoundTrips() {
        let cards = [Card("200", "OK"), Card("a=b", "c"), Card("소 잃고", "외양간 고친다")]
        #expect(Core.parseCards(Core.serialize(cards)) == cards)
    }

    @Test func diffStates() {
        #expect(Core.diff(answer: "서울", typed: "서우", composing: true).map(\.state) == [.ok, .composing])
        #expect(Core.diff(answer: "서울", typed: "서우", composing: false).map(\.state) == [.ok, .bad])
        #expect(Core.diff(answer: "OK", typed: "O", composing: false).map(\.state) == [.ok, .todo])
        #expect(Core.diff(answer: "OK", typed: "OKK", composing: false).map(\.state) == [.ok, .ok, .extra])
    }

    @Test func completingAdvancesEvenWhileComposing() {
        let s = Session(cards: [Card("대한민국", "서울"), Card("일본", "도쿄")], shuffle: false)
        #expect(!s.input("서우", composing: true, at: 0))
        #expect(!s.hadError)
        #expect(s.input("서울", composing: true, at: 1))
        #expect(s.current?.q == "일본")
        #expect(s.typed.isEmpty)
        #expect(s.streak == 1)
    }

    @Test func wrongCharacterRequeuesTheCard() {
        let cards = (0..<10).map { Card("k\($0)", "v\($0)") }
        let s = Session(cards: cards, shuffle: false)
        s.input("x", composing: false, at: 0)
        #expect(s.hadError)
        #expect(s.input("v0", composing: false, at: 1))
        #expect(s.queue.count == 11)
        #expect(s.queue[1 + Session.requeueGap] == 0)
        #expect(s.missed.count == 1)
    }

    @Test func revealAndSkipCountAsMisses() {
        let s = Session(cards: [Card("a", "1"), Card("b", "2")], shuffle: false)
        #expect(s.submit(at: 0) == .reveal)
        #expect(s.submit(at: 0) == .shake)
        #expect(s.input("1", composing: false, at: 1))
        s.skip(at: 2)
        #expect(s.accuracy == 0)
        #expect(s.queue == [0, 1, 0, 1])
        s.input("1", composing: false, at: 3)
        s.input("2", composing: false, at: 4)
        #expect(s.finished)
        #expect(s.accuracy == 0)
    }

    @Test func reverseModeAndDecomposedInput() {
        let s = Session(cards: [Card("서울", "수도")], shuffle: false, reverse: true)
        #expect(s.current?.q == "수도")
        #expect(s.input("서울".decomposedStringWithCanonicalMapping, composing: false, at: 0))
        #expect(s.finished)
    }

    @Test func feedCarriesOverflowToNextCards() {
        let s = Session(cards: [Card("a", "OK"), Card("b", "Found"), Card("c", "Gone")], shuffle: false)
        let r = s.feed("OKFoundGo", composing: false, at: 0)
        #expect(r.advanced == 2 && r.rest == "Go")
        #expect(s.current?.a == "Gone")
        #expect(s.typed == "Go")
        #expect(s.feed("Gone", composing: false, at: 1).advanced == 1)
        #expect(s.finished)
    }

    @Test func feedDoesNotCarryWhileComposing() {
        let s = Session(cards: [Card("a", "서울"), Card("b", "도쿄")], shuffle: false)
        #expect(s.feed("서울도", composing: true, at: 0).advanced == 0)
        #expect(s.current?.a == "서울")
    }

    @Test func keystrokesPerMinute() {
        let s = Session(cards: [Card("a", "abc")], shuffle: false)
        s.keystroke(at: 0); s.keystroke(at: 0.5); s.keystroke(at: 1)
        s.input("abc", composing: false, at: 3)
        #expect(s.kpm.map { Int($0.rounded()) } == 60)
        #expect(s.accuracy == 1)
    }

    @Test func bundledDecksDecode() throws {
        let url = try #require(Bundle(for: Session.self).url(forResource: "decks", withExtension: "json"))
        let file = try JSONDecoder().decode(DeckFile.self, from: Data(contentsOf: url))
        #expect(file.decks.count >= 6)
        #expect(file.decks.allSatisfy { !$0.cards.isEmpty })
        let toeic = file.decks.filter { $0.id.hasPrefix("toeic-") }.flatMap(\.cards)
        #expect(toeic.count > 2500)
        #expect(Set(toeic.map { $0.key.lowercased() }).count == toeic.count)
    }

    @Test func parseCardsDetailedCountsSkippedLines() {
        let r = Core.parseCardsDetailed("a = 1\nno separator\n\n# note\nb =\nc\t3")
        #expect(r.cards == [Card("a", "1"), Card("c", "3")])
        #expect(r.skipped == 2)
    }
}

struct EditorRowsTests {
    @Test func alwaysKeepsOneEmptyRowAtTheEnd() {
        var rows = EditorRows()
        #expect(rows.rows.count == 1)
        rows.set(rows.rows[0].id, q: "대한민국")
        #expect(rows.rows.count == 2)
        rows.set(rows.rows[0].id, a: "서울")
        #expect(rows.cards == [Card("대한민국", "서울")])
        rows.set(rows.rows[0].id, q: "", a: "")
        #expect(rows.rows.count == 1)
    }

    @Test func incompleteRowsAreCountedButNotSaved() {
        var rows = EditorRows(cards: [Card("a", "1")])
        rows.set(rows.rows[1].id, q: "b")
        #expect(rows.incompleteCount == 1)
        #expect(rows.cards == [Card("a", "1")])
        #expect(rows.firstIncomplete?.q == "b")
    }

    @Test func pasteReplacesEmptyRowAndInsertsAfterFilledOne() {
        var rows = EditorRows(cards: [Card("a", "1")])
        let r = rows.paste("b\t2\nc = 3\nnope", at: rows.rows[1].id)
        #expect(r.added == 2 && r.skipped == 1)
        #expect(rows.cards == [Card("a", "1"), Card("b", "2"), Card("c", "3")])
        #expect(r.next == rows.rows.last?.id)
        _ = rows.paste("x = 9", at: rows.rows[0].id)
        #expect(rows.cards.map(\.key) == ["a", "x", "b", "c"])
    }

    @Test func removingTheLastCardLeavesTheEmptyRow() {
        var rows = EditorRows(cards: [Card("a", "1"), Card("b", "2")])
        rows.remove(rows.rows[0].id)
        #expect(rows.cards == [Card("b", "2")])
        rows.remove(rows.rows[1].id) // the empty row: stays
        #expect(rows.rows.count == 2)
    }
}

struct ChoiceAndSeedTests {
    @Test func multipleChoiceOffersAnswerAndDistinctDistractors() {
        let cards = (0..<8).map { Card("w\($0)", "m\($0)") }
        let s = Session(cards: cards, shuffle: false, reverse: true, choices: 5)
        #expect(s.current?.q == "w0", "reverse is ignored in multiple choice")
        #expect(s.choices.count == 5)
        #expect(Set(s.choices).count == 5)
        #expect(s.choices.contains("m0"))
        let wrong = s.choices.firstIndex { $0 != "m0" }!
        #expect(s.choose(wrong, at: 0) == .wrong)
        #expect(s.wrongPicks.contains(wrong))
        #expect(s.choose(s.answerIndex!, at: 1) == .advance)
        #expect(s.current?.q == "w1")
        #expect(s.choices.count == 5)
        #expect(s.missed.count == 1)
        #expect(s.queue.count == 9)
    }

    @Test func smallDeckUsesWhatItHas() {
        let s = Session(cards: [Card("a", "1"), Card("b", "2"), Card("c", "2")], shuffle: false, choices: 5)
        #expect(s.choices.sorted() == ["1", "2"])
        #expect(s.choose(9, at: 0) == .none)
    }

    @Test func migrationReplacesRetiredDecksOnce() {
        let seed = [Deck(id: "toeic-basic-01", name: "T", category: "토익", cards: [Card("a", "1")]),
                    Deck(id: "toeic-mid-01", name: "U", cards: [Card("b", "2")])]
        let old = [Deck(id: "proverbs", name: "P", cards: []), Deck(id: "mine", name: "M", cards: [Card("x", "y")])]
        let next = Seed.migrate(old, from: 1, seed: seed)
        #expect(next.map(\.id) == ["toeic-basic-01", "toeic-mid-01", "mine"])
        #expect(Seed.migrate(next, from: Seed.version, seed: seed) == next)
        let v2 = [Deck(id: "toeic-1", name: "old", cards: []), Deck(id: "toefl-1", name: "F", cards: []),
                  Deck(id: "mine", name: "M", cards: [])]
        #expect(Seed.migrate(v2, from: 2, seed: seed).map(\.id) == ["toeic-basic-01", "toeic-mid-01", "mine"])
        let v3 = [Deck(id: "toeic-basic-01", name: "T", cards: []), Deck(id: "toefl-2", name: "F", cards: []),
                  Deck(id: "mine", name: "M", cards: [])]
        #expect(Seed.migrate(v3, from: 3, seed: seed).map(\.id) == ["toeic-basic-01", "mine"])
    }

    @Test func groupingKeepsOrderAndPutsUncategorizedLast() {
        let decks = [Deck(id: "1", name: "", category: "토플", cards: []), Deck(id: "2", name: "", cards: []),
                     Deck(id: "3", name: "", category: "토익", cards: []), Deck(id: "4", name: "", category: "토플", cards: [])]
        let g = Seed.group(decks)
        #expect(g.map(\.category) == ["토플", "토익", ""])
        #expect(g[0].decks.map(\.id) == ["1", "4"])
    }

    @Test func onlyTheCurrentDecksCategoryStartsOpen() {
        let decks = [Deck(id: "a", name: "", category: "토익 기초", cards: []), Deck(id: "b", name: "", category: "토익 기초", cards: []),
                     Deck(id: "c", name: "", category: "토플", cards: []), Deck(id: "d", name: "", cards: [])]
        #expect(Seed.collapsed(except: "c", in: decks) == ["토익 기초", ""])
        #expect(Seed.collapsed(except: "missing", in: decks) == ["토익 기초", "토플"])
    }

    @Test func decksWithoutCategoryStillDecode() throws {
        let json = #"{"version":1,"decks":[{"id":"a","name":"A","cards":[["k","v"]]}]}"#
        let file = try JSONDecoder().decode(DeckFile.self, from: Data(json.utf8))
        #expect(file.decks[0].category == "")
    }
}

struct PDFChunkTests {
    @Test func chunksRespectTheLimitAndKeepEveryLine() {
        let lines = (1...40).map { "word\($0) - 뜻\($0)" }
        let chunks = PDFTextExtractor.chunks(lines.joined(separator: "\n"), limit: 100)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(chunks.joined(separator: "\n").components(separatedBy: "\n") == lines)
    }

    @Test func veryLongLinesAreCut() {
        let chunks = PDFTextExtractor.chunks(String(repeating: "가", count: 250), limit: 100)
        #expect(chunks.map(\.count) == [100, 100, 50])
    }
}

struct MultipleMeaningTests {
    @Test func alternativesSplitOnCommasButKeepNumbers() {
        #expect(Core.alternatives("지원하다, 신청하다") == ["지원하다", "신청하다"])
        #expect(Core.alternatives("지원하다,신청하다 ,") == ["지원하다", "신청하다"])
        #expect(Core.alternatives("1,000") == ["1,000"])
        #expect(Core.alternatives("apply") == ["apply"])
        #expect(Core.pickTarget(["지원하다", "신청하다"], typed: "신") == "신청하다")
        #expect(Core.pickTarget(["지원하다", "신청하다"], typed: "") == "지원하다")
    }

    @Test func anyMeaningCompletesTheCard() {
        let s = Session(cards: [Card("apply", "지원하다, 신청하다"), Card("hire", "고용하다")], shuffle: false)
        #expect(!s.input("신청", composing: false, at: 0))
        #expect(s.target == "신청하다")
        #expect(!s.hadError)
        #expect(s.input("신청하다", composing: false, at: 10))
        #expect(s.current?.q == "hire")
        #expect(s.streak == 1)
    }

    @Test func meaningThatStartsALongerOneWaitsForReturn() {
        let s = Session(cards: [Card("a", "지원, 지원하다"), Card("b", "x")], shuffle: false)
        #expect(!s.input("지원", composing: false, at: 0))
        #expect(s.submit(at: 5) == .advance)
        #expect(s.current?.q == "b")
        #expect(s.streak == 1)
        let t = Session(cards: [Card("a", "지원, 지원하다"), Card("b", "x")], shuffle: false)
        #expect(t.input("지원하다", composing: false, at: 0))
    }

    @Test func pastedTextCarriesOverPastAShortMeaning() {
        let s = Session(cards: [Card("a", "가, 나"), Card("b", "다"), Card("c", "라")], shuffle: false)
        let r = s.feed("나다라", composing: false, at: 0)
        #expect(r.advanced == 3)
        #expect(s.finished)
    }

    @Test func choicesLeaveOutOptionsSharingAMeaning() {
        let cards = [Card("apply", "지원하다, 신청하다"), Card("register", "등록하다, 신청하다"),
                     Card("hire", "고용하다"), Card("fire", "해고하다")]
        for _ in 0..<20 {
            let s = Session(cards: cards, shuffle: false, choices: 5)
            #expect(!s.choices.contains("등록하다, 신청하다"))
            #expect(s.choices.count == 3)
        }
    }
}

@MainActor
struct SidebarStateTests {
    private func makeModel(seedVersion: Int?, collapsed: [String]?, deck: String?) -> AppModel {
        let suite = "TypeDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if let seedVersion { defaults.set(seedVersion, forKey: "seedVersion") }
        if let collapsed { defaults.set(collapsed, forKey: "collapsedCategories") }
        if let deck { defaults.set(deck, forKey: "selectedDeckID") }
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let bundle = Bundle(for: Session.self)
        if seedVersion != nil, let url = bundle.url(forResource: "decks", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            // An existing user: a saved deck list is already there.
            try? data.write(to: store)
        }
        return AppModel(storeURL: store, defaults: defaults, bundle: bundle)
    }

    @Test func firstLaunchAsksBeforeAddingDecks() {
        let model = makeModel(seedVersion: nil, collapsed: nil, deck: nil)
        #expect(model.deckPicker == .welcome)
        #expect(model.decks.isEmpty)
        let n = model.addBuiltIn(categories: ["토익 기초 (600+)", "토익 숙어"], firstRun: true)
        #expect(n == 32)
        #expect(model.deckPicker == nil)
        #expect(model.selectedDeckID == "toeic-basic-01")
        #expect(model.collapsedCategories == ["토익 숙어"])
    }

    @Test func firstLaunchCanStartEmpty() {
        let model = makeModel(seedVersion: nil, collapsed: nil, deck: nil)
        #expect(model.addBuiltIn(categories: [], firstRun: true) == 0)
        #expect(model.decks.isEmpty)
        #expect(model.selectedDeckID == nil)
    }

    @Test func deletingACategoryAndAddingItBack() {
        let model = makeModel(seedVersion: nil, collapsed: nil, deck: nil)
        model.addBuiltIn(categories: Set(Seed.group(model.seed).map(\.category)), firstRun: true)
        #expect(!model.decks.contains { $0.id.hasPrefix("toefl") })
        model.deleteCategory("토익 기초 (600+)")
        #expect(!model.decks.contains { $0.category == "토익 기초 (600+)" })
        #expect(model.selectedDeck?.category == "토익 중급 (800+)")
        #expect(model.addBuiltIn(categories: ["토익 기초 (600+)"], firstRun: false) == 28)
        #expect(model.decks.first?.id == "toeic-basic-01", "built-in decks keep the seed order")
    }

    @Test func selectedDecksCategoryIsOpenedEvenIfSavedClosed() {
        let model = makeModel(seedVersion: Seed.version, collapsed: ["토익 고급 (900+)", "토플"], deck: "toeic-adv-05")
        #expect(model.selectedDeckID == "toeic-adv-05")
        #expect(model.collapsedCategories == ["토플"])
    }

    @Test func collapseAllAndSelectReveals() {
        let model = makeModel(seedVersion: Seed.version, collapsed: [], deck: "toeic-adv-05")
        model.setAllCategories(open: false)
        #expect(model.allCategoriesCollapsed)
        model.select("toefl-1")
        #expect(!model.collapsedCategories.contains("토플"))
        model.setAllCategories(open: true)
        #expect(model.collapsedCategories.isEmpty)
    }
}

struct ColumnLayoutTests {
    @Test func columnsShareTheWidthAndStayUsable() {
        let c = ColumnLayout(width: 640, keyRatio: 0.4)
        #expect(c.key + c.value == c.available)
        #expect(abs(c.key - c.available * 0.4) <= 1)
        #expect(c.available == 546)
        #expect(ColumnLayout(width: 640, keyRatio: 0).key == 82, "never narrower than 15%")
        #expect(ColumnLayout(width: 640, keyRatio: 2).key == 437, "never wider than 80%")
        #expect(c.dividerX > ColumnLayout.inset + ColumnLayout.number + c.key)
    }
}

struct CategoryListTests {
    @Test func emptyCategoriesComeFromTheListInOrder() {
        let decks = [Deck(id: "1", name: "", category: "토익", cards: []), Deck(id: "2", name: "", cards: []),
                     Deck(id: "3", name: "", category: " 정보처리기사 ", cards: [])]
        let g = Seed.group(decks, order: ["정보처리기사", "한국사"])
        #expect(g.map(\.category) == ["정보처리기사", "한국사", "토익", ""])
        #expect(g[1].decks.isEmpty)
        #expect(Seed.sync(["한국사"], with: decks) == ["한국사", "토익", "정보처리기사"])
    }

    @Test func renameMovesDecksAndMerges() {
        let decks = [Deck(id: "1", name: "", category: "A", cards: []), Deck(id: "2", name: "", category: "B", cards: [])]
        let r = Seed.rename("A", to: "  새  이름 ", decks: decks, order: ["A", "B", "C"])
        #expect(r.order == ["새 이름", "B", "C"])
        #expect(r.decks[0].category == "새 이름")
        let m = Seed.rename("A", to: "C", decks: decks, order: ["A", "B", "C"])
        #expect(m.order == ["B", "C"])
        #expect(m.decks[0].category == "C")
    }

    @Test func importReadsCSVWithQuotesTSVAndText() {
        let csv = "\u{FEFF}apply,\"지원하다, 신청하다\"\nhire,고용하다\n\"say \"\"hi\"\"\",인사\nonly\n"
        let r = Core.parseImport(csv, fileName: "w.csv")
        #expect(r.cards == [Card("apply", "지원하다, 신청하다"), Card("hire", "고용하다"), Card("say \"hi\"", "인사")])
        #expect(r.skipped == 1)
        #expect(Core.parseImport("a,b,c", fileName: "x.CSV").cards == [Card("a", "b, c")])
        #expect(Core.parseImport("a\t1, 2", fileName: "x.tsv").cards == [Card("a", "1, 2")])
        #expect(Core.parseImport("OSI 7계층 = 물리, 데이터링크", fileName: "notes.txt").cards == [Card("OSI 7계층", "물리, 데이터링크")])
    }
}

@MainActor
struct CategoryModelTests {
    private func model(store: URL, defaults: UserDefaults) -> AppModel {
        AppModel(storeURL: store, defaults: defaults, bundle: Bundle(for: Session.self))
    }

    @Test func emptyCategorySurvivesARelaunchAndGetsDecks() {
        let suite = "TypeDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        let first = model(store: store, defaults: defaults)
        first.addBuiltIn(categories: [], firstRun: true)
        #expect(first.createCategory("정보처리기사") == nil)
        #expect(first.createCategory(" 정보처리기사 ") != nil, "duplicates are refused")
        #expect(first.createCategory(Seed.uncategorized) != nil)
        #expect(first.groups.map(\.category) == ["정보처리기사"])

        let again = model(store: store, defaults: defaults)
        #expect(again.categories == ["정보처리기사"])
        again.upsert(id: nil, name: "네트워크", category: "정보처리기사", cards: [Card("OSI 1계층", "물리 계층")])
        #expect(again.selectedDeck?.category == "정보처리기사")
        #expect(again.renameCategory("정보처리기사", to: "정보처리기사 필기") == nil)
        #expect(again.selectedDeck?.category == "정보처리기사 필기")
        again.deleteCategory("정보처리기사 필기")
        #expect(again.decks.isEmpty)
        #expect(again.categories.isEmpty)
    }

    @Test func csvFileBecomesADraftInTheChosenCategory() throws {
        let suite = "TypeDeckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory
        let m = model(store: dir.appendingPathComponent("\(suite).json"), defaults: defaults)
        m.addBuiltIn(categories: [], firstRun: true)
        m.createCategory("한국사")
        let file = dir.appendingPathComponent("\(suite) 조선 왕.csv")
        try "태조,이성계\n세종,\"이도, 한글 창제\"\n".write(to: file, atomically: true, encoding: .utf8)
        m.importCategory = "한국사"
        m.importFile(at: file)
        guard case .draft(let draft) = m.editorTarget else { Issue.record("no draft"); return }
        #expect(draft.category == "한국사")
        #expect(draft.name == "\(suite) 조선 왕")
        #expect(draft.cards == [Card("태조", "이성계"), Card("세종", "이도, 한글 창제")])
    }
}
