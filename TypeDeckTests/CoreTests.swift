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
        #expect(s.submit() == .reveal)
        #expect(s.submit() == .shake)
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
