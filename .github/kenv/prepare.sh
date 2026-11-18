#!/bin/bash
# shellcheck disable=SC2086 # TC is a word list ('' or 'LLVM=1') splatted into make
# Configure and partially build the kernel tree in the current directory for
# out-of-tree builds of this driver. Env: TC ('' for gcc, 'LLVM=1' for llvm),
# TOOLCHAIN (gcc|llvm), ARCH. kenv.sh hashes this file into the kernel-env
# cache key: any change here invalidates every cached kernel env.
set -e

# Use the arch default config, NOT the runner's distro /boot/config.
make $TC defconfig
# Enable the kernel options the rtl8822cs module needs so the out-of-tree
# build sees complete headers (mirrors Buildroot rtl8822cs.mk CONFIG fixups).
scripts/config --enable NET
scripts/config --enable WIRELESS
scripts/config --enable CFG80211
scripts/config --enable MAC80211
scripts/config --enable MMC
# The arm64 defconfig carries RFKILL=m; in Kconfig tristate arithmetic
# CFG80211's dependency "RFKILL || !RFKILL" then evaluates to m, which
# caps CFG80211/MAC80211 back to =m on olddefconfig — and =m exports
# never reach vmlinux.symvers, so modpost fails the module link with
# "cfg80211_* undefined". Force it built-in.
scripts/config --enable RFKILL
# Disable certificate-related options that require distro-specific files
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable SYSTEM_REVOCATION_KEYS
scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
# -Werror gate, set explicitly so it does not depend on which arch
# defconfig happens to carry CONFIG_WERROR (x86_64 does, arm64 does
# not). gcc cells gate on the driver's warnings — the same condition
# the Buildroot x86 autobuilder hits — and their classes are at zero.
# llvm cells stay informational until the clang-only classes reach
# zero too (counted in the summary; only the kernel's default-fatal
# diagnostics fail the build) — then enable WERROR here as well.
if [ "$TOOLCHAIN" = "gcc" ]; then
  scripts/config --enable WERROR
else
  scripts/config --disable WERROR
fi
# Reconcile and prepare for external module builds
make $TC olddefconfig
# modules_prepare sets up the external-module scaffolding (modpost, modfinal
# rules); without it the out-of-tree build dies at __modfinal ("No rule to
# make target '88x2cs.ko'"). vmlinux is then a PARTIAL build (no loadable =m
# modules, no bzImage; ~5 min vs ~10 for a full make) that emits
# vmlinux.symvers with every exported symbol. A complete Module.symvers is
# only written by 'make modules', which we don't need — the driver's deps are
# all =y, so vmlinux.symvers is complete for it. Copy it to Module.symvers so
# a leftover "undefined symbol" means a REAL link break, not a missing symvers.
make $TC modules_prepare
make -j"$(nproc)" $TC vmlinux
cp vmlinux.symvers Module.symvers
