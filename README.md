<p align="center"><img src="docs/logo.png" width="160" alt="GNote++ logo"></p>

# GNote++ — Markdown and code editor for macOS

[![Latest release](https://img.shields.io/github/v/release/jcubillosz/gnote-plus-plus)](https://github.com/jcubillosz/gnote-plus-plus/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)
[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-0070ba)](https://www.paypal.com/donate/?hosted_button_id=Q2E7M3ZS53NF8)

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
- Syntax-highlighted code blocks in the preview, formatting toolbar, list
  continuation, table formatting (⌥⌘T), image paste and drag-and-drop.
- Heading outline in the sidebar; print and PDF export; spell checker (English
  and Spanish).
- **Private by design**: the preview runs no JavaScript and diagrams render
  offline.

## And a full code editor

- **Syntax highlighting** for every language Notepad++ supports, with its same
  definitions and color themes; light and dark mode.
- Bookmarks, code folding, change history, brace and tag matching, smart
  highlight, **multi-cursor and column editing**, autocompletion, line
  operations, function list, **minimap**.
- **Find and replace** with regular expressions, plus **find in files** across a
  folder.
- **Encoding and line-ending detection** (UTF-8, Latin-1, CRLF…) preserved on
  save; tabs, file tree, session restore, reload of files changed on disk.
- Interface in English and Spanish.

![GNote++ code editor on macOS with file tree, tabs, syntax highlighting and minimap](docs/screenshots/editor.png)

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

## Support the project

GNote++ is free and built in spare time. If it saves you time, a
[donation via PayPal](https://www.paypal.com/donate/?hosted_button_id=Q2E7M3ZS53NF8)
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
[Donar con PayPal](https://www.paypal.com/donate/?hosted_button_id=Q2E7M3ZS53NF8)

---

## Descargar

**[GNote++.dmg — v1.3.0](releases/v1.3.0/GNote++.dmg)** (también en
[Releases](https://github.com/jcubillosz/gnote-plus-plus/releases/tag/v1.3.0)).
Firmado con Developer ID y notarizado por Apple — se abre sin advertencias de
Gatekeeper.

### Novedades en 1.3.0

- **Diagramas Mermaid** en la vista previa de Markdown (flujo, secuencia,
  clases, estados, Gantt, torta, mapas mentales y más), con un menú de
  plantillas para empezar. Se dibujan aparte, sin darle JavaScript a la vista
  previa, y se pueden guardar como PNG o SVG o copiar como imagen (también con
  clic derecho sobre el diagrama).
- **Markdown**: barra de formato propia sobre las pestañas; alertas de GitHub
  (`> [!NOTE]`, `[!WARNING]`…); casillas de tareas que se marcan con un clic en
  la vista previa; Enter continúa listas; formatear y alinear tablas (⌥⌘T);
  pegar o arrastrar imágenes (las de afuera se copian a `images/` junto al
  documento); esquema del documento en la barra lateral.
- **Funciones de Notepad++**: marcadores y plegado de código, historial de
  cambios en el margen, llaves y etiquetas pareadas, resaltado de la palabra
  seleccionada, multicursor y edición en columna, autocompletado en código,
  autocierre de paréntesis y comillas, operaciones de línea, comentar (⌘K),
  zoom y conversión de fin de línea.
- **Minimapa** del documento a la derecha del editor (⌃⌘M).
- **Buscar en archivos** de la carpeta abierta y lista de funciones del código
  en la barra lateral.
- Los archivos abiertos se recargan si otro programa los cambia; al guardar se
  avisa si el disco cambió.
- Árbol de archivos: mover archivos y carpetas arrastrando o con "Mover a…".
- Pestañas: flechas y menú para llegar a las que no entran en la ventana.
- **Impresión y PDF de Markdown**: ya no se repiten líneas entre páginas y se
  usa el tamaño de papel de la impresora (Archivo ▸ Ajustar página…).
- Corrige un cierre inesperado al abrir con ajuste de línea activo y el
  corrector encendido.

### Novedades en 1.2.0

- **Bloqueo de edición** por documento (candado en la toolbar, ⌘⇧L): fondo
  azul marino, solo lectura real, permite seleccionar y copiar. Útil para
  información sensible que no querés arriesgar a modificar por error.
- **Corrector ortográfico** en español e inglés (desactivado por defecto,
  Editar ▸ Ortografía): subrayado ondulado, sugerencias, aprender e ignorar
  palabras desde el menú contextual. En código solo revisa comentarios y
  strings.
- **Markdown**: tres modos de vista (editor / dividida / solo vista previa) y
  doble-click en el render para saltar a la línea del fuente. Bloques de
  código con etiqueta de lenguaje y coloreado de sintaxis en la vista previa
  y la impresión. Letra de impresión ~30% más chica.
- **Árbol de archivos**: crear archivos/carpetas y renombrar directamente
  ahí (incluida la extensión), con refresco automático al detectar cambios
  en disco.
- Arrastrar archivos y carpetas desde Finder para abrirlos; se restaura la
  sesión (pestañas, cursor, carpeta) al relanzar la app.
- El punto de "sin guardar" ya no aparece al abrir un archivo sin
  modificarlo, y cada pestaña recuerda su posición del cursor y su
  selección al volver a ella.

### Novedades en 1.1.0

- **Coloreado de sintaxis**: se corrige un bug que dejaba el editor sin
  colorear (texto plano negro) en cualquier build hecho con `swift build`
  fuera del `.app` empaquetado — afectaba a todos los lenguajes salvo
  Markdown.
- **Imprimir / exportar a PDF de Markdown**, reescrito: ahora usa el motor
  real de WebKit en vez de un importador limitado, así que tablas, títulos y
  bloques de código salen igual que en la vista previa. Paginación real
  (corta entre párrafos/filas, no a mitad de renglón) y margen de hoja de
  2cm.
- Blockquote (`> texto`) con estética de nota: borde y texto verde, fondo
  verde claro.

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
  GitHub Flavored Markdown (tablas, listas de tareas, tachado, autolinks),
  renderizada con [cmark-gfm](https://github.com/github/cmark-gfm).
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

**[Donar vía PayPal](https://www.paypal.com/donate/?hosted_button_id=Q2E7M3ZS53NF8)**
