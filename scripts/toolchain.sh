#!/bin/bash

# Shared Apple toolchain discovery for Bib's standalone build and tests.
# Bib uses APIs introduced in the macOS 14 / iOS 17 SDKs, which ship with
# Xcode 15 and Command Line Tools for Xcode 15 or newer.

BIB_MINIMUM_SWIFT_VERSION="5.9"
BIB_MINIMUM_MACOS_SDK_VERSION="14.0"

bib_version_at_least() {
    /usr/bin/awk -v actual="$1" -v minimum="$2" 'BEGIN {
        split(actual, a, "."); split(minimum, m, ".")
        for (i = 1; i <= 4; i++) {
            av = (a[i] == "" ? 0 : a[i]) + 0
            mv = (m[i] == "" ? 0 : m[i]) + 0
            if (av > mv) exit 0
            if (av < mv) exit 1
        }
        exit 0
    }'
}

bib_toolchain_versions() {
    local developer_dir="$1"
    local swift_output
    swift_output="$(DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun swiftc --version 2>/dev/null)" || return 1
    BIB_CANDIDATE_SWIFT_VERSION="$(printf '%s\n' "$swift_output" | /usr/bin/sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | /usr/bin/head -1)"
    BIB_CANDIDATE_SDK_VERSION="$(DEVELOPER_DIR="$developer_dir" /usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null)" || return 1
    [ -n "$BIB_CANDIDATE_SWIFT_VERSION" ] && [ -n "$BIB_CANDIDATE_SDK_VERSION" ]
}

bib_toolchain_is_compatible() {
    local developer_dir="$1"
    bib_toolchain_versions "$developer_dir" || return 1
    bib_version_at_least "$BIB_CANDIDATE_SWIFT_VERSION" "$BIB_MINIMUM_SWIFT_VERSION" &&
        bib_version_at_least "$BIB_CANDIDATE_SDK_VERSION" "$BIB_MINIMUM_MACOS_SDK_VERSION"
}

bib_toolchain_help() {
    cat >&2 <<EOF

Bib requires Swift ${BIB_MINIMUM_SWIFT_VERSION}+ and the macOS ${BIB_MINIMUM_MACOS_SDK_VERSION}+ SDK (Xcode 15 or newer).

To install developer tools for the first time:
  xcode-select --install

To update existing tools, use System Settings > General > Software Update, or
install a current Xcode from the App Store. Then select it with:
  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer

You can also choose a toolchain for one build without changing the Mac:
  BIB_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-mac.sh
EOF
}

bib_configure_toolchain() {
    local candidates=()
    local selected=""
    local candidate
    local selected_by_xcode=""

    if [ -n "${BIB_DEVELOPER_DIR:-}" ]; then
        candidates+=("$BIB_DEVELOPER_DIR")
    else
        selected_by_xcode="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
        [ -n "$selected_by_xcode" ] && candidates+=("$selected_by_xcode")
        candidates+=("/Applications/Xcode.app/Contents/Developer")
        candidates+=("/Library/Developer/CommandLineTools")
    fi

    for candidate in "${candidates[@]}"; do
        [ -d "$candidate" ] || continue
        if bib_toolchain_is_compatible "$candidate"; then
            selected="$candidate"
            break
        fi
        if bib_toolchain_versions "$candidate"; then
            printf 'Skipping incompatible toolchain: %s (Swift %s, macOS SDK %s)\n' \
                "$candidate" "$BIB_CANDIDATE_SWIFT_VERSION" "$BIB_CANDIDATE_SDK_VERSION" >&2
        fi
    done

    if [ -z "$selected" ]; then
        printf 'Error: no compatible Apple developer toolchain was found.\n' >&2
        bib_toolchain_help
        return 1
    fi

    export DEVELOPER_DIR="$selected"
    BIB_DEVELOPER_TOOLS="$selected"
    BIB_SWIFT_VERSION="$BIB_CANDIDATE_SWIFT_VERSION"
    BIB_MACOS_SDK_VERSION="$BIB_CANDIDATE_SDK_VERSION"
    BIB_SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
    export BIB_DEVELOPER_TOOLS BIB_SWIFT_VERSION BIB_MACOS_SDK_VERSION BIB_SDK_PATH

    printf 'Using developer tools: %s (Swift %s, macOS SDK %s)\n' \
        "$BIB_DEVELOPER_TOOLS" "$BIB_SWIFT_VERSION" "$BIB_MACOS_SDK_VERSION"
}
