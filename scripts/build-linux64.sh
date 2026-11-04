#!/usr/bin/env bash
# Builds build/linux64/Image: a riscv64 Linux 6.12 kernel with an embedded busybox
# initramfs, restricted to RV64IMA + Zicsr + Zifencei (no C, F/D or V).
#
# Pipeline (finished steps are skipped via stamp files in $RV64_SW/stamps):
#   compiler-rt builtins -> musl (static) -> busybox (static) -> initramfs -> kernel
# Needs: clang-19, ld.lld-19, llvm-{ar,ranlib,objcopy,objdump}-19, host gcc, make,
# bc, flex, bison, perl, curl, xz, bzip2.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD

W=${RV64_SW:-/tmp/rv64-sw}
OUT=$REPO/build/linux64
JOBS=${JOBS:-$(nproc)}
LLVM_VER=19
TARGET=riscv64-unknown-linux-musl
MARCH=rv64ima
MABI=lp64

# name|url|sha256
LINUX_VER=6.12.115
MUSL_VER=1.2.5
BB_VER=1.36.1
CRT_VER=19.1.7
LINUX_TAR=linux-$LINUX_VER.tar.xz
LINUX_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/$LINUX_TAR
LINUX_SHA=0ec90fe4b20422b1b664b77e6d2dde22b40bd41e7eb2cad8ac8739a4749cb1bb
MUSL_TAR=musl-$MUSL_VER.tar.gz
MUSL_URL=https://musl.libc.org/releases/$MUSL_TAR
MUSL_SHA=a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4
BB_TAR=busybox-$BB_VER.tar.bz2
BB_URL=https://busybox.net/downloads/$BB_TAR
BB_SHA=b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314
CRT_TAR=compiler-rt-$CRT_VER.src.tar.xz
CRT_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-$CRT_VER/$CRT_TAR
CRT_SHA=c12b6e764202c615c1a3af9a13d477846878757ae0e29e5f8979215a6958fffc

SRC=$W/src
SYSROOT=$W/sysroot
BUILTINS=$W/crt/libclang_rt.builtins-riscv64.a
CCW=$W/cc-rv64
STAMPS=$W/stamps
mkdir -p "$W" "$SRC" "$STAMPS" "$OUT" "$W/crt"

log() { printf '\n==> %s\n' "$*"; }
done_() { [ -f "$STAMPS/$1" ]; }
mark() { touch "$STAMPS/$1"; }

