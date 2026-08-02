#include "NppDataShim.h"
#include "pugixml.hpp"

#include <cstring>
#include <cstdlib>
#include <string>
#include <sstream>
#include <vector>
#include <map>

namespace {

// Orden real de Notepad++ (LANG_INDEX_* en PowerEditor/src/MISC/Common/NppConstants.h),
// usado tal cual por ScintillaEditView::setLexer para decidir con qué índice de
// SCI_SETKEYWORDS se manda cada lista. No se traduce lógica de Notepad++, solo se
// reutiliza esta tabla de nombres->índice (dato, no código GPL).
const std::map<std::string, int>& langIndexByTagName() {
    static const std::map<std::string, int> table = {
        {"instre1", 0}, {"instre2", 1},
        {"type1", 2}, {"type2", 3}, {"type3", 4}, {"type4", 5},
        {"type5", 6}, {"type6", 7}, {"type7", 8},
    };
    return table;
}

char* dupString(const std::string& s) {
    char* out = static_cast<char*>(std::malloc(s.size() + 1));
    if (out) {
        std::memcpy(out, s.c_str(), s.size() + 1);
    }
    return out;
}

} // namespace

namespace {

char* buildKeywordsResult(pugi::xml_node lang) {
    std::string name = lang.attribute("name").as_string();
    std::string result = name;

    for (pugi::xml_node kw : lang.children("Keywords")) {
        std::string tagName = kw.attribute("name").as_string();
        auto it = langIndexByTagName().find(tagName);
        if (it == langIndexByTagName().end()) continue; // ignora substyleN, no soportado aún
        std::string text = kw.text().as_string();
        if (text.empty()) continue;
        result += '\x1F';
        result += std::to_string(it->second);
        result += ':';
        result += text;
    }
    return dupString(result);
}

} // namespace

char* npp_lookup_language(const char* langsXmlPath, const char* extRaw) {
    if (!langsXmlPath || !extRaw) return nullptr;
    std::string ext = extRaw;

    pugi::xml_document doc;
    if (!doc.load_file(langsXmlPath)) return nullptr;

    for (pugi::xml_node lang : doc.child("NotepadPlus").child("Languages").children("Language")) {
        std::string extsAttr = lang.attribute("ext").as_string();
        std::istringstream iss(extsAttr);
        std::string token;
        bool matched = false;
        while (iss >> token) {
            if (token == ext) { matched = true; break; }
        }
        if (!matched) continue;
        return buildKeywordsResult(lang);
    }
    return nullptr;
}

char* npp_lookup_language_by_name(const char* langsXmlPath, const char* langNameRaw) {
    if (!langsXmlPath || !langNameRaw) return nullptr;
    std::string langName = langNameRaw;

    pugi::xml_document doc;
    if (!doc.load_file(langsXmlPath)) return nullptr;

    for (pugi::xml_node lang : doc.child("NotepadPlus").child("Languages").children("Language")) {
        if (langName != lang.attribute("name").as_string()) continue;
        return buildKeywordsResult(lang);
    }
    return nullptr;
}

char* npp_lookup_styles(const char* themeXmlPath, const char* langNameRaw) {
    if (!themeXmlPath || !langNameRaw) return nullptr;
    std::string langName = langNameRaw;

    pugi::xml_document doc;
    if (!doc.load_file(themeXmlPath)) return nullptr;

    for (pugi::xml_node lexer : doc.child("NotepadPlus").child("LexerStyles").children("LexerType")) {
        if (langName != lexer.attribute("name").as_string()) continue;

        std::string result;
        bool first = true;
        for (pugi::xml_node word : lexer.children("WordsStyle")) {
            int styleID = word.attribute("styleID").as_int(-1);
            std::string fg = word.attribute("fgColor").as_string();
            std::string bg = word.attribute("bgColor").as_string();
            // -1 reproduce STYLE_NOT_USED del original (Parameters.cpp:5086): atributo
            // ausente = "no administrado", distinto de 0 = "sin adornos".
            int fontStyle = word.attribute("fontStyle").as_int(-1);
            if (styleID < 0 || fg.empty()) continue;
            if (!first) result += ';';
            first = false;
            result += std::to_string(styleID);
            result += ',';
            result += fg;
            result += ',';
            result += bg;
            result += ',';
            result += std::to_string(fontStyle);
        }
        return dupString(result);
    }
    return nullptr;
}

char* npp_lookup_global_style(const char* themeXmlPath, const char* widgetNameRaw) {
    if (!themeXmlPath || !widgetNameRaw) return nullptr;
    std::string widgetName = widgetNameRaw;

    pugi::xml_document doc;
    if (!doc.load_file(themeXmlPath)) return nullptr;

    for (pugi::xml_node widget : doc.child("NotepadPlus").child("GlobalStyles").children("WidgetStyle")) {
        if (widgetName != widget.attribute("name").as_string()) continue;
        std::string fg = widget.attribute("fgColor").as_string();
        std::string bg = widget.attribute("bgColor").as_string();
        return dupString(fg + "," + bg);
    }
    return nullptr;
}

char* npp_list_language_names(const char* langsXmlPath) {
    if (!langsXmlPath) return nullptr;

    pugi::xml_document doc;
    if (!doc.load_file(langsXmlPath)) return nullptr;

    std::string result;
    bool first = true;
    for (pugi::xml_node lang : doc.child("NotepadPlus").child("Languages").children("Language")) {
        std::string name = lang.attribute("name").as_string();
        if (name.empty()) continue;
        if (!first) result += ';';
        first = false;
        result += name;
    }
    return dupString(result);
}

void npp_free_string(char* s) {
    std::free(s);
}
