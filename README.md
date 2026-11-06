<p align="center"><img src="docs/logo.png" width="160" alt="GNote++ logo"></p>

# GNote++ — Markdown and code editor for macOS

[![Latest release](https://img.shields.io/github/v/release/jcubillosz/gnote-plus-plus)](https://github.com/jcubillosz/gnote-plus-plus/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)
[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-0070ba)](https://www.paypal.com/ncp/payment/ARSKH5DQC8WAL)

**English** · [Español](#español) · [Website](https://jcubillosz.github.io/gnote-plus-plus/)

GNote++ is a free, open-source **Markdown and code editor for Mac**, built on
the source code of [Notepad++](https://notepad-plus-plus.org/). Write **AI
prompts, docs and web content** with a live preview and **Mermaid diagrams**,
on top of the [Scintilla](https://www.scintilla.org/) editing engine and the
syntax highlighting of every Notepad++ language. A native SwiftUI app — no
Wine, no emulation. Signed and notarized by Apple.

**[Download GNote++ for macOS (.dmg)](https://github.com/jcubillosz/gnote-plus-plus/releases/latest)**

![GNote++ Markdown editor with live preview, Mermaid flowchart, GitHub alert, task list and document outline](docs/screenshots/markdown-mermaid.png)

## Who it's for

- **Prompt engineers** — system prompts, prompt libraries, `CLAUDE.md` and
  `AGENTS.md` are Markdown. See them rendered as you write, navigate them from
  the outline, sketch agent flows in Mermaid, and lock a finished prompt
  against accidental edits.
- **Web and content editors** — posts and pages for Markdown-based sites;
  pasted images are saved next to the file; GitHub-style preview.
- **Technical writers** — READMEs, runbooks and docs with alerts, task lists,
  diagrams (PNG/SVG export) and PDF export.
- **Developers** — every Notepad++ language, regex search, find in files,
  multi-cursor editing, minimap.

## Markdown, done properly

- **Editor, split or preview-only view**; double-click the preview to jump to
  the source line.
- **GitHub Flavored Markdown**: tables, task lists you can tick in the preview,
  alerts (`> [!NOTE]`, `[!WARNING]`…), strikethrough, autolinks.
- **Mermaid diagrams** (flowchart, sequence, class, state, Gantt, pie, mind
  map…) with templates; export as PNG or SVG.
- **Formatting toolbar, compact or large**: the large one works like a word
  processor — big icons with labels, dropdowns with live samples (heading
  sizes, list types, alert colours) and a grid to pick the table size.
  Links, highlight, keyboard keys, footnotes, collapsible sections; ⌘B, ⌘I,
  ⌘K.
- Syntax-highlighted code blocks in the preview, list continuation, table
  formatting (⌥⌘T), image paste and drag-and-drop.
- Heading outline in the sidebar; print and PDF export; spell checker (English
  and Spanish).
- **Private by design**: the preview runs no JavaScript and diagrams render
  offline.

![Markdown editor in light mode with the large formatting toolbar, live preview and Mermaid diagram](docs/screenshots/markdown-light.png)

## And a full code editor

- **Syntax highlighting** for every language Notepad++ supports, with its same
  definitions and color themes; light and dark mode.
- Bookmarks, code folding, change history, brace and tag matching, smart
  highlight, **multi-cursor and column editing**, autocompletion, line
  operations, function list, **minimap**.
- **Auto-indent** as you type (braces, Python, HTML/XML), **reindent** a file
  or selection, and closing brackets that step over instead of doubling.
- **Format and minify JSON** (key order preserved), **format XML**, MD5/SHA
  hashes and Base64 in the Tools menu.
- **Find and replace** with regular expressions, plus **find in files** across a
  folder.
- **Encoding and line-ending detection** (UTF-8, Latin-1, CRLF…) preserved on
  save; tabs, file tree, session restore, reload of files changed on disk.
- Interface in English and Spanish.

![GNote++ code editor on macOS with file tree, tabs, syntax highlighting and minimap](docs/screenshots/editor.png)

![Find with highlight-all: every match marked in the code, dark theme](docs/screenshots/highlights.png)

![Find in files: search results grouped by file in the sidebar](docs/screenshots/find-in-files.png)

## How it differs from Notepad++

| | Notepad++ | GNote++ |
|---|---|---|
| Runs on | Windows | macOS, native app |
| Markdown | Syntax highlighting; preview via third-party plugins | Built-in live preview, Mermaid, outline, toolbar, PDF export |
| Languages and themes | Notepad++ definitions | The same definitions and themes |
| Editing engine | Scintilla | Scintilla |
| License | GPL-3.0, free | GPL-3.0, free |

GNote++ is not affiliated with or endorsed by Notepad++.

## What's new in 1.4.0

- **Large Markdown toolbar**, word-processor style: big icons with labels,
  dropdowns with live samples (headings at their size, list types, alerts in
  their colour) and a grid to pick the table size. Switch between it and the
  compact bar (⇕ button or View menu); the app remembers your choice. New:
  link, highlight, keyboard key, subscript and superscript, horizontal rule,
  collapsible section and footnote; ⌘B, ⌘I and ⌘K (link) shortcuts.
- **Auto-indent** by language: Enter keeps the indentation and adds a level
  after `{`, `[`, `(`, `:` in Python or an HTML/XML tag; closing brackets
  align with their opener. **Reindent** a document or selection (Edit ▸
  Whitespace).
- **Format and minify JSON** (key order preserved) and **format XML**, in the
  Tools menu, next to MD5/SHA-1/SHA-256 and Base64.
- **Friendlier auto-close**: typing the `)`, `]`, `}` or quote the editor
  already closed steps over it instead of doubling it.
- **Minimap inside the editor**, next to the scroll bar.
- **Visible highlights in dark mode**: find all, the current match, the
  selected word, matching braces and tags, and multi-selection use theme
  colours with good contrast. Dark theme with better contrast for diff, XML and
  JSON, and dark blockquotes in the preview.
- **More Notepad++ features**: save all; close others, to the right or all
  (right-click a tab); drag tabs to reorder and middle-click to close; show
  end of line, indent guides and edge line; tabs ↔ spaces; insert date and
  time; replace in selection only; go to matching brace (⌃⌘B); new line and
  case operations; View ▸ Summary.
- Picking a heading replaces the line's existing heading.
- ⌘Q with unsaved changes asks before quitting; saving a file that is a
  symbolic link no longer replaces the link; "Replace all" undoes in one step;
  switching theme updates every tab; closing a background tab no longer
  changes the active one; the find counter shows which match you are on.
- Complete English interface (some texts were still untranslated).

[Full release history](https://jcubillosz.github.io/gnote-plus-plus/changelog/)

## Support the project

GNote++ is free and built in spare time. If it saves you time, a
[donation via PayPal](https://www.paypal.com/ncp/payment/ARSKH5DQC8WAL)
helps keep it maintained and pays for the Apple developer account that lets it
open without security warnings.

---

## Español

GNote++ es un **editor de Markdown y código, gratuito, de código abierto para
macOS**, basado en el código fuente de [Notepad++](https://notepad-plus-plus.org/).
Pensado para escribir **prompts de IA, documentación y contenido web** con
vista previa en vivo y **diagramas Mermaid**, sobre el motor de edición y el
coloreado de sintaxis de Notepad++.

No es un port de la interfaz Win32 ni una capa de compatibilidad: la UI está
escrita de cero en SwiftUI y usa [Scintilla](https://www.scintilla.org/) como
componente de edición. Lo que se reutiliza de Notepad++ es su lógica de datos —
la detección de codificación (uchardet) y las definiciones de lenguajes y temas
(`langs.model.xml`, `stylers.model.xml`).

[Sitio web en español](https://jcubillosz.github.io/gnote-plus-plus/es/) ·
[Donar con PayPal](https://www.paypal.com/ncp/payment/ARSKH5DQC8WAL)

---

## Descargar

**[GNote++.dmg — v1.4.0](releases/v1.4.0/GNote++.dmg)** (también en
[Releases](https://github.com/jcubillosz/gnote-plus-plus/releases/tag/v1.4.0)).
Firmado con Developer ID y notarizado por Apple — se abre sin advertencias de
Gatekeeper.

### Novedades en 1.4.0

- **Barra de Markdown grande**, al estilo de los procesadores de texto: íconos
  grandes con su nombre, desplegables con muestras (títulos a su tamaño,
  tipos de lista, alertas con su color) y una cuadrícula para elegir el tamaño
  de la tabla. Se alterna con la barra compacta (botón ⇕ o Vista) y la app
  recuerda la elección. Nuevos: enlace, resaltado, tecla, subíndice y
  superíndice, línea horizontal, sección plegable y nota al pie; atajos ⌘B,
  ⌘I y ⌘K (enlace).
- **Indentación automática** según el lenguaje: Enter mantiene la sangría y
  sube un nivel tras `{`, `[`, `(`, `:` en Python o una etiqueta HTML/XML; el
  cierre se alinea con su apertura. **Reindentar** documento o selección
  (Editar ▸ Espacios en blanco).
- **Formatear y minificar JSON** (conserva el orden de las claves) y
  **formatear XML**, en el menú Herramientas, junto a MD5/SHA-1/SHA-256 y
  Base64.
- **Autocierre más cómodo**: escribir a mano el `)`, `]`, `}` o la comilla que
  el editor ya cerró pasa por encima en vez de duplicarlo.
- **Minimapa dentro del editor**, junto a la barra de scroll.
- **Resaltados visibles en tema oscuro**: buscar todo, la coincidencia actual,
  la palabra seleccionada, llaves y etiquetas pareadas y la multiselección
  usan colores del tema con buen contraste. Tema oscuro con más contraste en
  diff, XML y JSON, y citas de la vista previa en oscuro.
- **Más funciones de Notepad++**: guardar todo; cerrar otras, a la derecha o
  todas (clic derecho en la pestaña); arrastrar pestañas para ordenarlas y
  cerrarlas con el clic del medio; mostrar fin de línea, guías de indentación
  y línea de margen; tabs ↔ espacios; insertar fecha y hora; reemplazar solo
  en la selección; ir a la llave pareja (⌃⌘B); nuevas operaciones de línea y
  de mayúsculas; Vista ▸ Resumen.
- Elegir un título reemplaza el que ya tenía la línea.
- ⌘Q con cambios sin guardar pregunta antes de salir; guardar un archivo que
  es un enlace simbólico ya no reemplaza el enlace; "Reemplazar todos" se
  deshace de una vez; cambiar de tema actualiza todas las pestañas; cerrar una
  pestaña de fondo ya no cambia la activa; el contador de la búsqueda muestra
  en qué coincidencia estás.
- Interfaz en inglés completa (quedaban textos sin traducir).

[Historial completo de versiones](https://jcubillosz.github.io/gnote-plus-plus/es/changelog/)

## Qué hace

- **Editor Scintilla** con pestañas, árbol de archivos y temas claro y oscuro
  que siguen al sistema.
- **Coloreado de sintaxis** para todos los lenguajes de Notepad++, usando sus
  mismas definiciones y paletas, con negrita y cursiva.
- **Codificación y fin de línea**: se detectan al abrir y se conservan al
  guardar. Un archivo Latin-1 con CRLF se guarda como Latin-1 con CRLF.
- **Buscar y reemplazar** con expresiones regulares, coincidencia de
  mayúsculas, palabras completas, wrap-around y resaltado de todas las
  coincidencias.
- **Markdown**: coloreado en el editor y vista previa en vivo compatible con
  GitHub Flavored Markdown (tablas, listas de tareas, tachado, autolinks,
  alertas), renderizada con [cmark-gfm](https://github.com/github/cmark-gfm);
  **diagramas Mermaid** con exportación a PNG/SVG, esquema del documento e
  impresión/PDF.
- **Barra de formato compacta o grande**: la grande funciona como un
  procesador de texto, con íconos y nombre, desplegables con muestras
  (títulos, listas, alertas) y una cuadrícula para elegir el tamaño de la
  tabla.
- **Indentación automática** al escribir, **reindentar**, autocierre que pasa
  por encima del cierre, **formatear JSON y XML**, multicursor, marcadores,
  plegado, minimapa y buscar en archivos.
- Ir a la línea o a una posición, archivos recientes, restaurar la última
  pestaña cerrada, renombrar archivos.
- Interfaz en **español e inglés**, siguiendo el idioma del sistema.

## Requisitos

- macOS 13 o superior
- Xcode Command Line Tools (para compilar)

## Compilar

No hay proyecto de Xcode: es un paquete de Swift Package Manager.

```bash
cd mac/NppMacPOC
swift build
./scripts/make_app_bundle.sh
open .build/GNote++.app
```

`make_app_bundle.sh` arma el `.app` a mano a partir del binario de SwiftPM y lo
firma ad-hoc, que es lo que exige arm64 para poder ejecutarlo.

> El paquete alcanza `PowerEditor/`, `lexilla/` y `scintilla/` por symlinks
> relativos, así que hay que clonar el repositorio completo. Compilar solo la
> carpeta `mac/` no funciona.

## Créditos

GNote++ existe gracias al trabajo de otros:

| Componente | Autor | Licencia |
|---|---|---|
| [Notepad++](https://github.com/notepad-plus-plus/notepad-plus-plus) | Don Ho | GPL-3.0 |
| [Scintilla](https://www.scintilla.org/) · [Lexilla](https://www.scintilla.org/Lexilla.html) | Neil Hodgson | HPND |
| [uchardet](https://www.freedesktop.org/wiki/Software/uchardet/) | Mozilla · Free Software Foundation | MPL-1.1 |
| [pugixml](https://pugixml.org/) | Arseny Kapoulkine | MIT |
| [cmark-gfm](https://github.com/github/cmark-gfm) | John MacFarlane · GitHub | BSD-2 |
| [Boost.Regex](https://www.boost.org/doc/libs/release/libs/regex/) | John Maddock | BSL-1.0 |
| [Mermaid](https://mermaid.js.org/) | Knut Sveidqvist y colaboradores | MIT |

GNote++ no está afiliado a Notepad++ ni cuenta con su respaldo, y no usa su
nombre, su ícono ni su imagen de marca.

## Licencia

GPL-3.0, heredada de Notepad++. Ver [LICENSE](LICENSE).

Eso incluye tu derecho a obtener, estudiar, modificar y redistribuir este
código fuente.

## Apoyar el proyecto

Si GNote++ te resulta útil, puedes contribuir a su desarrollo:

**[Donar vía PayPal](https://www.paypal.com/ncp/payment/ARSKH5DQC8WAL)**
