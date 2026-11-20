import Foundation

/// Símbolos que contienen la primera línea visible (de documento) y cuya propia línea ya quedó
/// arriba del borde: si la declaración se ve, fijarla duplicaría lo que ya está en pantalla.
/// Con más niveles que `maxLines` se fijan los más internos; nunca más de un tercio de la vista.
func stickyHeaders(items: [OutlineItem], topLine: Int, visibleLines: Int, maxLines: Int = 3) -> [OutlineItem] {
    let cap = min(maxLines, visibleLines / 3)
    guard cap > 0 else { return [] }
    let chain = enclosingSymbols(items: items, caretLine: topLine).filter { $0.line < topLine }
    return Array(chain.suffix(cap))
}
