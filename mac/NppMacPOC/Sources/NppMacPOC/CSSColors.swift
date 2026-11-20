import AppKit
import Scintilla

// Colores CSS: subrayado del color de cada literal (indicador 15) y Editar → Elegir color….

// PURE-BEGIN
struct CSSColorMatch {
    enum Format { case hex3, hex4, hex6, hex8, rgb, hsl, named }
    typealias RGBA = (r: Double, g: Double, b: Double, a: Double)
    /// Bytes UTF-8 (posiciones de Scintilla), ya desplazados por `byteOffset`.
    let range: Range<Int>
    let rgba: RGBA
    let format: Format
}

/// Los 148 nombres de CSS Color 4 (sin `transparent` ni `currentcolor`), en 0xRRGGBB.
let cssNamedColors: [String: UInt32] = [
    "aliceblue": 0xF0F8FF, "antiquewhite": 0xFAEBD7, "aqua": 0x00FFFF, "aquamarine": 0x7FFFD4,
    "azure": 0xF0FFFF, "beige": 0xF5F5DC, "bisque": 0xFFE4C4, "black": 0x000000,
    "blanchedalmond": 0xFFEBCD, "blue": 0x0000FF, "blueviolet": 0x8A2BE2, "brown": 0xA52A2A,
    "burlywood": 0xDEB887, "cadetblue": 0x5F9EA0, "chartreuse": 0x7FFF00, "chocolate": 0xD2691E,
    "coral": 0xFF7F50, "cornflowerblue": 0x6495ED, "cornsilk": 0xFFF8DC, "crimson": 0xDC143C,
    "cyan": 0x00FFFF, "darkblue": 0x00008B, "darkcyan": 0x008B8B, "darkgoldenrod": 0xB8860B,
    "darkgray": 0xA9A9A9, "darkgreen": 0x006400, "darkgrey": 0xA9A9A9, "darkkhaki": 0xBDB76B,
    "darkmagenta": 0x8B008B, "darkolivegreen": 0x556B2F, "darkorange": 0xFF8C00, "darkorchid": 0x9932CC,
    "darkred": 0x8B0000, "darksalmon": 0xE9967A, "darkseagreen": 0x8FBC8F, "darkslateblue": 0x483D8B,
    "darkslategray": 0x2F4F4F, "darkslategrey": 0x2F4F4F, "darkturquoise": 0x00CED1, "darkviolet": 0x9400D3,
    "deeppink": 0xFF1493, "deepskyblue": 0x00BFFF, "dimgray": 0x696969, "dimgrey": 0x696969,
    "dodgerblue": 0x1E90FF, "firebrick": 0xB22222, "floralwhite": 0xFFFAF0, "forestgreen": 0x228B22,
    "fuchsia": 0xFF00FF, "gainsboro": 0xDCDCDC, "ghostwhite": 0xF8F8FF, "gold": 0xFFD700,
    "goldenrod": 0xDAA520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xADFF2F,
    "grey": 0x808080, "honeydew": 0xF0FFF0, "hotpink": 0xFF69B4, "indianred": 0xCD5C5C,
    "indigo": 0x4B0082, "ivory": 0xFFFFF0, "khaki": 0xF0E68C, "lavender": 0xE6E6FA,
    "lavenderblush": 0xFFF0F5, "lawngreen": 0x7CFC00, "lemonchiffon": 0xFFFACD, "lightblue": 0xADD8E6,
    "lightcoral": 0xF08080, "lightcyan": 0xE0FFFF, "lightgoldenrodyellow": 0xFAFAD2, "lightgray": 0xD3D3D3,
    "lightgreen": 0x90EE90, "lightgrey": 0xD3D3D3, "lightpink": 0xFFB6C1, "lightsalmon": 0xFFA07A,
    "lightseagreen": 0x20B2AA, "lightskyblue": 0x87CEFA, "lightslategray": 0x778899, "lightslategrey": 0x778899,
    "lightsteelblue": 0xB0C4DE, "lightyellow": 0xFFFFE0, "lime": 0x00FF00, "limegreen": 0x32CD32,
    "linen": 0xFAF0E6, "magenta": 0xFF00FF, "maroon": 0x800000, "mediumaquamarine": 0x66CDAA,
    "mediumblue": 0x0000CD, "mediumorchid": 0xBA55D3, "mediumpurple": 0x9370DB, "mediumseagreen": 0x3CB371,
    "mediumslateblue": 0x7B68EE, "mediumspringgreen": 0x00FA9A, "mediumturquoise": 0x48D1CC, "mediumvioletred": 0xC71585,
    "midnightblue": 0x191970, "mintcream": 0xF5FFFA, "mistyrose": 0xFFE4E1, "moccasin": 0xFFE4B5,
    "navajowhite": 0xFFDEAD, "navy": 0x000080, "oldlace": 0xFDF5E6, "olive": 0x808000,
    "olivedrab": 0x6B8E23, "orange": 0xFFA500, "orangered": 0xFF4500, "orchid": 0xDA70D6,
    "palegoldenrod": 0xEEE8AA, "palegreen": 0x98FB98, "paleturquoise": 0xAFEEEE, "palevioletred": 0xDB7093,
    "papayawhip": 0xFFEFD5, "peachpuff": 0xFFDAB9, "peru": 0xCD853F, "pink": 0xFFC0CB,
    "plum": 0xDDA0DD, "powderblue": 0xB0E0E6, "purple": 0x800080, "rebeccapurple": 0x663399,
    "red": 0xFF0000, "rosybrown": 0xBC8F8F, "royalblue": 0x4169E1, "saddlebrown": 0x8B4513,
    "salmon": 0xFA8072, "sandybrown": 0xF4A460, "seagreen": 0x2E8B57, "seashell": 0xFFF5EE,
    "sienna": 0xA0522D, "silver": 0xC0C0C0, "skyblue": 0x87CEEB, "slateblue": 0x6A5ACD,
    "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xFFFAFA, "springgreen": 0x00FF7F,
    "steelblue": 0x4682B4, "tan": 0xD2B48C, "teal": 0x008080, "thistle": 0xD8BFD8,
    "tomato": 0xFF6347, "turquoise": 0x40E0D0, "violet": 0xEE82EE, "wheat": 0xF5DEB3,
    "white": 0xFFFFFF, "whitesmoke": 0xF5F5F5, "yellow": 0xFFFF00, "yellowgreen": 0x9ACD32,
]

