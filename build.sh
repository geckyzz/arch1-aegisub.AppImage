#!/usr/bin/env bash
# =============================================================================
# build.sh
# Builds arch1t3cht/Aegisub (migration03-02) as an AppImage on Fedora,
# with DependencyControl and Aegisub-DiscordRPC bundled.
#
# Usage:
#   chmod +x build.sh
#   ./build.sh [--skip-deps] [--skip-luajit]
#
# Flags:
#   --skip-deps    Skip dnf install (if deps already installed)
#   --skip-luajit  Skip LuaJIT build (if already built + installed to /usr/local)
#
# Output: Aegisub-migration03-02-x86_64.AppImage in the current directory.
# =============================================================================

set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/arch1t3cht/Aegisub.git"
BRANCH="migration03-02"
BUILD_DIR="$(pwd)/aegisub-build"
SOURCE_DIR="$BUILD_DIR/src"
INSTALL_DIR="$BUILD_DIR/install"
APPDIR="$BUILD_DIR/AppDir"
TOOLS_DIR="$BUILD_DIR/tools"
ARCH="$(uname -m)"   # x86_64 or aarch64
VERSION="migration03-02"
OUTPUT_NAME="Aegisub-${VERSION}-${ARCH}.AppImage"
CACHE_DIR="$BUILD_DIR/cache"
EXTRA_DICTS=()


