import SwiftUI

struct PracticeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            ProgressLine(value: progress)
                .padding(.horizontal, 28)
            ZStack {
                TypingInput(
                    focusToken: model.focusToken,
                    resetToken: model.resetToken,
                    onText: { text, composing in model.handleText(text, composing: composing) },
                    onCommand: { model.handle($0) },
                    onKeystroke: { model.keystroke() },
                    onFocusChange: { focused in model.isTypingFocused = focused }
                )
                stage
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { model.refocus() }
            StatusBar()
        }
        .background(Palette.background)
        .navigationTitle(model.selectedDeck?.name ?? "TypeDeck")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("연습 방식", selection: $model.mode) {
                    ForEach(PracticeMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("따라치기: 정답을 보며 입력 · 외워치기: 기억해서 입력 (⌘1, ⌘2)")
                Toggle(isOn: $model.reverse) { Label("뒤집기", systemImage: "arrow.left.arrow.right") }
                    .help("키와 값의 방향을 바꿉니다 (⇧⌘R)")
                Toggle(isOn: $model.shuffle) { Label("섞기", systemImage: "shuffle") }
                    .help("카드 순서를 섞습니다")
                Toggle(isOn: $model.showNotes) { Label("메모", systemImage: "text.alignleft") }
                    .help("카드 아래에 메모를 보여 줍니다")
                Button {
                    if let id = model.selectedDeckID { model.editorTarget = .deck(id) }
                } label: { Label("편집", systemImage: "square.and.pencil") }
                    .disabled(model.selectedDeckID == nil)
                    .help("덱 편집 (⌘E)")
            }
        }
        .onChange(of: model.mode) { model.refocus() }
    }

    private var progress: Double {
        guard let s = model.session, !s.queue.isEmpty else { return 0 }
        return Double(s.pos) / Double(s.queue.count)
    }

    @ViewBuilder private var stage: some View {
        if let session = model.session {
            if session.finished {
                SummaryCard(session: session)
                    .frame(height: 340)
            } else {
                VStack(spacing: 6) {
                    CardStack(session: session)
                    if model.showNotes, let shown = NotePanel.shownItem(session, mode: model.mode) {
                        NotePanel(item: shown.item, live: shown.live)
                            .id(shown.item.id)
                            .padding(.top, 26) // clears the cards stacked behind the front one
                    }
                }
            }
        } else {
            EmptyCard()
                .frame(height: 340)
        }
    }
}

private struct ProgressLine: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.line)
                Capsule().fill(Palette.accent).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.12), value: value)
    }
}

private struct CardShape: ViewModifier {
    var border: Color = Palette.line
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 10)
    }
}

private struct CardStack: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let depth = min(2, session.remaining - 1)
        let height: CGFloat = 340
        ZStack {
            ForEach((1...max(depth, 1)).reversed(), id: \.self) { d in
                if d <= depth {
                    Color.clear
                        .modifier(CardShape())
                        .scaleEffect(1 - 0.045 * CGFloat(d), anchor: .bottom)
                        .offset(y: 13 * CGFloat(d))
                        .opacity(d == 1 ? 0.7 : 0.4)
                }
            }
            if let item = session.current {
                FrontCard(session: session, item: item)
                    .id(session.pos)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.975, anchor: .bottom).combined(with: .offset(y: 10)),
                        removal: .offset(x: 60, y: -28).combined(with: .opacity)
                    ))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.15), value: session.pos)
    }
}

private struct FrontCard: View {
    /// Long questions and answers (sentences) get smaller type so they fit on the card.
    static func questionSize(_ text: String) -> CGFloat { text.count > 60 ? 22 : text.count > 24 ? 29 : 42 }
    static func answerSize(_ text: String) -> CGFloat { text.count > 80 ? 19 : text.count > 30 ? 23 : 30 }

    @Environment(AppModel.self) private var model
    let session: Session
    let item: Session.Item
    @State private var shake: CGFloat = 0

