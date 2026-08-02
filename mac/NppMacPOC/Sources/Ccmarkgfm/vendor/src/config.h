/* Generado normalmente por CMake desde src/config.h.in. Escrito a mano porque
   acá cmark-gfm se compila con SwiftPM. Los tres HAVE_* que CMake detecta por
   feature-test están fijos en 1: el paquete es macOS-only (.macOS(.v13)) y
   clang los provee todos. Se omite el bloque de fallback de snprintf para MSVC
   anterior a 2015 que trae el upstream — inalcanzable en este target. */

#ifndef CMARK_CONFIG_H
#define CMARK_CONFIG_H

#ifdef __cplusplus
extern "C" {
#endif

#define HAVE_STDBOOL_H

#ifdef HAVE_STDBOOL_H
  #include <stdbool.h>
#elif !defined(__cplusplus)
  typedef char bool;
#endif

#define HAVE___BUILTIN_EXPECT

#define HAVE___ATTRIBUTE__

#ifdef HAVE___ATTRIBUTE__
  #define CMARK_ATTRIBUTE(list) __attribute__ (list)
#else
  #define CMARK_ATTRIBUTE(list)
#endif

#ifndef CMARK_INLINE
  #define CMARK_INLINE inline
#endif

#ifdef __cplusplus
}
#endif

#endif
