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
                Button("PDF에서 덱 만들기…") { model.showPDFImporter = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.importStatus != nil)
            }
            CommandGroup(after: .sidebar) {
                Button("모든 카테고리 펼치기") { model.setAllCategories(open: true) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("모든 카테고리 접기") { model.setAllCategories(open: false) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
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
                Button("5지선다") { model.mode = .choice; model.refocus() }
                    .keyboardShortcut("3")
                Button("방향 뒤집기") { model.reverse.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
