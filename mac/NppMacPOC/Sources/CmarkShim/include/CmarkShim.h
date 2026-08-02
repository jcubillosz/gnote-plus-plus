#ifndef CMARK_SHIM_H
#define CMARK_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Renderiza Markdown (GitHub Flavored) a un fragmento HTML.
///
/// Devuelve un buffer nuevo terminado en NUL que el llamador debe liberar con
/// `cmark_shim_free`, o NULL si falla. `markdown` debe ser UTF-8; `len` es su
/// largo en bytes, sin contar el NUL.
///
/// `with_sourcepos` != 0 agrega atributos `data-sourcepos="linea:col-linea:col"`
/// a cada elemento. Sirve para mapear preview→editor (scroll sync); ensucia la
/// salida, así que el export a HTML/PDF debe pasar 0.
char *cmark_shim_render_html(const char *markdown, size_t len, int with_sourcepos);

/// Libera un buffer devuelto por `cmark_shim_render_html`.
void cmark_shim_free(char *html);

#ifdef __cplusplus
}
#endif

#endif /* CMARK_SHIM_H */
