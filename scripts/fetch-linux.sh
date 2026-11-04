#!/usr/bin/env bash
# Fetches a prebuilt RV32IMA Linux kernel and busybox initramfs from semu's
# rolling release (github.com/sysprog21/semu), checked against the release's
# SHA-1 manifest, into build/linux/.
set -euo pipefail
cd "$(dirname "$0")/.."
URL=${PREBUILT_URL:-https://github.com/sysprog21/semu/releases/download/prebuilt}
OUT=build/linux
mkdir -p "$OUT"
curl -fsSL -o "$OUT/prebuilt.sha1" "$URL/prebuilt.sha1"
for f in Image rootfs.cpio; do
  [ -f "$OUT/$f" ] && continue
  curl -fsSL -o "$OUT/$f.bz2" "$URL/$f.bz2"
  want=$(awk -v f="$f.bz2" '$2 == f {print $1}' "$OUT/prebuilt.sha1")
  got=$(sha1sum "$OUT/$f.bz2" | awk '{print $1}')
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "checksum mismatch for $f.bz2 (want '$want', got '$got')" >&2
    exit 1
  fi
  bunzip2 -f "$OUT/$f.bz2"
done
ls -l "$OUT/Image" "$OUT/rootfs.cpio"
