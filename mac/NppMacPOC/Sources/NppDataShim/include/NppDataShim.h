#ifndef NPP_DATA_SHIM_H
#define NPP_DATA_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

// Todas las funciones parsean PowerEditor/src/langs.model.xml, stylers.model.xml y
// PowerEditor/installer/themes/DarkModeDefault.xml (código de datos real de Notepad++,
// sin traducir su lógica de C++, solo se leen como datos vía pugixml). Los strings
// devueltos son propiedad del caller: liberar con npp_free_string.

// Busca <Language ext="..."> que contenga `ext` (sin el punto). Si lo encuentra,
// devuelve un string con formato:
//   "<languageName>\x1F<idx>:<keywords>\x1F<idx>:<keywords>\x1F..."
// (registros separados por 0x1F, campos vacíos posibles). NULL si no hay match.
char* npp_lookup_language(const char* langsXmlPath, const char* ext);

// Igual que npp_lookup_language pero busca por <Language name="..."> exacto en vez de por
// extensión. Necesario para casos donde Notepad++ guarda la extensión default fuera de este
// XML (p.ej. "javascript" tiene ext="" acá; su ".js" default vive en una tabla C++ aparte
// en ScintillaEditView.cpp, _langNameInfoArray). NULL si no hay match.
char* npp_lookup_language_by_name(const char* langsXmlPath, const char* langName);

// Busca <LexerType name="langName"> en un XML de tema (stylers.model.xml o
// DarkModeDefault.xml, mismo esquema). Devuelve un string con formato
// "<styleID>,<fgHexRRGGBB>,<bgHexRRGGBB>,<fontStyle>;...", uno por <WordsStyle>.
// bgHex puede ser cadena vacía si el atributo no está presente, pero el campo
// siempre está — 4 partes separadas por coma. fontStyle es una máscara de bits
// (1=negrita, 2=cursiva, 4=subrayado, combinables) o -1 si el atributo
// "fontStyle" no está presente en el XML (STYLE_NOT_USED del original, ver
// Parameters.cpp:5086 — "no administrado", distinto de 0 "sin adornos").
// NULL si no hay match.
char* npp_lookup_styles(const char* themeXmlPath, const char* langName);

// Busca <GlobalStyles><WidgetStyle name="..."> en un XML de tema. Devuelve
// "<fgHexRRGGBB>,<bgHexRRGGBB>" (cualquiera puede ser cadena vacía). NULL si no hay match.
char* npp_lookup_global_style(const char* themeXmlPath, const char* widgetName);

// Devuelve "<name1>;<name2>;..." con todos los <Language name="..."> de langs.model.xml.
// NULL si el XML no carga.
char* npp_list_language_names(const char* langsXmlPath);

void npp_free_string(char* s);

#ifdef __cplusplus
}
#endif

#endif
