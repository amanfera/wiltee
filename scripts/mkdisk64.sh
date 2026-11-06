#!/usr/bin/env bash
# Creates build/disk64.img: a 16 MiB ext2 image for the guest's virtio-blk disk (no root
# needed, host mke2fs -d). Contents:
#   /hello.txt    one known line
#   /data.bin     ~300 KiB of deterministic text (needs indirect blocks, many virtio requests)
#   /data.sha256  `sha256sum` of data.bin, so the guest can verify what it read
# Fixed UUID, hash seed and root ownership; mke2fs still stamps creation times.
# Usage: scripts/mkdisk64.sh [output-image]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/disk64.img}
MIB=${DISK64_MIB:-16}
HELLO="hello from wiltee virtio-blk"
UUID=77696c74-6565-4000-8000-000000000064

command -v mke2fs >/dev/null || { echo "mke2fs not found (apt-get install e2fsprogs)" >&2; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "$HELLO" > "$STAGE/hello.txt"
awk 'BEGIN { for (i = 0; i < 34134; i++) printf "%08x\n", (i * 2654435761) % 4294967296 }' > "$STAGE/data.bin"
( cd "$STAGE" && sha256sum data.bin > data.sha256 )
find "$STAGE" -exec touch -h -d @0 {} +

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
truncate -s "${MIB}M" "$OUT"
mke2fs -q -F -t ext2 -L wiltee -U "$UUID" -m 0 \
  -E root_owner=0:0,hash_seed="$UUID" -d "$STAGE" "$OUT"
echo "$OUT: $(stat -c %s "$OUT") bytes, ext2, /hello.txt = \"$HELLO\""
