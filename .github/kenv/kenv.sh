#!/bin/bash
# shellcheck disable=SC2086 # TC is a word list ('' or 'LLVM=1') splatted into make
# Kernel env cache: the part of a prepared kernel tree that an external module
# build reads (what distro "linux-headers" packages ship), stored as an OCI
# artifact so a CI cell can skip the clone, defconfig and vmlinux build.
#
#   kenv.sh tag                  print the artifact tag of this cell
#   kenv.sh restore REF DIR      pull REF, unpack it into DIR; exit 0 = hit, 1 = miss
#   kenv.sh pack KTREE FILE      package the prepared tree KTREE into FILE (.tar.zst);
#                                exit 3 = this kernel cannot be packaged
#   kenv.sh verify FILE KO REPO  build HEAD of the driver checkout REPO against the
#                                unpacked FILE; exit 0 when its code matches KO
#   kenv.sh push REF FILE        push FILE as REF unless REF exists (needs
#                                REGISTRY_CONFIG with a login); exit 0 when REF
#                                was pushed or already existed
#
# Env: KERNEL_TAG, TOOLCHAIN (gcc|llvm), ARCH, TC ('' or 'LLVM=1');
# KENV_ORAS_FLAGS, extra oras flags (--oci-layout for a local test).
set -euo pipefail

# Bump when the package layout or the build it is checked against changes:
# the bump moves every tag, so no cell reads a package of the old layout.
FORMAT=1
ARTIFACT_TYPE=application/vnd.jethome.kenv.v1
LAYER_TYPE=application/vnd.oci.image.layer.v1.tar+zstd
PULL_TIMEOUT=600
here=$(dirname "$(readlink -f "$0")")

case "$TOOLCHAIN" in
  gcc) cc=gcc ccname=gcc ccver=$(gcc -dumpfullversion 2>/dev/null || true) ld=ld ;;
  llvm) cc=clang ccname=clang ccver=$(clang -dumpversion 2>/dev/null || true) ld=ld.lld ;;
  *) echo "kenv: unknown TOOLCHAIN '$TOOLCHAIN'" >&2; exit 2 ;;
esac

first_line() { "$@" 2>/dev/null | head -n 1 || true; }

# Everything the prepared tree depends on besides the kernel source, one
# 'name<TAB>value' line each: the config steps (prepare.sh), the host OS
# (shared libraries of the host tools such as objtool) and every tool whose
# version Kconfig reads into .config (CONFIG_CC_VERSION_TEXT,
# CONFIG_LD_VERSION, CONFIG_PAHOLE_VERSION, CONFIG_RUSTC_VERSION_TEXT, ...).
# A tool that is missing gives an empty value. Each line also becomes an
# io.jethome.kenv.<name> annotation of the artifact.
inputs() {
  local os
  # shellcheck source=/dev/null
  os=$(. /etc/os-release && echo "$ID $VERSION_ID")
  printf '%s\t%s\n' \
    format "$FORMAT" \
    kernel "$KERNEL_TAG" \
    toolchain "$TOOLCHAIN" \
    arch "$ARCH" \
    os "$os" \
    prepare-sha256 "$(sha256sum < "$here/prepare.sh" | cut -d' ' -f1)" \
    cc "$(first_line "$cc" --version)" \
    ld "$(first_line "$ld" --version)" \
    pahole "$(first_line pahole --version)" \
    rustc "$(first_line rustc --version)" \
    bindgen "$(first_line bindgen --version)"
}

