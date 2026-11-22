#!/bin/bash
# Build kernel.development.sweet on a Mac, with the same steps as
# .github/workflows/xnu.yml (which is the reference: macos-14 + Xcode 15).
#
#   tools/build-xnu-macos.sh            # build, output in xnu/out/
#   XCODE=/Applications/Xcode_15.2.app tools/build-xnu-macos.sh
#
# Needs: full Xcode 15.x (not just Command Line Tools; `xcrun --find iig`
# must work), Homebrew, ~30 GB free.  Xcode 16 breaks xnu-8796: its iig emits
# IORPC.kernelContent, which this kernel's IOKit ABI does not have.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$PWD

DXB_REPO=${DXB_REPO:-https://github.com/blacktop/darwin-xnu-build}
DXB_SHA=${DXB_SHA:-663906528d1cd5ea8fde7de6f16de73db9511549}
export MACOS_VERSION=${MACOS_VERSION:-13.5}
export KERNEL_CONFIG=${KERNEL_CONFIG:-DEVELOPMENT}
export MACHINE_CONFIG=${MACHINE_CONFIG:-SWEET}

# --- toolchain ------------------------------------------------------------
XC=${XCODE:-$(ls -d /Applications/Xcode_15*.app 2>/dev/null | sort -V | tail -1)}
if [ -z "$XC" ] || [ ! -d "$XC" ]; then
	echo "No Xcode 15 found. Install Xcode 15.x, or set XCODE=/Applications/Xcode_15.x.app" >&2
	echo "Xcode 16 will NOT work: its iig breaks the xnu-8796 IORPC ABI." >&2
	exit 1
fi
export DEVELOPER_DIR="$XC/Contents/Developer"
echo "== Xcode: $XC"
xcodebuild -version
xcrun --find iig >/dev/null || {
	echo "iig missing: that Xcode is Command Line Tools only, not a full Xcode" >&2
	exit 1
}

for t in jq gum bash cmake ninja ccache git; do
	command -v "$t" >/dev/null || brew install "$t"
done

# build.sh only checks that `xcodes` exists (Xcode is already installed).
if ! command -v xcodes >/dev/null; then
	sudo mkdir -p /usr/local/bin
	printf '#!/bin/sh\nexit 0\n' | sudo tee /usr/local/bin/xcodes >/dev/null
	sudo chmod +x /usr/local/bin/xcodes
fi

# --- sources --------------------------------------------------------------
if [ ! -d dxb/.git ]; then
	git init -q dxb
	git -C dxb fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA"
	git -C dxb checkout -q FETCH_HEAD
fi
cp xnu/patches/*.patch xnu/patches/*.sh dxb/patches/
python3 tools/require-port-patches.py dxb/build.sh

# Same three edits as the workflow, idempotent so a re-run is harmless.
python3 - <<'PY'
from pathlib import Path
p = Path('dxb/build.sh')
s = p.read_text()
s = s.replace('ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"',
              'ARCHS="arm64" VALID_ARCHS="arm64" '
              'OTHER_CFLAGS="-mkernel -nostdinc -Wno-packed -mcpu=cortex-a53"')
s = s.replace('export CC="$(xcrun -find clang)"', 'export CC="$CCACHE_WRAP/clang"')
s = s.replace('export CXX="$(xcrun -find clang++)"', 'export CXX="$CCACHE_WRAP/clang++"')
p.write_text(s)
PY
grep -c 'mcpu=cortex-a53' dxb/build.sh

# --- ccache wrappers ------------------------------------------------------
export CCACHE_DIR=$ROOT/.ccache
export CCACHE_BASEDIR=$ROOT
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime,file_macro,pch_defines
export CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-3G}
export CCACHE_WRAP=$ROOT/ccache-bin
mkdir -p "$CCACHE_WRAP"
for t in clang clang++; do
	printf '#!/bin/sh\nexec ccache %s "$@"\n' "$(xcrun -find $t)" >"$CCACHE_WRAP/$t"
	chmod +x "$CCACHE_WRAP/$t"
done

# --- build ----------------------------------------------------------------
cd dxb
export MAKEFLAGS=${MAKEFLAGS:--k}
ccache -z
bash build.sh
ccache -s

# --- collect --------------------------------------------------------------
cd "$ROOT"
mkdir -p xnu/out
cp -R dxb/fakeroot/System/Library/Kernels/. xnu/out/ 2>/dev/null || true
ls -l xnu/out/
( cd xnu/out && shasum -a 256 kernel.* >SHA256SUMS ) || true
cat xnu/out/SHA256SUMS 2>/dev/null || true
echo "Kernel config: $KERNEL_CONFIG, machine: $MACHINE_CONFIG"
