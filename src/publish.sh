#!/bin/bash
# Crea il tag di versione e lo pusha: GitHub Actions compila l'app e pubblica il DMG nella Release.
# Uso: src/publish.sh vX.Y.Z
set -e
cd "$(dirname "$0")/.."
VER="${1:?uso: src/publish.sh vX.Y.Z}"
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "versione non valida: $VER (atteso vX.Y.Z)"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree non pulito: committa prima"; exit 1; }
git push origin main
git tag -a "$VER" -m "Estrai Allegati $VER"
git push origin "$VER"
echo "Tag $VER pushato. Release: https://github.com/LucaTomei/estrai-allegati/releases/tag/$VER (pronta in ~5 min)"
echo "Stato build: https://github.com/LucaTomei/estrai-allegati/actions"