fetch() { # tar url sha
  local f=$W/$1
  if [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$3" ]; then rm -f "$f"; fi
  if [ ! -f "$f" ]; then
    log "download $1"
    curl -fL --retry 3 -o "$f.part" "$2"
    mv "$f.part" "$f"
  fi
  echo "$3  $f" | sha256sum -c - >/dev/null || { echo "sha256 mismatch: $f" >&2; exit 1; }
}

extract() { # tar dir
  [ -f "$SRC/$2/.extracted" ] && return 0
  rm -rf "${SRC:?}/$2"
  tar -C "$SRC" -xf "$W/$1"
  touch "$SRC/$2/.extracted"
}

CLANG="clang-$LLVM_VER --target=$TARGET -march=$MARCH -mabi=$MABI"

fetch "$LINUX_TAR" "$LINUX_URL" "$LINUX_SHA"
fetch "$MUSL_TAR" "$MUSL_URL" "$MUSL_SHA"
fetch "$BB_TAR" "$BB_URL" "$BB_SHA"
fetch "$CRT_TAR" "$CRT_URL" "$CRT_SHA"

# ---- compiler-rt builtins (generic C only: soft-float, 128-bit int helpers, atomics) ----
if ! done_ builtins; then
  log "compiler-rt builtins"
  extract "$CRT_TAR" "compiler-rt-$CRT_VER.src"
  B=$SRC/compiler-rt-$CRT_VER.src/lib/builtins
  O=$W/crt/obj
  rm -rf "$O" "$BUILTINS"; mkdir -p "$O"
  # Not usable/needed on a bare riscv64 Linux/musl target (Apple, EH, TLS, trampolines).
  EXCL=" apple_versioning os_version_check gcc_personality_v0 emutls enable_execute_stack trampoline_setup eprintf clear_cache "
  objs=()
  for f in "$B"/*.c "$B"/riscv/fp_mode.c; do
    n=$(basename "$f" .c)
    case "$EXCL" in *" $n "*) continue;; esac
    case $n in *xf*|*xc3) continue;; esac   # x87 long double
    $CLANG -O2 -ffreestanding -nostdinc -isystem "$(clang-$LLVM_VER -print-resource-dir)/include" -fno-builtin -fno-stack-protector -fvisibility=hidden \
      -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables \
      -I"$B" -c "$f" -o "$O/$n.o"
    objs+=("$O/$n.o")
  done
  llvm-ar-$LLVM_VER rcs "$BUILTINS" "${objs[@]}"
  llvm-ranlib-$LLVM_VER "$BUILTINS"
  mark builtins
fi

# ---- musl ----
if ! done_ musl; then
  log "musl $MUSL_VER"
  extract "$MUSL_TAR" "musl-$MUSL_VER"
  rm -rf "$SYSROOT"
  ( cd "$SRC/musl-$MUSL_VER"
    make distclean >/dev/null 2>&1 || true
    ./configure --target=riscv64 --disable-shared --prefix="$SYSROOT" \
      CC="$CLANG" AR=llvm-ar-$LLVM_VER RANLIB=llvm-ranlib-$LLVM_VER \
      LIBCC="$BUILTINS" CROSS_COMPILE=riscv64-
    make -j"$JOBS"
    make install )
  mark musl
fi

# ---- kernel headers into the sysroot (busybox needs <linux/*.h>) ----
if ! done_ khdrs; then
  log "kernel uapi headers"
  extract "$LINUX_TAR" "linux-$LINUX_VER"
  make -C "$SRC/linux-$LINUX_VER" O="$W/khdrs-build" ARCH=riscv LLVM=-$LLVM_VER HOSTCC=gcc headers_install INSTALL_HDR_PATH="$SYSROOT" >/dev/null
  mark khdrs
fi

# clang driver wrapper: static musl, our builtins instead of libgcc/compiler-rt
cat > "$CCW" <<EOF
#!/bin/sh
S=$SYSROOT
B=$BUILTINS
COMMON="--target=$TARGET -march=$MARCH -mabi=$MABI -nostdinc -isystem \$S/include -isystem \$(clang-$LLVM_VER -print-resource-dir)/include -Qunused-arguments"
for a in "\$@"; do case \$a in -c|-S|-E|-M|-MM) exec clang-$LLVM_VER \$COMMON "\$@";; esac; done
exec clang-$LLVM_VER \$COMMON -fuse-ld=lld --ld-path=/usr/bin/ld.lld-$LLVM_VER -nostdlib -static -L\$S/lib \$S/lib/crt1.o \$S/lib/crti.o "\$@" -lc \$B \$S/lib/crtn.o
EOF
chmod +x "$CCW"

# ---- busybox ----
BBD=$SRC/busybox-$BB_VER
# LD must be a real linker: busybox's default is "$(CC) -nostdlib", which would pull in crt1.o
BBMAKE=(make -C "$BBD" HOSTCC=gcc CC="$CCW" LD=ld.lld-$LLVM_VER AR=llvm-ar-$LLVM_VER
        STRIP=llvm-strip-$LLVM_VER)
if ! done_ busybox; then
  log "busybox $BB_VER"
  extract "$BB_TAR" "busybox-$BB_VER"
  cd "$BBD"
  make distclean >/dev/null 2>&1 || true
  make HOSTCC=gcc defconfig >/dev/null
  setcfg() { # SYM y|n
    sed -i -e "/^# CONFIG_$1 is not set/d" -e "/^CONFIG_$1=/d" .config
    if [ "$2" = y ]; then echo "CONFIG_$1=y" >> .config; else echo "# CONFIG_$1 is not set" >> .config; fi
  }
  setcfg STATIC y
  setcfg PIE n
  for s in TC FEATURE_INETD_RPC SELINUX SELINUXENABLED \
           SETFILES RESTORECON MATCHPATHCON RUNCON GETENFORCE \
           SETENFORCE SESTATUS SETSEBOOL GETSEBOOL SELINUXENABLED CHCON \
           FEATURE_MOUNT_NFS FEATURE_MOUNT_CIFS INETD STATIC_LIBGCC \
           WERROR DEBUG; do
    setcfg "$s" n
  done
  for s in SH_IS_ASH ASH ASH_ALIAS FEATURE_EDITING FEATURE_USE_INITTAB INIT GETTY LOGIN \
           MOUNT UMOUNT UNAME CAT GREP ECHO LS PS SLEEP POWEROFF HALT REBOOT DMESG FREE TOP VI \
           MKFS_EXT2 IFCONFIG IP UDHCPC PING WGET NC HOSTNAME MKDIR FEATURE_IP_ADDRESS \
           FEATURE_IP_LINK FEATURE_IP_ROUTE; do
    setcfg "$s" y
  done
  make HOSTCC=gcc oldconfig < <(yes "") >/dev/null
  "${BBMAKE[@]}" -j"$JOBS"
  cd "$REPO"
  mark busybox
fi
BUSYBOX=$BBD/busybox

# ---- initramfs list ----
log "initramfs"
STAGE=$W/rootfs-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
"${BBMAKE[@]}" CONFIG_PREFIX="$STAGE" install >/dev/null
LIST=$OUT/initramfs.list
declare -A have
emit() { echo "$*"; }
{
  # nodes.list carries the base dirs, /dev/console, /dev/null and /init
  cat platform/rootfs64/nodes.list
  while read -r _ d _; do have[$d]=1; done < <(grep '^dir ' platform/rootfs64/nodes.list)
  # busybox tree: dirs, the binary, applet symlinks
  while read -r p; do
    p=${p#.}
    if [ -L "$STAGE$p" ]; then
      echo "slink $p $(readlink "$STAGE$p") 777 0 0"
    elif [ -d "$STAGE$p" ]; then
      [ -n "${have[$p]:-}" ] || echo "dir $p 755 0 0"; have[$p]=1
    else
      echo "file $p $STAGE$p 755 0 0"
    fi
  done < <(cd "$STAGE" && find . -mindepth 1 | LC_ALL=C sort)
  # overlay files (parent dirs created on demand)
  while read -r p; do
    p=${p#.}; d=""
    IFS=/ read -ra parts <<< "${p%/*}"
    for c in "${parts[@]}"; do
      [ -z "$c" ] && continue
      d=$d/$c
      [ -n "${have[$d]:-}" ] || { echo "dir $d 755 0 0"; have[$d]=1; }
    done
    echo "file $p $REPO/platform/rootfs64$p $(stat -c %a "platform/rootfs64$p") 0 0"
  done < <(cd platform/rootfs64 && find . -type f ! -name nodes.list | LC_ALL=C sort)
} > "$LIST.tmp"
cmp -s "$LIST.tmp" "$LIST" && rm -f "$LIST.tmp" || mv "$LIST.tmp" "$LIST"

# ---- kernel ----
KD=$SRC/linux-$LINUX_VER
KB=$W/kbuild
extract "$LINUX_TAR" "linux-$LINUX_VER"
log "kernel $LINUX_VER"
KMAKE=(make -C "$KD" O="$KB" ARCH=riscv LLVM=-$LLVM_VER HOSTCC=gcc HOSTCXX=g++ -j"$JOBS")
mkdir -p "$KB"
FRAG=$KB/linux64.frag
# kconfig only accepts "# CONFIG_X is not set" for disabled bools, not CONFIG_X=n
{ sed -E 's/^(CONFIG_[A-Za-z0-9_]+)=n$/# \1 is not set/' platform/linux64.config; echo "CONFIG_INITRAMFS_SOURCE=\"$LIST\""; } > "$FRAG"
if [ ! -f "$KB/.config" ] || [ "$FRAG" -nt "$KB/.config" ] || [ platform/linux64.config -nt "$KB/.config" ]; then
  "${KMAKE[@]}" tinyconfig
  ( cd "$KD" && KCONFIG_CONFIG="$KB/.config" ARCH=riscv ./scripts/kconfig/merge_config.sh -m -O "$KB" "$KB/.config" "$FRAG" >/dev/null )
  "${KMAKE[@]}" olddefconfig
  # merge_config -m runs olddefconfig-free; re-check requested symbols survived
  while IFS= read -r l; do
    case "$l" in CONFIG_*=*) ;; *) continue;; esac
    k=${l%%=*}; v=${l#*=}
    [ "$k" = CONFIG_INITRAMFS_SOURCE ] && continue
    if [ "$v" = n ]; then
      grep -q "^$k=" "$KB/.config" && { echo "config: $k not disabled" >&2; exit 1; }
    else
      grep -qxF "$l" "$KB/.config" || echo "warning: $l not honoured by Kconfig" >&2
    fi
  done < platform/linux64.config
fi
"${KMAKE[@]}" Image

cp "$KB/arch/riscv/boot/Image" "$OUT/Image"
cp "$KB/vmlinux" "$OUT/vmlinux"
cp "$KB/.config" "$OUT/kernel.config"
ls -l "$OUT/Image"
log "done: $OUT/Image"
