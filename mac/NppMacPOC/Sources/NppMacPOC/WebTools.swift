// Herramientas web puras (URL, entidades HTML, JWT, timestamps). Sin dependencias de UI para poder probarlas aparte.
import Foundation

func urlEncode(_ text: String) -> String {
    // Solo los "unreserved" de RFC 3986 quedan sin escapar (a diferencia de urlQueryAllowed, que deja & = /).
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
}

func urlDecode(_ text: String) -> String? { text.removingPercentEncoding }

func htmlEntitiesEncode(_ text: String) -> String {
    var out = ""
    for c in text.unicodeScalars {
        switch c {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.unicodeScalars.append(c)
        }
    }
    return out
}

/// Las 252 entidades con nombre de HTML 4.01 (latin1, especiales, símbolos, griego, flechas,
/// matemáticas), más `apos` (XML/HTML5).
private let namedEntities: [String: String] = [
    "quot": "\"", "amp": "&", "lt": "<", "gt": ">", "nbsp": "\u{00A0}", "iexcl": "¡", "cent": "¢",
    "pound": "£", "curren": "¤", "yen": "¥", "brvbar": "¦", "sect": "§", "uml": "¨", "copy": "©",
    "ordf": "ª", "laquo": "«", "not": "¬", "shy": "\u{00AD}", "reg": "®", "macr": "¯", "deg": "°",
    "plusmn": "±", "sup2": "²", "sup3": "³", "acute": "´", "micro": "µ", "para": "¶", "middot": "·",
    "cedil": "¸", "sup1": "¹", "ordm": "º", "raquo": "»", "frac14": "¼", "frac12": "½", "frac34": "¾",
    "iquest": "¿", "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å",
    "AElig": "Æ", "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì",
    "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó",
    "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "times": "×", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú",
    "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý", "THORN": "Þ", "szlig": "ß", "agrave": "à", "aacute": "á",
    "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è",
    "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï",
    "eth": "ð", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö",
    "divide": "÷", "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü",
    "yacute": "ý", "thorn": "þ", "yuml": "ÿ", "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
    "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜", "Alpha": "Α", "Beta": "Β", "Gamma": "Γ",
    "Delta": "Δ", "Epsilon": "Ε", "Zeta": "Ζ", "Eta": "Η", "Theta": "Θ", "Iota": "Ι", "Kappa": "Κ",
    "Lambda": "Λ", "Mu": "Μ", "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο", "Pi": "Π", "Rho": "Ρ", "Sigma": "Σ",
    "Tau": "Τ", "Upsilon": "Υ", "Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω", "alpha": "α",
    "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
    "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
    "pi": "π", "rho": "ρ", "sigmaf": "ς", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
    "chi": "χ", "psi": "ψ", "omega": "ω", "thetasym": "ϑ", "upsih": "ϒ", "piv": "ϖ", "ensp": "\u{2002}",
    "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}",
    "rlm": "\u{200F}", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
    "ldquo": "“", "rdquo": "”", "bdquo": "„", "dagger": "†", "Dagger": "‡", "bull": "•", "hellip": "…",
    "permil": "‰", "prime": "′", "Prime": "″", "lsaquo": "‹", "rsaquo": "›", "oline": "‾", "frasl": "⁄",
    "euro": "€", "image": "ℑ", "weierp": "℘", "real": "ℜ", "trade": "™", "alefsym": "ℵ", "larr": "←",
    "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔", "crarr": "↵", "lArr": "⇐", "uArr": "⇑",
    "rArr": "⇒", "dArr": "⇓", "hArr": "⇔", "forall": "∀", "part": "∂", "exist": "∃", "empty": "∅",
    "nabla": "∇", "isin": "∈", "notin": "∉", "ni": "∋", "prod": "∏", "sum": "∑", "minus": "−",
    "lowast": "∗", "radic": "√", "prop": "∝", "infin": "∞", "ang": "∠", "and": "∧", "or": "∨",
    "cap": "∩", "cup": "∪", "int": "∫", "there4": "∴", "sim": "∼", "cong": "≅", "asymp": "≈", "ne": "≠",
    "equiv": "≡", "le": "≤", "ge": "≥", "sub": "⊂", "sup": "⊃", "nsub": "⊄", "sube": "⊆", "supe": "⊇",
    "oplus": "⊕", "otimes": "⊗", "perp": "⊥", "sdot": "⋅", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊",
    "rfloor": "⌋", "lang": "〈", "rang": "〉", "loz": "◊", "spades": "♠", "clubs": "♣", "hearts": "♥",
    "diams": "♦",
    "apos": "'",
]

