#!/bin/bash
# shellcheck disable=SC2086 # TC is a word list ('' or 'LLVM=1') splatted into make
# Kernel env cache: the part of a prepared kernel tree that an external module
# build reads (what distro "linux-headers" packages ship), kept in the Actions
# cache so a CI cell can skip the clone, defconfig and vmlinux build.
#
#   kenv.sh key                  print the cache key of this cell
#   kenv.sh pack KTREE DIR       copy what an external module build reads from
#                                the prepared tree KTREE into DIR; exit 3 = this
#                                kernel cannot be packaged
#   kenv.sh check DIR            exit 0 when the kernel env in DIR was built by
#                                this runner's compiler
#   kenv.sh verify DIR KO REPO   build HEAD of the driver checkout REPO against a
#                                copy of DIR; exit 0 when its code matches KO
#
# Env: KERNEL_TAG, TOOLCHAIN (gcc|llvm), ARCH, TC ('' or 'LLVM=1').
set -euo pipefail

# Bump when the package layout or the build it is checked against changes:
# the bump moves every key, so no cell reads a package of the old layout.
FORMAT=1
here=$(dirname "$(readlink -f "$0")")

case "$TOOLCHAIN" in
  gcc) cc=gcc ld=ld ;;
  llvm) cc=clang ld=ld.lld ;;
  *) echo "kenv: unknown TOOLCHAIN '$TOOLCHAIN'" >&2; exit 2 ;;
esac

first_line() { "$@" 2>/dev/null | head -n 1 || true; }

# Everything the prepared tree depends on besides the kernel source: the
# config steps (prepare.sh), the host OS (shared libraries of the host tools
# such as objtool) and every tool whose version Kconfig reads into .config
# (CONFIG_CC_VERSION_TEXT, CONFIG_LD_VERSION, CONFIG_PAHOLE_VERSION,
# CONFIG_RUSTC_VERSION_TEXT, ...). A tool that is missing hashes as empty.
key_inputs() {
  local id
  # shellcheck source=/dev/null
  id=$(. /etc/os-release && echo "$ID $VERSION_ID")
  echo "format $FORMAT"
  echo "kernel $KERNEL_TAG"
  echo "toolchain $TOOLCHAIN arch $ARCH"
  echo "os $id"
  echo "prepare $(sha256sum < "$here/prepare.sh" | cut -d' ' -f1)"
  echo "cc $(first_line "$cc" --version)"
  echo "ld $(first_line "$ld" --version)"
  echo "pahole $(first_line pahole --version)"
  echo "rustc $(first_line rustc --version)"
  echo "bindgen $(first_line bindgen --version)"
}

key() {
  local h
  h=$(key_inputs | sha256sum | cut -c1-16)
  echo "kenv-$KERNEL_TAG-$TOOLCHAIN-$ARCH-$h"
}

check() {
  local want have
  # Older kernels write the value quoted, newer ones bare.
  want=$(sed -n 's/^CONFIG_CC_VERSION_TEXT=//p' "$1/include/config/auto.conf" 2>/dev/null || true)
  want=${want#\"}
  want=${want%\"}
  have=$(first_line "$cc" --version)
  if [ "$want" != "$have" ]; then
    echo "kenv: kernel env built by '$want', this runner has '$have'" >&2
    return 1
  fi
}

pack() {
  local ktree=$1 dir=$2
  ktree=$(readlink -f "$ktree")
  # The kernel's own list of what an external module build needs; kernels
  # before it was split out of builddeb (and its run-command target) are not
  # cached.
  if [ ! -x "$ktree/scripts/package/install-extmod-build" ] ||
     ! grep -q '^run-command:' "$ktree/Makefile"; then
    echo "kenv: $KERNEL_TAG has no install-extmod-build; not packaged" >&2
    return 3
  fi
  rm -rf "$dir"
  # The script copies with tar, which keeps the mtimes: nothing in the copy
  # looks newer than its outputs.
  make -C "$ktree" -s $TC run-command \
       KBUILD_RUN_COMMAND="\$(srctree)/scripts/package/install-extmod-build $dir"
  # .config is not read by the module build; it travels for diagnostics.
  cp -p "$ktree/.config" "$dir/.config"
  key_inputs > "$dir/kenv-key.txt"
  du -sh "$dir" >&2
}

# The code sections of a module, one 'name sha256' line each. Data sections
# are left out: they carry __FILE__ strings, which name the source and kernel
# directories.
text_digest() {
  local ko=$1 s tmp
  tmp=$(mktemp)
  for s in $(readelf -SW "$ko" | sed -n 's/^ *\[ *[0-9]*\] \(\.[^ ]*text[^ ]*\) .*/\1/p' | grep -v '^\.rela' | sort); do
    objcopy -O binary --only-section="$s" "$ko" "$tmp"
    echo "$s $(sha256sum < "$tmp" | cut -d' ' -f1)"
  done
  rm -f "$tmp"
}

verify() {
  local dir=$1 ko=$2 repo=$3 tmp rc=0
  tmp=$(mktemp -d)
  # A copy, so the build cannot change what gets saved.
  cp -a "$dir" "$tmp/ktree"
  check "$tmp/ktree"
  mkdir -p "$tmp/src"
  git -C "$repo" archive HEAD | tar -xf - -C "$tmp/src"
  make -C "$tmp/src" -j"$(nproc)" $TC KSRC="$tmp/ktree" > "$tmp/build.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -f "$tmp/src/88x2cs.ko" ]; then
    tail -n 50 "$tmp/build.log" >&2
    echo "kenv: the driver does not build against the package (rc=$rc)" >&2
    rm -rf "$tmp"
    return 1
  fi
  if ! diff <(text_digest "$ko") <(text_digest "$tmp/src/88x2cs.ko") >&2; then
    echo "kenv: code built against the package differs from the full tree's" >&2
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

cmd=${1:-}
shift || true
case "$cmd" in
  key) key ;;
  pack) pack "$@" ;;
  check) check "$@" ;;
  verify) verify "$@" ;;
  *) sed -n '3,16p' "$0" >&2; exit 2 ;;
esac
