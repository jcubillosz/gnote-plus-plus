// Stub para el símbolo lmUserDefine que normalmente aporta lexilla/lexers/LexUser.cxx.
// Ese archivo depende de <windows.h> (Win32) y no se compila en este POC de macOS;
// este stub solo evita el link error del catálogo de Lexilla.cxx. UDL (user-defined
// languages) queda sin implementar hasta portar LexUser.cxx de verdad.
#include <cstddef>
#include <cstdint>
#include "Sci_Position.h"
#include "ILexer.h"
#include "LexerModule.h"

using namespace Lexilla;

namespace {

void NoOpLexer(Sci_PositionU, Sci_Position, int, WordList *[], Accessor &) {
}

}

extern const LexerModule lmUserDefine(152 /* SCLEX_USER */, NoOpLexer, "user");
