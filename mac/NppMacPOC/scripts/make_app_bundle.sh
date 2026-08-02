#!/bin/bash
# Empaqueta el ejecutable SPM NppMacPOC como GNote++.app.
#
# El binario se sigue llamando NppMacPOC porque ese es el nombre del target del
# paquete; solo cambia la identidad visible del bundle (ver AppResources/Info.plist).
# No usa Xcode project — reusa el build de `swift build` y arma la estructura de bundle
# a mano (patrón común para apps AppKit basadas en Swift Package Manager).
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/$CONFIG"
APP_DIR="$ROOT/.build/GNote++.app"

echo "==> swift build -c $CONFIG"
(cd "$ROOT" && swift build -c "$CONFIG")

echo "==> Armando $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp "$BUILD_DIR/NppMacPOC" "$APP_DIR/Contents/MacOS/NppMacPOC"
cp "$ROOT/AppResources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Ícono: se copia solo si existe, para que el script siga sirviendo en un árbol
# donde todavía no se corrió scripts/make_icon.swift.
if [ -f "$ROOT/AppResources/GNotePP.icns" ]; then
  cp "$ROOT/AppResources/GNotePP.icns" "$APP_DIR/Contents/Resources/"
else
  echo "==> AVISO: falta AppResources/GNotePP.icns, el .app queda con el ícono genérico"
fi

# Recurso de datos (langs.model.xml/stylers.model.xml) generado por SPM
cp -R "$BUILD_DIR/NppMacPOC_NppMacPOC.bundle" "$APP_DIR/Contents/Resources/"

# Scintilla.framework vendorizado
cp -R "$ROOT/Frameworks/Scintilla.framework" "$APP_DIR/Contents/Frameworks/"

# El binario se linkeó con rpath relativo al layout de .build/ (dev); agregamos también
# el rpath real dentro del .app (Contents/MacOS/NppMacPOC -> ../Frameworks).
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/NppMacPOC" 2>/dev/null || true

echo "==> Firma ad-hoc (necesaria en arm64 para poder ejecutar)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Listo: $APP_DIR"
echo "    Abrir con: open \"$APP_DIR\""
