import AppKit
import SwiftUI

/// An invisible view that receives keyboard and IME input directly.
///
/// It never gives up first responder while practising, so moving to the next card costs nothing:
/// the buffer is cleared in place, and any syllable still being composed is discarded so it
/// cannot leak into the next card.
final class TypingInputView: NSView, NSTextInputClient {
    enum Command { case submit, skip, clear }

    /// Called with the current text. Return the text to keep (the overflow) when the card was
    /// completed, or nil to keep typing on the same card.
    var onText: ((String, Bool) -> String?)?
    var onCommand: ((Command) -> Void)?
    var onKeystroke: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    private var committed = ""
    private var marked = ""
    private var inKeyDown = false
    private var dirty = false
    private var advancedDuringEvent = false

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// Drops everything typed so far, including IME state.
    func reset() {
        if !marked.isEmpty { discardComposition() }
        committed = ""
        marked = ""
        dirty = false
    }

    // MARK: Keyboard

    private static let nonCharacterKeys: Set<UInt16> = [36, 76, 48, 53, 51, 117, 123, 124, 125, 126]

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) {
            super.keyDown(with: event)
            return
        }
        if !Self.nonCharacterKeys.contains(event.keyCode), !(event.characters ?? "").isEmpty {
            onKeystroke?()
        }
        inKeyDown = true
        advancedDuringEvent = false
        if inputContext?.handleEvent(event) != true {
            interpretKeyEvents([event])
        }
        inKeyDown = false
        flush()
        if needsDiscard {
            needsDiscard = false
            discardComposition()
        }
    }

    override func doCommand(by selector: Selector) {
        // Text inserted earlier in this same key event (an IME committing on Return) is
        // evaluated first, so Return does not also hit the next card.
        flush()
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)):
            if !advancedDuringEvent { onCommand?(.submit) }
        case #selector(insertTab(_:)), #selector(insertBacktab(_:)):
            if !advancedDuringEvent {
                onCommand?(.skip)
                committed = ""
                marked = ""
            }
        case #selector(cancelOperation(_:)):
            reset()
            onCommand?(.clear)
        case #selector(deleteBackward(_:)):
            if !committed.isEmpty { committed.removeLast(); changed() }
        case #selector(deleteWordBackward(_:)):
            let trimmed = committed.replacingOccurrences(of: "\\s*\\S*$", with: "", options: .regularExpression)
            committed = trimmed
            changed()
        case #selector(deleteToBeginningOfLine(_:)), #selector(deleteToBeginningOfParagraph(_:)):
            committed = ""
            changed()
        default:
            break
        }
    }

    private func changed() {
        dirty = true
        if !inKeyDown { flush() }
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        guard let rest = onText?(committed + marked, !marked.isEmpty) else { return }
        let hadMarked = !marked.isEmpty
        marked = ""
        committed = rest
        advancedDuringEvent = true
        if hadMarked {
            // Discarding inside the input method's own callback is unsafe, so it waits for
            // keyDown to finish.
            if inKeyDown { needsDiscard = true } else { discardComposition() }
        }
    }

    private var needsDiscard = false
    private var discarding = false

    private func discardComposition() {
        // Some input methods commit the syllable when asked to discard it; ignore that.
        discarding = true
        inputContext?.discardMarkedText()
        discarding = false
    }

    // MARK: NSTextInputClient

    private var text: String { committed + marked }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !discarding else { return }
        committed += Self.plain(string)
        marked = ""
        changed()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !discarding else { return }
        marked = Self.plain(string)
        changed()
    }

    func unmarkText() {
        guard !discarding else { return }
        committed += marked
        marked = ""
        changed()
    }

    func selectedRange() -> NSRange {
        NSRange(location: (text as NSString).length, length: 0)
    }

    func markedRange() -> NSRange {
        marked.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: (committed as NSString).length, length: (marked as NSString).length)
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let ns = text as NSString
        let clipped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        actualRange?.pointee = clipped
        return NSAttributedString(string: ns.substring(with: clipped))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Candidate windows (Hanja, Japanese) appear near the bottom of the card.
        let local = NSRect(x: bounds.midX - 120, y: bounds.minY + 40, width: 1, height: 24)
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    private static func plain(_ string: Any) -> String {
        (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
}

/// SwiftUI wrapper. Changing `focusToken` pulls keyboard focus back and clears the buffer.
struct TypingInput: NSViewRepresentable {
    var focusToken: Int
    var resetToken: Int
    var onText: (String, Bool) -> String?
    var onCommand: (TypingInputView.Command) -> Void
    var onKeystroke: () -> Void
    var onFocusChange: (Bool) -> Void

    final class Coordinator {
        var focusToken = -1
        var resetToken = -1
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TypingInputView {
        let view = TypingInputView()
        // Typing while something else (the deck list, a toolbar button) has focus still lands here.
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let view, let window = view.window, event.window === window,
                  window.attachedSheet == nil,
                  window.firstResponder !== view,
                  !(window.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control]).isEmpty
            else { return event }
            window.makeFirstResponder(view)
            view.keyDown(with: event)
            return nil
        }
        return view
    }

    func updateNSView(_ view: TypingInputView, context: Context) {
        view.onText = onText
        view.onCommand = onCommand
        view.onKeystroke = onKeystroke
        view.onFocusChange = onFocusChange
        if context.coordinator.resetToken != resetToken {
            context.coordinator.resetToken = resetToken
            view.reset()
        }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }
}