func htmlEntitiesDecode(_ text: String) -> String {
    let s = Array(text.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    while i < s.count {
        if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";"), semi > i + 1 {
            let body = String(String.UnicodeScalarView(s[(i + 1)..<semi]))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = numericEntity(UInt32(body.dropFirst(2), radix: 16))
            } else if body.hasPrefix("#") {
                replacement = numericEntity(UInt32(body.dropFirst(), radix: 10))
            } else {
                replacement = namedEntities[body]
            }
            if let r = replacement {
                out.append(contentsOf: r.unicodeScalars)
                i = semi + 1
                continue
            }
        }
        out.append(s[i])
        i += 1
    }
    return String(out)
}

/// `&#0;` y los controles C0 (salvo tab, LF y CR) quedan sin decodificar: un NUL o un ESC en el
/// documento no se ve y rompe a quien lo lea después; se deja la entidad como estaba.
private func numericEntity(_ value: UInt32?) -> String? {
    guard let value, let scalar = Unicode.Scalar(value) else { return nil }
    if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D { return nil }
    return String(scalar)
}

/// Sin selección, una transformación del documento entero (formatear, timestamp ↔ fecha) no debe
/// comerse el salto final del archivo. Por unicodeScalars: "\r\n" es un solo Character en Swift.
func keepingTrailingEOL(of original: String, in result: String) -> String {
    func endsWithEOL(_ t: String) -> Bool { t.unicodeScalars.last == "\n" || t.unicodeScalars.last == "\r" }
    guard endsWithEOL(original), !endsWithEOL(result) else { return result }
    let scalars = original.unicodeScalars
    if scalars.last == "\r" { return result + "\r" }
    let beforeLast = scalars.index(before: scalars.endIndex)
    let isCRLF = beforeLast > scalars.startIndex && scalars[scalars.index(before: beforeLast)] == "\r"
    return result + (isCRLF ? "\r\n" : "\n")
}

private func base64URLDecode(_ part: String) -> Data? {
    var b64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    // base64url suele venir sin "=": Data(base64Encoded:) exige el relleno.
    while b64.count % 4 != 0 { b64 += "=" }
    return Data(base64Encoded: b64)
}

/// Decodifica encabezado y payload (sin verificar la firma). nil si no es un JWT con JSON válido.
func decodeJWT(_ token: String) -> (header: String, payload: String)? {
    let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var decoded: [String] = []
    for part in parts.prefix(2) {
        guard let data = base64URLDecode(String(part)), let json = String(data: data, encoding: .utf8),
              let formatted = try? formatJSON(json, indent: "  ") else { return nil }
        decoded.append(formatted)
    }
    return (decoded[0], decoded[1])
}

/// Fechas ISO de los claims exp/iat/nbf del payload (en el orden dado), si son numéricos.
func jwtTimeClaims(payload: String, timeZone: TimeZone) -> [(name: String, iso: String)] {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return [] }
    return ["exp", "iat", "nbf"].compactMap { key in
        guard let n = obj[key] as? NSNumber, let iso = timestampToISO(String(n.int64Value), timeZone: timeZone) else { return nil }
        return (key, iso)
    }
}

func timestampToISO(_ text: String, timeZone: TimeZone) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Double(t) else { return nil }
    let seconds: Double
    switch t.count {
    case 10: seconds = n
    case 13: seconds = n / 1000
    default: return nil
    }
    let f = ISO8601DateFormatter()
    f.timeZone = timeZone
    f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    return f.string(from: Date(timeIntervalSince1970: seconds))
}

func isoToTimestamp(_ text: String) -> Int? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: t) { return Int(d.timeIntervalSince1970) }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: t).map { Int($0.timeIntervalSince1970) }
}