# <kernel tag>-<compiler>-<compiler version>-<arch>-<sha8 of all inputs>,
# e.g. v6.18.64-gcc-13.3.0-x86_64-1a2b3c4d. The readable part names the
# package; the hash covers what it leaves out (OS, distro patch level of the
# compiler, prepare.sh, the other tools).
tag() {
  local t
  t="$KERNEL_TAG-$ccname-$ccver-$ARCH-$(inputs | sha256sum | cut -c1-8)"
  # An OCI tag: [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}
  if ! [[ "$t" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "kenv: '$t' is not a valid tag" >&2
    return 1
  fi
  echo "$t"
}

cc_matches() {
  local want have
  # Older kernels write the value quoted, newer ones bare.
  want=$(sed -n 's/^CONFIG_CC_VERSION_TEXT=//p' "$1/include/config/auto.conf" 2>/dev/null || true)
  want=${want#\"}
  want=${want%\"}
  have=$(first_line "$cc" --version)
  if [ "$want" != "$have" ]; then
    echo "kenv: package built by '$want', this runner has '$have'" >&2
    return 1
  fi
}

restore() {
  local ref=$1 dir=$2 tmp
  command -v oras >/dev/null || { echo "kenv: oras is missing" >&2; return 1; }
  tmp=$(mktemp -d)
  # A missing tag and an unreachable registry are both a miss: the cell then
  # builds the tree itself.
  if ! timeout "$PULL_TIMEOUT" oras pull --no-tty ${KENV_ORAS_FLAGS:-} -o "$tmp" "$ref" >&2 ||
     [ ! -f "$tmp/kenv.tar.zst" ]; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  # tar keeps the packed mtimes, so nothing in the tree looks newer than its
  # outputs.
  if ! zstd -dcq "$tmp/kenv.tar.zst" | tar -xf - -C "$dir" || ! cc_matches "$dir"; then
    rm -rf "$tmp" "$dir"
    return 1
  fi
  rm -rf "$tmp"
}

pack() {
  local ktree=$1 out=$2 stage
  ktree=$(readlink -f "$ktree")
  # The kernel's own list of what an external module build needs; kernels
  # before it was split out of builddeb (and its run-command target) are not
  # cached.
  if [ ! -x "$ktree/scripts/package/install-extmod-build" ] ||
     ! grep -q '^run-command:' "$ktree/Makefile"; then
    echo "kenv: $KERNEL_TAG has no install-extmod-build; not packaged" >&2
    return 3
  fi
  stage=$(mktemp -d)
  # The script copies with tar, which keeps the mtimes.
  make -C "$ktree" -s $TC run-command \
       KBUILD_RUN_COMMAND="\$(srctree)/scripts/package/install-extmod-build $stage/kenv"
  # .config is not read by the module build; it travels for diagnostics.
  cp -p "$ktree/.config" "$stage/kenv/.config"
  inputs > "$stage/kenv/kenv-inputs.txt"
  mkdir -p "$(dirname "$out")"
  tar -C "$stage/kenv" --numeric-owner -cf - . | zstd -q -T0 -10 -o "$out" -f
  rm -rf "$stage"
  ls -l "$out" >&2
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
  local file=$1 ko=$2 repo=$3 tmp rc=0
  tmp=$(mktemp -d)
  mkdir -p "$tmp/ktree" "$tmp/src"
  zstd -dcq "$file" | tar -xf - -C "$tmp/ktree"
  cc_matches "$tmp/ktree"
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

push() {
  local ref=$1 file=$2 name value
  local -a ann
  local err
  # Tags are never overwritten: the first package pushed under a tag stays.
  # Checked right before the push, so a tag pushed by a parallel run during
  # this run's build is kept as well. Only a definite "not found" lets the
  # push go: any other answer leaves the tag alone.
  if err=$(oras manifest fetch ${KENV_ORAS_FLAGS:-} --registry-config "$REGISTRY_CONFIG" \
             --descriptor "$ref" 2>&1 > /dev/null); then
    echo "kenv: $ref exists; not pushed" >&2
    return 0
  fi
  if ! grep -qi 'not found' <<< "$err"; then
    echo "kenv: cannot tell whether $ref exists; not pushed: $err" >&2
    return 1
  fi
  ann=(--annotation "org.opencontainers.image.title=kernel env $KERNEL_TAG $TOOLCHAIN/$ARCH"
       --annotation "org.opencontainers.image.created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
       --annotation "org.opencontainers.image.version=$KERNEL_TAG")
  [ -n "${SOURCE_URL:-}" ] && ann+=(--annotation "org.opencontainers.image.source=$SOURCE_URL")
  [ -n "${SOURCE_REVISION:-}" ] && ann+=(--annotation "org.opencontainers.image.revision=$SOURCE_REVISION")
  while IFS=$'\t' read -r name value; do
    ann+=(--annotation "io.jethome.kenv.$name=$value")
  done < <(inputs)
  (
    cd "$(dirname "$file")"
    oras push --no-tty ${KENV_ORAS_FLAGS:-} --registry-config "$REGISTRY_CONFIG" \
         --artifact-type "$ARTIFACT_TYPE" "${ann[@]}" \
         "$ref" "$(basename "$file"):$LAYER_TYPE"
  )
}

cmd=${1:-}
shift || true
case "$cmd" in
  tag) tag ;;
  restore) restore "$@" ;;
  pack) pack "$@" ;;
  verify) verify "$@" ;;
  push) push "$@" ;;
  *) sed -n '3,18p' "$0" >&2; exit 2 ;;
esac
