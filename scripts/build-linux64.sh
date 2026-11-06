#!/usr/bin/env bash
# Builds build/linux64-$PROFILE/Image: a riscv64 Linux 6.12 kernel with an embedded
# musl/busybox initramfs, for one of three ISA profiles (PROFILE, default gc):
#
#   ima   rv64ima    / lp64    no C, no F/D   kernel RISCV_ISA_C=n FPU=n
#   imac  rv64imac   / lp64    C, no F/D      kernel RISCV_ISA_C=y FPU=n
#   gc    rv64imafdc / lp64d   C + F/D        kernel RISCV_ISA_C=y FPU=y (hard float everywhere)
#
# Usage: [PROFILE=ima|imac|gc] [JOBS=n] [RV64_SW=/tmp/rv64-sw] scripts/build-linux64.sh
# Outputs (build/linux64-$PROFILE/): Image vmlinux System.map kernel.config initramfs.list busybox
#   and, for tests/qemu64.py only, opensbi.bin/opensbi.elf (OpenSBI built for the profile's ISA)
#
# Pipeline (finished steps are skipped via stamp files in $RV64_SW/$PROFILE/stamps):
#   compiler-rt builtins -> musl (static) -> busybox (static) -> initramfs list -> kernel
#   -> instruction-mix check (llvm-objdump) of vmlinux, vdso and busybox
# Source tarballs are shared in $RV64_SW/dl; everything else is per profile.
# Needs: clang-19, ld.lld-19, llvm-{ar,ranlib,objcopy,objdump,strip}-19, host gcc, make,
# bc, flex, bison, perl, curl, xz, bzip2, flock.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD

PROFILE=${PROFILE:-gc}
case $PROFILE in
  ima)  MARCH=rv64ima;    MABI=lp64 ;;
  imac) MARCH=rv64imac;   MABI=lp64 ;;
  gc)   MARCH=rv64imafdc; MABI=lp64d ;;
  *) echo "PROFILE must be ima, imac or gc (got '$PROFILE')" >&2; exit 2 ;;
esac

RV64_SW=${RV64_SW:-/tmp/rv64-sw}
DL=$RV64_SW/dl
W=$RV64_SW/$PROFILE
OUT=$REPO/build/linux64-$PROFILE
JOBS=${JOBS:-$(nproc)}
LLVM_VER=19
TARGET=riscv64-unknown-linux-musl

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

# OpenSBI is only used by tests/qemu64.py (the emulator answers SBI calls itself). QEMU's
# bundled firmware is built with C and F/D, so the no-C profile needs one built for its ISA.
OSBI_VER=1.5.1
OSBI_TAR=opensbi-$OSBI_VER.tar.gz
OSBI_URL=https://github.com/riscv-software-src/opensbi/archive/refs/tags/v$OSBI_VER.tar.gz
OSBI_SHA=6bab6fadd69f38f08e5c767517aafbf8525f54454b2848d6a7eb0e74b683153b

SRC=$W/src
SYSROOT=$W/sysroot
BUILTINS=$W/crt/libclang_rt.builtins-riscv64.a
CCW=$W/cc-rv64
STAMPS=$W/stamps
mkdir -p "$DL" "$W" "$SRC" "$STAMPS" "$OUT" "$W/crt"

log() { printf '\n==> [%s] %s\n' "$PROFILE" "$*"; }
done_() { [ -f "$STAMPS/$1" ]; }
mark() { touch "$STAMPS/$1"; }

