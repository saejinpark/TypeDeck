import SwiftUI

@main
struct TypeDeckApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("TypeDeck", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 덱") { model.editorTarget = .new }
                    .keyboardShortcut("n")
                Button("새 카테고리…") { model.categoryPrompt = .new }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("자료로 덱 만들기…") { model.startImport(into: nil) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.importStatus != nil)
            }
            CommandMenu("연습") {
                Button("처음부터 다시") { model.startSession() }
                    .keyboardShortcut("r")
                Button("덱 편집…") {
                    if let id = model.selectedDeckID { model.editorTarget = .deck(id) }
                }
                .keyboardShortcut("e")
                .disabled(model.selectedDeckID == nil)
                Divider()
                Button("따라치기") { model.mode = .copy; model.refocus() }
                    .keyboardShortcut("1")
                Button("외워치기") { model.mode = .recall; model.refocus() }
                    .keyboardShortcut("2")
                Button("방향 뒤집기") { model.reverse.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
