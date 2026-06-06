#!/usr/bin/env bash

# Package script for macOS using a nanobrew Qt 6 installation.
# Adapted for the maintainer's nanobrew setup at /opt/nanobrew/prefix.
# The app must already be built via `cmake --preset release` before running this.

set -Eeuo pipefail
IFS=$'\n\t'

cd "$(dirname "${BASH_SOURCE[0]}")/../.." > /dev/null 2>&1

PROJECT_DIR="$(pwd -P)"

source .ci/ci_utils.sh

NB_PREFIX="/opt/nanobrew/prefix"
OLD_PATH="$PATH"
export PATH="${NB_PREFIX}/bin:${OLD_PATH}"

if [[ "${OS_NAME}" != "Darwin" ]]; then
    print_fatal "Packaging script only works on macOS!"
fi

usage() {
    cat << EOF
Usage: $(basename "$0") [--no-confirm]

Packages the already-built MediaElch.app (from build/release/) into a DMG
using the nanobrew Qt 6 installation at ${NB_PREFIX}.

Run cmake --preset release first to build the app.

Options
  --no-confirm   Package without confirmation prompt.
EOF
    exit
}

parse_params() {
    NO_CONFIRM=0
    while :; do
        case "${1-}" in
        -h | --help) usage ;;
        -v | --verbose) set -x ;;
        --no-confirm) NO_CONFIRM=1 ;;
        -?*) print_fatal "Unknown option: $1" ;;
        *) break ;;
        esac
        shift
    done
}

parse_params "$@"

#######################################################
# Dependency check

print_important "Checking dependencies:"
HAS_MISSING=0
for cmd in git cmake ninja clang++ macdeployqt curl 7za; do
    if command -v "$cmd" > /dev/null 2>&1; then
        printf "  \033[0;32m✔\033[0m %s\n" "$cmd"
    else
        printf "  \033[0;31m✘\033[0m %s not found\n" "$cmd"
        HAS_MISSING=1
    fi
done
if [[ ${HAS_MISSING} -ne 0 ]]; then
    print_fatal "Missing dependencies. Abort."
fi
echo ""

#######################################################
# Gather version info

gather_project_and_system_details

if [[ "${NO_CONFIRM}" != "1" ]]; then
    echo ""
    print_important "Package MediaElch ${ME_VERSION} for macOS (nanobrew Qt 6)?"
    print_important "It is recommended to clean build/release first for a fresh package."
    read -r -s -p "Press enter to continue, Ctrl+C to cancel"
    echo ""
fi
echo ""

#######################################################
# Verify app is built

BUILD_DIR="${PROJECT_DIR}/build/release"

if [[ ! -d "${BUILD_DIR}/MediaElch.app/Contents/MacOS" ]]; then
    print_fatal "MediaElch.app not found at ${BUILD_DIR}. Run: cmake --preset release && cmake --build --preset release"
fi

#######################################################
# Download dependencies into third_party folder

THIRD_PARTY_DIR="${PROJECT_DIR}/third_party/packaging_macOS_nanobrew"
mkdir -p "${THIRD_PARTY_DIR}"
cd "${THIRD_PARTY_DIR}"

# MediaInfoDLL
if [[ ! -f libmediainfo.0.dylib ]]; then
    print_info "Downloading libmediainfo"
    curl -L -o MediaInfo_DLL.tar.bz2 "${MAC_MEDIAINFO_URL}"
    validate_sha512 "MediaInfo_DLL.tar.bz2" "${MAC_MEDIAINFO_SHA512}"
    tar -xjf MediaInfo_DLL.tar.bz2
    mv MediaInfoLib/libmediainfo.0.dylib ./
    rm -rf MediaInfoLib MediaInfo_DLL.tar.bz2
fi

# create-dmg
if [[ ! -d create-dmg ]]; then
    print_info "Downloading create-dmg"
    git clone "${MAC_CREATE_DMG_GIT_REPO}"
    pushd "create-dmg" > /dev/null
    git checkout "${MAC_CREATE_DMG_GIT_HASH}" > /dev/null
    popd > /dev/null
fi

# ffmpeg
if [[ ! -f ffmpeg ]]; then
    print_info "Downloading ffmpeg"
    curl -L -o ffmpeg.7z "${MAC_FFMPEG_URL}"
    validate_sha512 "ffmpeg.7z" "${MAC_FFMPEG_SHA512}"
    7za e ffmpeg.7z ffmpeg
    rm ffmpeg.7z
fi

#######################################################
# Copy dependencies into app bundle

cd "${BUILD_DIR}"

