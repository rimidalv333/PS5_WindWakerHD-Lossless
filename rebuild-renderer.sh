#!/usr/bin/env bash
# Wind Waker HD for the PS5 - rebuild the renderer objects of the builder kit with wwhd-lsfg.patch
# (shadow-slice hold + Lossless Scaling frame generation).
#
#   rebuild-renderer.sh KIT_DIR PATCH_FILE            build into KIT_DIR/.rebuild, change nothing else
#   rebuild-renderer.sh KIT_DIR PATCH_FILE --install  ... and put the new objects into KIT_DIR/lib
#
# UNTESTED ON A CONSOLE. It follows the flags of the port's own CMake files (ps5/cmake/ps5-game.cmake,
# vendor/wwhd/CMakeLists.txt); the kit has no compile_commands.json, so they are reconstructed.
# Replaced in the kit: draw.cpp.o, surfaces.cpp.o, backend.cpp.o. Added: the lsfg_*.cpp.o objects
# (and their lines in lib/link.txt). Every other object stays the kit's own.
# Needs: git, network access (clones ZeldaWWHDRecomp and Vulkan-Headers), the kit unzipped.
# Run it where make-title.sh runs (the kit's Docker container, or a Linux with LLVM 22).
#   JOBS   compilers at once (default 3; each can take 1-2 GB)
set -euo pipefail

kit=$(cd -- "${1:?usage: rebuild-renderer.sh KIT_DIR PATCH_FILE [--install]}" && pwd)
patch=$(readlink -f "${2:?missing PATCH_FILE}")
install=false; [[ ${3:-} == --install ]] && install=true
sdk="$kit/sdk"
work="$kit/.rebuild"
fail() { echo "rebuild-renderer.sh: $*" >&2; exit 2; }

# the kit's own build exports these; a bare container does not
[[ -n ${LLVM_CONFIG:-} ]] || { [[ -x /usr/lib/llvm-22/bin/llvm-config ]] && export LLVM_CONFIG=/usr/lib/llvm-22/bin/llvm-config; }
[[ -n ${PS5_CLANG:-} ]] || { [[ -x /usr/lib/llvm-22/bin/clang ]] && export PS5_CLANG=/usr/lib/llvm-22/bin/clang; }
: "${LLVM_CONFIG:?LLVM_CONFIG is not set (/usr/lib/llvm-22/bin/llvm-config)}" "${PS5_CLANG:?PS5_CLANG is not set (/usr/lib/llvm-22/bin/clang)}"

[[ -f $patch ]] || fail "$patch not found"
[[ -f $kit/lib/link.txt ]] || fail "$kit has no lib/link.txt: is it the kit's folder?"
vk=CMakeFiles/wwhd.dir/runtime/src/gfx/vulkan
replaced=(draw surfaces backend)
added=(lsfg_shim lsfg_shaders lsfg_common lsfg_mipmaps lsfg_alpha lsfg_beta lsfg_gamma lsfg_delta lsfg_generate lsfg_chain lsfg_dll lsfg_cut lsfg_present)
for f in "${replaced[@]}"; do
    [[ -f $kit/lib/$vk/$f.cpp.o || -f $kit/lib/$vk/$f.cpp.o.orig ]] || fail "kit has no $f.cpp.o"
done
cxx="$sdk/bin/prospero-clang++"
[[ -x $cxx ]] || fail "$cxx not found; the SDK's compilers are: $(ls "$sdk/bin" | tr '\n' ' ')"
nm="$sdk/bin/llvm-nm"

# ---- the revisions the kit was built from
echo "==> the kit was built from:"
grep -E "PS5_WindWakerHD|ZeldaWWHDRecomp" "$kit/SOURCES.txt" || fail "no SOURCES.txt in the kit"
expected_port=8a2d59a7505d4c1b906fb76f198340afc56691b0
kit_port=$(sed -n 's/^PS5_WindWakerHD  *[^ ]*  *\([0-9a-f]\{7,40\}\).*/\1/p' "$kit/SOURCES.txt")
if [[ $kit_port != "$expected_port" && ${FORCE:-} != 1 ]]; then
    fail "the kit was built from PS5_WindWakerHD ${kit_port:-?}, this patch from $expected_port (FORCE=1 to go on anyway)"
fi
rev=$(sed -n 's/^ZeldaWWHDRecomp  *[^ ]*  *\([0-9a-f]\{7,40\}\).*/\1/p' "$kit/SOURCES.txt")
[[ -n $rev ]] || fail "cannot read ZeldaWWHDRecomp's revision from SOURCES.txt"

mkdir -p "$work"
if [[ ! -d $work/wwhd/.git ]]; then
    git clone -q https://github.com/ZeldaWWHDRecomp/ZeldaWWHDRecomp "$work/wwhd"
fi
git -C "$work/wwhd" checkout -q --force "$rev"
git -C "$work/wwhd" reset -q --hard "$rev" && git -C "$work/wwhd" clean -fdq
git -C "$work/wwhd" apply --check "$patch" || fail "the patch does not apply to ZeldaWWHDRecomp $rev"
git -C "$work/wwhd" apply "$patch"
[[ -d $work/Vulkan-Headers ]] || git clone -q --depth 1 https://github.com/KhronosGroup/Vulkan-Headers "$work/Vulkan-Headers"
# SDL3's headers (backend.cpp uses them; the kit carries none): the revision SOURCES.txt names, headers only
if [[ ! -d $work/SDL/include/SDL3 ]]; then
    sdl_rev=$(sed -n 's/^SDL3  *[^ ]*  *\([^ ]*\).*/\1/p' "$kit/SOURCES.txt")
    [[ $sdl_rev =~ -g([0-9a-f]+)$ ]] && sdl_rev=${BASH_REMATCH[1]}
    rm -rf "$work/SDL"
    git clone -q --filter=blob:none --no-checkout https://github.com/libsdl-org/SDL "$work/SDL"
    git -C "$work/SDL" sparse-checkout set include
    git -C "$work/SDL" checkout -q "${sdl_rev:-release-3.2.8}" 2>/dev/null || {
        echo "(SDL revision '${sdl_rev:-}' not found: using release-3.2.8's headers)"; git -C "$work/SDL" checkout -q release-3.2.8; }
