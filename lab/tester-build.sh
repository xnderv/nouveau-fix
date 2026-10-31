#!/bin/bash
# nouveau-fix lab driver: build (and optionally install) the lab nouveau module for the RUNNING kernel. For testers.
#   bash lab/tester-build.sh                 — fetch nouveau sources for this kernel (sparse git clone of the matching
#                                              upstream tag from github.com/gregkh/linux, ~15 MB), apply the patches, build
#   SRC=/path/to/linux bash lab/tester-build.sh — use your own kernel source tree instead (e.g. the one your kernel was built from)
#   bash lab/tester-build.sh install         — then install the built module (asks for sudo), depmod, update-initramfs
#   bash lab/tester-build.sh remove          — remove the lab module again (back to your distribution's nouveau)
# Needs: git, make, gcc, and the headers of the running kernel (Debian/Ubuntu: sudo apt install linux-headers-$(uname -r)).
# Patches (from this repository, in this order): 0001 (channel teardown race), lab/0002 (instrumented reclocking, core
# clocks computed from the card's VBIOS with lab_vbios_src=1), 0004 (PMU load counters), 0006 (fan PWM read).
# The module goes to /lib/modules/<kernel>/updates/nouveau-fix/nouveau.ko; the distribution's nouveau stays untouched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; KIT="$(dirname "$HERE")"
KVER="$(uname -r)"; KBUILD="/lib/modules/$KVER/build"
WORK="${WORK:-$HOME/nouveau-fix-build/$KVER}"
SLOT="/lib/modules/$KVER/updates/nouveau-fix/nouveau.ko"
PATCHES=("$KIT/patches/0001-nouveau-abi16-idle-channel-before-engobj-del.patch" "$HERE/0002-LAB-fermi-reclock-instrumented.patch"
         "$KIT/patches/0004-LAB-pmu-perf-load.patch" "$KIT/patches/0006-nouveau-therm-mask-pwm-update-bit-on-read.patch")
die() { echo "STOP: $*"; exit 1; }

case "${1:-build}" in
build)
    command -v git >/dev/null || die "git is missing (sudo apt install git)"
    command -v make >/dev/null && command -v gcc >/dev/null || die "make/gcc missing (sudo apt install build-essential)"
    [ -e "$KBUILD/Makefile" ] || die "no headers for the running kernel $KVER (sudo apt install linux-headers-$KVER)"
    rm -rf "$WORK"; mkdir -p "$WORK"
    if [ -n "${SRC:-}" ]; then
        [ -d "$SRC/drivers/gpu/drm/nouveau" ] || die "SRC=$SRC has no drivers/gpu/drm/nouveau"
        cp -r "$SRC/drivers/gpu/drm/nouveau" "$WORK/nouveau"
        echo "=== sources: $SRC (your tree)"
    else
        V="$(make -s -C "$KBUILD" kernelversion 2>/dev/null | tail -n 1 || true)"
        [[ "$V" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || V="$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{if(v!="") print v"."p"."s}' "$KBUILD/Makefile")"
        TAG="v${V%.0}"
        echo "=== kernel $KVER, upstream $V: fetching drivers/gpu/drm/nouveau of tag $TAG from github.com/gregkh/linux"
        git clone -q --filter=blob:none --no-checkout --depth 1 --branch "$TAG" https://github.com/gregkh/linux.git "$WORK/src" \
            || die "could not fetch tag $TAG; run with SRC=/path/to/your/kernel/source instead"
        git -C "$WORK/src" sparse-checkout set drivers/gpu/drm/nouveau
        git -C "$WORK/src" checkout -q
        cp -r "$WORK/src/drivers/gpu/drm/nouveau" "$WORK/nouveau"; rm -rf "$WORK/src"
    fi
    cd "$WORK/nouveau"
    for P in "${PATCHES[@]}"; do
        [ -r "$P" ] || die "patch not found: $P"
        if patch -p1 --dry-run -s < "$P" > "$WORK/dry.txt" 2>&1; then
            patch -p1 < "$P" > "$WORK/patch-$(basename "$P").txt" 2>&1
            echo "  applied $(basename "$P")$(grep -qE 'fuzz' "$WORK/patch-$(basename "$P").txt" && echo ' (with fuzz — please mention it)')"
        else
            cat "$WORK/dry.txt"; die "$(basename "$P") does not apply to these sources. Nothing was built or installed; please send this output."
        fi
    done
    echo "=== building (a few minutes)..."
    make -C "$KBUILD" M="$WORK/nouveau" -j"$(nproc)" modules > "$WORK/build.log" 2>&1 \
        || { tail -n 25 "$WORK/build.log"; die "build failed; nothing installed. Please send $WORK/build.log"; }
    KO="$WORK/nouveau/nouveau.ko"
    VM="$(modinfo -F vermagic "$KO")"; [ "${VM%% *}" = "$KVER" ] || die "the module was not built for $KVER ($VM)"
    PRMS="$(modinfo -p "$KO")"; [[ "$PRMS" == *lab_vbios_src:* ]] || die "the built module has no lab_vbios_src parameter (old patch?)"
    echo "=== built: $KO, srcversion $(modinfo -F srcversion "$KO")"
    echo "    next: bash $0 install"
    ;;
install)
    KO="$WORK/nouveau/nouveau.ko"
    [ -e "$KO" ] || die "build first: bash $0"
    VM="$(modinfo -F vermagic "$KO")"; [ "${VM%% *}" = "$KVER" ] || die "the built module is not for the running kernel $KVER; build again"
    echo "Installing $KO (srcversion $(modinfo -F srcversion "$KO")) to $SLOT (sudo)"
    sudo install -D -m 644 "$KO" "$SLOT"
    sudo depmod -a "$KVER"
    if command -v update-initramfs >/dev/null; then sudo update-initramfs -u -k "$KVER"
    elif command -v dracut >/dev/null; then sudo dracut -f --kver "$KVER"; fi
    echo "=== installed. Set the options line in /etc/modprobe.d/nouveau-lab.conf (see the instructions), update the"
    echo "    initramfs once more if you changed it, and reboot. Undo at any time: bash $0 remove"
    ;;
remove)
    sudo rm -f "$SLOT"; sudo depmod -a "$KVER"
    if command -v update-initramfs >/dev/null; then sudo update-initramfs -u -k "$KVER"
    elif command -v dracut >/dev/null; then sudo dracut -f --kver "$KVER"; fi
    echo "=== lab module removed; after a reboot your distribution's nouveau is used (or delete /etc/modprobe.d/nouveau-lab.conf too)"
    ;;
*)
    sed -n '2,12p' "$0"; exit 1 ;;
esac
