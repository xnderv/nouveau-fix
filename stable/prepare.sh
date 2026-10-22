#!/bin/bash
# DKMS PRE_BUILD: put the nouveau source matching kernel $1 into ./nouveau and apply patches/.
# The pristine source is cached in /var/cache/nouveau-gf114/nouveau-<linux version>.tar so that a kernel
# update does not need the network when its upstream base is unchanged.
set -euo pipefail
KVER="$1"; HERE="$(cd "$(dirname "$0")" && pwd)"; cd "$HERE"
KBUILD="/lib/modules/$KVER/build"
[ -e "$KBUILD/Makefile" ] || { echo "no kernel headers for $KVER"; exit 1; }
UPV="$(make -s -C "$KBUILD" kernelversion 2>/dev/null | tail -n 1 || true)"
if ! [[ "$UPV" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    MF="/usr/src/linux-headers-${KVER%-generic}/Makefile"; [ -r "$MF" ] || MF="$KBUILD/Makefile"
    UPV="$(awk -F' = ' '/^VERSION =/{v=$2} /^PATCHLEVEL =/{p=$2} /^SUBLEVEL =/{s=$2} END{if(v!="") print v"."p"."s}' "$MF")"
fi
[[ "$UPV" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "cannot determine upstream Linux version for $KVER (got '$UPV')"; exit 1; }
TAG="v${UPV%.0}"
CACHE=/var/cache/nouveau-gf114; TAR="$CACHE/nouveau-$UPV.tar"
rm -rf nouveau src
if [ -s "$TAR" ]; then
    echo "nouveau-gf114: using cached nouveau source for Linux $UPV"
    tar -xf "$TAR"
else
    echo "nouveau-gf114: fetching nouveau source for Linux $UPV ($TAG)"
    command -v git >/dev/null || { echo "git is required (apt install git)"; exit 1; }
    git clone -q --filter=blob:none --no-checkout --depth 1 --branch "$TAG" https://github.com/gregkh/linux.git src
    git -C src sparse-checkout set drivers/gpu/drm/nouveau
    git -C src checkout -q
    cp -r src/drivers/gpu/drm/nouveau nouveau; rm -rf src
    mkdir -p "$CACHE" && tar -cf "$TAR.tmp" nouveau && mv "$TAR.tmp" "$TAR" || true
fi
cd nouveau
for P in "$HERE"/patches/*.patch; do
    # <patch>.needs = "file|pattern": apply only while the pattern is still in the file (i.e. the bug is still there)
    if [ -r "$P.needs" ]; then
        NF="$(cut -d'|' -f1 "$P.needs")"; NP="$(cut -d'|' -f2- "$P.needs")"
        if ! grep -qF -- "$NP" "$NF" 2>/dev/null; then
            echo "nouveau-gf114: $(basename "$P") not needed for Linux $UPV (already fixed upstream), skipped"; continue
        fi
    fi
    if patch -p1 -s -N --dry-run < "$P" >/dev/null 2>&1; then
        patch -p1 -s -N < "$P"; echo "nouveau-gf114: applied $(basename "$P")"
    elif patch -p1 -s -R --dry-run < "$P" >/dev/null 2>&1; then
        echo "nouveau-gf114: $(basename "$P") is already part of Linux $UPV, skipped"
    else
        echo "nouveau-gf114: $(basename "$P") does not apply to Linux $UPV — the patch needs updating"; exit 2
    fi
done
