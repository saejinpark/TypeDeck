#if DEBUG
import AppKit

/// Debug-only App Store screenshot scenes. Launch with `-screenshot <scene>`; the app then runs on
/// a throwaway store with sample data, so the user's own decks are never touched. Scenes:
/// practice, memo, editor, draft, summary.
@MainActor
enum ScreenshotDemo {
    static var scene: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screenshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func model() -> AppModel? {
        guard scene != nil else { return nil }
        let suite = "TypeDeck.screenshot"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("screenshot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(storeURL: dir.appendingPathComponent("decks.json"), defaults: UserDefaults(suiteName: suite)!)
    }

    /// Well-established facts only: these cards appear in the store listing.
    static let safetyCards: [Card] = [
        Card("도수율", "연근로시간 100만 시간당 재해 건수"),
        Card("강도율", "연근로시간 1,000시간당 근로손실일수"),
        Card("연천인율", "근로자 1,000명당 1년간 재해자 수"),
        Card("하인리히 법칙", "1 : 29 : 300", note: "중상 1 : 경상 29 : 무상해 사고 300"),
        Card("버드 법칙", "1 : 10 : 30 : 600", note: "중상 1 : 경상 10 : 무상해 사고 30 : 무상해 무사고 600"),
        Card("사망 근로손실일수", "7,500일"),
        Card("송기마스크", "산소 농도 18% 미만인 곳에서 쓰는 호흡용 보호구"),
        Card("안전모 AE종", "낙하·비래, 감전 위험 방지"),
    ]
    static let signCards: [Card] = [
        Card("금지 표지", "빨간 원과 사선"),
        Card("경고 표지", "노란 바탕, 검은 삼각형 테두리"),
        Card("지시 표지", "파란 원, 흰 그림"),
        Card("안내 표지", "녹색 바탕"),
    ]
    /// What Apple Intelligence actually made from the lecture-notes test PDF.
    static let draftCards: [Card] = [
        Card("도미노 이론", "재해 5단계 도미노 구조"), Card("도수율", "100만 시간당 재해 건수"),
        Card("강도율", "1,000시간당 근로손실일수"), Card("연천인율", "1,000명당 연간 재해자 수"),
        Card("안전 교육", "지식·기능·태도 3단계"), Card("태도 교육", "안전 습관 익히는 단계"),
        Card("OJT", "직장 내 개별 지도 방식"), Card("Off JT", "직장 밖 집단 교육 방식"),
        Card("방진마스크", "분진 작업용 보호구"), Card("방독마스크", "유해 가스 작업용"),
        Card("송기마스크", "산소 농도 18% 미만용"), Card("금지 표지", "빨간색 원 사선"),
        Card("경고 표지", "노란 바탕 검은 삼각형"), Card("지시 표지", "파란 원 흰 그림"),
        Card("안내 표지", "녹색 바탕"),
    ]

    static func arrange(_ m: AppModel) async {
        guard let scene else { return }
        m.finishWelcome(sampleCategories: Set(Seed.categories(seed: m.seed).map(\.category)))
        _ = m.createCategory("산업안전기사")
        m.upsert(id: nil, name: "안전관리론 01", category: "산업안전기사", cards: safetyCards)
        m.upsert(id: nil, name: "안전관리론 02", category: "산업안전기사", cards: signCards)
        m.shuffle = false
        // A learning record built by actually typing rounds: some days fully memorized.
        for (id, share) in [("toeic-basic-02", 1.0), ("toeic-basic-03", 1.0), ("toeic-basic-04", 1.0),
                            ("toeic-basic-05", 0.7), ("toeic-basic-06", 0.4), ("toeic-basic-01", 0.3)] {
            practice(m, id, share: share, rounds: 3)
        }
        place()
        switch scene {
        case "memo":
            m.mode = .copy
            m.showNotes = true
            m.select("en-sent-02")
            m.startSession()
            if let a = m.session?.current?.a { _ = m.handleText(a, composing: false) }
            if let a = m.session?.current?.a { _ = m.handleText(String(a.prefix(19)), composing: false) }
        case "editor":
            m.select(m.decks.first { $0.name == "안전관리론 01" }?.id)
            m.editorTarget = .deck(m.selectedDeckID ?? "")
        case "draft":
            m.select(m.decks.first { $0.name == "안전관리론 01" }?.id)
            m.editorTarget = .draft(DeckDraft(name: "산업안전기사 강의노트", category: "산업안전기사", cards: draftCards,
                message: "⚠︎ Apple Intelligence가 만든 초안 \(draftCards.count)장이에요. AI는 틀린 내용도 그럴듯하게 만들어요. 원문과 한 장씩 대조하고, 틀리거나 필요 없는 카드는 지운 뒤 저장하세요."))
        case "summary":
            m.mode = .recall
            let id = m.decks.first { $0.name == "안전관리론 01" }?.id
            practice(m, id ?? "", share: 1, rounds: 2)
            m.select(id)
            m.startSession()
            var n = 0
            // Typed a character at a time at a steady pace, so time and speed read like a real round.
            while let s = m.session, let c = s.current {
                if n == 3, s.missed.isEmpty {
                    try? await Task.sleep(for: .seconds(2))
                    _ = m.handle(.skip)
                } else {
                    var typed = ""
                    for ch in c.a {
                        m.keystroke()
                        typed.append(ch)
                        try? await Task.sleep(for: .milliseconds(170))
                        if m.handleText(typed, composing: false) != nil { break }
                    }
                }
                n += 1
            }
        default: // practice
            m.mode = .recall
            m.select("toeic-basic-01")
            m.startSession()
            _ = m.handleText("줄, 노선, 제", composing: false)
        }
    }

    /// Types rounds of a deck: the first `share` of its cards right, the rest skipped.
    private static func practice(_ m: AppModel, _ id: String, share: Double, rounds: Int) {
        m.select(id)
        for _ in 0..<rounds {
            m.startSession()
            guard let s = m.session else { return }
            let keep = Int((Double(s.items.count) * share).rounded())
            while let c = s.current {
                if c.id < keep { _ = m.handleText(c.a, composing: false) } else { _ = m.handle(.skip) }
            }
        }
    }

    /// 1440×900 points on a Retina screen, so a window capture is 2880×1800 pixels.
    private static func place() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        window.setFrame(NSRect(x: frame.minX + 40, y: frame.maxY - 900 - 20, width: 1440, height: 900), display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
#endif
