/**
 * Override de build para NppMacPOC (no vendorizado, no toca PowerEditor/src/pugixml/).
 * Idéntico a pugiconfig.hpp original salvo PUGIXML_CHARCONV_FLOAT deshabilitado:
 * std::to_chars/from_chars(float/double) de libc++ requieren macOS 26 SDK-wise
 * aunque el deployment target sea menor, lo que rompe el build. pugixml cae
 * automáticamente a strtod/snprintf si el macro no está definido.
 */
#ifndef HEADER_PUGICONFIG_HPP
#define HEADER_PUGICONFIG_HPP

// #define PUGIXML_CHARCONV_FLOAT
// #define PUGIXML_COMPACT
#define PUGIXML_NO_XPATH
// #define PUGIXML_NO_STL
// #define PUGIXML_NO_EXCEPTIONS
#define PUGIXML_HEADER_ONLY
// #define PUGIXML_HAS_LONG_LONG
// #define PUGIXML_HAS_STRING_VIEW

#endif
