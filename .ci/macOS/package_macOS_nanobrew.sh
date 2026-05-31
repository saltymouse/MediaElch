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
