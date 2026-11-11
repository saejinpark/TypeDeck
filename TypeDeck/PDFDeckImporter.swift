import AppKit
import Foundation
import PDFKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reads the text of a PDF. Pages without a text layer (scans) go through Vision OCR.
enum PDFTextExtractor {
    struct Result {
        var text: String
        var pageCount: Int
        var ocrPages: Int
    }

    static func extract(from url: URL, progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> Result {
        guard let document = PDFDocument(url: url) else { throw ImportError.unreadable }
        var parts: [String] = []
        var ocrPages = 0
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            await progress(i + 1, document.pageCount)
            guard let page = document.page(at: i) else { continue }
            let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if layer.count >= 20 {
                parts.append(layer)
            } else if let ocr = recognize(page), !ocr.isEmpty {
                parts.append(ocr)
                ocrPages += 1
            }
        }
        return Result(text: cleanPages(parts).joined(separator: "\n\n"), pageCount: document.pageCount, ocrPages: ocrPages)
    }

    /// Drops what is printed on the page rather than written in it: running headers and footers
    /// (a short line that repeats on at least a quarter of the pages, and on three or more), page
    /// numbers, and table-of-contents lines with dot leaders.
    static func cleanPages(_ pages: [String]) -> [String] {
        let lines = pages.map { $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) } }
        var pagesWith: [String: Int] = [:]
        for page in lines { for line in Set(page) where !line.isEmpty && line.count <= 60 { pagesWith[line, default: 0] += 1 } }
        let repeats = max(3, (pages.count + 3) / 4)
        return lines.map { page in
            page.filter { line in
                !line.isEmpty
                    && (pagesWith[line] ?? 0) < repeats
                    && line.wholeMatch(of: /[\d\s\-–—\/|.]{1,9}/) == nil
                    && !line.contains(/[…·.]{4,}/)
            }.joined(separator: "\n")
        }
    }

    private static func recognize(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 2000 / max(bounds.width, bounds.height, 1)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Splits text into pieces of at most `limit` characters, at line breaks where possible.
    static func chunks(_ text: String, limit: Int = 1400) -> [String] {
        var out: [String] = []
        var current = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var pieces = [line]
            if line.count > limit {
                pieces = stride(from: 0, to: line.count, by: limit).map { start in
                    let a = line.index(line.startIndex, offsetBy: start)
                    let b = line.index(a, offsetBy: min(limit, line.count - start))
                    return String(line[a..<b])
                }
            }
            for piece in pieces {
                if current.count + piece.count + 1 > limit, !current.isEmpty {
                    out.append(current)
                    current = ""
                }
                current += current.isEmpty ? piece : "\n" + piece
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

enum ImportError: LocalizedError {
    case unreadable
    case noText
    case noCards
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "PDF를 열 수 없어요."
        case .noText: return "PDF에서 글자를 찾지 못했어요."
        case .noCards: return "이 PDF에서 카드로 만들 만한 내용을 찾지 못했어요."
        case .unavailable(let reason): return reason
        }
    }
}

/// Turns text into cards with the on-device Apple Intelligence model.
enum DeckGenerator {
    /// nil when the model can be used, otherwise a reason to show.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "이 Mac은 Apple Intelligence를 지원하지 않아요."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "시스템 설정에서 Apple Intelligence를 켜 주세요."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence 모델을 준비하는 중이에요. 잠시 후 다시 시도해 주세요."
            case .unavailable:
                return "지금은 Apple Intelligence를 쓸 수 없어요."
            }
        }
        #endif
        return "Apple Intelligence는 macOS 26 이상에서 쓸 수 있어요."
    }

    struct Output {
        var cards: [Card]
        var failedChunks: Int
    }

    /// The longest key kept: a term or a question, not a sentence copied from the page.
    static let maxKeyLength = 50

    /// Checks a card the model made from `source`. Drops empty cards, keys that are not in the
    /// source (the model made them up; spacing it restored does not count) or are whole sentences,
    /// cards whose answer is already in the key ("C-1 협착" → "협착"), questions when the source
    /// has no answers (the model would guess, and a wrong answer gets memorized), and repeats of a
    /// key that differ only in spacing or punctuation ("HAZOP)" and ", HAZOP)").
    static func accept(key rawKey: String, value rawValue: String, in source: String, seen: inout Set<String>) -> Card? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = letters(key), v = letters(value)
        let isQuestion = key.hasSuffix("?") || key.hasSuffix("？")
        guard !k.isEmpty, !v.isEmpty, key.count <= maxKeyLength, letters(source).contains(k), !k.contains(v),
              !isQuestion || hasAnswers(source), seen.insert(k).inserted else { return nil }
        return Card(key, value)
    }

    /// Whether a passage prints the answers to its questions (an answer key or worked solutions).
    static func hasAnswers(_ source: String) -> Bool {
        source.contains(/정답|해설|풀이|답\s*[:：]|(?i)answers?\b|(?i)solutions?\b/)
    }

    /// Letters and digits only, lowercased, for comparing cards.
    private static func letters(_ s: String) -> String {
        String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    static func cards(from chunks: [String], progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> Output {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            var cards: [Card] = []
            var seen: Set<String> = []
            var failed = 0
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                await progress(i + 1, chunks.count)
                let (found, ok) = await generate(chunk, splitsLeft: 2)
                if !ok { failed += 1 }
                for card in found {
                    if let kept = accept(key: card.key, value: card.value, in: chunk, seen: &seen) { cards.append(kept) }
                }
            }
            return Output(cards: cards, failedChunks: failed)
        }
        #endif
        throw ImportError.unavailable(unavailableReason ?? "")
    }

    #if canImport(FoundationModels)
    static let instructions = """
    You turn study material into flashcards for a typing practice app, where the user types each answer from memory.
    Each card has a key (a word, term or question) and a value (its meaning, definition or answer).
    Prefer pairs the text already states: "word - meaning", "term: definition", glossary entries, question and answer.
    A practice question makes a card only when the text itself gives its answer (an answer key, a solution).
    Never answer a question yourself: a wrong answer would be memorized.
    If the text has no such pairs, make cards for its important terms with a short definition taken from the text.
    Shorten long definitions to their core in a few words; never copy a long sentence.
    The key is a term, a name or a question, never a whole instruction or a sentence copied from a table.
    The value must not repeat the key; a card whose answer is written in its question is useless.
    Use only information in the text. Keep the original language; do not translate.
    Text taken from a PDF may have lost the spaces between Korean words; write keys and values with natural spacing.
    Keep each value short, ideally under 30 characters.
    Skip headings, page numbers, example sentences, and filled-in forms or worked examples: people's names,
    dates, scores, codes and row labels of a sample worksheet are not things to memorize.
    If nothing in the text can become a card, return an empty list.
    """

    /// Returns the cards and whether the chunk was processed. Chunks that fail are split and retried.
    @available(macOS 26.0, *)
    private static func generate(_ chunk: String, splitsLeft: Int) async -> ([GeneratedCard], Bool) {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: "Make flashcards from this text:\n\n\(chunk)",
                generating: GeneratedDeck.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return (response.content.cards, true)
        } catch is CancellationError {
            return ([], true)
        } catch {
            guard splitsLeft > 0, chunk.count > 200 else { return ([], false) }
            let halves = PDFTextExtractor.chunks(chunk, limit: chunk.count / 2 + 1)
            var all: [GeneratedCard] = []
            var ok = true
            for half in halves {
                let (found, halfOK) = await generate(half, splitsLeft: splitsLeft - 1)
                all += found
                ok = ok && halfOK
            }
            return (all, ok)
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedDeck {
    @Guide(description: "The things in the text most worth memorizing for an exam, in the order they appear", .maximumCount(20))
    var cards: [GeneratedCard]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedCard {
    @Guide(description: "A term, name or question from the text, under 40 characters, with natural word spacing")
    var key: String
    @Guide(description: "Its meaning, definition or answer in a few words, under 40 characters, with natural word spacing")
    var value: String
}
#endif
