import Scintilla

/// Motor de búsqueda/reemplazo sobre la API de "target" de Scintilla. No mantiene estado propio:
/// lee/escribe FindViewModel y opera directamente sobre el editor compartido.

func buildSearchFlags(_ find: FindViewModel) -> Int {
    var flags = 0
    if find.matchCase { flags |= SCFIND_MATCHCASE }
    if find.wholeWord { flags |= SCFIND_WHOLEWORD }
    if find.useRegex { flags |= (SCFIND_REGEXP | SCFIND_CXX11REGEX) }
    return flags
}

/// Busca `find.findText` en el rango [from, to) del documento. Devuelve el rango encontrado
/// (start, end) o nil si no hay coincidencia. No modifica selección ni target fuera de la llamada.
private func search(editor: ScintillaView, find: FindViewModel, from: Int, to: Int) -> (start: Int, end: Int)? {
    guard !find.findText.isEmpty else { return nil }
    _ = ScintillaView.directCall(editor, message: SCI_SETSEARCHFLAGS, wParam: uptr_t(buildSearchFlags(find)), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETTARGETSTART, wParam: uptr_t(from), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETTARGETEND, wParam: uptr_t(to), lParam: 0)

    var foundStart: sptr_t = -1
    find.findText.withCString { cstr in
        foundStart = ScintillaView.directCall(
            editor, message: SCI_SEARCHINTARGET,
            wParam: uptr_t(find.findText.utf8.count),
            lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))
        )
    }
    guard foundStart >= 0 else { return nil }
    let start = Int(ScintillaView.directCall(editor, message: SCI_GETTARGETSTART, wParam: 0, lParam: 0))
    let end = Int(ScintillaView.directCall(editor, message: SCI_GETTARGETEND, wParam: 0, lParam: 0))
    return (start, end)
}

private func selectAndReveal(editor: ScintillaView, start: Int, end: Int) {
    _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(start), lParam: sptr_t(end))
    _ = ScintillaView.directCall(editor, message: SCI_SCROLLCARET, wParam: 0, lParam: 0)

    markCurrentMatch(editor: editor, start: start, end: end)
}

/// Marca [start, end) como match actual: borde del indicador 10 (limpiado del resto del
/// documento) y SIN el relleno del 9, que mezclado con el color de selección dejaba el match
/// actual casi igual a los demás. El match anterior recupera su relleno del 9 si "resaltar
/// todo" está pintado.
private func markCurrentMatch(editor: ScintillaView, start: Int, end: Int) {
    let docLength = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    if let previous = indicatorRun(editor: editor, indicator: INDICATOR_FIND_CURRENT, docLength: docLength),
       indicatorRun(editor: editor, indicator: INDICATOR_FIND_HIGHLIGHT, docLength: docLength) != nil {
        _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_FIND_HIGHLIGHT), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(previous.start), lParam: sptr_t(previous.end - previous.start))
    }
    _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_FIND_CURRENT), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: sptr_t(docLength))
    _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(start), lParam: sptr_t(end - start))
    _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_FIND_HIGHLIGHT), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: uptr_t(start), lParam: sptr_t(end - start))
}

/// Primer tramo del documento con el indicador puesto, o nil si no hay ninguno.
private func indicatorRun(editor: ScintillaView, indicator: Int, docLength: Int) -> (start: Int, end: Int)? {
    guard docLength > 0 else { return nil }
    var start = 0
    if ScintillaView.directCall(editor, message: SCI_INDICATORVALUEAT, wParam: uptr_t(indicator), lParam: 0) == 0 {
        start = Int(ScintillaView.directCall(editor, message: SCI_INDICATOREND, wParam: uptr_t(indicator), lParam: 0))
    }
    guard start < docLength else { return nil }
    let end = Int(ScintillaView.directCall(editor, message: SCI_INDICATOREND, wParam: uptr_t(indicator), lParam: sptr_t(start)))
    return end > start ? (start, end) : nil
}

