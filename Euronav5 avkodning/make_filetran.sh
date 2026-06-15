#!/bin/bash
#
# make_filetran.sh — build a FileTran.tgz exactly like the Euronav5 reference.
#
# Usage:
#   ./make_filetran.sh <root-folder>
#
#   <root-folder> must contain a "db" subfolder. The resulting FileTran.tgz
#   is written into that same <root-folder> (e.g. the PCMCIA/PAS card root).
#
# What it guarantees (byte-format identical to the reference FileTran.tgz):
#   - GNU tar format            (magic "ustar  \0")
#   - top-level "db/" entry, owner root / group 0
#   - dirs 0775, files 0664
#   - gzip with NO embedded filename (flags 0x00) and level -9 (XFL 02)
#   - macOS junk (.DS_Store, ._*) stripped
#
# It does NOT fake timestamps — the gzip + member mtimes come from the files,
# so two runs differ only in time/size, never in format.

set -euo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
    echo "usage: $0 <root-folder>   (folder that contains 'db'; tgz goes here)" >&2
    exit 1
fi

# Resolve to an absolute path and validate.
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || { echo "error: '$1' not found" >&2; exit 1; }
SRC="$ROOT/db"
[ -d "$SRC" ] || { echo "error: no 'db' folder in $ROOT" >&2; exit 1; }

OUT="$ROOT/FileTran.tgz"

# Stage a clean copy on a real filesystem so FAT-card perms and macOS junk
# don't leak into the archive.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/filetran.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$SRC" "$STAGE/db"

# Strip macOS junk.
find "$STAGE/db" \( -name '.DS_Store' -o -name '._*' \) -exec rm -rf {} + 2>/dev/null || true

# Normalize permissions to match the reference (dirs 0775, files 0664).
find "$STAGE/db" -type d -exec chmod 775 {} +
find "$STAGE/db" -type f -exec chmod 664 {} +

# Build: GNU tar format, root/0 ownership, piped through gzip -9.
# The pipe (not "tar -czf") is what makes gzip omit the filename (flags 0x00)
# and the explicit -9 sets XFL 02 — both required to match the reference.
tar -C "$STAGE" --format=gnutar --uid 0 --gid 0 --uname root --gname 0 -cf - db \
    | gzip -9 -c > "$OUT"

sync

echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
tar tzvf "$OUT"
