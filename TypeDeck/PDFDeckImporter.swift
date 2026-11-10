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
        var title: String?
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
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(text: parts.joined(separator: "\n\n"), pageCount: document.pageCount,
                      ocrPages: ocrPages, title: title?.isEmpty == false ? title : nil)
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
                    let key = card.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = card.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, !value.isEmpty, key != value,
                          seen.insert(key.lowercased()).inserted else { continue }
                    cards.append(Card(key, value))
                }
            }
            return Output(cards: cards, failedChunks: failed)
        }
        #endif
        throw ImportError.unavailable(unavailableReason ?? "")
    }

    #if canImport(FoundationModels)
    static let instructions = """
    You turn study material into flashcards for a typing practice app.
    Each card has a key (a word, term or question) and a value (its meaning, definition or answer).
    Prefer pairs the text already states: "word - meaning", "term: definition", glossary entries, question and answer.
    If the text has no such pairs, make cards for its important terms with a short definition taken from the text.
    Use only information in the text. Keep the original language; do not translate.
    Keep each value short, ideally under 30 characters. Skip headings, page numbers and example sentences.
    If nothing in the text can become a card, return an empty list.
    """

    /// Returns the cards and whether the chunk was processed. Chunks that fail are split and retried.
    @available(macOS 26.0, *)
    private static func generate(_ chunk: String, splitsLeft: Int) async -> ([GeneratedCard], Bool) {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: "Make flashcards from this text:\n\n\(chunk)",
                generating: GeneratedDeck.self
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
    @Guide(description: "Flashcards found in the text, in the order they appear", .maximumCount(60))
    var cards: [GeneratedCard]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedCard {
    @Guide(description: "The word, term or question, as written in the text")
    var key: String
    @Guide(description: "Its meaning, definition or answer, short, as written in the text")
    var value: String
}
#endif