/// Busca hacia adelante desde el final de la selección actual. Wrap-around: si no encuentra
/// hasta el final del documento, reintenta una vez desde la posición 0.
func findNext(editor: ScintillaView, find: FindViewModel) {
    let docLength = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    let selEnd = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))

    if let match = search(editor: editor, find: find, from: selEnd, to: docLength) {
        selectAndReveal(editor: editor, start: match.start, end: match.end)
    } else if let match = search(editor: editor, find: find, from: 0, to: selEnd) {
        selectAndReveal(editor: editor, start: match.start, end: match.end)
    }
    updateCurrentMatchIndex(editor: editor, find: find)
}

/// Busca hacia atrás desde el principio de la selección actual. Wrap-around simétrico a findNext:
/// Scintilla busca hacia atrás cuando targetStart > targetEnd.
func findPrevious(editor: ScintillaView, find: FindViewModel) {
    let docLength = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    let selStart = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))

    if let match = search(editor: editor, find: find, from: selStart, to: 0) {
        selectAndReveal(editor: editor, start: match.start, end: match.end)
    } else if let match = search(editor: editor, find: find, from: docLength, to: selStart) {
        selectAndReveal(editor: editor, start: match.start, end: match.end)
    }
    updateCurrentMatchIndex(editor: editor, find: find)
}

/// Posición (1-based) de la selección entre las coincidencias, para el contador "n/total" de
/// la barra; 0 si la selección no es una coincidencia. Antes nadie la actualizaba al navegar y
/// el contador quedaba en "0/N".
private func updateCurrentMatchIndex(editor: ScintillaView, find: FindViewModel) {
    let docLength = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    let selStart = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let selEnd = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
    var cursor = 0
    var ordinal = 0
    while cursor <= selStart, let match = search(editor: editor, find: find, from: cursor, to: docLength) {
        ordinal += 1
        if match.start == selStart, match.end == selEnd {
            find.currentMatchIndex = ordinal
            return
        }
        if match.start > selStart { break }
        cursor = max(match.end, match.start + 1)
    }
    find.currentMatchIndex = 0
}

/// Reemplaza la selección actual SOLO si coincide exactamente con una búsqueda de find.findText
/// (mismo target que dejó la última llamada a search/findNext/findPrevious), luego avanza al
/// siguiente match. Si la selección actual no es un match válido, primero busca uno.
func replaceCurrent(editor: ScintillaView, find: FindViewModel) {
    guard !find.findText.isEmpty else { return }
    let selStart = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let selEnd = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))

    guard let match = search(editor: editor, find: find, from: selStart, to: selEnd), match.start == selStart, match.end == selEnd else {
        findNext(editor: editor, find: find)
        return
    }

    _ = ScintillaView.directCall(editor, message: SCI_SETTARGETSTART, wParam: uptr_t(match.start), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_SETTARGETEND, wParam: uptr_t(match.end), lParam: 0)
    find.replaceText.withCString { cstr in
        let message = find.useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
        _ = ScintillaView.directCall(
            editor, message: message,
            wParam: uptr_t(find.replaceText.utf8.count),
            lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))
        )
    }
    findNext(editor: editor, find: find)
    highlightAllMatches(editor: editor, find: find)
}