rm -f ./*.dmg

# Ensure Info.plist is present — incremental cmake rebuilds after a prior
# macdeployqt run can leave it missing, which breaks the app icon and signing.
if [[ ! -f MediaElch.app/Contents/Info.plist ]]; then
    print_info "Info.plist missing from bundle — copying from source"
    cp "${PROJECT_DIR}/MediaElch.plist" MediaElch.app/Contents/Info.plist
fi

cp "${THIRD_PARTY_DIR}/ffmpeg" MediaElch.app/Contents/MacOS/
cp "${THIRD_PARTY_DIR}/libmediainfo.0.dylib" MediaElch.app/Contents/MacOS/

#######################################################
# Qt translations

QT_TRANSLATIONS_PATH="$(qmake -query QT_INSTALL_TRANSLATIONS)"
print_info "Copying Qt translations from ${QT_TRANSLATIONS_PATH}"
mkdir -p MediaElch.app/Contents/translations
cp "${QT_TRANSLATIONS_PATH}"/qt*.qm MediaElch.app/Contents/translations/

if [[ ! -f MediaElch.app/Contents/translations/qt_de.qm ]]; then
    print_fatal "German Qt translation missing — translations copy failed."
fi

#######################################################
# Bundle Qt frameworks

print_info "Running macdeployqt"
macdeployqt MediaElch.app -verbose=2

#######################################################
# Rewrite hardcoded nanobrew paths in the main binary
#
# With nanobrew's split-prefix Qt layout each Qt module lives under its own
# prefix (e.g. /opt/nanobrew/prefix/opt/qtbase/, /opt/nanobrew/prefix/opt/qtsvg/).
# macdeployqt copies all frameworks into Contents/Frameworks and patches the
# bundled copies and plugins (e.g. libqcocoa.dylib), but it does NOT rewrite the
# main binary's absolute LC_LOAD_DYLIB entries because they span multiple prefix
# directories. At runtime dyld loads the nanobrew Qt via those absolute paths AND
# loads the bundled Qt via libqcocoa.dylib → two Qt instances → fatal crash in
# init_platform.
#
# Fix: rewrite every absolute nanobrew path in the main binary to a bundle-relative
# @executable_path/../Frameworks reference, then add that directory as an LC_RPATH
# so @rpath-based dependencies (e.g. libquazip) also resolve from the bundle.
# Finally strip any remaining nanobrew LC_RPATH entries from all bundle binaries.

print_info "Rewriting nanobrew library references in main binary"
BINARY="MediaElch.app/Contents/MacOS/MediaElch"
FW="@executable_path/../Frameworks"

# Collect every absolute (non-system, non-@) dependency that points into nanobrew
# or MacPorts and has a matching copy in Contents/Frameworks, then rewrite it.
while IFS= read -r dep; do
    basename_dep="$(basename "$dep")"
    # Skip already-rewritten bundle-relative references
    [[ "$dep" == @* ]] && continue
    # Frameworks: rewrite to @executable_path/../Frameworks/<Foo>.framework/Versions/A/<Foo>
    if [[ "$dep" == *.framework/* ]]; then
        fw_name="${basename_dep}"
        bundled_path="${FW}/${fw_name}.framework/Versions/A/${fw_name}"
        if [[ -f "MediaElch.app/Contents/Frameworks/${fw_name}.framework/Versions/A/${fw_name}" ]]; then
            print_info "  Rewriting: $dep → $bundled_path"
            install_name_tool -change "$dep" "$bundled_path" "$BINARY"
        fi
    # Flat dylibs: rewrite to @executable_path/../Frameworks/<lib>
    elif [[ "$dep" == /opt/* || "$dep" == /usr/local/* ]]; then
        if [[ -f "MediaElch.app/Contents/Frameworks/${basename_dep}" ]]; then
            print_info "  Rewriting: $dep → ${FW}/${basename_dep}"
            install_name_tool -change "$dep" "${FW}/${basename_dep}" "$BINARY"
        fi
    fi
done < <(otool -L "$BINARY" | awk 'NR>1{print $1}')

# Add the Frameworks directory as an rpath so @rpath-based deps (e.g. libquazip)
# also resolve from the bundle.
if ! otool -l "$BINARY" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "$FW" "$BINARY"
fi

# Strip any remaining nanobrew LC_RPATH entries from all bundle binaries so that
# dyld cannot fall back to loading a second copy of any library from the system.
strip_nanobrew_rpaths() {
    local binary="$1"
    local -a rpaths=()
    mapfile -t rpaths < <(otool -l "$binary" | awk '/LC_RPATH/{found=1} found && /path /{print $2; found=0}')
    for rpath in "${rpaths[@]}"; do
        case "$rpath" in
            /opt/nanobrew/*|"${NB_PREFIX}"*)
                print_info "  Removing rpath '$rpath' from $(basename "$binary")"
                install_name_tool -delete_rpath "$rpath" "$binary"
                ;;
        esac
    done
}

print_info "Stripping residual nanobrew rpaths from app bundle"
strip_nanobrew_rpaths "$BINARY"
while IFS= read -r lib; do
    strip_nanobrew_rpaths "$lib"
done < <(find MediaElch.app/Contents/PlugIns MediaElch.app/Contents/Frameworks \
             -name "*.dylib" -type f 2>/dev/null)
codesign --force --sign - "MediaElch.app"

#######################################################
# Create DMG

DMG_NAME="MediaElch_macOS_nanobrew_${ME_VERSION_NAME}.dmg"

print_info "Running create-dmg"
"${THIRD_PARTY_DIR}/create-dmg/create-dmg" \
    --volname "MediaElch" \
    --volicon "${PROJECT_DIR}/MediaElch.icns" \
    --background "${PROJECT_DIR}/.ci/macOS/backgroundImage.tiff" \
    --window-pos 200 120 \
    --window-size 550 400 \
    --icon-size 100 \
    --icon MediaElch.app 150 190 \
    --hide-extension MediaElch.app \
    --app-drop-link 400 190 \
    "${DMG_NAME}" \
    MediaElch.app

mv "${DMG_NAME}" "${PROJECT_DIR}/"

print_success "DMG created: ${PROJECT_DIR}/${DMG_NAME}"