    var body: some View {
        let showAnswer = model.mode == .copy || session.revealed
        let target = session.target
        let parts = Core.diff(answer: target, typed: session.typed, composing: session.composing)
        let hasError = showAnswer && parts.contains { $0.state == .bad || $0.state == .extra }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Pill(text: session.revealed ? "정답 공개" : (model.reverse ? "값" : "키"), highlighted: session.revealed)
                Spacer()
                Text("남은 카드 \(session.remaining)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 10)
            Text(item.q)
                .font(.system(size: Self.questionSize(item.q), weight: .bold))
                .tracking(item.q.count > 24 ? -0.3 : -0.8)
                .lineSpacing(item.q.count > 24 ? 3 : 0)
                .foregroundStyle(Palette.ink)
                .lineLimit(4)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 10)
            DashedLine()
                .padding(.bottom, 16)
            AnswerLine(parts: parts, alts: item.alts, target: target, typed: session.typed, showAnswer: showAnswer,
                       awaitingReturn: session.awaitingReturn, size: Self.answerSize(item.a))
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        }
        .padding(.horizontal, 34)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(CardShape(border: hasError ? Palette.bad : Palette.line))
        .offset(x: shake)
        .onChange(of: model.shakeToken) {
            withAnimation(.interpolatingSpring(stiffness: 900, damping: 9)) { shake = 9 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.interpolatingSpring(stiffness: 900, damping: 9)) { shake = 0 }
            }
        }
    }
}

