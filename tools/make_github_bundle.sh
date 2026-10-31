#!/usr/bin/env bash
# Build the GitHub hand-off bundle from a clean commit.
#
#   bash tools/make_github_bundle.sh
#
# Produces out/github-upload/ with
#   kindlearnki/                     a fresh single-commit repo (git archive of HEAD)
#   release/kindlearnki-koplugin-<v>.tgz / .zip   installable plugin archives
#   release/RELEASE_NOTES.md         body for the GitHub release
#   CHECKSUMS.txt
# and out/kindlearnki-github-upload.zip, which is the file to hand over.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

version=$(sed -n 's/.*VERSION = "\([^"]*\)".*/\1/p' kindlearnki.koplugin/core/version.lua | head -1)
[ -n "$version" ] || { echo "cannot read the plugin version" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
    echo "working tree is dirty; commit first (the bundle is built from HEAD)" >&2
    exit 1
fi

bundle=out/github-upload
src=out/release-src
rm -rf "$bundle"
mkdir -p "$bundle/release" "$bundle/kindlearnki"
[ -f "$src/RELEASE_NOTES.md" ] || { echo "missing $src/RELEASE_NOTES.md" >&2; exit 1; }
[ -f "$src/上传说明.md" ]      || { echo "missing $src/上传说明.md" >&2; exit 1; }
cp "$src/RELEASE_NOTES.md" "$bundle/release/RELEASE_NOTES.md"
cp "$src/上传说明.md" "$bundle/上传说明.md"

echo "== repo export (HEAD $(git rev-parse --short HEAD))"
git archive --format=tar HEAD | tar -x -C "$bundle/kindlearnki"

(cd "$bundle/kindlearnki"
    git init -q -b main
    git add -A
    git -c user.name="DrSkyeagle" \
        -c user.email="24759695+DrSkyeagle@users.noreply.github.com" \
        commit -q -m "kindlearnki ${version} — 在越狱 Kindle（KOReader）上复习 Anki 并与 AnkiWeb 双向同步"
    echo "   files: $(git ls-files | wc -l), commit: $(git rev-parse --short HEAD)"
)

echo "== plugin archives"
tar -czf "$bundle/release/kindlearnki-koplugin-${version}.tgz" \
    --exclude='kindlearnki.koplugin/tests' \
    --exclude='kindlearnki.koplugin/doc' \
    -C . kindlearnki.koplugin
python tools/pack_plugin.py >/dev/null
cp "out/kindlearnki.koplugin-${version}.zip" \
   "$bundle/release/kindlearnki-koplugin-${version}.zip"

echo "== checksums"
(
    cd "$bundle/release"
    sha256sum "kindlearnki-koplugin-${version}.tgz" \
              "kindlearnki-koplugin-${version}.zip" > ../CHECKSUMS.txt
)
cat "$bundle/CHECKSUMS.txt"

echo "== verifying the archives"
tmp=$(mktemp -d)
tar -xzf "$bundle/release/kindlearnki-koplugin-${version}.tgz" -C "$tmp"
test -f "$tmp/kindlearnki.koplugin/main.lua" || { echo "tgz is missing main.lua" >&2; exit 1; }
test -f "$tmp/kindlearnki.koplugin/_meta.lua" || { echo "tgz is missing _meta.lua" >&2; exit 1; }
test ! -d "$tmp/kindlearnki.koplugin/tests" || { echo "tgz must not ship tests/" >&2; exit 1; }
python - "$bundle/release/kindlearnki-koplugin-${version}.zip" <<'PY'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
assert "kindlearnki.koplugin/main.lua" in names, "zip is missing main.lua"
assert not any(n.startswith("kindlearnki.koplugin/tests/") for n in names), "zip ships tests/"
print(f"   zip entries: {len(names)}")
PY
rm -rf "$tmp"

echo "== hand-off archive"
python - "$bundle" "out/kindlearnki-github-upload.zip" <<'PY'
import os, sys, zipfile
bundle, target = sys.argv[1], sys.argv[2]
if os.path.exists(target):
    os.remove(target)
count = 0
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
    for base, _dirs, files in os.walk(bundle):
        for name in files:
            path = os.path.join(base, name)
            archive.write(path, os.path.relpath(path, os.path.dirname(bundle)))
            count += 1
print(f"   {count} entries")
PY

echo
echo "done:"
echo "  $bundle/kindlearnki/                     (push this)"
echo "  $bundle/release/kindlearnki-koplugin-${version}.{tgz,zip}"
echo "  out/kindlearnki-github-upload.zip        (hand this to the uploader)"