fetch() { # tarball url sha256 (cache shared between profiles, so serialise downloads)
  local f=$DL/$1
  ( flock 9
    if [ -f "$f" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$3" ]; then rm -f "$f"; fi
    if [ ! -f "$f" ]; then
      log "download $1"
      curl -fL --retry 3 -o "$f.part" "$2"
      mv "$f.part" "$f"
    fi
    echo "$3  $f" | sha256sum -c - >/dev/null || { echo "sha256 mismatch: $f" >&2; exit 1; }
  ) 9>"$DL/.lock"
}

extract() { # tarball dir
  [ -f "$SRC/$2/.extracted" ] && return 0
  rm -rf "${SRC:?}/$2"
  tar -C "$SRC" -xf "$DL/$1"
  touch "$SRC/$2/.extracted"
}

# Static non-PIE code throughout (clang defaults to PIE for *-musl triples).
RVFLAGS="--target=$TARGET -march=$MARCH -mabi=$MABI -fno-pic -fno-pie"
CLANG="clang-$LLVM_VER $RVFLAGS"
LLD=$(command -v ld.lld-$LLVM_VER)

log "profile $PROFILE: -march=$MARCH -mabi=$MABI, work dir $W, jobs $JOBS"
fetch "$LINUX_TAR" "$LINUX_URL" "$LINUX_SHA"
fetch "$MUSL_TAR" "$MUSL_URL" "$MUSL_SHA"
fetch "$BB_TAR" "$BB_URL" "$BB_SHA"
fetch "$CRT_TAR" "$CRT_URL" "$CRT_SHA"

# ---- compiler-rt builtins (generic C only: soft-float, 128-bit int helpers, atomics) ----
# Built with the profile's ABI: lld refuses to mix lp64 and lp64d objects.
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

# ---- kernel uapi headers into the sysroot (busybox needs <linux/*.h>) ----
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
COMMON="$RVFLAGS -nostdinc -isystem \$S/include -isystem \$(clang-$LLVM_VER -print-resource-dir)/include -Qunused-arguments"
for a in "\$@"; do case \$a in -c|-S|-E|-M|-MM) exec clang-$LLVM_VER \$COMMON "\$@";; esac; done
exec clang-$LLVM_VER \$COMMON -fuse-ld=lld --ld-path=$LLD -nostdlib -static -no-pie -L\$S/lib \$S/lib/crt1.o \$S/lib/crti.o "\$@" -lc \$B \$S/lib/crtn.o
EOF
chmod +x "$CCW"

# ---- busybox ----
BBD=$SRC/busybox-$BB_VER
# LD must be a real linker: busybox's default is "$(CC) -nostdlib", which would pull in crt1.o
BBMAKE=(make -C "$BBD" HOSTCC=gcc CC="$CCW" LD=ld.lld-$LLVM_VER AR=llvm-ar-$LLVM_VER
        STRIP=llvm-strip-$LLVM_VER)
BB_OFF="TC FEATURE_INETD_RPC SELINUX SELINUXENABLED SETFILES RESTORECON MATCHPATHCON RUNCON
  GETENFORCE SETENFORCE SESTATUS SETSEBOOL GETSEBOOL CHCON FEATURE_MOUNT_NFS FEATURE_MOUNT_CIFS
  INETD STATIC_LIBGCC WERROR DEBUG PIE FEATURE_WGET_HTTPS FEATURE_WGET_OPENSSL"
BB_ON="STATIC SH_IS_ASH ASH ASH_ALIAS FEATURE_EDITING FEATURE_USE_INITTAB INIT GETTY LOGIN
  MOUNT UMOUNT UNAME CAT GREP ECHO LS PS SLEEP POWEROFF HALT REBOOT DMESG FREE TOP VI
  MKFS_EXT2 MKE2FS IFCONFIG IP UDHCPC PING WGET NC HOSTNAME MKDIR FEATURE_IP_ADDRESS
  FEATURE_IP_LINK FEATURE_IP_ROUTE AWK FEATURE_AWK_LIBM DD MD5SUM SHA256SUM SEQ SYNC DF DU
  NPROC UPTIME DATE TIME HEAD TAIL WC SORT CUT TR HEXDUMP MKNOD ROUTE TELNET ARP TASKSET
  FEATURE_TASKSET_FANCY"
