import SwiftUI
import Scintilla

/// Barra flotente de Find/Replace, estilo VSCode. Ver docs/superpowers/specs/2026-07-25-find-replace-design.md.
struct FindBarView: View {
    let editor: ScintillaView
    @ObservedObject var find: FindViewModel
    @FocusState private var findFieldFocused: Bool
    @State private var pendingHighlight: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: { find.showReplace.toggle() }) {
                    Image(systemName: find.showReplace ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)

                TextField(L("Buscar"), text: $find.findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($findFieldFocused)
                    .onSubmit { findNext(editor: editor, find: find) }
                    .onChange(of: find.findText) { _ in scheduleHighlight() }
                    .frame(minWidth: 180)

                Toggle("Aa", isOn: $find.matchCase)
                    .toggleStyle(.button)
                    .help(L("Coincidir mayúsculas/minúsculas"))
                    .onChange(of: find.matchCase) { _ in scheduleHighlight() }
                Toggle(".*", isOn: $find.useRegex)
                    .toggleStyle(.button)
                    .help(L("Expresión regular"))
                    .onChange(of: find.useRegex) { _ in scheduleHighlight() }
                Toggle("ab", isOn: $find.wholeWord)
                    .toggleStyle(.button)
                    .help(L("Solo palabras completas"))
                    .onChange(of: find.wholeWord) { _ in scheduleHighlight() }

                Text(find.matchCount == 0 && !find.findText.isEmpty ? L("Sin resultados") : "\(find.currentMatchIndex)/\(find.matchCount)")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .frame(minWidth: 90, alignment: .leading)

                Button(action: { findPrevious(editor: editor, find: find) }) {
                    Image(systemName: "chevron.up")
                }
                Button(action: { findNext(editor: editor, find: find) }) {
                    Image(systemName: "chevron.down")
                }
                Button(action: closeBar) {
                    Image(systemName: "xmark")
                }
            }

            if find.showReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 20)
                    TextField(L("Reemplazar"), text: $find.replaceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 180)
                    Button(L("Reemplazar")) { replaceCurrent(editor: editor, find: find) }
                    Button(L("Reemplazar todos")) { replaceAll(editor: editor, find: find) }
                }
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .cornerRadius(8)
        .shadow(radius: 4)
        .padding(.top, 8)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear { findFieldFocused = true }
        .onExitCommand { closeBar() }
    }

    private func scheduleHighlight() {
        pendingHighlight?.cancel()
        let item = DispatchWorkItem { highlightAllMatches(editor: editor, find: find) }
        pendingHighlight = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func closeBar() {
        pendingHighlight?.cancel()
        clearHighlights(editor: editor)
        find.isVisible = false
    }
}