/// Recorre el documento reemplazando todas las coincidencias. Avanza el cursor de búsqueda por
/// el largo del reemplazo (no del match original) para no reprocesar texto ya sustituido.
func replaceAll(editor: ScintillaView, find: FindViewModel) {
    guard !find.findText.isEmpty else { return }
    let selStart = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let selEnd = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
    let useSelection = find.inSelection && selStart < selEnd
    var cursor = useSelection ? selStart : 0
    // limit se ajusta tras cada reemplazo: el texto sustituido cambia el largo del rango buscado.
    var limit = useSelection ? selEnd : Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    var count = 0
    let maxIterations = 100_000 // guarda contra loops infinitos en patrones regex degenerados

    // Un solo paso de deshacer para todo el reemplazo (también si no hubo coincidencias).
    _ = ScintillaView.directCall(editor, message: SCI_BEGINUNDOACTION, wParam: 0, lParam: 0)
    for _ in 0..<maxIterations {
        guard cursor <= limit, let match = search(editor: editor, find: find, from: cursor, to: limit) else { break }

        _ = ScintillaView.directCall(editor, message: SCI_SETTARGETSTART, wParam: uptr_t(match.start), lParam: 0)
        _ = ScintillaView.directCall(editor, message: SCI_SETTARGETEND, wParam: uptr_t(match.end), lParam: 0)
        var replacedLength = 0
        find.replaceText.withCString { cstr in
            let message = find.useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
            replacedLength = Int(ScintillaView.directCall(
                editor, message: message,
                wParam: uptr_t(find.replaceText.utf8.count),
                lParam: sptr_t(bitPattern: UInt(bitPattern: cstr))
            ))
        }
        count += 1
        limit += replacedLength - (match.end - match.start)
        cursor = match.start + max(replacedLength, 1) // +1 mínimo evita loop infinito en match vacío + reemplazo vacío
    }
    _ = ScintillaView.directCall(editor, message: SCI_ENDUNDOACTION, wParam: 0, lParam: 0)

    if useSelection {
        _ = ScintillaView.directCall(editor, message: SCI_SETSEL, wParam: uptr_t(selStart), lParam: sptr_t(limit))
    }
    find.matchCount = count
    find.currentMatchIndex = count > 0 ? 1 : 0
    highlightAllMatches(editor: editor, find: find)
}

/// Limpia y vuelve a pintar el indicador de highlight sobre TODAS las coincidencias actuales.
func highlightAllMatches(editor: ScintillaView, find: FindViewModel) {
    clearHighlights(editor: editor)
    guard !find.findText.isEmpty else {
        find.matchCount = 0
        find.currentMatchIndex = 0
        return
    }

    let docLength = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_FIND_HIGHLIGHT), lParam: 0)

    let selStart = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONSTART, wParam: 0, lParam: 0))
    let selEnd = Int(ScintillaView.directCall(editor, message: SCI_GETSELECTIONEND, wParam: 0, lParam: 0))
    var selectionIsMatch = false
    var currentOrdinal = 0
    var cursor = 0
    var count = 0
    let maxIterations = 100_000

    for _ in 0..<maxIterations {
        guard cursor <= docLength, let match = search(editor: editor, find: find, from: cursor, to: docLength) else { break }
        _ = ScintillaView.directCall(editor, message: SCI_INDICATORFILLRANGE, wParam: uptr_t(match.start), lParam: sptr_t(match.end - match.start))
        count += 1
        if match.start == selStart, match.end == selEnd { selectionIsMatch = true; currentOrdinal = count }
        cursor = max(match.end, match.start + 1) // +1 mínimo evita loop infinito en match vacío
    }

    find.matchCount = count
    find.currentMatchIndex = currentOrdinal

    // Si ya hay un match actual seleccionado, repintar el indicador 10 encima del highlight
    // general recién pintado — si no, el highlight-all pisa la marca roja del match actual
    // (ver bug replaceCurrent/replaceAll/scheduleHighlight en final-fix-findings.md). Solo si
    // la selección ES una coincidencia: una selección cualquiera no debe perder el relleno.
    if selStart != selEnd, selectionIsMatch {
        markCurrentMatch(editor: editor, start: selStart, end: selEnd)
    }
}

func clearHighlights(editor: ScintillaView) {
    let docLength = Int(ScintillaView.directCall(editor, message: SCI_GETLENGTH, wParam: 0, lParam: 0))
    _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_FIND_HIGHLIGHT), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: sptr_t(docLength))
    _ = ScintillaView.directCall(editor, message: SCI_SETINDICATORCURRENT, wParam: uptr_t(INDICATOR_FIND_CURRENT), lParam: 0)
    _ = ScintillaView.directCall(editor, message: SCI_INDICATORCLEARRANGE, wParam: 0, lParam: sptr_t(docLength))
}
