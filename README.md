# GNote++

Editor de texto nativo para macOS, basado en el código fuente de
[Notepad++](https://notepad-plus-plus.org/).

No es un port de la interfaz Win32 ni una capa de compatibilidad: la UI está
escrita de cero en SwiftUI y usa [Scintilla](https://www.scintilla.org/) como
componente de edición. Lo que se reutiliza de Notepad++ es su lógica de datos —
la detección de codificación (uchardet) y las definiciones de lenguajes y temas
(`langs.model.xml`, `stylers.model.xml`).

---

## Descargar

**[GNote++.dmg — v1.2.0](releases/v1.2.0/GNote++.dmg)** (también en
[Releases](https://github.com/jcubillosz/gnote-plus-plus/releases/tag/v1.2.0)).
Firmado con Developer ID y notarizado por Apple — se abre sin advertencias de
Gatekeeper.

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

GNote++ no está afiliado a Notepad++ ni cuenta con su respaldo, y no usa su
nombre, su ícono ni su imagen de marca.

## Licencia

GPL-3.0, heredada de Notepad++. Ver [LICENSE](LICENSE).

Eso incluye tu derecho a obtener, estudiar, modificar y redistribuir este
código fuente.

## Apoyar el proyecto

Si GNote++ te resulta útil, puedes contribuir a su desarrollo:

**[Donar vía PayPal](https://www.paypal.com/donate/?hosted_button_id=Q2E7M3ZS53NF8)**