# busybox declares ptr_to_globals const and writes it through a cast; clang then hoists the
# load above the assignment and applets (getty, awk, ...) crash. This define disables the trick.
BB_CFLAGS="-DBB_GLOBAL_CONST="
# The stamp name carries the applet selection, so editing the lists above rebuilds busybox.
BB_STAMP=busybox-$(printf '%s|%s|%s|%s|%s' "$BB_ON" "$BB_OFF" "$BB_CFLAGS" "$MARCH" "$MABI" | sha256sum | cut -c1-12)
if ! done_ "$BB_STAMP"; then
  log "busybox $BB_VER"
  extract "$BB_TAR" "busybox-$BB_VER"
  ( cd "$BBD"
    make distclean >/dev/null 2>&1 || true
    make HOSTCC=gcc defconfig >/dev/null
    setcfg() { # SYM y|n
      sed -i -e "/^# CONFIG_$1 is not set/d" -e "/^CONFIG_$1=/d" .config
      if [ "$2" = y ]; then echo "CONFIG_$1=y" >> .config; else echo "# CONFIG_$1 is not set" >> .config; fi
    }
    for s in $BB_OFF; do setcfg "$s" n; done
    for s in $BB_ON; do setcfg "$s" y; done
    sed -i '/^CONFIG_EXTRA_CFLAGS=/d' .config
    echo "CONFIG_EXTRA_CFLAGS=\"$BB_CFLAGS\"" >> .config
    make HOSTCC=gcc oldconfig < <(yes "") >/dev/null
    grep -qxF "CONFIG_EXTRA_CFLAGS=\"$BB_CFLAGS\"" .config || { echo "busybox: EXTRA_CFLAGS lost" >&2; exit 1; }
    for s in $BB_ON; do
      grep -qx "CONFIG_$s=y" .config || { echo "busybox: CONFIG_$s not enabled after oldconfig" >&2; exit 1; }
    done
    "${BBMAKE[@]}" -j"$JOBS" )
  mark "$BB_STAMP"
fi
BUSYBOX=$BBD/busybox

# ---- initramfs list ----
log "initramfs"
STAGE=$W/rootfs-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
"${BBMAKE[@]}" CONFIG_PREFIX="$STAGE" install >/dev/null
LIST=$OUT/initramfs.list
declare -A have
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
export KBUILD_BUILD_USER=wiltee KBUILD_BUILD_HOST=wiltee KBUILD_BUILD_VERSION=1 KBUILD_BUILD_TIMESTAMP='Thu Jan  1 00:00:00 UTC 1970'
KMAKE=(make -C "$KD" O="$KB" ARCH=riscv LLVM=-$LLVM_VER HOSTCC=gcc HOSTCXX=g++ -j"$JOBS")
mkdir -p "$KB"
CFG_BASE=platform/linux64.config
CFG_PROFILE=platform/linux64-$PROFILE.config
[ -f "$CFG_PROFILE" ] || { echo "missing $CFG_PROFILE" >&2; exit 1; }
FRAG=$KB/linux64.frag
# kconfig only accepts "# CONFIG_X is not set" for disabled bools, not CONFIG_X=n
{ sed -E 's/^(CONFIG_[A-Za-z0-9_]+)=n$/# \1 is not set/' "$CFG_BASE" "$CFG_PROFILE"
  echo "CONFIG_INITRAMFS_SOURCE=\"$LIST\""; } > "$FRAG.new"
