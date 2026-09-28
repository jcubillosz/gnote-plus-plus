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
# --build-system native fuerza el layout clásico de SPM (.build/<triple>/<config>/),
# que es el que este script lee más abajo (BUILD_DIR). Con el toolchain Swift 6.4+,
# `swift build` sin flags usa el backend "swiftbuild" por defecto, que compila a
# .build/out/Products/<Config>/ en su lugar — mismo binario, otra carpeta. Sin este
# flag, este script podía copiar un binario de una corrida vieja que haya quedado en
# BUILD_DIR (de una sesión anterior con --build-system native) en vez del recién
# compilado, empaquetando una versión desactualizada de la app sin ningún error.
(cd "$ROOT" && swift build -c "$CONFIG" --build-system native)

echo "==> Armando $APP_DIR"
rm -rf "$APP_DIR"

# Bundles de nombres anteriores: si quedan, es facilísimo abrir el equivocado y
# ver una versión vieja sin entender por qué (pasó con NppMacPOC.app tras el
# rebrand: mostraba 0.1.0 y sin ventana About).
for stale in "$ROOT"/.build/*.app; do
  [ -e "$stale" ] || continue
  if [ "$stale" != "$APP_DIR" ]; then
    echo "==> Eliminando bundle obsoleto: $(basename "$stale")"
    rm -rf "$stale"
  fi
done
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

# Recurso de datos (langs.model.xml/stylers.model.xml) generado por SPM.
cp -R "$BUILD_DIR/NppMacPOC_NppMacPOC.bundle" "$APP_DIR/Contents/Resources/"

# langs.model.xml/stylers.model.xml/DarkModeDefault.xml llegan a este bundle
# como symlinks a PowerEditor/ (fuente vendorizada) — y están rotos (apuntan
# a mac/PowerEditor/..., un nivel de más; el real es <repo>/PowerEditor/...).
# Un symlink roto/que escapa del .app es además "invalid destination for
# symbolic link in bundle" para Gatekeeper/notarización (rechazo real
# encontrado al notarizar). Se sobreescriben acá con el contenido real.
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
RES_BUNDLE="$APP_DIR/Contents/Resources/NppMacPOC_NppMacPOC.bundle"
# rm primero: son symlinks (rotos), "cp -f" sobre un symlink escribe a través
# de él en vez de reemplazarlo.
rm -f "$RES_BUNDLE/langs.model.xml" "$RES_BUNDLE/stylers.model.xml" "$RES_BUNDLE/DarkModeDefault.xml"
cp "$REPO_ROOT/PowerEditor/src/langs.model.xml" "$RES_BUNDLE/langs.model.xml"
cp "$REPO_ROOT/PowerEditor/src/stylers.model.xml" "$RES_BUNDLE/stylers.model.xml"
cp "$REPO_ROOT/PowerEditor/installer/themes/DarkModeDefault.xml" "$RES_BUNDLE/DarkModeDefault.xml"

# Scintilla.framework vendorizado
cp -R "$ROOT/Frameworks/Scintilla.framework" "$APP_DIR/Contents/Frameworks/"

# El binario se linkeó con rpath relativo al layout de .build/ (dev); agregamos también
# el rpath real dentro del .app (Contents/MacOS/NppMacPOC -> ../Frameworks).
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/NppMacPOC" 2>/dev/null || true

echo "==> Firma ad-hoc (necesaria en arm64 para poder ejecutar)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Listo: $APP_DIR"
echo "    Abrir con: open \"$APP_DIR\""