fi

src="$work/wwhd"
cemu="$src/runtime/third_party/cemu"
flags=(
    --sysroot="$sdk/target"
    -DNDEBUG -O3 -g1 -ffunction-sections -fdata-sections -fno-omit-frame-pointer -march=znver2
    -fexperimental-library -std=gnu++20 -ffp-contract=off -w
    -DWWHD_HAS_VULKAN=1 -DWWHD_SDL_HOST=1 -DVK_NO_PROTOTYPES -DENABLE_VULKAN=1
    -include "$cemu/cemu_shim.h"
    -I"$src/runtime/include" -I"$src/runtime/src" -I"$src/runtime/src/gx2"
    -I"$cemu" -I"$cemu/Cafe"
    -I"$src/runtime/third_party/fmt/include" -I"$src/runtime/third_party/xxhash" -I"$src/runtime/third_party/imgui"
    -I"$work/Vulkan-Headers/include"
    -I"$work/SDL/include"
)
mkdir -p "$work/obj"
compile() {
    echo "==> compiling $1.cpp"
    sh "$kit/ps5/tools/cc-init-array.sh" "$cxx" "${flags[@]}" \
        -o "$work/obj/$1.cpp.o" -c "$src/runtime/src/gfx/vulkan/$1.cpp"
}
export -f compile 2>/dev/null || true
pids=(); running=0; jobs=${JOBS:-3}
for f in "${replaced[@]}" "${added[@]}"; do
    compile "$f" &
    pids+=($!); running=$((running + 1))
    if (( running >= jobs )); then wait -n || fail "a compile failed (see above)"; running=$((running - 1)); fi
done
for p in "${pids[@]}"; do wait "$p" || fail "a compile failed (see above)"; done

# ---- checks taken from the kit's own objects (they use the SDK's LLVM 18 libc++, whose names carry the tag
# ne180100, and their initialisers are in .init_array, from cc-init-array.sh)
for f in draw backend; do
    obj="$work/obj/$f.cpp.o"
    "$nm" "$obj" | grep -q 'ne180100' || [[ ${FORCE:-} == 1 ]] ||
        fail "$f.cpp.o was not built against the SDK's libc++ (no ne180100 in its names): the compiler wrapper has not used --sysroot=$sdk/target (FORCE=1 to go on anyway)"
done
for f in draw surfaces backend; do
    grep -aq '\.init_array' "$work/obj/$f.cpp.o" || [[ ${FORCE:-} == 1 ]] ||
        fail "$f.cpp.o has no .init_array: cc-init-array.sh did not take effect (FORCE=1 to go on anyway)"
done

# ---- a mismatch of flags shows here: a replaced object should differ from the kit's by the patch's own
# symbols and by little else
for f in "${replaced[@]}"; do
    old="$kit/lib/$vk/$f.cpp.o"; [[ -f $old.orig ]] && old=$old.orig
    echo "==> symbols that differ in $f.cpp.o (< kit's, > new):"
    syms() { "$nm" -C "$1" | grep -v -e ' \.L' -e 'GCC_except_table' | sed 's/^[0-9a-f]* //' | sort -u; }
    diff <(syms "$old") <(syms "$work/obj/$f.cpp.o") | grep '^[<>]' | head -40 || true
done
echo
if ! $install; then
    echo "Nothing was changed in the kit. Look at the symbol differences above: a handful of lines (ps5_skip_*,"
    echo "lsfg_*, g_lsfgDevice) is expected, a long list means the flags differ."
    echo "To use the new objects:  $0 $kit $patch --install"
    exit 0
fi
for f in "${replaced[@]}"; do
    old="$kit/lib/$vk/$f.cpp.o"
    [[ -f $old.orig ]] || cp "$old" "$old.orig"
    cp "$work/obj/$f.cpp.o" "$old"
done
for f in "${added[@]}"; do cp "$work/obj/$f.cpp.o" "$kit/lib/$vk/$f.cpp.o"; done
[[ -f $kit/lib/link.txt.orig ]] || cp "$kit/lib/link.txt" "$kit/lib/link.txt.orig"
for f in "${added[@]}"; do
    grep -qxF "$vk/$f.cpp.o" "$kit/lib/link.txt" || sed -i "s#^$vk/surfaces\.cpp\.o\$#&\n$vk/$f.cpp.o#" "$kit/lib/link.txt"
done
for f in "${added[@]}"; do grep -qxF "$vk/$f.cpp.o" "$kit/lib/link.txt" || fail "could not add $f to lib/link.txt"; done
rm -rf "$work"  # (a Docker build copies the whole kit folder: keep the clones out of it)
echo "==> installed. The kit's originals are kept as *.orig beside them (lib/link.txt too)."
echo "    Remove the Docker image (docker rmi wwhd-ps5-kit:<version>), run make-title.sh again (it reuses the"
echo "    compiled game code and only links), copy the new eboot.bin to the console, and put Lossless.dll"
echo "    beside env.txt with WWHD_PS5_LSFG=1 in env.txt."
