#include "CmarkShim.h"

#include <cmark-gfm.h>
#include <cmark-gfm-core-extensions.h>
#include <cmark-gfm-extension_api.h>

#include <stdlib.h>

// Las cinco extensiones que definen "GitHub Flavored Markdown". `tagfilter`
// además cumple un rol de seguridad: neutraliza script/iframe/style/textarea y
// compañía dentro del HTML crudo que el Markdown puede traer.
static const char *const kGfmExtensions[] = {
    "table", "strikethrough", "autolink", "tasklist", "tagfilter"
};

static const size_t kGfmExtensionCount =
    sizeof(kGfmExtensions) / sizeof(kGfmExtensions[0]);

char *cmark_shim_render_html(const char *markdown, size_t len, int with_sourcepos) {
    if (markdown == NULL) {
        return NULL;
    }

    // Idempotente: cmark-gfm se protege internamente de registros repetidos.
    cmark_gfm_core_extensions_ensure_registered();

    // CMARK_OPT_UNSAFE deja pasar el HTML crudo del documento — es lo que hace
    // GitHub y sin esto se pierden <details>, <br> y tablas HTML, rompiendo la
    // compatibilidad que es el objetivo. El riesgo lo cubren tres capas
    // encimadas: la extensión `tagfilter` acá, y del lado de la vista
    // JavaScript deshabilitado más un <meta> CSP restrictivo.
    int options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES;
    if (with_sourcepos) {
        options |= CMARK_OPT_SOURCEPOS;
    }

    cmark_parser *parser = cmark_parser_new(options);
    if (parser == NULL) {
        return NULL;
    }

    for (size_t i = 0; i < kGfmExtensionCount; i++) {
        cmark_syntax_extension *ext = cmark_find_syntax_extension(kGfmExtensions[i]);
        if (ext != NULL) {
            cmark_parser_attach_syntax_extension(parser, ext);
        }
    }

    cmark_parser_feed(parser, markdown, len);
    cmark_node *doc = cmark_parser_finish(parser);
    if (doc == NULL) {
        cmark_parser_free(parser);
        return NULL;
    }

    // La lista de extensiones pertenece al parser, así que hay que renderizar
    // antes de liberarlo. Sin pasarla, las tablas salen como texto plano.
    char *html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser));

    cmark_node_free(doc);
    cmark_parser_free(parser);
    return html;
}

void cmark_shim_free(char *html) {
    // cmark usa el allocator por defecto (malloc/free) en todas las rutas que
    // toca este shim, así que free() es la contraparte correcta.
    free(html);
}