private func cssIsIdentByte(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b >= 0x80
}

private func cssHexValue(_ b: UInt8) -> Int? {
    switch b {
    case 0x30...0x39: return Int(b) - 0x30
    case 0x41...0x46: return Int(b) - 0x41 + 10
    case 0x61...0x66: return Int(b) - 0x61 + 10
    default: return nil
    }
}

private func cssClamp(_ v: Double) -> Double { min(1, max(0, v)) }

/// Un argumento de rgb()/hsl(): número con unidad opcional (`%`, `deg`, `rad`, `grad`, `turn`).
private func cssParseNumber(_ token: String) -> (value: Double, unit: String)? {
    if token == "none" { return (0, "") }
    var numberEnd = token.startIndex
    while numberEnd < token.endIndex, "+-.0123456789".contains(token[numberEnd]) {
        numberEnd = token.index(after: numberEnd)
    }
    guard let value = Double(token[..<numberEnd]), value.isFinite else { return nil }
    let unit = String(token[numberEnd...])
    guard ["", "%", "deg", "rad", "grad", "turn"].contains(unit) else { return nil }
    return (value, unit)
}

private func cssAlpha(_ token: String?) -> Double? {
    guard let token else { return 1 }
    guard let (v, unit) = cssParseNumber(token) else { return nil }
    switch unit {
    case "": return cssClamp(v)
    case "%": return cssClamp(v / 100)
    default: return nil
    }
}

private func cssHSLToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
    guard s > 0 else { return (l, l, l) }
    func channel(_ p: Double, _ q: Double, _ t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    let hue = h / 360
    return (channel(p, q, hue + 1.0 / 3), channel(p, q, hue), channel(p, q, hue - 1.0 / 3))
}

private func cssRGBToHSL(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
    let mx = max(r, g, b), mn = min(r, g, b)
    let l = (mx + mn) / 2
    let d = mx - mn
    guard d > 0 else { return (0, 0, l) }
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: Double
    if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    h *= 60
    return (h, s, l)
}

