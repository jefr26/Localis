#!/usr/bin/env bash
# Construye Localis.app a partir del paquete Swift.
#   bash build_app.sh              -> app sin sandbox (para probar)
#   SANDBOX=1 bash build_app.sh    -> app con sandbox, sin red
#   bash build_app.sh install      -> además la copia a /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="Localis.app"

echo "▸ Compilando (release)…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Localis"

echo "▸ Armando ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/Localis"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
# Cuando tengas un ícono, ponlo en Resources/AppIcon.icns y añade
# CFBundleIconFile = AppIcon al Info.plist.
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "${APP}/Contents/Resources/"

echo "▸ Firmando (ad-hoc)…"
if [ "${SANDBOX:-0}" = "1" ]; then
  codesign --force --sign - --entitlements Resources/Localis.entitlements "${APP}"
else
  codesign --force --sign - "${APP}"
fi

if [ "${1:-}" = "install" ]; then
  echo "▸ Instalando en /Applications…"
  rm -rf "/Applications/${APP}"
  cp -R "${APP}" /Applications/
  echo "✔ Instalada: /Applications/${APP}"
else
  echo "✔ Lista: $(pwd)/${APP}"
fi
