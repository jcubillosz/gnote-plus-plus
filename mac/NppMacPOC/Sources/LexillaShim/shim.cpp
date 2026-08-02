#include "LexillaShim.h"
#include "ILexer.h"
#include "Lexilla.h"

uintptr_t Lexilla_CreateLexer(const char *name) {
    Scintilla::ILexer5 *lexer = CreateLexer(name);
    return reinterpret_cast<uintptr_t>(lexer);
}