/// Argumentos de rgb()/rgba()/hsl()/hsla(): con comas o con espacios y `/` antes del alfa.
private func cssParseFunction(_ name: String, arguments: String) -> CSSColorMatch.RGBA? {
    let tokens = arguments.lowercased()
        .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "/" })
        .map(String.init)
    guard tokens.count == 3 || tokens.count == 4, let a = cssAlpha(tokens.count == 4 ? tokens[3] : nil) else { return nil }
    if name.hasPrefix("rgb") {
        var channels: [Double] = []
        for token in tokens.prefix(3) {
            guard let (v, unit) = cssParseNumber(token) else { return nil }
            switch unit {
            case "": channels.append(cssClamp(v / 255))
            case "%": channels.append(cssClamp(v / 100))
            default: return nil
            }
        }
        return (channels[0], channels[1], channels[2], a)
    }
    guard let (hv, hUnit) = cssParseNumber(tokens[0]),
          let (sv, sUnit) = cssParseNumber(tokens[1]), sUnit == "" || sUnit == "%",
          let (lv, lUnit) = cssParseNumber(tokens[2]), lUnit == "" || lUnit == "%" else { return nil }
    var degrees: Double
    switch hUnit {
    case "", "deg": degrees = hv
    case "rad": degrees = hv * 180 / .pi
    case "grad": degrees = hv * 0.9
    case "turn": degrees = hv * 360
    default: return nil
    }
    degrees = degrees.truncatingRemainder(dividingBy: 360)
    if degrees < 0 { degrees += 360 }
    let (r, g, b) = cssHSLToRGB(h: degrees, s: cssClamp(sv / 100), l: cssClamp(lv / 100))
    return (r, g, b, a)
}

/// Colores de `text` tratado como CSS. Los nombres solo cuentan como valor (tras `:` en la misma
/// declaración: `;`, `{` y `}` la cierran), para no marcar "red" en un selector o en prosa.
/// Comentarios `/* */` y strings se saltean.
func findCSSColors(in text: String, byteOffset: Int) -> [CSSColorMatch] {
    let bytes = Array(text.utf8)
    let n = bytes.count
    var result: [CSSColorMatch] = []
    var inValue = false
    var i = 0
    func byte(_ k: Int) -> UInt8 { k >= 0 && k < n ? bytes[k] : 0 }
    while i < n {
        let c = bytes[i]
        switch c {
        case UInt8(ascii: "/") where byte(i + 1) == UInt8(ascii: "*"):
            var j = i + 2
            while j < n, !(bytes[j] == UInt8(ascii: "*") && byte(j + 1) == UInt8(ascii: "/")) { j += 1 }
            i = min(n, j + 2)
            continue
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            // Un string CSS no cruza líneas sin escapar: cortar en el salto limita el daño de una
            // comilla suelta (p. ej. un apóstrofo) al resto de esa línea.
            var j = i + 1
            while j < n, bytes[j] != c, bytes[j] != UInt8(ascii: "\n") {
                j += bytes[j] == UInt8(ascii: "\\") ? 2 : 1
            }
            i = min(n, j + 1)
            continue
        case UInt8(ascii: ":"):
            inValue = true
        case UInt8(ascii: ";"), UInt8(ascii: "{"), UInt8(ascii: "}"):
            inValue = false
        case UInt8(ascii: "#"):
            let prev = byte(i - 1)
            var j = i + 1
            while j < n, cssIsIdentByte(bytes[j]) { j += 1 }
            let digits = bytes[(i + 1)..<j]
            if (i == 0 || (!cssIsIdentByte(prev) && prev != UInt8(ascii: "&"))),
               [3, 4, 6, 8].contains(digits.count), digits.allSatisfy({ cssHexValue($0) != nil }) {
                let values = digits.map { Double(cssHexValue($0)!) }
                let short = digits.count <= 4
                func component(_ k: Int) -> Double {
                    short ? values[k] * 17 / 255 : (values[2 * k] * 16 + values[2 * k + 1]) / 255
                }
                let hasAlpha = digits.count == 4 || digits.count == 8
                let formats: [Int: CSSColorMatch.Format] = [3: .hex3, 4: .hex4, 6: .hex6, 8: .hex8]
                let format = formats[digits.count]!
                result.append(CSSColorMatch(range: (byteOffset + i)..<(byteOffset + j),
                                            rgba: (component(0), component(1), component(2), hasAlpha ? component(3) : 1),
                                            format: format))
            }
            i = j
            continue
        default:
            let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            let prev = byte(i - 1)
            guard isLetter else { break }
            var j = i + 1
            while j < n, cssIsIdentByte(bytes[j]) { j += 1 }
            let startsWord = i == 0 || !(cssIsIdentByte(prev) || ".#@$%/\\".utf8.contains(prev))
            if startsWord {
                let word = String(decoding: bytes[i..<j], as: UTF8.self).lowercased()
                if ["rgb", "rgba", "hsl", "hsla"].contains(word), byte(j) == UInt8(ascii: "(") {
                    var k = j + 1
                    while k < n, k - j < 120, !"();{}\n".utf8.contains(bytes[k]) { k += 1 }
                    if byte(k) == UInt8(ascii: ")"),
                       let rgba = cssParseFunction(word, arguments: String(decoding: bytes[(j + 1)..<k], as: UTF8.self)) {
                        result.append(CSSColorMatch(range: (byteOffset + i)..<(byteOffset + k + 1), rgba: rgba,
                                                    format: word.hasPrefix("rgb") ? .rgb : .hsl))
                        i = k + 1
                        continue
                    }
                } else if inValue, byte(j) != UInt8(ascii: "."), byte(j) != UInt8(ascii: "("),
                          let hex = cssNamedColors[word] {
                    result.append(CSSColorMatch(range: (byteOffset + i)..<(byteOffset + j),
                                                rgba: (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
                                                       Double(hex & 0xFF) / 255, 1),
                                                format: .named))
                }
            }
            i = j
            continue
        }
        i += 1
    }
    return result
}