# Keep track of temporary directories for cleanup via EXIT trap
declare -a TEMP_DIRS=()
cleanup() {
    if [[ ${#TEMP_DIRS[@]} -gt 0 ]]; then
        info "Cleaning up temporary directories..."
        rm -rf "${TEMP_DIRS[@]}"
    fi
}
trap cleanup EXIT

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "${BLUE}==== $* ====${NC}"; }

need_cmd() { command -v "$1" &>/dev/null || error "Required command not found: $1"; }

# =============================================================================
# 1. INSTALL BUILD DEPENDENCIES
# =============================================================================
install_deps() {
    step "Installing Build Dependencies"
    local os_id="" os_like=""
    if [[ -f /etc/os-release ]]; then
        os_id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
        os_like="$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
    fi

    if [[ "$os_id" == "fedora" || "$os_like" =~ "fedora" ]]; then
        info "Installing build dependencies via dnf..."

        # Enable RPM Fusion free repo if not already enabled (needed for ffms2, ffmpeg)
        if ! rpm -q rpmfusion-free-release &>/dev/null; then
            info "Enabling RPM Fusion free repository..."
            sudo dnf install -y \
                "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
        fi

        sudo dnf install -y \
            git gcc gcc-c++ meson ninja-build cmake pkg-config gettext intltool \
            boost-devel \
            wxGTK-devel \
            libicu-devel \
            zlib-devel \
            libass-devel \
            ffms2-devel \
            fftw-devel \
            hunspell-devel \
            uchardet-devel \
            libcurl-devel \
            openal-soft-devel \
            pulseaudio-libs-devel \
            alsa-lib-devel \
            mesa-libGL-devel \
            fontconfig-devel \
            freetype-devel \
            gtest-devel \
            desktop-file-utils \
            squashfs-tools \
            fuse fuse-libs \
            patchelf \
            wget curl unzip \
            vapoursynth-devel \
            lua5.1-filesystem \
            lua5.1-socket \
            lua-moonscript \
            wayland-devel \
            libxkbcommon-devel
    elif [[ "$os_id" == "ubuntu" || "$os_id" == "debian" || "$os_like" =~ "debian" || "$os_like" =~ "ubuntu" ]]; then
        info "Installing build dependencies via apt..."
        sudo apt-get update

        # Determine wxGTK package name (varies across Ubuntu/Debian versions)
        local wx_pkg="libwxgtk3.2-dev"
        if ! apt-cache show "$wx_pkg" &>/dev/null; then
            wx_pkg="libwxgtk3.0-gtk3-dev"
        fi

        # Determine Lua 5.1 dependencies
        local lua_fs="lua-filesystem"
        local lua_socket="lua-socket"
        local moonscript_pkg="moonscript"

        sudo apt-get install -y \
            git build-essential meson ninja-build cmake pkg-config gettext intltool \
            libboost-dev "$wx_pkg" libicu-dev zlib1g-dev libass-dev \
            libffms2-dev libfftw3-dev libhunspell-dev libuchardet-dev libcurl4-openssl-dev \
            libopenal-dev libpulse-dev libasound2-dev libgl1-mesa-dev \
            libfontconfig1-dev libfreetype6-dev libgtest-dev desktop-file-utils \
            squashfs-tools fuse libfuse2 patchelf wget curl unzip \
            libvapoursynth-dev "$lua_fs" "$lua_socket" "$moonscript_pkg" \
            libwayland-dev libxkbcommon-dev
    else
        warn "Unsupported OS distribution '$os_id'. Skipping automatic package dependency installation."
        warn "Please ensure you have equivalent build dependencies installed."
    fi

    mkdir -p "$CACHE_DIR"
    info "Dependencies installed."
}

# =============================================================================
# 2. BUILD LUAJIT WITH LUA 5.2 COMPAT
#
# CRITICAL: Fedora's packaged luajit is NOT compiled with LUAJIT_ENABLE_LUA52COMPAT.
# Aegisub's meson build runs a runtime test (tests/tests/luajit_52.c) and will
# refuse to use system luajit if it fails. Almost all automation scripts
# (DependencyControl, moonscript, DiscordRPC via ffi, etc.) break without this.
# We build from the exact commit Aegisub's wrap file references for consistency.
# =============================================================================
build_luajit() {
    if /usr/local/bin/luajit -e \
        "if table.pack then os.exit(0) else os.exit(1) end" 2>/dev/null; then
        info "LuaJIT with Lua 5.2 compat already installed at /usr/local, skipping."
        return 0
    fi

    step "Building LuaJIT with Lua 5.2 Compatibility"

    local luajit_src
    luajit_src="$(mktemp -d)"
    TEMP_DIRS+=("$luajit_src")

    # Same commit as in src/subprojects/luajit.wrap — keeps versions in sync
    local LUAJIT_COMMIT="04dca7911ea255f37be799c18d74c305b921c1a6"
    local luajit_archive="$CACHE_DIR/luajit-${LUAJIT_COMMIT}.tar.gz"
    if [[ ! -f "$luajit_archive" ]]; then
        info "Downloading LuaJIT archive..."
        curl -fsSL -L -o "$luajit_archive" \
            "https://github.com/LuaJIT/LuaJIT/archive/${LUAJIT_COMMIT}.tar.gz"
    fi
    tar -xz -C "$luajit_src" --strip-components=1 -f "$luajit_archive"

    make -C "$luajit_src" -j"$(nproc)" XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT"
    sudo make -C "$luajit_src" install \
        PREFIX=/usr/local \
        XCFLAGS="-DLUAJIT_ENABLE_LUA52COMPAT"

    # Register /usr/local/lib so the linker and meson's run-test find it
    if [[ -d /etc/ld.so.conf.d ]]; then
        echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/luajit-local.conf
    fi
    sudo ldconfig

    # Verify 5.2 compat (table.pack is the canary)
    if /usr/local/bin/luajit \
        -e "if table.pack then os.exit(0) else os.exit(1) end"; then
        info "LuaJIT 5.2 compat verified OK."
    else
        error "LuaJIT 5.2 compat test failed after build."
    fi
}

# =============================================================================
# 3. DOWNLOAD APPIMAGE TOOLING
# =============================================================================
fetch_tooling() {
    step "Downloading AppImage Tooling"
    mkdir -p "$TOOLS_DIR"

    # linuxdeploy — assembles AppDir and bundles shared library deps
    local linuxdeploy_bin="$TOOLS_DIR/linuxdeploy-${ARCH}.AppImage"
    if [[ ! -f "$linuxdeploy_bin" ]]; then
        info "Downloading linuxdeploy..."
        curl -fsSL -L -o "$linuxdeploy_bin" \
            "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${ARCH}.AppImage"
        chmod +x "$linuxdeploy_bin"
    fi

    # Extract linuxdeploy and remove its bundled patchelf to force it to use system's patchelf (fixes DT_RELR / .relr.dyn corruption)
    LINUXDEPLOY="$TOOLS_DIR/linuxdeploy-extracted/AppRun"
    if [[ ! -f "$LINUXDEPLOY" ]]; then
        info "Extracting linuxdeploy and unbundling patchelf..."
        rm -rf "$TOOLS_DIR/linuxdeploy-extracted"
        mkdir -p "$TOOLS_DIR/linuxdeploy-extracted"
        (
            cd "$TOOLS_DIR"
            ./linuxdeploy-${ARCH}.AppImage --appimage-extract >/dev/null
            mv squashfs-root/* linuxdeploy-extracted/
            rm -rf squashfs-root
        )
        rm -f "$TOOLS_DIR/linuxdeploy-extracted/usr/bin/patchelf"
        info "linuxdeploy extracted. Forced to use system patchelf."
    fi

    # GTK plugin — bundles GTK3/GLib runtime assets needed by wxWidgets
    LINUXDEPLOY_GTK="$TOOLS_DIR/linuxdeploy-plugin-gtk.sh"
    if [[ ! -f "$LINUXDEPLOY_GTK" ]]; then
        info "Downloading linuxdeploy GTK plugin..."
        curl -fsSL -o "$LINUXDEPLOY_GTK" \
            "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"
        chmod +x "$LINUXDEPLOY_GTK"
    fi

    # AppImage output plugin — calls appimagetool internally
    LINUXDEPLOY_APPIMAGE="$TOOLS_DIR/linuxdeploy-plugin-appimage-${ARCH}.AppImage"
    if [[ ! -f "$LINUXDEPLOY_APPIMAGE" ]]; then
        info "Downloading linuxdeploy AppImage plugin..."
        curl -fsSL -L -o "$LINUXDEPLOY_APPIMAGE" \
            "https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-${ARCH}.AppImage"
        chmod +x "$LINUXDEPLOY_APPIMAGE"
    fi

    export PATH="$TOOLS_DIR:$PATH"
}

# =============================================================================
# 4. CLONE SOURCE
# =============================================================================
clone_source() {
    step "Cloning Aegisub Source Code"
    if [[ -d "$SOURCE_DIR/.git" ]]; then
        info "Source already cloned; updating..."
        git -C "$SOURCE_DIR" fetch --depth=1 origin "$BRANCH"
        git -C "$SOURCE_DIR" checkout FETCH_HEAD
        git -C "$SOURCE_DIR" submodule update --init --recursive --depth=1
    else
        info "Cloning $BRANCH ..."
        git clone --depth=1 --branch "$BRANCH" \
            --recurse-submodules --shallow-submodules \
            "$REPO_URL" "$SOURCE_DIR"
    fi

    # BestSource embeds a libp2p symlink that breaks git on re-clone; remove it
    if [[ -L "$SOURCE_DIR/subprojects/bestsource/libp2p" ]]; then
        warn "Removing bestsource/libp2p symlink (known git issue)..."
        rm "$SOURCE_DIR/subprojects/bestsource/libp2p"
    fi

    # Patch libaegisub/unix/path.cpp to correctly set ?data path for AppImage
    info "Patching libaegisub path token for AppImage support..."
    git -C "$SOURCE_DIR" checkout libaegisub/unix/path.cpp 2>/dev/null || true
    sed -i 's|if (data == "") data = home/".aegisub";|if (data != "") data = data.parent_path() / "share" / "aegisub"; if (data == "") data = home/".aegisub";|' "$SOURCE_DIR/libaegisub/unix/path.cpp"
}

# =============================================================================
# 5. BUILD WITH MESON
# =============================================================================
build() {
    step "Compiling Aegisub with Meson"
    local build_subdir="$BUILD_DIR/meson-build"

    info "Configuring meson..."

    # Key flags:
    #   --prefix=/usr          linuxdeploy expects binaries/data under usr/
    #   --buildtype=release    optimised, no debug symbols
    #   --strip                strip binary (reduces AppImage size)
    #   -Db_lto=false          REQUIRED — Aegisub cannot be built with LTO
    #   -Dsystem_luajit=true   use our /usr/local luajit (5.2 compat confirmed)
    #   -Davisynth=disabled    AviSynth is Windows-only
    #   -Dtests=false          skip test binaries (saves time)
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig" \
    meson setup "$build_subdir" "$SOURCE_DIR" \
        --prefix=/usr \
        --buildtype=release \
        --strip \
        -Db_lto=false \
        -Dsystem_luajit=true \
        -Davisynth=disabled \
        -Denable_update_checker=false \
        -Dcpp_args='-DAPPIMAGE_BUILD' \
        -Dc_args='-DAPPIMAGE_BUILD' \
        -Dtests=false

    info "Compiling (this takes a few minutes)..."
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/lib64/pkgconfig:/usr/share/pkgconfig" \
    meson compile -C "$build_subdir" -j"$(nproc)"

    info "Installing to staging directory..."
    DESTDIR="$INSTALL_DIR" meson install -C "$build_subdir"
    info "Build complete."
}

# =============================================================================
# 6. BUNDLE DEPENDENCYCONTROL
# =============================================================================
bundle_depctrl() {
    step "Bundling DependencyControl"

    local AUTOLOAD="$INSTALL_DIR/usr/share/aegisub/automation/autoload"
    local INCLUDE="$INSTALL_DIR/usr/share/aegisub/automation/include"
    mkdir -p "$AUTOLOAD" "$INCLUDE/l0/DependencyControl"

    # 1. Download and extract DependencyControl
    local archive="$CACHE_DIR/depctrl-stable-v0.6.3-alpha.zip"
    if [[ ! -f "$archive" ]]; then
        curl -fsSL -L -o "$archive" \
            "https://github.com/TypesettingTools/DependencyControl/archive/refs/tags/v0.6.3-alpha.zip"
    fi
    local depctrl_temp
    depctrl_temp="$(mktemp -d)"
    TEMP_DIRS+=("$depctrl_temp")
    unzip -q -o "$archive" -d "$depctrl_temp"

    local SRC="$depctrl_temp/DependencyControl-0.6.3-alpha"

    # Main module (must be in include/l0/ to be required as "l0.DependencyControl")
    cp "$SRC/modules/DependencyControl.moon"            "$INCLUDE/l0/DependencyControl.moon"
    # Toolbox macro (optional UI for managing installed scripts, goes in autoload)
    cp "$SRC/macros/l0.DependencyControl.Toolbox.moon"  "$AUTOLOAD/"
    # Sub-modules required at runtime by DependencyControl.moon
    cp "$SRC/modules/DependencyControl/"*.moon          "$INCLUDE/l0/DependencyControl/"
    # Feed JSON (used to resolve script update URLs)
    cp "$SRC/DependencyControl.json"                    "$INSTALL_DIR/usr/share/aegisub/"

    # 2. Download and compile ffi-experiments (provides BadMutex, PreciseTimer, requireffi, DownloadManager)
    info "Compiling and bundling ffi-experiments..."
    local FFI_EXP_COMMIT="b8897ead55b84ec4148e900882bff8336b38f939"
    local ffiexp_archive="$CACHE_DIR/ffi-experiments-${FFI_EXP_COMMIT}.tar.gz"
    if [[ ! -f "$ffiexp_archive" ]]; then
        curl -fsSL -L -o "$ffiexp_archive" \
            "https://github.com/TypesettingTools/ffi-experiments/archive/${FFI_EXP_COMMIT}.tar.gz"
    fi
    local ffiexp_temp
    ffiexp_temp="$(mktemp -d)"
    TEMP_DIRS+=("$ffiexp_temp")
    tar -xzf "$ffiexp_archive" -C "$ffiexp_temp" --strip-components=1

    (
        cd "$ffiexp_temp"
        rm -rf build
        meson setup build
        meson compile -C build
    )

    # Copy ffi-experiments Lua and compiled .so libraries
    mkdir -p "$INCLUDE/BM/BadMutex" "$INCLUDE/DM/DownloadManager" "$INCLUDE/PT/PreciseTimer" "$INCLUDE/requireffi"
    cp "$ffiexp_temp/build/bad-mutex/BadMutex.lua"                 "$INCLUDE/BM/BadMutex.lua"
    cp "$ffiexp_temp/build/bad-mutex/libBadMutex.so"               "$INCLUDE/BM/BadMutex/libBadMutex.so"
    cp "$ffiexp_temp/build/download-manager/DownloadManager.lua"   "$INCLUDE/DM/DownloadManager.lua"
    cp "$ffiexp_temp/build/download-manager/libDownloadManager.so" "$INCLUDE/DM/DownloadManager/libDownloadManager.so"
    cp "$ffiexp_temp/build/precise-timer/PreciseTimer.lua"         "$INCLUDE/PT/PreciseTimer.lua"
    cp "$ffiexp_temp/build/precise-timer/libPreciseTimer.so"       "$INCLUDE/PT/PreciseTimer/libPreciseTimer.so"
    cp "$ffiexp_temp/build/requireffi/requireffi.lua"              "$INCLUDE/requireffi/requireffi.lua"

    # 3. Download and bundle luajson (v1.3.3)
    info "Bundling luajson..."
    local luajson_archive="$CACHE_DIR/luajson-1.3.3.tar.gz"
    if [[ ! -f "$luajson_archive" ]]; then
        curl -fsSL -L -o "$luajson_archive" \
            "https://github.com/harningt/luajson/archive/1.3.3.tar.gz"
    fi
    local luajson_temp
    luajson_temp="$(mktemp -d)"
    TEMP_DIRS+=("$luajson_temp")
    tar -xzf "$luajson_archive" -C "$luajson_temp" --strip-components=1

    cp -f "$luajson_temp/lua/json.lua" "$INCLUDE/"
    cp -rf "$luajson_temp/lua/json"     "$INCLUDE/"

    info "DependencyControl and dependencies bundled."
}

# =============================================================================
# 7. BUNDLE DISCORD RPC
#
# The plugin uses LuaJIT's FFI to load libdiscord-rpc.so at runtime via:
#   ffi.load("discord-rpc")
#
# On Linux, ffi.load() expands "discord-rpc" → "libdiscord-rpc.so" and
# searches LD_LIBRARY_PATH, then the standard linker cache. Inside an AppImage,
# linuxdeploy sets up AppRun to prepend $APPDIR/usr/lib to LD_LIBRARY_PATH,
# so placing the .so there makes ffi.load() find it automatically.
#
# The plugin lua script goes in automation/autoload so Aegisub loads it on startup.
# =============================================================================
bundle_discord_rpc() {
    step "Bundling Aegisub-DiscordRPC"

    local AUTOLOAD="$INSTALL_DIR/usr/share/aegisub/automation/autoload"
    local LIB_DIR="$INSTALL_DIR/usr/lib"
    mkdir -p "$AUTOLOAD" "$LIB_DIR"

    # ── .so library ──────────────────────────────────────────────────────────
    # Source priority (first found wins):
    #   1. discord-rpc-linux.zip next to this script (user-provided, as uploaded)
    #   2. libdiscord-rpc.so shipped in the plugin repo (same binary, different path)
    #   3. Download directly from the repo
    local SO_SRC=""
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "$SCRIPT_DIR/discord-rpc-linux.zip" ]]; then
        info "Extracting libdiscord-rpc.so from discord-rpc-linux.zip..."
        unzip -p "$SCRIPT_DIR/discord-rpc-linux.zip" \
            "discord-rpc/linux-dynamic/lib/libdiscord-rpc.so" \
            > "$LIB_DIR/libdiscord-rpc.so"
        SO_SRC="zip"
    else
        local rpc_so="$CACHE_DIR/libdiscord-rpc.so"
        if [[ ! -f "$rpc_so" ]]; then
            info "Downloading libdiscord-rpc.so from Aegisub-DiscordRPC repo..."
            curl -fsSL -L \
                "https://github.com/mnh48/Aegisub-DiscordRPC/raw/master/libdiscord-rpc.so" \
                -o "$rpc_so"
        fi
        cp "$rpc_so" "$LIB_DIR/libdiscord-rpc.so"
        SO_SRC="download"
    fi

    chmod 755 "$LIB_DIR/libdiscord-rpc.so"

    # Verify it's a valid ELF shared object for the right arch
    local so_info
    so_info="$(file "$LIB_DIR/libdiscord-rpc.so")"
    if ! echo "$so_info" | grep -q "ELF 64-bit"; then
        error "libdiscord-rpc.so does not appear to be a 64-bit ELF: $so_info"
    fi
    info "libdiscord-rpc.so OK ($SO_SRC): $so_info"

    # ── Lua script ────────────────────────────────────────────────────────────
    local rpc_lua="$CACHE_DIR/discord-rpc.lua"
    if [[ ! -f "$rpc_lua" ]]; then
        info "Downloading discord-rpc.lua..."
        curl -fsSL \
            "https://raw.githubusercontent.com/mnh48/Aegisub-DiscordRPC/master/discord-rpc.lua" \
            -o "$rpc_lua"
    fi
    cp "$rpc_lua" "$AUTOLOAD/discord-rpc.lua"

    # ── Patch ffi.load path ───────────────────────────────────────────────────
    # Inside an AppImage, the working directory at startup is not usr/lib.
    # ffi.load("discord-rpc") works if LD_LIBRARY_PATH contains the .so dir,
    # which linuxdeploy's AppRun sets up. But as a belt-and-suspenders fallback,
    # we patch the script to also try loading by absolute path via APPDIR env var.
    # We insert a small preamble after the first `local ffi = require "ffi"` line.
    python3 - "$AUTOLOAD/discord-rpc.lua" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    src = f.read()

preamble = r'''
-- AppImage compatibility: if ffi.load("discord-rpc") fails (library not in
-- LD_LIBRARY_PATH yet), fall back to an absolute path inside the AppImage.
local _discord_rpc_load_ok, _discord_rpc_load_err = pcall(function()
    local ffi = require "ffi"
    -- Try standard name first (works when LD_LIBRARY_PATH is set by AppRun)
    local ok, err = pcall(function() ffi.load("discord-rpc") end)
    if not ok then
        -- Fall back to APPDIR-relative path (AppImage sets $APPDIR at runtime)
        local appdir = os.getenv("APPDIR") or ""
        ffi.load(appdir .. "/usr/lib/libdiscord-rpc.so")
    end
end)
'''

# Insert preamble right after `local ffi = require "ffi"` line
patched = re.sub(
    r'(local ffi = require "ffi"\n)',
    r'\1' + preamble + '\n',
    src,
    count=1
)

# Opsec/Persec protection: Redact/Omit video files, paths, or names to prevent leaking private information
opsec_safe_rpc = '''
presence = {
    state = "Active editing session",
    details = "Idle",
    startTimestamp = now,
    largeImageKey = "aegisub",
    smallImageKey = "",
}
discordRPC.updatePresence(presence)

function update_rpc(subs, sel, act)
    local line_info = ""
    if subs and act then
        local active_line_obj = subs[act]
        if active_line_obj then
            local ok, start_frame = pcall(aegisub.frame_from_ms, active_line_obj.start_time)
            if ok and start_frame then
                line_info = string.format("Line: %d | Frame: %d", act, start_frame)
            else
                line_info = string.format("Line: %d", act)
            end
        end
    end

    presence = {
        state = "Active editing session",
        details = (line_info ~= "") and line_info or "Editing subtitle",
        startTimestamp = now,
        largeImageKey = "aegisub",
        smallImageKey = "",
    }
    discordRPC.updatePresence(presence)
end
'''

patched = re.sub(
    r'presence = \{\s*state = "No video file loaded yet".*?end\s*(?=\naegisub\.register_macro)',
    opsec_safe_rpc.strip(),
    patched,
    flags=re.DOTALL
)

# If the pattern wasn't found the file is already patched or layout changed — skip
if patched == src:
    print("[discord-rpc patch] Pattern not found, skipping patch (may already be applied)")
else:
    with open(path, 'w') as f:
        f.write(patched)
    print("[discord-rpc patch] Applied AppImage LD_LIBRARY_PATH fallback and Opsec patches")
PYEOF

    info "Aegisub-DiscordRPC bundled."
    info "  .so  → AppDir/usr/lib/libdiscord-rpc.so"
    info "  .lua → AppDir/usr/share/aegisub/automation/autoload/discord-rpc.lua"
}

# =============================================================================
# 7b. BUNDLE SPELLCHECKING DICTIONARIES (Indonesian & English)
# =============================================================================
bundle_dictionaries() {
    step "Bundling Hunspell Dictionaries"
    local DICT_DIR="$INSTALL_DIR/usr/share/aegisub/dictionaries"
    local CACHE_DICT="$CACHE_DIR/dictionaries"
    mkdir -p "$DICT_DIR" "$CACHE_DICT"

    # English (en_US)
    info "Bundling en_US dictionary..."
    if [[ ! -f "$CACHE_DICT/en_US.aff" ]]; then
        curl -fsSL -o "$CACHE_DICT/en_US.aff" "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/en/en_US.aff"
    fi
    if [[ ! -f "$CACHE_DICT/en_US.dic" ]]; then
        curl -fsSL -o "$CACHE_DICT/en_US.dic" "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/en/en_US.dic"
    fi
    cp "$CACHE_DICT/en_US.aff" "$DICT_DIR/"
    cp "$CACHE_DICT/en_US.dic" "$DICT_DIR/"

    # Indonesian (id_ID)
    info "Bundling id_ID dictionary..."
    if [[ ! -f "$CACHE_DICT/id_ID.aff" ]]; then
        curl -fsSL -o "$CACHE_DICT/id_ID.aff" "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/id/id_ID.aff"
    fi
    if [[ ! -f "$CACHE_DICT/id_ID.dic" ]]; then
        curl -fsSL -o "$CACHE_DICT/id_ID.dic" "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/id/id_ID.dic"
    fi
    cp "$CACHE_DICT/id_ID.aff" "$DICT_DIR/"
    cp "$CACHE_DICT/id_ID.dic" "$DICT_DIR/"

    # Create fallback duplicates for id.aff/id.dic
    cp "$DICT_DIR/id_ID.aff" "$DICT_DIR/id.aff"
    cp "$DICT_DIR/id_ID.dic" "$DICT_DIR/id.dic"

    # Custom extra dictionaries
    if [[ ${#EXTRA_DICTS[@]} -gt 0 ]]; then
        for dict_spec in "${EXTRA_DICTS[@]}"; do
            # Format is LOCALE:AFF_URL;DIC_URL
            local dict_pattern='^([^:]+):([^;]+);(.+)$'
            if [[ "$dict_spec" =~ $dict_pattern ]]; then
                local locale="${BASH_REMATCH[1]}"
                local aff_url="${BASH_REMATCH[2]}"
                local dic_url="${BASH_REMATCH[3]}"

                info "Bundling custom dictionary for locale '$locale'..."
                if [[ ! -f "$CACHE_DICT/${locale}.aff" ]]; then
                    curl -fsSL -o "$CACHE_DICT/${locale}.aff" "$aff_url"
                fi
                if [[ ! -f "$CACHE_DICT/${locale}.dic" ]]; then
                    curl -fsSL -o "$CACHE_DICT/${locale}.dic" "$dic_url"
                fi
                cp "$CACHE_DICT/${locale}.aff" "$DICT_DIR/"
                cp "$CACHE_DICT/${locale}.dic" "$DICT_DIR/"
                info "Custom dictionary '$locale' bundled successfully."
            else
                warn "Invalid --add-dict format: '$dict_spec'. Expected LOCALE:AFF_URL;DIC_URL"
            fi
        done
    fi

    info "Dictionaries bundled."
}

# =============================================================================
# 7c. BUNDLE LUA MODULES (LuaFileSystem & LuaSocket)
# =============================================================================
bundle_lua_modules() {
    step "Bundling LuaFileSystem & LuaSocket"
    local LUA_INC="$INSTALL_DIR/usr/share/aegisub/automation/include"
    mkdir -p "$LUA_INC"

    # Copy LuaFileSystem (lfs.so) from host paths
    local lfs_path=""
    for p in /usr/lib64/lua/5.1/lfs.so /usr/lib/x86_64-linux-gnu/lua/5.1/lfs.so /usr/lib/lua/5.1/lfs.so; do
        if [[ -f "$p" ]]; then
            lfs_path="$p"
            break
        fi
    done

    if [[ -n "$lfs_path" ]]; then
        cp "$lfs_path" "$LUA_INC/"
        info "Bundled LuaFileSystem (lfs.so) from $lfs_path"
    else
        warn "LuaFileSystem not found in standard library paths"
    fi

    # Copy LuaSocket (.lua and .so files) from host paths
    local socket_core="" mime_core=""
    for p in /usr/lib64/lua/5.1/socket/core.so /usr/lib/x86_64-linux-gnu/lua/5.1/socket/core.so /usr/lib/lua/5.1/socket/core.so; do
        if [[ -f "$p" ]]; then
            socket_core="$p"
            break
        fi
    done
    for p in /usr/lib64/lua/5.1/mime/core.so /usr/lib/x86_64-linux-gnu/lua/5.1/mime/core.so /usr/lib/lua/5.1/mime/core.so; do
        if [[ -f "$p" ]]; then
            mime_core="$p"
            break
        fi
    done

    local lua_share_path=""
    for p in /usr/share/lua/5.1 /usr/share/lua/5.1; do
        if [[ -d "$p" ]]; then
            lua_share_path="$p"
            break
        fi
    done

    if [[ -n "$socket_core" && -n "$mime_core" && -n "$lua_share_path" ]]; then
        # C modules
        mkdir -p "$LUA_INC/socket" "$LUA_INC/mime"
        cp "$socket_core" "$LUA_INC/socket/"
        cp "$mime_core" "$LUA_INC/mime/"

        # Lua modules
        cp "$lua_share_path/socket.lua" "$LUA_INC/"
        cp "$lua_share_path/ltn12.lua" "$LUA_INC/"
        cp "$lua_share_path/mime.lua" "$LUA_INC/"
        cp -r "$lua_share_path/socket/"* "$LUA_INC/socket/"

        info "Bundled LuaSocket"
    else
        warn "LuaSocket not found in standard library paths"
    fi
}

# =============================================================================
# 7d. CONFIGURE FONTCONFIG
# =============================================================================
configure_fontconfig() {
    step "Configuring Fontconfig"
    local CONF_DIR="$INSTALL_DIR/etc/fonts"
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/fonts.conf" << 'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <dir>/usr/local/share/fonts</dir>
  <dir>~/.fonts</dir>
  <dir>~/.local/share/fonts</dir>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
</fontconfig>
EOF
    info "Fontconfig configuration created."
}

# =============================================================================
# 7e. BUNDLE UNANIMATED'S AEGISUB SCRIPTS COLLECTION
# =============================================================================
bundle_unanimated_scripts() {
    step "Bundling Unanimated's Aegisub Scripts Collection"
    local AUTOLOAD="$INSTALL_DIR/usr/share/aegisub/automation/autoload"
    mkdir -p "$AUTOLOAD"

    local luaegisub_temp
    luaegisub_temp="$(mktemp -d)"
    TEMP_DIRS+=("$luaegisub_temp")

    git clone --depth=1 "https://github.com/unanimated/luaegisub.git" "$luaegisub_temp"

    cp "$luaegisub_temp"/ua.*.lua "$AUTOLOAD/"
    info "unanimated's Aegisub scripts collection bundled."
}

# =============================================================================
# 8. ASSEMBLE APPDIR
# =============================================================================
assemble_appdir() {
    step "Assembling AppDir"
    rm -rf "$APPDIR"
    cp -a "$INSTALL_DIR/." "$APPDIR/"

    # Copy our custom LuaJIT .so explicitly — linuxdeploy scans ldd output but
    # /usr/local/lib is outside its default search scope, so be explicit.
    local luajit_so
    luajit_so="$(find /usr/local/lib -name 'libluajit-5.1.so.2' | head -1)"
    if [[ -n "$luajit_so" ]]; then
        mkdir -p "$APPDIR/usr/lib"
        cp -P "$luajit_so" "$APPDIR/usr/lib/"
        local luajit_real
        luajit_real="$(readlink -f "$luajit_so")"
        [[ "$luajit_real" != "$luajit_so" ]] && cp "$luajit_real" "$APPDIR/usr/lib/"
        info "Bundled LuaJIT: $luajit_so"
    fi

    # Sanity checks
    local desktop
    desktop="$(find "$APPDIR" -name '*.desktop' | head -1)"
    [[ -n "$desktop" ]] || error "No .desktop file found in AppDir."

    local binary
    binary="$(find "$APPDIR/usr/bin" -name 'aegisub' -type f | head -1)"
    [[ -n "$binary" ]] || error "aegisub binary not found in AppDir."

    # Confirm both DiscordRPC files made it in
    [[ -f "$APPDIR/usr/lib/libdiscord-rpc.so" ]] || \
        warn "libdiscord-rpc.so missing from AppDir/usr/lib — DiscordRPC may not work."
    [[ -f "$APPDIR/usr/share/aegisub/automation/autoload/discord-rpc.lua" ]] || \
        warn "discord-rpc.lua missing from autoload — DiscordRPC will not load."

    info "AppDir assembled. Binary: $binary"
}

# =============================================================================
# 9. PACKAGE WITH LINUXDEPLOY → AppImage
# =============================================================================
package() {
    step "Packaging AppImage"

    local desktop_file
    desktop_file="$(find "$APPDIR" -name '*.desktop' | head -1)"

    # Prefer largest PNG, fall back to SVG
    local icon_file
    icon_file="$(find "$APPDIR" -name '*.png' -path '*/hicolor/*' | sort -t/ | tail -1)"
    [[ -z "$icon_file" ]] && \
        icon_file="$(find "$APPDIR" -name '*.svg' | head -1)"

    local aegisub_bin
    aegisub_bin="$(find "$APPDIR/usr/bin" -name 'aegisub' -type f | head -1)"

    export DEPLOY_GTK_VERSION=3
    export VERSION="$VERSION"
    export LDAI_NO_APPSTREAM=1
    export LDAI_OUTPUT="$OUTPUT_NAME"
    export NO_STRIP=1

    # 1. Run linuxdeploy to populate AppDir and link libraries
    "$LINUXDEPLOY" \
        --appdir "$APPDIR" \
        --executable "$aegisub_bin" \
        --desktop-file "$desktop_file" \
        ${icon_file:+--icon-file "$icon_file"} \
        --plugin gtk

    # 2. Post-processing cleanups (removing system libs that cause SIGSEGV)
    if [[ -f "$APPDIR/AppRun" ]]; then
        info "Patching AppRun to set GIO_MODULE_DIR=\"\" to prevent segfaults from host GIO modules..."
        sed -i '2i\export GIO_MODULE_DIR=""' "$APPDIR/AppRun"
    fi

    # Comment out theme and backend overrides in the GTK plugin hook to allow host theme and Wayland, and merge GSettings schemas
    local hook_file="$APPDIR/apprun-hooks/linuxdeploy-plugin-gtk.sh"
    if [[ -f "$hook_file" ]]; then
        info "Patching GTK plugin hook to allow native Wayland, host themes, and schemas..."
        sed -i 's|^export GDK_BACKEND=x11|# export GDK_BACKEND=x11|' "$hook_file"
        sed -i 's|^export GTK_THEME=|# export GTK_THEME=|' "$hook_file"
        sed -i 's|^export GSETTINGS_SCHEMA_DIR=.*|export GSETTINGS_SCHEMA_DIR="$APPDIR/usr/share/glib-2.0/schemas:/usr/share/glib-2.0/schemas"|' "$hook_file"
    fi

    info "Post-processing AppDir: removing conflicting system libraries to prevent segfaults..."
    local blacklist=(
        "libcap.so*"
        "libsystemd.so*"
        "libudev.so*"
        "libselinux.so*"
        "libseccomp.so*"
        "libgpg-error.so*"
        "libgcrypt.so*"
        "libdbus-1.so*"
        "libwayland-client.so*"
        "libwayland-cursor.so*"
        "libwayland-egl.so*"
        "libxkbcommon.so*"
        "libxkbcommon-x11.so*"
        "libgbm.so*"
        "libdrm.so*"
        "libGL.so*"
        "libEGL.so*"
        "libglapi.so*"
        "libxcb.so*"
        "libxcb-*"
        "libX11.so*"
        "libX11-xcb.so*"
    )
    for lib in "${blacklist[@]}"; do
        find "$APPDIR/usr/lib" -name "$lib" -delete -print 2>/dev/null || true
    done

    # 3. Package final AppImage using output plugin standalone
    info "Packaging AppImage..."
    "$LINUXDEPLOY_APPIMAGE" --appdir "$APPDIR"

    # linuxdeploy sometimes names the output differently; normalise it
    if [[ ! -f "$OUTPUT_NAME" ]]; then
        local found
        found="$(ls -t ./*.AppImage 2>/dev/null | head -1)"
        [[ -n "$found" ]] && mv "$found" "$OUTPUT_NAME"
    fi

    [[ -f "$OUTPUT_NAME" ]] || error "AppImage not produced. Check linuxdeploy output above."

    info "=== SUCCESS ==="
    info "AppImage : $(pwd)/$OUTPUT_NAME"
    info "Size     : $(du -sh "$OUTPUT_NAME" | cut -f1)"
    info ""
    info "Bundled extras:"
    info "  • DependencyControl (autoload + modules)"
    info "  • Aegisub-DiscordRPC (libdiscord-rpc.so + discord-rpc.lua)"
    info "  • Unanimated's Aegisub scripts collection"
}

# =============================================================================
# CLEAN SYSTEM (Removes build directory, compiled LuaJIT, and optionally deps)
# =============================================================================
clean_system() {
    step "Cleaning Aegisub Build Environment"

    # 1. Remove Aegisub build directory
    if [[ -d "$BUILD_DIR" ]]; then
        info "Removing build directory: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi

    # 2. Remove compiled LuaJIT from /usr/local
    info "Removing custom compiled LuaJIT from /usr/local..."
    sudo rm -f /usr/local/bin/luajit
    sudo rm -rf /usr/local/include/luajit-2.1
    sudo rm -f /usr/local/lib/libluajit-5.1.so*
    sudo rm -f /usr/local/lib/pkgconfig/luajit.pc
    sudo rm -f /etc/ld.so.conf.d/luajit-local.conf
    sudo ldconfig

    # 3. Ask to remove development packages
    warn "This will uninstall Aegisub-specific development packages."
    read -p "Do you want to proceed with package removal? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Removing build dependencies..."
        if command -v dnf &>/dev/null; then
            sudo dnf remove -y \
                boost-devel wxGTK-devel libicu-devel zlib-devel libass-devel \
                ffms2-devel fftw-devel hunspell-devel uchardet-devel libcurl-devel \
                openal-soft-devel pulseaudio-libs-devel alsa-lib-devel mesa-libGL-devel \
                fontconfig-devel freetype-devel gtest-devel vapoursynth-devel \
                wayland-devel libxkbcommon-devel lua5.1-filesystem lua5.1-socket \
                compat-lua-devel compat-lua-libs
        elif command -v apt-get &>/dev/null; then
            local wx_pkg="libwxgtk3.2-dev"
            if ! apt-cache show "$wx_pkg" &>/dev/null; then
                wx_pkg="libwxgtk3.0-gtk3-dev"
            fi
            sudo apt-get remove -y \
                libboost-dev "$wx_pkg" libicu-dev zlib1g-dev libass-dev \
                libffms2-dev libfftw3-dev libhunspell-dev libuchardet-dev libcurl4-openssl-dev \
                libopenal-dev libpulse-dev libasound2-dev libgl1-mesa-dev \
                libfontconfig1-dev libfreetype6-dev libgtest-dev libvapoursynth-dev \
                lua-filesystem lua-socket moonscript libwayland-dev libxkbcommon-dev
        fi
    fi

    info "Clean complete!"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    local skip_deps=0 skip_luajit=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-deps)   skip_deps=1; shift ;;
            --skip-luajit) skip_luajit=1; shift ;;
            --clean)
                clean_system
                exit 0 ;;
            --add-dict)
                if [[ $# -lt 2 ]]; then
                    error "--add-dict requires an argument in format LOCALE:AFF_URL;DIC_URL"
                fi
                EXTRA_DICTS+=("$2")
                shift 2 ;;
            --add-dict=*)
                EXTRA_DICTS+=("${1#*=}")
                shift ;;
            --help|-h)
                echo "Usage: $0 [--skip-deps] [--skip-luajit] [--clean] [--add-dict LOCALE:AFF_URL;DIC_URL]"
                echo "  --skip-deps    Skip dependency install step"
                echo "  --skip-luajit  Skip LuaJIT build (already at /usr/local)"
                echo "  --clean        Clean build files, custom LuaJIT, and build dependencies"
                echo "  --add-dict     Add custom Hunspell dictionary. Format: LOCALE:AFF_URL;DIC_URL"
                echo "                 Example: --add-dict \"fr_FR:http://example.com/fr.aff;http://example.com/fr.dic\""
                exit 0 ;;
            *)
                shift ;;
        esac
    done

    local os_name="Linux" os_version=""
    if [[ -f /etc/os-release ]]; then
        os_name="$(grep -E '^NAME=' /etc/os-release | cut -d= -f2 | tr -d '"')"
        os_version="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    fi

    step "Aegisub ${BRANCH} AppImage builder (${os_name}${os_version:+ $os_version} / ${ARCH})"
    info "    Bundled: DependencyControl, Aegisub-DiscordRPC, Unanimated's Aegisub scripts collection"

    need_cmd git
    need_cmd curl
    need_cmd unzip
    need_cmd python3

    mkdir -p "$BUILD_DIR"

    [[ $skip_deps   -eq 0 ]] && install_deps
    [[ $skip_luajit -eq 0 ]] && build_luajit

    need_cmd meson
    need_cmd ninja

    fetch_tooling
    clone_source
    build
    bundle_depctrl
    bundle_discord_rpc
    bundle_dictionaries
    bundle_lua_modules
    bundle_unanimated_scripts
    configure_fontconfig
    assemble_appdir
    package

    step "All done!"
}

main "$@"
