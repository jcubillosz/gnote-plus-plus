import Foundation

private let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

/// PATH para lanzar un formateador: los shebangs `#!/usr/bin/env node|python3` se resuelven con él.
/// Los directorios del sistema van al final: sin las herramientas de línea de comandos,
/// `/usr/bin/python3` es un shim que abre el diálogo de instalación.
func composeToolSearchPath(executableDirectory: String, fixed: [String], login: [String]) -> String {
    var seen = Set<String>()
    var out: [String] = []
    for dir in [executableDirectory] + fixed + login where dir.hasPrefix("/") && !systemDirectories.contains(dir) {
        if seen.insert(dir).inserted { out.append(dir) }
    }
    return (out + systemDirectories).joined(separator: ":")
}