private func cssByte(_ v: Double) -> Int { Int((cssClamp(v) * 255).rounded()) }

/// Número corto: sin ceros de más (0.5, no 0.50; 1, no 1.0).
private func cssNumber(_ v: Double, decimals: Int) -> String {
    let scale = pow(10, Double(decimals))
    let rounded = (v * scale).rounded() / scale
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

/// El color en el formato del literal original. Hex sigue hex: el corto solo si el color entra
/// (cada canal con sus dos dígitos iguales), si no pasa al largo; `hex4`/`hex8` siempre llevan
/// alfa y `hex3`/`hex6` solo si es < 1. Un nombre pasa a hex (no hay nombre para cualquier color).
func formatCSSColor(_ rgba: CSSColorMatch.RGBA, like format: CSSColorMatch.Format) -> String {
    let r = cssByte(rgba.r), g = cssByte(rgba.g), b = cssByte(rgba.b), a = cssByte(rgba.a)
    let opaque = a == 255
    switch format {
    case .rgb:
        return opaque ? "rgb(\(r), \(g), \(b))" : "rgba(\(r), \(g), \(b), \(cssNumber(cssClamp(rgba.a), decimals: 2)))"
    case .hsl:
        let (h, s, l) = cssRGBToHSL(cssClamp(rgba.r), cssClamp(rgba.g), cssClamp(rgba.b))
        let hue = Int(h.rounded()) % 360, sat = Int((s * 100).rounded()), light = Int((l * 100).rounded())
        return opaque ? "hsl(\(hue), \(sat)%, \(light)%)"
            : "hsla(\(hue), \(sat)%, \(light)%, \(cssNumber(cssClamp(rgba.a), decimals: 2)))"
    case .hex3, .hex4, .hex6, .hex8, .named:
        let withAlpha = format == .hex4 || format == .hex8 || !opaque
        let channels = withAlpha ? [r, g, b, a] : [r, g, b]
        let short = (format == .hex3 || format == .hex4) && channels.allSatisfy { $0 % 17 == 0 }
        return "#" + channels.map { short ? String($0 / 17, radix: 16) : String(format: "%02x", $0) }.joined()
    }
}

/// Tramos de CSS dentro de HTML, en bytes de `text`: el interior de `<style…>…</style>` y el
/// valor de los atributos `style="…"`/`style='…'`. El lexer hypertext no estiliza ese CSS (queda
/// SCE_H_DEFAULT), así que se decide por texto. `startsInStyleBlock`: el texto empieza dentro de
/// un bloque abierto antes (el llamador lo averigua sin recorrer el documento entero).
func cssRegionsInHTML(_ text: String, startsInStyleBlock: Bool) -> [Range<Int>] {
    let bytes = Array(text.utf8)
    let n = bytes.count
    var regions: [Range<Int>] = []
    var blockStart: Int? = startsInStyleBlock ? 0 : nil
    func isSpace(_ b: UInt8) -> Bool {
        b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r")
    }
    func isStyleWord(at k: Int) -> Bool {
        guard k + 5 <= n else { return false }
        return zip(bytes[k..<(k + 5)], "style".utf8).allSatisfy { ($0 | 0x20) == $1 }
    }
    var i = 0
    while i < n {
        if let start = blockStart {
            if styleTagBoundary(bytes, at: i) == .close {
                if i > start { regions.append(start..<i) }
                blockStart = nil
                i += 7
            } else {
                i += 1
            }
            continue
        }
        if styleTagBoundary(bytes, at: i) == .open {
            guard let gt = bytes[i...].firstIndex(of: UInt8(ascii: ">")) else { break }
            blockStart = gt + 1
            i = gt + 1
            continue
        }
        if i > 0, isSpace(bytes[i - 1]), isStyleWord(at: i) {
            var j = i + 5
            while j < n, isSpace(bytes[j]) { j += 1 }
            if j < n, bytes[j] == UInt8(ascii: "=") {
                j += 1
                while j < n, isSpace(bytes[j]) { j += 1 }
                if j < n, bytes[j] == UInt8(ascii: "\"") || bytes[j] == UInt8(ascii: "'"),
                   let close = bytes[(j + 1)...].firstIndex(of: bytes[j]) {
                    if close > j + 1 { regions.append((j + 1)..<close) }
                    i = close + 1
                    continue
                }
            }
        }
        i += 1
    }
    if let start = blockStart, start < n { regions.append(start..<n) }
    return regions
}
// PURE-END

// MARK: - Indicador 15

/// Estilos del lexer css donde un literal no es un color: comentario, selector `#id`, strings
/// (SCE_CSS_COMMENT 9, SCE_CSS_ID 10, SCE_CSS_DOUBLESTRING 13, SCE_CSS_SINGLESTRING 14 en
/// lexilla/include/SciLexer.h). El escaneo de texto ya saltea comentarios y strings, pero el
/// rango puede empezar en medio de uno.
private let cssNonColorStyles: Set<Int> = [9, 10, 13, 14]

/// Recalcula los subrayados de color del rango visible ±100 líneas (como SmartHighlighter):
/// recorrer el documento entero no escala en un HTML de varios MB tipeando rápido.
func updateCSSColorIndicators(editor: ScintillaView, lexerName: String) {
    func call(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }
    let length = call(SCI_GETLENGTH)
    let previous = call(SCI_GETINDICATORCURRENT)
    _ = call(SCI_SETINDICATORCURRENT, INDICATOR_CSS_COLOR)
    defer {
        // El resto de la app llena indicadores con el valor por defecto (1): no dejarle un color.
        _ = call(SCI_SETINDICATORVALUE, 1)
        _ = call(SCI_SETINDICATORCURRENT, previous)
    }
    _ = call(SCI_INDICATORCLEARRANGE, 0, length)
    guard lexerName == "css" || lexerName == "hypertext", length > 0 else { return }

    let lineCount = call(SCI_GETLINECOUNT)
    let firstVisible = firstVisibleDocumentLine(editor)
    let startLine = max(0, firstVisible - 100)
    let endLine = min(lineCount, firstVisible + call(SCI_LINESONSCREEN) + 100)
    let rangeStart = call(SCI_POSITIONFROMLINE, startLine)
    let rangeEnd = endLine >= lineCount ? length : call(SCI_POSITIONFROMLINE, endLine)
    guard rangeStart >= 0, rangeEnd > rangeStart,
          let text = SpellChecker.targetText(editor: editor, start: rangeStart, end: rangeEnd),
          text.utf8.count == rangeEnd - rangeStart else { return }

    var matches: [CSSColorMatch] = []
    if lexerName == "css" {
        // Solo lo ya estilizado (lo visible siempre lo está): forzar SCI_COLOURISE re-lexea desde 0.
        let endStyled = call(SCI_GETENDSTYLED)
        matches = findCSSColors(in: text, byteOffset: rangeStart).filter {
            $0.range.lowerBound >= endStyled || !cssNonColorStyles.contains(call(SCI_GETSTYLEAT, $0.range.lowerBound))
        }
    } else {
        let bytes = Array(text.utf8)
        let inside = rangeStart > 0 && styleBlockIsOpen(before: rangeStart, editor: editor)
        for region in cssRegionsInHTML(text, startsInStyleBlock: inside) {
            matches += findCSSColors(in: String(decoding: bytes[region], as: UTF8.self),
                                     byteOffset: rangeStart + region.lowerBound)
        }
    }
    for match in matches.prefix(10_000) {
        let bgr = cssByte(match.rgba.r) | cssByte(match.rgba.g) << 8 | cssByte(match.rgba.b) << 16
        _ = call(SCI_SETINDICATORVALUE, bgr | SC_INDICVALUEBIT)
        _ = call(SCI_INDICATORFILLRANGE, match.range.lowerBound, match.range.count)
    }
}

/// ¿Hay un `<style>` abierto antes de `position`? Dos búsquedas hacia atrás en Scintilla (nativas,
/// sin copiar el texto) del último `<style`/`</style`; el más cercano decide. Compartida con el
/// Tab de Emmet (Emmet.swift). Cambia el target y los search flags.
func styleBlockIsOpen(before position: Int, editor: ScintillaView) -> Bool {
    func call(_ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }
    _ = call(SCI_SETSEARCHFLAGS, 0)   // sin SCFIND_MATCHCASE: <STYLE> también vale
    func lastOccurrence(_ needle: String) -> Int {
        _ = call(SCI_SETTARGETRANGE, position, 0)   // inicio > fin = buscar hacia atrás
        return needle.withCString { call(SCI_SEARCHINTARGET, needle.utf8.count, Int(bitPattern: UInt(bitPattern: $0))) }
    }
    let found = max(lastOccurrence("<style"), lastOccurrence("</style"))
    guard found >= 0,
          let snippet = SpellChecker.targetText(editor: editor, start: found, end: min(found + 7, position)) else { return false }
    return isInsideStyleBlock(snippet)
}

// MARK: - Elegir color…

/// Editar → Elegir color…: abre el NSColorPanel con el color bajo el caret y reescribe el literal
/// en su formato en cada cambio. Toda la sesión es una acción de deshacer: se abre al empezar y
/// se cierra al cerrar el panel, al salir el caret del literal o ante una edición ajena.
func pickCSSColor(editor: ScintillaView) {
    CSSColorPicker.shared.begin(editor: editor)
}

final class CSSColorPicker: NSObject {
    static let shared = CSSColorPicker()

    private weak var editor: ScintillaView?
    private var documentPointer = 0
    private var range = 0..<0
    private var format: CSSColorMatch.Format = .hex6
    private var literal = ""
    private var applying = false
    private var closeObserver: NSObjectProtocol?

    private func call(_ editor: ScintillaView, _ message: UInt32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(ScintillaView.directCall(editor, message: message, wParam: uptr_t(bitPattern: wParam), lParam: sptr_t(lParam)))
    }

    func begin(editor: ScintillaView) {
        endSession()
        guard call(editor, SCI_GETREADONLY) == 0 else { NSSound.beep(); return }
        let caret = call(editor, SCI_GETCURRENTPOS)
        let line = call(editor, SCI_LINEFROMPOSITION, caret)
        let lineStart = call(editor, SCI_POSITIONFROMLINE, line)
        let lineEnd = call(editor, SCI_GETLINEENDPOSITION, line)
        let lineText = lineEnd > lineStart ? SpellChecker.targetText(editor: editor, start: lineStart, end: lineEnd) ?? "" : ""
        let match = lineText.utf8.count == lineEnd - lineStart
            ? findCSSColors(in: lineText, byteOffset: lineStart).first { $0.range.lowerBound <= caret && caret <= $0.range.upperBound }
            : nil

        let panel = NSColorPanel.shared
        _ = call(editor, SCI_BEGINUNDOACTION)
        let initial: CSSColorMatch.RGBA
        if let match {
            range = match.range
            format = match.format
            literal = SpellChecker.targetText(editor: editor, start: range.lowerBound, end: range.upperBound) ?? ""
            initial = match.rgba
        } else {
            // Sin color bajo el caret: se inserta el color actual del panel y se sigue editando ese.
            let current = Self.components(of: panel.color) ?? (0, 0, 0, 1)
            initial = (current.r, current.g, current.b, 1)
            format = .hex6
            literal = formatCSSColor(initial, like: .hex6)
            let start = call(editor, SCI_GETSELECTIONSTART)
            _ = call(editor, SCI_SETTARGETRANGE, start, call(editor, SCI_GETSELECTIONEND))
            literal.withCString { _ = call(editor, SCI_REPLACETARGET, literal.utf8.count, Int(bitPattern: UInt(bitPattern: $0))) }
            range = start..<(start + literal.utf8.count)
            _ = call(editor, SCI_SETEMPTYSELECTION, range.upperBound)
        }
        self.editor = editor
        documentPointer = call(editor, SCI_GETDOCPOINTER)

        // Sin target mientras se asigna el color: que el panel no reescriba el literal recién leído.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = NSColor(srgbRed: initial.r, green: initial.g, blue: initial.b, alpha: initial.a)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in self?.endSession() }
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let editor else { return }
        guard sessionIsValid(editor) else { endSession(); return }
        guard let rgba = Self.components(of: sender.color) else { return }
        let text = formatCSSColor(rgba, like: format)
        guard text != literal else { return }
        applying = true
        defer { applying = false }
        _ = call(editor, SCI_SETTARGETRANGE, range.lowerBound, range.upperBound)
        text.withCString { _ = call(editor, SCI_REPLACETARGET, text.utf8.count, Int(bitPattern: UInt(bitPattern: $0))) }
        range = range.lowerBound..<(range.lowerBound + text.utf8.count)
        literal = text
        _ = call(editor, SCI_SETEMPTYSELECTION, range.upperBound)
    }

    /// Mismo documento, editable y con el literal tal como lo dejó la sesión.
    private func sessionIsValid(_ editor: ScintillaView) -> Bool {
        call(editor, SCI_GETDOCPOINTER) == documentPointer
            && call(editor, SCI_GETREADONLY) == 0
            && SpellChecker.targetText(editor: editor, start: range.lowerBound, end: range.upperBound) == literal
    }

    /// SC_UPDATE_SELECTION: el caret fuera del literal (o en otro documento) cierra la sesión.
    func editorSelectionChanged() {
        guard let editor, !applying else { return }
        let caret = call(editor, SCI_GETCURRENTPOS)
        if call(editor, SCI_GETDOCPOINTER) != documentPointer || caret < range.lowerBound || caret > range.upperBound {
            endSession()
        }
    }

    /// Edición que no hizo el panel (tipeo, deshacer, recarga): cierra la sesión en el acto. Con
    /// `async`, una edición en otra pestaña o un SCI_SETDOCPOINTER entre medio dejaban la acción de
    /// deshacer abierta o la cerraban sobre otro documento. SCI_ENDUNDOACTION no modifica el texto,
    /// así que es válido dentro de SCN_MODIFIED.
    func editorContentChanged() {
        guard editor != nil, !applying else { return }
        endSession()
    }

    /// Cierra la acción de deshacer y suelta el panel. Debe llamarse ANTES de cambiar de
    /// documento (TabsViewModel.attachToEditor): SCI_ENDUNDOACTION actúa sobre el documento
    /// actual y uno con la acción abierta agruparía todas sus ediciones posteriores.
    func endSession() {
        guard let editor else { return }
        self.editor = nil
        if call(editor, SCI_GETDOCPOINTER) == documentPointer {
            _ = call(editor, SCI_ENDUNDOACTION)
        }
        // Nadie más en la app usa el panel de colores: soltarlo sin preguntar de quién es.
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    private static func components(of color: NSColor) -> CSSColorMatch.RGBA? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent), Double(srgb.alphaComponent))
    }
}
