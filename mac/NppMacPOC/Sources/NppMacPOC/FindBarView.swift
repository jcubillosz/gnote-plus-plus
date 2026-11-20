import SwiftUI
import Scintilla

/// Barra flotente de Find/Replace, estilo VSCode. Ver docs/superpowers/specs/2026-07-25-find-replace-design.md.
struct FindBarView: View {
    let editor: ScintillaView
    @ObservedObject var find: FindViewModel
    /// Documento activo bloqueado: Reemplazar/Reemplazar todos quedan deshabilitados
    /// (buscar y navegar entre matches sigue funcionando, no modifica el documento).
    var isLocked: Bool = false
    /// Buscar todo: `true` = en todos los documentos abiertos, `false` = solo el actual.
    var onFindAll: (Bool) -> Void = { _ in }
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
                    .frame(minWidth: 80, idealWidth: 220)

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

                Text(find.statusMessage ?? (find.matchCount == 0 && !find.findText.isEmpty ? L("Sin resultados") : "\(find.currentMatchIndex)/\(find.matchCount)"))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(minWidth: 40, idealWidth: 90, alignment: .leading)

                Button(action: { findPrevious(editor: editor, find: find) }) {
                    Image(systemName: "chevron.up")
                }
                Button(action: { findNext(editor: editor, find: find) }) {
                    Image(systemName: "chevron.down")
                }
                Menu {
                    Button(L("Buscar todo en el documento actual")) { onFindAll(false) }
                    Button(L("Buscar todo en los documentos abiertos")) { onFindAll(true) }
                    Divider()
                    Button(L("Marcar todo")) {
                        let n = markAllMatches(editor: editor, find: find, bookmarkLines: find.markLines)
                        find.statusMessage = L("\(n) coincidencias marcadas")
                    }
                    Button(L("Borrar marcas")) { clearMarks(editor: editor); find.statusMessage = nil }
                    Toggle(L("Marcar también la línea"), isOn: $find.markLines)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(find.findText.isEmpty)
                Button(action: closeBar) {
                    Image(systemName: "xmark")
                }
            }

            if find.showReplace {
                HStack(spacing: 6) {
                    Spacer().frame(width: 20)
                    TextField(L("Reemplazar"), text: $find.replaceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 80, idealWidth: 220)
                    Button(L("Reemplazar")) { replaceCurrent(editor: editor, find: find) }
                        .disabled(isLocked)
                    Button(L("Reemplazar todos")) { replaceAll(editor: editor, find: find) }
                        .disabled(isLocked)
                    Toggle(isOn: $find.inSelection) { Image(systemName: "text.cursor") }
                        .toggleStyle(.button)
                        .help(L("Reemplazar solo dentro de la selección"))
                        .accessibilityLabel(L("Reemplazar solo dentro de la selección"))
                }
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .cornerRadius(8)
        .shadow(radius: 4)
        .padding(.top, 8)
        .padding(.trailing, 16)
        // Con el editor angosto (sidebar abierto) la barra se desbordaba hacia la izquierda y
        // quedaba bajo el panel lateral: margen izquierdo propio + campos que se encogen.
        .padding(.leading, 8)
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
        find.inSelection = false
    }
}
