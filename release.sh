#!/bin/zsh
# Publie une version : compile, notarise (Apple), zippe puis crée la release GitHub.
# Usage : ./release.sh <version> [notes]   (ex. ./release.sh 0.2.0)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?Usage : ./release.sh <version> [notes]}"
TAG="v$VERSION"
DIST="$PWD/dist"
NOTES="${2:-kYNEDIT $VERSION}"
git diff --quiet && git diff --cached --quiet || { echo "Modifications non commitées : commiter avant la release." >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git ls-remote origin refs/heads/main | cut -f1)" ] || { echo "main n'est pas poussé sur origin." >&2; exit 1; }
! git rev-parse "$TAG" >/dev/null 2>&1 || { echo "La version $TAG existe déjà." >&2; exit 1; }

# Compilation hors du dossier d'installation (la copie installée garde sa signature locale)
STAGE="$(mktemp -d)"
DEST="$STAGE" ./build.sh "$VERSION"
rm -rf "$DIST"
DIST="$DIST" /Volumes/SKYRIM/TOOLS/MAC/_tools/notarize_app.sh "$STAGE/kYNEDIT.app"
ZIP="$DIST/kYNEDIT-$VERSION.zip"
mv "$DIST/kYNEDIT.zip" "$ZIP"
rm -rf "$STAGE"

git tag "$TAG" && git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" --title "kYNEDIT $VERSION" --notes "$NOTES"
