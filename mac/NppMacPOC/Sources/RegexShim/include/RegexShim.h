#ifndef NPP_REGEX_SHIM_H
#define NPP_REGEX_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

// Motor de expresiones regulares de Notepad++ (Boost.Regex, sintaxis Perl) para las reglas de
// functionList/*.xml, que usan \K, \h, (?m-s:...) y clases POSIX: NSRegularExpression (ICU)
// no soporta \K. Mismas opciones que functionParser.cpp: el punto incluye saltos de línea.
//
// El texto son los bytes UTF-8 del documento (mismas posiciones que Scintilla).

// Compila `pattern`. NULL si no es válido; en ese caso, si `errorOut` no es NULL, recibe un
// mensaje que el caller libera con npp_regex_free_string.
void* npp_regex_compile(const char* pattern, char** errorOut);

// Busca en text[start, end). Devuelve 1 y la coincidencia en [*outStart, *outEnd) (posiciones
// absolutas en `text`), 0 si no hay, -1 si el motor falla (p.ej. complejidad excesiva).
int npp_regex_search(void* regex, const char* text, long textLength, long start, long end, long* outStart, long* outEnd);

void npp_regex_free(void* regex);
void npp_regex_free_string(char* s);

#ifdef __cplusplus
}
#endif

#endif
