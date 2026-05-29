# Building MediaElch on macOS with nanobrew (nb) or Homebrew

This guide documents how to build MediaElch on macOS using Qt 6 installed via
[nanobrew](https://github.com/nicholasgasior/nanobrew) (`nb`) or the more common
[Homebrew](https://brew.sh/) (`brew`).

> **Note:** Most developers use Homebrew. The nanobrew section documents a more
> complex path with extra gotchas. If you're new to this, start with Homebrew.

---

## Option A: Homebrew (Recommended)

Install dependencies:

```sh
brew install cmake ninja qt llvm libmediainfo quazip
```

Configure and build:

```sh
git clone --recursive https://github.com/Komet/MediaElch.git
cd MediaElch
cmake --preset release \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt)" \
  -DCMAKE_CXX_COMPILER="$(brew --prefix llvm)/bin/clang++" \
  -DCMAKE_C_COMPILER="$(brew --prefix llvm)/bin/clang"
cmake --build build/release -- -j$(sysctl -n hw.logicalcpu)
```

The resulting app bundle is at `build/release/MediaElch.app`.

---

## Option B: nanobrew (`nb`)

[nanobrew](https://github.com/nicholasgasior/nanobrew) is a fast Homebrew-compatible
package manager written in Zig. As of version 0.1.193 it has several known bugs that
require manual workarounds when building Qt 6 projects.

### Prerequisites

```sh
# Verify nb is installed
nb --version        # e.g. 0.1.193
which nb            # /opt/nanobrew/prefix/bin/nb
```

### 1. Install dependencies

```sh
nb install qt         # Qt 6 (meta-package; pulls in qtbase, qtmultimedia, etc.)
nb install llvm       # LLVM 22 (required — Qt was compiled with LLVM libc++)
nb install cmake ninja
nb install libmediainfo
```

### 2. Fix nanobrew circular symlinks (Qt meta-package bug)

nanobrew's `qt` meta-package creates circular symlinks in the prefix. Run this
Python script once after installing Qt:

```python
#!/usr/bin/env python3
"""Fix circular Qt symlinks created by nanobrew's qt meta-package."""
import os, subprocess, re

PREFIX = "/opt/nanobrew/prefix"
CELLAR = f"{PREFIX}/Cellar"

# Map component names to their Cellar directories
qt_components = {
    "Qt6": "qtbase",
    "Qt6Bluetooth": "qtconnectivity",
    "Qt6Charts": "qtcharts",
    "Qt6Concurrent": "qtbase",
    "Qt6Core": "qtbase",
    "Qt6DataVisualization": "qtdatavis3d",
    "Qt6Gui": "qtbase",
    "Qt6Multimedia": "qtmultimedia",
    "Qt6MultimediaWidgets": "qtmultimedia",
    "Qt6Network": "qtbase",
    "Qt6OpenGL": "qtbase",
    "Qt6Sql": "qtbase",
    "Qt6Svg": "qtsvg",
    "Qt6Test": "qtbase",
    "Qt6Widgets": "qtbase",
    "Qt6Xml": "qtbase",
    "Qt6Core5Compat": "qt5compat",
    "Qt6LinguistTools": "qttools",
}

cmake_dir = f"{PREFIX}/lib/cmake"
for entry in os.listdir(cmake_dir):
    full = os.path.join(cmake_dir, entry)
    if os.path.islink(full):
        target = os.readlink(full)
        # Detect circular: target resolves back through prefix
        if "../../../../lib/cmake" in target or os.path.realpath(full) == full:
            component = entry  # e.g. "Qt6Multimedia"
            pkg = qt_components.get(component)
            if pkg:
                version = os.listdir(f"{CELLAR}/{pkg}")[0]
                new_target = f"../../../Cellar/{pkg}/{version}/lib/cmake/{component}"
                os.remove(full)
                os.symlink(new_target, full)
                print(f"Fixed: {entry} -> {new_target}")
```

Save as `fix_qt_symlinks.py` and run with `python3 fix_qt_symlinks.py`.

### 3. Fix truncated object filenames (nanobrew bug)

nanobrew truncates long filenames. Check for and fix broken plugin objects:

```sh
# Find truncated names in Qt plugin directories
find /opt/nanobrew/prefix/Cellar/qtbase -name "QDa" -o -name "QDar" | head

# If found, create properly-named symlinks:
cd /opt/nanobrew/prefix/Cellar/qtbase/6.11.1/share/qt/plugins/permissions/objects-Release/QDarwinBluetoothPermissionPlugin_init.cpp.o.dir/
for truncated in QDa QDar QDarw; do
  [ -e "$truncated" ] && ln -sf "$truncated" "QDarwinBluetoothPermissionPlugin_init.cpp.o"
done
```

### 4. Fix `@@HOMEBREW_PREFIX@@` placeholders in Qt binaries

nanobrew doesn't substitute `@@HOMEBREW_PREFIX@@` in precompiled binaries. Fix `moc`
and other Qt tools, **plus the SVG and icon-engine plugins** (required for toolbar icons):

```sh
PREFIX=/opt/nanobrew/prefix
QT_BIN="$PREFIX/opt/qtbase/bin"

for binary in \
  "$QT_BIN"/moc "$QT_BIN"/rcc "$QT_BIN"/uic "$QT_BIN"/qmake \
  "$PREFIX/share/qt/plugins/imageformats/libqsvg.dylib" \
  "$PREFIX/share/qt/plugins/imageformats/libqpdf.dylib" \
  "$PREFIX/share/qt/plugins/iconengines/libqsvgicon.dylib"; do
  if otool -L "$binary" 2>/dev/null | grep -q '@@HOMEBREW_PREFIX@@'; then
    otool -L "$binary" | grep '@@HOMEBREW_PREFIX@@' | awk '{print $1}' | while read old; do
      new="${old//@@HOMEBREW_PREFIX@@/$PREFIX}"
      install_name_tool -change "$old" "$new" "$binary"
    done
    codesign --force --sign - "$binary"
  fi
done
```

Without fixing the SVG plugin, toolbar icons will silently fail to render (blank buttons).

### 5. Patch Qt6Targets.cmake (Apple-clang-only flag)

Qt's cmake config injects `-fno-objc-msgsend-selector-stubs` which only Apple clang
supports (not LLVM clang). Remove it:

```sh
TARGETS_FILE=/opt/nanobrew/prefix/Cellar/qtbase/6.11.1/lib/cmake/Qt6/Qt6Targets.cmake
# Remove the flag from INTERFACE_COMPILE_OPTIONS
sed -i '' 's|\$<\$<AND:\$<STREQUAL:\$<TARGET_PROPERTY:TYPE>,STATIC_LIBRARY>,\$<COMPILE_LANGUAGE:OBJC,OBJCXX>>:-fno-objc-msgsend-selector-stubs>;;||g' "$TARGETS_FILE"
```

Or edit the file manually and remove the `$<...:OBJCXX>>:-fno-objc-msgsend-selector-stubs>;`
expression from the `INTERFACE_COMPILE_OPTIONS` property.

### 6. Configure CMake

```sh
git clone --recursive https://github.com/Komet/MediaElch.git
cd MediaElch

LLVM_PREFIX=/opt/nanobrew/prefix/opt/llvm
NB_PREFIX=/opt/nanobrew/prefix

cmake --preset release \
  -DCMAKE_PREFIX_PATH="$NB_PREFIX" \
  -DCMAKE_CXX_COMPILER="$LLVM_PREFIX/bin/clang++" \
  -DCMAKE_C_COMPILER="$LLVM_PREFIX/bin/clang" \
  -DCMAKE_CXX_FLAGS="-stdlib=libc++ -nostdinc++ -isystem $LLVM_PREFIX/include/c++/v1 -isystem $LLVM_PREFIX/include" \
  -DCMAKE_EXE_LINKER_FLAGS="-L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++" \
  -DCMAKE_SHARED_LINKER_FLAGS="-L$LLVM_PREFIX/lib/c++ -Wl,-rpath,$LLVM_PREFIX/lib/c++ -lc++" \
  -DENABLE_LTO=OFF \
  -S /Users/lukas/Code/MediaElch
```

**Why LLVM clang instead of Apple clang?**
Qt 6.11.1 from nanobrew was compiled with LLVM 22's libc++. This library uses the
`[abi:nqe220104]` inline namespace for `_LIBCPP_HIDE_FROM_ABI` functions. Apple clang's
system libc++ uses a different ABI tag, causing linker failures like:

```
Undefined symbols for architecture arm64:
  "std::__1::basic_ostream<char, ...>& std::__1::operator<<[abi:nqe220104]<...>"
```

You must compile with the same LLVM libc++ that Qt was built against.

### 7. Patch build.ninja if needed

After cmake configure, if ObjC++ files (`.mm`) still reference the bad flag:

```sh
sed -i '' 's/-fno-objc-msgsend-selector-stubs//g' build/release/build.ninja
```

### 8. Build

```sh
cmake --build build/release -- -j$(sysctl -n hw.logicalcpu)
```

The app bundle is at `build/release/MediaElch.app`.

---

## Troubleshooting

### `operator<<[abi:nqe220104]` linker error

Cause: LLVM libc++ ABI mismatch. Qt was built with LLVM 22 libc++; you compiled
MediaElch against a different libc++ (e.g. Apple clang's).

Fix: Use LLVM clang with the `-stdlib=libc++ -nostdinc++` flags as shown above,
pointing to the same LLVM install that Qt uses.

### `moc: killed` (exit 137) after install_name_tool

macOS kills binaries whose code signature is invalidated. After any `install_name_tool`
modification, re-sign with: `codesign --force --sign - <binary>`

### Qt cmake components not found (find_package loop)

Circular symlinks in `/opt/nanobrew/prefix/lib/cmake/Qt6*/` prevent cmake from finding
Qt components. Run the symlink fix script from step 2 above.

### `-fno-objc-msgsend-selector-stubs` compile error

This flag is Apple-clang-only. If it appears, patch `Qt6Targets.cmake` (step 5) and
`build.ninja` (step 7).

### Toolbar icons blank (SVG icons not rendering)

Cause: `libqsvg.dylib` and `libqsvgicon.dylib` have unresolved `@@HOMEBREW_PREFIX@@`
dependency paths so they silently fail to load at runtime.

Fix: Run the plugin fix commands in step 4 (the `for binary in ...` loop that includes
the imageformats and iconengines `.dylib` files).

### `MediaInfoDLL.h` not found

Install libmediainfo: `nb install libmediainfo` (or `brew install libmediainfo`).

### Missing submodule files (quazip, etc.)

```sh
git submodule update --init --recursive
```
