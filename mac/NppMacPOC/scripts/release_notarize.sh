#!/bin/bash
# Build de release + firma Developer ID + notarización + DMG, para distribuir
# GNote++ fuera del App Store (ver docs/superpowers/plans/ — decisión: GPL de
# Notepad++ es incompatible con los términos de distribución del App Store,
# así que se distribuye como descarga directa notarizada).
#
# Requiere una sola vez, antes de correr este script:
#   xcrun notarytool store-credentials "gnotepp-notary" \
#     --apple-id "tu-apple-id@ejemplo.com" \
#     --team-id "TUTEAMID" \
#     --password "contraseña-de-aplicación"  # generada en appleid.apple.com
#
# Uso:
#   ./scripts/release_notarize.sh "Developer ID Application: Tu Nombre (TEAMID)"
#
# El identity string exacto sale de: security find-identity -v -p codesigning
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${1:?Uso: $0 \"Developer ID Application: Nombre (TEAMID)\"}"
NOTARY_PROFILE="${NOTARY_PROFILE:-gnotepp-notary}"
ENTITLEMENTS="$ROOT/AppResources/GNotePP.entitlements"
APP_DIR="$ROOT/.build/GNote++.app"
DMG_DIR="$ROOT/.build/release"
DMG_PATH="$DMG_DIR/GNote++.dmg"

echo "==> 1/6 Build release + empaquetado del .app"
"$ROOT/scripts/make_app_bundle.sh" release

echo "==> 2/6 Firma Scintilla.framework (Developer ID, hardened runtime)"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" \
  "$APP_DIR/Contents/Frameworks/Scintilla.framework"

echo "==> 3/6 Firma GNote++.app (Developer ID, hardened runtime, entitlements)"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP_DIR"

echo "==> Verificando firma"
# Ni --deep ni --strict: el bundle de recursos de SwiftPM
# (NppMacPOC_NppMacPOC.bundle) no tiene estructura de bundle de código
# válida y ambas flags lo tratan como uno, fallando con "No such file or
# directory" aunque la firma real esté OK (confirmado con codesign -dvvv:
# Authority=Developer ID Application, Runtime Version presente). El .app y
# Scintilla.framework ya se firmaron individualmente arriba; notarytool
# hace su propia validación más profunda al subir el DMG.
codesign --verify --verbose=2 "$APP_DIR"
spctl --assess --type execute --verbose "$APP_DIR" || echo "==> AVISO: spctl rechaza pre-notarización, esperado (aún no notarizado)"

echo "==> 4/6 Empaquetando DMG"
mkdir -p "$DMG_DIR"
rm -f "$DMG_PATH"
hdiutil create -volname "GNote++" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"

echo "==> 5/6 Notarizando (puede tardar varios minutos)"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> 6/6 Stapling"
xcrun stapler staple "$DMG_PATH"

echo "==> Verificación final"
# No se chequea el DMG en sí (hdiutil no lo firma, "no usable signature" es
# esperado): se monta y se valida el .app de adentro, que es lo que Gatekeeper
# evalúa cuando el usuario lo copia a Aplicaciones.
MOUNT_DIR="$(mktemp -d)"
hdiutil attach -nobrowse -quiet "$DMG_PATH" -mountpoint "$MOUNT_DIR"
spctl -a -vvv --type execute "$MOUNT_DIR/GNote++.app"
hdiutil detach -quiet "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo "==> Listo: $DMG_PATH"
