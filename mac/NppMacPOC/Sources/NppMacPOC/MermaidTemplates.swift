import Foundation
import Scintilla

/// Plantillas básicas de cada tipo de diagrama Mermaid (menú "Diagramas" de la barra de
/// formato), para orientar sobre la sintaxis.
enum MermaidTemplates {
    struct Template: Identifiable {
        let id: String
        let title: String
        let body: String
    }

    static var all: [Template] {
        [
            Template(id: "flow-shapes", title: L("Diagrama de flujo: formas"), body: """
            flowchart TD
                A[Rectángulo]
                B(Redondeado)
                C([Estadio])
                D[[Subrutina]]
                E{Rombo / Decisión}
                F{{Hexágono}}
                G>Bandera]
                H[(Base de datos)]
            """),
            Template(id: "flow-decision", title: L("Diagrama de flujo: decisión"), body: """
            flowchart TD
                A[Inicio] --> B{¿Condición?}
                B -->|Sí| C[Acción 1]
                B -->|No| D[Acción 2]
                C --> E[Fin]
                D --> E
            """),
            Template(id: "sequence", title: L("Secuencia"), body: """
            sequenceDiagram
                participant C as Cliente
                participant S as Servidor

                C->>S: Login
                Note over C,S: Credenciales cifradas con TLS
                Note right of S: Valida contra BBDD
                S-->>C: Token JWT
            """),
            Template(id: "class", title: L("Clases"), body: """
            classDiagram
                class Animal {
                    +String nombre
                    +comer()
                }
                class Perro {
                    +ladrar()
                }
                Animal <|-- Perro
            """),
            Template(id: "state", title: L("Estados"), body: """
            stateDiagram-v2
                [*] --> Borrador
                Borrador --> Revisión: enviar
                Revisión --> Publicado: aprobar
                Revisión --> Borrador: rechazar
                Publicado --> [*]
            """),
            Template(id: "er", title: L("Entidad-relación"), body: """
            erDiagram
                CLIENTE ||--o{ PEDIDO : realiza
                PEDIDO ||--|{ LINEA : contiene
                PRODUCTO ||--o{ LINEA : aparece_en
            """),
            Template(id: "gantt", title: L("Gantt"), body: """
            gantt
                title Proyecto
                dateFormat YYYY-MM-DD
                section Diseño
                    Requisitos :a1, 2026-01-05, 7d
                    Maquetas   :after a1, 5d
                section Desarrollo
                    Implementación :2026-01-19, 14d
            """),
            Template(id: "pie", title: L("Gráfico de torta"), body: """
            pie title Uso del tiempo
                "Trabajo" : 8
                "Sueño" : 8
                "Ocio" : 4
                "Otros" : 4
            """),
            Template(id: "journey", title: L("Recorrido de usuario"), body: """
            journey
                title Comprar en línea
                section Buscar
                    Encontrar producto: 4: Usuario
                section Pagar
                    Ingresar tarjeta: 2: Usuario
                    Confirmación: 5: Usuario, Sistema
            """),
            Template(id: "mindmap", title: L("Mapa mental"), body: """
            mindmap
                root((Proyecto))
                    Objetivos
                        Corto plazo
                        Largo plazo
                    Equipo
                        Diseño
                        Desarrollo
            """),
            Template(id: "timeline", title: L("Línea de tiempo"), body: """
            timeline
                title Historia
                2024 : Idea
                2025 : Prototipo : Primeros usuarios
                2026 : Lanzamiento
            """),
            Template(id: "git", title: L("Ramas de Git"), body: """
            gitGraph
                commit
                branch feature
                checkout feature
                commit
                checkout main
                merge feature
                commit
            """),
        ]
    }

    /// Bloque ```mermaid en una línea propia: si el caret está a mitad de una línea con
    /// texto, se abre una nueva antes.
    static func insert(_ template: Template, editor: ScintillaView) {
        let pos = Int(ScintillaView.directCall(editor, message: SCI_GETCURRENTPOS, wParam: 0, lParam: 0))
        let line = Int(ScintillaView.directCall(editor, message: SCI_LINEFROMPOSITION, wParam: uptr_t(pos), lParam: 0))
        let lineStart = Int(ScintillaView.directCall(editor, message: SCI_POSITIONFROMLINE, wParam: uptr_t(line), lParam: 0))
        let prefix = pos > lineStart ? "\n" : ""
        let text = prefix + "```mermaid\n" + template.body + "\n```\n"
        text.withCString { cstr in
            _ = ScintillaView.directCall(editor, message: SCI_REPLACESEL, wParam: 0, lParam: sptr_t(bitPattern: UInt(bitPattern: cstr)))
        }
        _ = ScintillaView.directCall(editor, message: SCI_SCROLLCARET, wParam: 0, lParam: 0)
    }
}
