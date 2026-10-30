#!/usr/bin/env bash
# Construye Localis.app a partir del paquete Swift.
#   bash build_app.sh              -> app sin sandbox (para probar)
#   SANDBOX=1 bash build_app.sh    -> app con sandbox, sin red
#   bash build_app.sh install      -> además la copia a /Applications
#
# Private Cloud Compute exige el entitlement com.apple.developer.private-cloud-compute,
# que solo se acepta con un perfil de aprovisionamiento de tu cuenta de desarrollador:
#   PROFILE=ruta/Localis.provisionprofile bash build_app.sh
#   (opcional) SIGN_ID="Apple Development: …" si tienes más de una identidad.
# El identificador de la app se toma del perfil.
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
# Ícono de Icon Composer: actool genera Assets.car (macOS 26+) y AppIcon.icns.
# Info.plist ya declara CFBundleIconName y CFBundleIconFile = AppIcon.
echo "▸ Compilando ícono…"
xcrun actool Resources/AppIcon.icon --compile "${APP}/Contents/Resources" \
  --app-icon AppIcon --include-all-app-icons \
  --enable-on-demand-resources NO --development-region es \
  --target-device mac --platform macosx --minimum-deployment-target 26.0 \
  --output-partial-info-plist /dev/null \
  --output-format human-readable-text --errors >/dev/null

# Traducciones: el String Catalog se compila en es.lproj y en.lproj.
echo "▸ Compilando traducciones…"
xcrun xcstringstool compile Resources/Localizable.xcstrings \
  --output-directory "${APP}/Contents/Resources"

if [ -n "${PROFILE:-}" ]; then
  echo "▸ Firmando con perfil de aprovisionamiento (Private Cloud Compute)…"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  security cms -D -i "$PROFILE" > "$WORK/profile.plist"
  PB=/usr/libexec/PlistBuddy
  APP_ID="$($PB -c "Print :Entitlements:com.apple.application-identifier" "$WORK/profile.plist")"
  TEAM="$($PB -c "Print :TeamIdentifier:0" "$WORK/profile.plist")"
  if ! $PB -c "Print :Entitlements:com.apple.developer.private-cloud-compute" "$WORK/profile.plist" >/dev/null 2>&1; then
    echo "✘ El perfil no incluye com.apple.developer.private-cloud-compute." >&2
    exit 1
  fi

  # El identificador de la app debe coincidir con el del perfil.
  $PB -c "Set :CFBundleIdentifier ${APP_ID#"$TEAM".}" "${APP}/Contents/Info.plist"
  cp "$PROFILE" "${APP}/Contents/embedded.provisionprofile"

  ENT="$WORK/app.entitlements"
  if [ "${SANDBOX:-0}" = "1" ]; then
    cp Resources/Localis.entitlements "$ENT"
  else
    $PB -c "Clear dict" "$ENT" >/dev/null
  fi
  $PB -c "Add :com.apple.application-identifier string $APP_ID" \
      -c "Add :com.apple.developer.team-identifier string $TEAM" \
      -c "Add :com.apple.developer.private-cloud-compute bool true" "$ENT"

  IDENTITY="${SIGN_ID:-Apple Development}"
  codesign --force --sign "$IDENTITY" --entitlements "$ENT" "${APP}"
else
  echo "▸ Firmando (ad-hoc, sin Private Cloud Compute)…"
  if [ "${SANDBOX:-0}" = "1" ]; then
    codesign --force --sign - --entitlements Resources/Localis.entitlements "${APP}"
  else
    codesign --force --sign - "${APP}"
  fi
fi

if [ "${1:-}" = "install" ]; then
  echo "▸ Instalando en /Applications…"
  rm -rf "/Applications/${APP}"
  cp -R "${APP}" /Applications/
  echo "✔ Instalada: /Applications/${APP}"
else
  echo "✔ Lista: $(pwd)/${APP}"
fi