private struct DashedLine: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 1)
            .overlay(
                Line().stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// 메모 under the card, the same for every deck. In 따라치기 (or once the answer is shown) it
/// belongs to the current card; in 외워치기 to the card just finished, so reading never holds up
/// typing. A card without a 메모 shows only a '메모 쓰기' button, and either can be edited here.
private struct NotePanel: View {
    @Environment(AppModel.self) private var model
    let item: Session.Item
    let live: Bool
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    static func shownItem(_ session: Session, mode: PracticeMode) -> (item: Session.Item, live: Bool)? {
        let live = !session.finished && (mode == .copy || session.revealed)
        guard let item = live ? session.current : session.lastDone else { return nil }
        return (item, live)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(live ? "메모" : "방금 친 카드")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.accent)
                if !live {
                    Text(item.a)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if !editing {
                    Button(item.note.isEmpty ? "＋ 메모 쓰기" : "고치기") { startEditing() }
                        .buttonStyle(.link)
                        .font(.system(size: 12.5, weight: .semibold))
                }
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 80, maxHeight: 180)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.accent, lineWidth: 2))
                    .focused($focused)
                HStack {
                    Text("⌘↩ 저장 · esc 취소").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("취소") { stopEditing(save: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("저장") { stopEditing(save: true) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            } else if !item.note.isEmpty {
                ScrollView {
                    Text(item.note)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        // Takes what is left under the card (up to 240pt) and scrolls; never pushes the window.
        .frame(maxWidth: .infinity, maxHeight: item.note.isEmpty && !editing ? nil : 240, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line))
        .onDisappear { if editing { stopEditing(save: true) } }
    }

    private func startEditing() {
        draft = item.note
        editing = true
        DispatchQueue.main.async { focused = true }
    }

    private func stopEditing(save: Bool) {
        if save && draft.trimmingCharacters(in: .whitespacesAndNewlines) != item.note {
            model.setNote(draft, forItem: item.id)
        }
        editing = false
        model.refocus()
    }
}

private struct AnswerLine: View {
    @Environment(AppModel.self) private var model
    let parts: [CharDiff]
    /// Every accepted answer; `target` is the one being typed and gets the character view.
    let alts: [String]
    let target: String
    let typed: String
    let showAnswer: Bool
    var awaitingReturn = false

    /// Type size; smaller for sentences so they fit on the card.
    var size: CGFloat = 30

    var body: some View {
        TimelineView(.periodic(from: model.lastInput, by: 0.53)) { context in
            let phase = Int(context.date.timeIntervalSince(model.lastInput) / 0.53)
            let caretOn = model.isTypingFocused && phase % 2 == 0
            Text(attributed(caretOn: caretOn, caretDim: !model.isTypingFocused))
                .font(.system(size: size, weight: .medium))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caret(on: Bool, dim: Bool) -> AttributedString {
        var c = AttributedString("|")
        c.foregroundColor = on ? Palette.accent : (dim ? Palette.accent.opacity(0.25) : .clear)
        c.font = .system(size: size, weight: .light)
        c.kern = -4
        return c
    }

    private func attributed(caretOn: Bool, caretDim: Bool) -> AttributedString {
        var out = AttributedString()
        if showAnswer {
            for (k, alt) in alts.enumerated() {
                if k > 0 { out += muted(", ") }
                if alt == target { out += diffRun(caretOn: caretOn, caretDim: caretDim) } else { out += muted(alt) }
            }
        } else {
            var t = AttributedString(typed)
            t.foregroundColor = Palette.ink
            out += t
            out += caret(on: caretOn, dim: caretDim)
            if typed.isEmpty {
                var hint = AttributedString("  기억나는 대로 입력")
                hint.foregroundColor = Palette.ghost
                hint.font = .system(size: size * 0.6, weight: .medium)
                out += hint
            }
        }
        if awaitingReturn {
            var hint = AttributedString("  ↩ Return으로 넘기기")
            hint.foregroundColor = Palette.accent
            hint.font = .system(size: size * 0.5, weight: .semibold)
            out += hint
        }
        return out
    }

    private func muted(_ text: String) -> AttributedString {
        var run = AttributedString(text)
        run.foregroundColor = Palette.ghost
        run.font = .system(size: size * 0.68, weight: .regular)
        return run
    }

    private func diffRun(caretOn: Bool, caretDim: Bool) -> AttributedString {
        var out = AttributedString()
        let caretIndex = typed.count
        for (i, part) in parts.enumerated() {
            if i == caretIndex { out += caret(on: caretOn, dim: caretDim) }
            var run = AttributedString(String(part.shown))
            switch part.state {
            case .ok:
                run.foregroundColor = Palette.ink
            case .bad:
                run.foregroundColor = Palette.bad
                run.backgroundColor = Palette.bad.opacity(0.15)
            case .composing:
                run.foregroundColor = Palette.ink
                run.underlineStyle = Text.LineStyle(pattern: .solid, color: Palette.accent)
            case .todo:
                run.foregroundColor = Palette.ghost
            case .extra:
                run.foregroundColor = Palette.bad
                run.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Palette.bad)
            }
            out += run
        }
        if caretIndex >= parts.count { out += caret(on: caretOn, dim: caretDim) }
        return out
    }
}

private struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Pill(text: "라운드 완료")
            Text("정확도 \(percent(session.accuracy))")
                .font(.system(size: 34, weight: .bold))
                .tracking(-1)
                .foregroundStyle(Palette.ink)
            HStack(spacing: 12) {
                stat("카드", "\(session.items.count)")
                stat("타/분", number(session.kpm))
                stat("시간", time(session.activeTime))
                stat("최고 연속", "\(session.bestStreak)")
            }
            let missed = session.missed
            if !missed.isEmpty {
                ScrollView {
                    FlowLayout {
                        ForEach(missed) { item in
                            (Text(item.q).fontWeight(.semibold) + Text(" → \(item.a)"))
                                .font(.system(size: 13))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.bad.opacity(0.15)))
                        }
                    }
                }
                .frame(maxHeight: 64)
            }
            HStack(spacing: 8) {
                Button { model.startSession() } label: {
                    HStack(spacing: 6) { KeyCap(label: "return"); Text("다시 하기") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if !missed.isEmpty {
                    Button { model.startSession(onlyMissed: true) } label: {
                        HStack(spacing: 6) { KeyCap(label: "tab"); Text("틀린 \(missed.count)장만") }
                    }
                    .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .modifier(CardShape())
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 22, weight: .bold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line))
    }
}

private struct EmptyCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            if model.decks.isEmpty {
                Text("아직 덱이 없어요. 공부할 주제마다 카테고리를 만들고, 외울 것을 덱으로 정리해 보세요.")
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                HStack {
                    Button("새 카테고리") { model.categoryPrompt = .new }
                        .buttonStyle(.borderedProminent)
                    Button("새 덱") { model.editorTarget = .new }
                    Button("자료로 덱 만들기") { model.startImport(into: nil) }
                }
            } else {
                Text("이 덱에는 카드가 없어요.")
                    .foregroundStyle(Palette.muted)
                Button("카드 추가하기") {
                    if let id = model.selectedDeckID { model.editorTarget = .deck(id) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(CardShape())
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 22) {
            if let s = model.session {
                stat("진행", "\(min(s.pos + 1, s.queue.count))/\(s.queue.count)")
                stat("정확도", percent(s.accuracy))
                stat("타/분", number(s.kpm))
                stat("연속", "\(s.streak)")
                Spacer()
                if s.finished {
                    hint("return", "다시 하기")
                    if !s.missed.isEmpty { hint("tab", "틀린 카드만") }
                } else {
                    hint("return", "정답 보기")
                    hint("tab", "건너뛰기")
                    hint("esc", "지우기")
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 18)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(label: key)
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
    }
}

private func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
private func number(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "—" }
private func time(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}
