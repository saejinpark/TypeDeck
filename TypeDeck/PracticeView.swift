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
                    onFocusChange: { focused in model.isTypingFocused = focused },
                    onNumberKey: { model.handleChoiceKey($0) }
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
                .help("따라치기: 정답을 보며 입력 · 외워치기: 기억해서 입력 · 5지선다: 1-5로 고르기 (⌘1, ⌘2, ⌘3)")
                Toggle(isOn: $model.reverse) { Label("뒤집기", systemImage: "arrow.left.arrow.right") }
                    .help(model.mode == .choice ? "5지선다에서는 방향을 바꾸지 않아요" : "키와 값의 방향을 바꿉니다 (⇧⌘R)")
                    .disabled(model.mode == .choice)
                Toggle(isOn: $model.shuffle) { Label("섞기", systemImage: "shuffle") }
                    .help("카드 순서를 섞습니다")
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
                CardStack(session: session)
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
        let height: CGFloat = model.mode == .choice ? 420 : 340
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
            if let item = session.current, model.mode == .choice {
                ChoiceCard(session: session, item: item)
                    .id(session.pos)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.975, anchor: .bottom).combined(with: .offset(y: 10)),
                        removal: .offset(x: 60, y: -28).combined(with: .opacity)
                    ))
            } else if let item = session.current {
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
                .font(.system(size: 42, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Palette.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 10)
            DashedLine()
                .padding(.bottom, 16)
            AnswerLine(parts: parts, alts: item.alts, target: target, typed: session.typed, showAnswer: showAnswer,
                       awaitingReturn: session.awaitingReturn)
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

private struct ChoiceCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let item: Session.Item
    @State private var shake: CGFloat = 0

    var body: some View {
        let showRight = session.revealed || !session.wrongPicks.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Pill(text: session.revealed ? "정답 공개" : "문제", highlighted: session.revealed)
                Spacer()
                Text("남은 카드 \(session.remaining)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            Text(item.q)
                .font(.system(size: 38, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            VStack(spacing: 7) {
                ForEach(Array(session.choices.enumerated()), id: \.offset) { i, text in
                    let wrong = session.wrongPicks.contains(i)
                    let right = showRight && i == session.answerIndex
                    Button { model.choose(i) } label: {
                        HStack(spacing: 12) {
                            KeyCap(label: "\(i + 1)")
                            Text(text)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(wrong ? Palette.bad : Palette.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(wrong ? Palette.bad.opacity(0.14) : right ? Palette.good.opacity(0.14) : Palette.panel))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(wrong ? Palette.bad : right ? Palette.good : Palette.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(CardShape())
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

private struct AnswerLine: View {
    @Environment(AppModel.self) private var model
    let parts: [CharDiff]
    /// Every accepted answer; `target` is the one being typed and gets the character view.
    let alts: [String]
    let target: String
    let typed: String
    let showAnswer: Bool
    var awaitingReturn = false

    private static let size: CGFloat = 30

    var body: some View {
        TimelineView(.periodic(from: model.lastInput, by: 0.53)) { context in
            let phase = Int(context.date.timeIntervalSince(model.lastInput) / 0.53)
            let caretOn = model.isTypingFocused && phase % 2 == 0
            Text(attributed(caretOn: caretOn, caretDim: !model.isTypingFocused))
                .font(.system(size: Self.size, weight: .medium))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func caret(on: Bool, dim: Bool) -> AttributedString {
        var c = AttributedString("|")
        c.foregroundColor = on ? Palette.accent : (dim ? Palette.accent.opacity(0.25) : .clear)
        c.font = .system(size: Self.size, weight: .light)
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
                hint.font = .system(size: Self.size * 0.6, weight: .medium)
                out += hint
            }
        }
        if awaitingReturn {
            var hint = AttributedString("  ↩ Return으로 넘기기")
            hint.foregroundColor = Palette.accent
            hint.font = .system(size: Self.size * 0.5, weight: .semibold)
            out += hint
        }
        return out
    }

    private func muted(_ text: String) -> AttributedString {
        var run = AttributedString(text)
        run.foregroundColor = Palette.ghost
        run.font = .system(size: Self.size * 0.68, weight: .regular)
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
                if model.mode == .choice {
                    stat("남음", "\(s.remaining)")
                } else {
                    stat("타/분", number(s.kpm))
                }
                stat("연속", "\(s.streak)")
                Spacer()
                if s.finished {
                    hint("return", "다시 하기")
                    if !s.missed.isEmpty { hint("tab", "틀린 카드만") }
                } else if model.mode == .choice {
                    hint("1–\(s.choices.count)", "고르기")
                    hint("return", "정답 보기")
                    hint("tab", "건너뛰기")
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
