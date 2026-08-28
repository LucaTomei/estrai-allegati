#!/bin/bash
# Pusha main e pubblica il DMG come GitHub Release.
# Uso: src/publish.sh v1.0.0
set -e
cd "$(dirname "$0")/.."
VER="${1:?uso: src/publish.sh vX.Y.Z}"
git push -u origin main
[ -f "Estrai Allegati.dmg" ] || src/build_app.sh
git tag -f "$VER" && git push -f origin "$VER"
if gh release view "$VER" >/dev/null 2>&1; then
  gh release upload "$VER" "Estrai Allegati.dmg" --clobber
else
  gh release create "$VER" "Estrai Allegati.dmg" --title "Estrai Allegati $VER" \
    --notes "App universale (Apple Silicon + Intel), non notarizzata: al primo avvio tasto destro → Apri."
fi