cmp -s "$FRAG.new" "$FRAG" && rm -f "$FRAG.new" || mv "$FRAG.new" "$FRAG"
if [ ! -f "$KB/.config" ] || [ "$FRAG" -nt "$KB/.config" ]; then
  "${KMAKE[@]}" tinyconfig
  ( cd "$KD" && KCONFIG_CONFIG="$KB/.config" ARCH=riscv ./scripts/kconfig/merge_config.sh -m -O "$KB" "$KB/.config" "$FRAG" >/dev/null )
  "${KMAKE[@]}" olddefconfig
  # Every requested symbol must have survived olddefconfig (dependencies can silently override).
  bad=0
  while IFS= read -r l; do
    case "$l" in CONFIG_*=*) ;; *) continue;; esac
    k=${l%%=*}; v=${l#*=}
    [ "$k" = CONFIG_INITRAMFS_SOURCE ] && continue
    if [ "$v" = n ]; then
      if grep -q "^$k=" "$KB/.config"; then echo "config: $k=n not honoured" >&2; bad=1; fi
    elif ! grep -qxF "$l" "$KB/.config"; then
      echo "config: $l not honoured (got: $(grep "^$k=" "$KB/.config" || echo unset))" >&2; bad=1
    fi
  done < <(cat "$CFG_BASE" "$CFG_PROFILE")
  if [ $bad = 1 ]; then rm -f "$KB/.config"; echo "kernel config check failed" >&2; exit 1; fi
fi
"${KMAKE[@]}" Image

cp "$KB/arch/riscv/boot/Image" "$OUT/Image"
cp "$KB/vmlinux" "$OUT/vmlinux"
cp "$KB/System.map" "$OUT/System.map"
cp "$KB/.config" "$OUT/kernel.config"
cp "$BUSYBOX" "$OUT/busybox"
ls -l "$OUT/Image"

# ---- OpenSBI for the QEMU boot test (optional: a failure only costs tests/qemu64.py) ----
build_opensbi() {
  local isa d=$SRC/opensbi-$OSBI_VER
  case $PROFILE in ima) isa=rv64ima;; imac) isa=rv64imac;; gc) isa=rv64imafdc;; esac
  fetch "$OSBI_TAR" "$OSBI_URL" "$OSBI_SHA" || return 1
  extract "$OSBI_TAR" "opensbi-$OSBI_VER" || return 1
  make -C "$d" -j"$JOBS" O="$W/opensbi" LLVM=1 CC=clang-$LLVM_VER LD=ld.lld-$LLVM_VER \
    AR=llvm-ar-$LLVM_VER OBJCOPY=llvm-objcopy-$LLVM_VER PLATFORM=generic PLATFORM_RISCV_XLEN=64 \
    PLATFORM_RISCV_ISA=${isa}_zicsr_zifencei PLATFORM_RISCV_ABI=lp64 > "$W/opensbi.log" 2>&1 || return 1
  cp "$W/opensbi/platform/generic/firmware/fw_dynamic.bin" "$OUT/opensbi.bin" || return 1
  cp "$W/opensbi/platform/generic/firmware/fw_dynamic.elf" "$OUT/opensbi.elf"
}
log "OpenSBI $OSBI_VER ($PROFILE ISA, for QEMU tests only)"
build_opensbi || { echo "warning: OpenSBI build failed (see $W/opensbi.log); tests/qemu64.py will use QEMU's firmware" >&2; rm -f "$OUT/opensbi.bin" "$OUT/opensbi.elf"; }

# ---- instruction mix: what the profile promises must be what was emitted ----
# Per ELF: total instructions, 2-byte (compressed) instructions, F/D instructions.
isa_count() {
  llvm-objdump-$LLVM_VER -d "$1" | awk '
    /<unknown>/ { next }   # data words in text (Image header, jump tables)
    /^[[:space:]]*[0-9a-f]+:[[:space:]]+[0-9a-f]+[[:space:]]/ {
      n++; if (length($2) == 4) c++
      if ($3 ~ /^(c\.)?f/ && $3 !~ /^fence/) fp++
    }
    END { printf "%d %d %d\n", n, c, fp }'
}
log "instruction mix ($PROFILE)"
VDSO=$KB/arch/riscv/kernel/vdso/vdso.so.dbg
fail=0
for f in "$OUT/vmlinux" "$VDSO" "$OUT/busybox"; do
  read -r n c fp < <(isa_count "$f")
  printf '%-52s insns=%-8d compressed(2B)=%-7d fp=%d\n' "${f#"$REPO/"}" "$n" "$c" "$fp"
  case $PROFILE in
    ima)  [ "$c" = 0 ] && [ "$fp" = 0 ] || fail=1 ;;
    imac) [ "$c" -gt 0 ] && [ "$fp" = 0 ] || fail=1 ;;
    gc)   [ "$c" -gt 0 ] || fail=1
          # C code in the kernel and vdso is soft-float; only fpu.S and busybox/musl use F/D
          case $f in */vdso.so.dbg) ;; *) [ "$fp" -gt 0 ] || fail=1 ;; esac ;;
  esac
done
if [ -f "$OUT/opensbi.elf" ]; then   # informational: QEMU-only firmware
  read -r n c fp < <(isa_count "$OUT/opensbi.elf")
  printf '%-52s insns=%-8d compressed(2B)=%-7d fp=%d\n' "build/linux64-$PROFILE/opensbi.elf (QEMU only)" "$n" "$c" "$fp"
fi
[ $fail = 0 ] || { echo "instruction mix does not match profile $PROFILE" >&2; exit 1; }
log "done: $OUT/Image"
