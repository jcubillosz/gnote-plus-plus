import AppKit
import SwiftUI
import Scintilla

/// Estado de la vista de tabla CSV/TSV. El NSTableView vive acá (no en el representable) para
/// sobrevivir a los cambios de pestaña, igual que los WKWebView de las vistas previas.
final class CSVTableViewModel: NSObject, ObservableObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let tableView = NSTableView()
    let scrollView = NSScrollView()

    @Published private(set) var table = CSVTable(rows: [], truncated: false, unterminatedQuote: false)
    /// nil = detección automática.
    @Published var manualDelimiter: Character? { didSet { reparseLast() } }
    @Published var manualHeader: Bool? { didSet { rebuild() } }
    @Published private(set) var detectedDelimiter: Character = ","

    var delimiter: Character { manualDelimiter ?? detectedDelimiter }
    var hasHeader: Bool { manualHeader ?? guessHasHeader(table) }

    var onSortDocument: ((Int) -> Void)?
    var onJump: ((Int) -> Void)?

    private var bytes: [UInt8] = []
    private var lastText = ""
    private var documentID: UUID?
    private var fileExtension: String?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "gnote.csv-parse", qos: .userInitiated)
    /// Orden solo de la vista: índices en table.rows (sin encabezado).
    private var displayRows: [Int] = []
    private(set) var sortColumn: Int?
    private(set) var sortAscending = true
    private var columnCount = 0

    override init() {
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]
    }

    // MARK: - Refresco

    func scheduleRefresh(editor: ScintillaView, document: Document) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshNow(editor: editor, document: document) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func refreshNow(editor: ScintillaView, document: Document) {
        pending?.cancel()
        if documentID != document.id {
            documentID = document.id
            sortColumn = nil
            manualDelimiter = nil
            manualHeader = nil
        }
        fileExtension = document.url?.pathExtension
        parse(currentText(editor), detect: manualDelimiter == nil)
    }

    func clear() {
        pending?.cancel()
        generation += 1
        documentID = nil
        guard !table.rows.isEmpty else { return }
        table = CSVTable(rows: [], truncated: false, unterminatedQuote: false)
        bytes = []
        lastText = ""
        rebuild()
    }

    private func reparseLast() { parse(lastText, detect: false) }

    /// Parseo en segundo plano con generación: un resultado viejo nunca pisa uno nuevo.
    private func parse(_ text: String, detect: Bool) {
        generation += 1
        let gen = generation
        let manual = manualDelimiter
        let ext = fileExtension
        let previousDelimiter = detectedDelimiter
        queue.async { [weak self] in
            let detected = detect ? detectDelimiter(text, fileExtension: ext)
                                  : previousDelimiter
            let parsed = parseCSV(text, delimiter: manual ?? detected)
            let rawBytes = Array(text.utf8)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.lastText = text
                self.bytes = rawBytes
                self.detectedDelimiter = detected
                self.table = parsed
                self.rebuild()
            }
        }
    }

    // MARK: - Tabla

    private func rebuild() {
        let header = hasHeader
        let count = table.rows.map(\.fields.count).max() ?? 0
        if count != columnCount {
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            for index in 0..<count {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
                column.width = 120
                column.minWidth = 30
                tableView.addTableColumn(column)
            }
            columnCount = count
            if let sort = sortColumn, sort >= count { sortColumn = nil }
        }
        for (index, column) in tableView.tableColumns.enumerated() {
            let title = header && !table.rows.isEmpty && index < table.rows[0].fields.count
                ? table.rows[0].fields[index] : String(index + 1)
            column.title = title
            let indicator = sortColumn == index ? (sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
            tableView.setIndicatorImage(indicator.flatMap { NSImage(named: $0) }, in: column)
        }
        if let sort = sortColumn {
            displayRows = sortedRowIndices(table, column: sort, ascending: sortAscending, skipHeader: header)
        } else {
            displayRows = Array((header ? min(1, table.rows.count) : 0)..<table.rows.count)
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        let fields = table.rows[displayRows[row]].fields
        // Saltos dentro de un campo: en una celda de una línea se muestran como ⏎.
        field.stringValue = column < fields.count ? fields[column].replacingOccurrences(of: "\n", with: "⏎") : ""
        return field
    }

    /// Clic en encabezado: ascendente → descendente → sin orden. Solo la vista.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let column = tableView.tableColumns.firstIndex(of: tableColumn) else { return }
        if sortColumn != column {
            sortColumn = column
            sortAscending = true
        } else if sortAscending {
            sortAscending = false
        } else {
            sortColumn = nil
        }
        rebuild()
    }

    @objc private func doubleClicked() {
        let row = tableView.clickedRow, column = tableView.clickedColumn
        guard row >= 0, row < displayRows.count else { return }
        let range = table.rows[displayRows[row]].rawRange
        let offset = csvFieldByteOffset(bytes[range], column: max(0, column), delimiter: delimiter)
        onJump?(range.lowerBound + offset)
    }

    // MARK: - Menús

    private var menuColumn = -1

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === tableView.headerView?.menu, let header = tableView.headerView, let event = NSApp.currentEvent {
            menuColumn = header.column(at: header.convert(event.locationInWindow, from: nil))
        } else {
            menuColumn = tableView.clickedColumn
            if tableView.clickedRow >= 0, !tableView.selectedRowIndexes.contains(tableView.clickedRow) {
                tableView.selectRowIndexes(IndexSet(integer: tableView.clickedRow), byExtendingSelection: false)
            }
        }
        if menuColumn >= 0 {
            menu.addItem(withTitle: L("Copiar columna"), action: #selector(copyColumn), keyEquivalent: "").target = self
            let sort = menu.addItem(withTitle: L("Ordenar documento por esta columna"),
                                    action: #selector(sortDocument), keyEquivalent: "")
            sort.target = self
            sort.isEnabled = canSortDocument
        }
        if menu === tableView.menu, !tableView.selectedRowIndexes.isEmpty {
            menu.addItem(withTitle: L("Copiar filas"), action: #selector(copyRows), keyEquivalent: "").target = self
        }
    }

    /// Lo actualiza ContentView: bloqueado o vista truncada deshabilitan "Ordenar documento".
    var isDocumentLocked = false
    private var canSortDocument: Bool { !isDocumentLocked && !table.truncated }

    @objc private func copyColumn() {
        guard menuColumn >= 0 else { return }
        let values = displayRows.map { index -> String in
            let fields = table.rows[index].fields
            return menuColumn < fields.count ? fields[menuColumn] : ""
        }
        toPasteboard(values.joined(separator: "\n"))
    }

    @objc private func copyRows() {
        let lines = tableView.selectedRowIndexes.map { table.rows[displayRows[$0]].fields.joined(separator: "\t") }
        toPasteboard(lines.joined(separator: "\n"))
    }

    @objc func copy(_ sender: Any?) { copyRows() }

    private func toPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @objc private func sortDocument() {
        guard menuColumn >= 0, canSortDocument else { NSSound.beep(); return }
        onSortDocument?(menuColumn)
    }
}

struct CSVTableView: View {
    @ObservedObject var model: CSVTableViewModel
    var isActive: Bool
    var isLocked: Bool
    var onSortDocument: (Int) -> Void
    var onJump: (Int) -> Void

    private static let delimiters: [(Character, String)] = [(",", ","), (";", ";"), ("\t", "Tab"), ("|", "|")]

    var body: some View {
        VStack(spacing: 0) {
            if isActive {
                HStack(spacing: 12) {
                    Picker(L("Delimitador"), selection: Binding(
                        get: { model.manualDelimiter.map(String.init) ?? "auto" },
                        set: { model.manualDelimiter = $0 == "auto" ? nil : $0.first }
                    )) {
                        Text(L("Automático") + " (\(Self.label(model.detectedDelimiter)))").tag("auto")
                        ForEach(Self.delimiters, id: \.1) { Text($0.1).tag(String($0.0)) }
                    }
                    .frame(maxWidth: 220)
                    Toggle(L("Primera fila es encabezado"), isOn: Binding(
                        get: { model.hasHeader },
                        set: { model.manualHeader = $0 }
                    ))
                    Spacer()
                    if model.table.unterminatedQuote {
                        Text(L("Comillas sin cerrar")).foregroundStyle(.orange)
                    }
                    if model.table.truncated {
                        Text(L("Vista truncada")).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                Divider()
            }
            CSVTableRepresentable(model: model, isActive: isActive)
        }
        .onAppear { sync() }
        .onChange(of: isLocked) { _ in sync() }
        .onChange(of: isActive) { _ in sync() }
    }

    private func sync() {
        model.isDocumentLocked = isLocked
        model.onSortDocument = onSortDocument
        model.onJump = onJump
    }

    private static func label(_ c: Character) -> String { c == "\t" ? "Tab" : String(c) }
}

/// Contenedor nuevo en cada makeNSView que adopta el NSScrollView compartido (mismo motivo que
/// MarkdownPreviewView). Inactiva = isHidden: el hitTest de AppKit ignora la opacidad.
private struct CSVTableRepresentable: NSViewRepresentable {
    @ObservedObject var model: CSVTableViewModel
    var isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let container = SharedEditorContainer()
        adopt(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) { adopt(into: container) }

    private func adopt(into container: NSView) {
        container.isHidden = !isActive
        guard model.scrollView.superview !== container else { return }
        model.scrollView.removeFromSuperview()
        model.scrollView.frame = container.bounds
        container.addSubview(model.scrollView)
    }
}
