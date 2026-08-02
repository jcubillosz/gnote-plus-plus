#ifndef LEXILLA_SHIM_H
#define LEXILLA_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Devuelve un puntero opaco a Scintilla::ILexer5 (o 0 si el nombre no existe).
uintptr_t Lexilla_CreateLexer(const char *name);

#ifdef __cplusplus
}
#endif

#endif
