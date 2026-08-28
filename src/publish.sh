#!/bin/bash
# Pubblica una versione: tag + push. GitHub Actions compila l'app e carica il DMG nella Release.
# Se `gh` è autenticato, la Release viene creata subito a nome dell'utente (la CI poi aggiorna l'asset).
# Uso: src/publish.sh vX.Y.Z
set -e
cd "$(dirname "$0")/.."
VER="${1:?uso: src/publish.sh vX.Y.Z}"
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "versione non valida: $VER (atteso vX.Y.Z)"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree non pulito: committa prima"; exit 1; }
git push origin main
git tag -a "$VER" -m "Estrai Allegati $VER"
git push origin "$VER"
if gh auth status >/dev/null 2>&1; then
  src/build_app.sh
  gh release create "$VER" "Estrai-Allegati.dmg" --title "Estrai Allegati $VER" \
    --notes $'App universale (Apple Silicon + Intel), non notarizzata: al primo avvio tasto destro → **Apri**.\n\nScarica `Estrai-Allegati.dmg` e trascina l\'app in Applicazioni.'
fi
echo "Release: https://github.com/LucaTomei/estrai-allegati/releases/tag/$VER"
echo "Build:   https://github.com/LucaTomei/estrai-allegati/actions"
