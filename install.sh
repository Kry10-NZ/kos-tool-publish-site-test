#!/bin/sh
# Copyright (c) 2026, Kry10 Limited. All rights reserved.
#
# SPDX-License-Identifier: LicenseRef-Kry10

# Installs kos-tool from GitHub Releases.
#
#   curl -fsSL https://<host> | sh
#   curl -fsSL https://<host> | sh -s -- --version 0.2.0 --to "$HOME/.local/bin"
#
# Options (each also read from the environment):
#   --version <version>  KOS_TOOL_VERSION  A release such as 0.2.0, or "latest" (the default).
#   --to <dir>           KOS_TOOL_DIR      Where kos-tool goes, /opt/kry10/bin by default.
#
# KOS_TOOL_RELEASES_URL points the script at a mirror laid out like GitHub Releases.

set -eu

RELEASES_URL=${KOS_TOOL_RELEASES_URL:-https://github.com/Kry10-NZ/kos-tool-release/releases}
# nix compiles absolute paths into the packages kos-tool installs, so it needs this directory whatever --to says.
KRY10_DIR=/opt/kry10

say() { printf '%s\n' "$*"; }
err() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    say "usage: install.sh [--version <version>] [--to <dir>]"
    say "  --version  a kos-tool release such as 0.2.0, or latest (default; also KOS_TOOL_VERSION)"
    say "  --to       the directory to install into (default /opt/kry10/bin; also KOS_TOOL_DIR)"
}

has() { command -v "$1" > /dev/null 2>&1; }

# Fails up front with every missing tool named, rather than partway through the install.
check_tools() {
    missing=
    for tool in curl uname mktemp chmod mkdir mv cut head tail sort; do
        has "$tool" || missing="$missing $tool"
    done
    if has sha256sum; then
        SHA256=sha256sum
    elif has shasum; then
        SHA256="shasum -a 256"
    else
        missing="$missing sha256sum-or-shasum"
    fi
    [ -z "$missing" ] || err "these tools are required but not installed:$missing"
    # BusyBox sort can lack -V, which comparing versions needs.
    printf '1\n' | sort -V > /dev/null 2>&1 || err "sort does not support -V. Install GNU coreutils."
}

detect_platform() {
    os=$(uname -s)
    arch=$(uname -m)
    case $os in
        Linux)
            case $arch in
                x86_64 | amd64) echo linux-x86_64 && return ;;
                aarch64 | arm64) echo linux-aarch64 && return ;;
            esac
            ;;
        Darwin)
            # A shell under Rosetta reports x86_64 on Apple silicon.
            if [ "$arch" = arm64 ] || [ "$(sysctl -n hw.optional.arm64 2> /dev/null)" = 1 ]; then
                echo macos-aarch64 && return
            fi
            ;;
    esac
    err "kos-tool is not built for $os $arch. It is built for linux-x86_64, linux-aarch64 and macos-aarch64."
}

# Succeeds when semver $1 is newer than $2. Kept in step with the publish job in kos-tool's main.yml.
newer() {
    a=${1%%+*} b=${2%%+*}
    [ "$a" != "$b" ] || return 1
    if [ "${a%%-*}" = "${b%%-*}" ]; then
        case $a in *-*) ;; *) return 0 ;; esac
        case $b in *-*) ;; *) return 1 ;; esac
    fi
    [ "$(printf '%s\n' "$a" "$b" | sort -V | tail -n 1)" = "$a" ]
}

# check_tools picks the command, sha256sum on Linux and shasum on macOS.
sha256() {
    $SHA256 "$1" | cut -d ' ' -f 1
}

# GitHub redirects releases/latest to the newest release that is not a pre-release.
resolve_latest() {
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES_URL/latest") ||
        err "could not reach $RELEASES_URL/latest"
    tag=${url##*/}
    case $tag in
        v[0-9]*) echo "${tag#v}" ;;
        *) err "could not find the latest kos-tool release at $RELEASES_URL" ;;
    esac
}

# kos-tool --version prints "kos-tool v<semver>-<build>" on its first line.
installed_version() {
    line=$("$1" --version 2> /dev/null | head -n 1) || return 0
    v=${line#kos-tool v}
    [ "$v" != "$line" ] || return 0
    echo "${v%-*}"
}

# Everything runs from here, called on the last line, so a download cut short by curl | sh runs nothing.
main() {
    version=${KOS_TOOL_VERSION:-latest}
    dir=${KOS_TOOL_DIR:-$KRY10_DIR/bin}

    while [ $# -gt 0 ]; do
        case $1 in
            --version)
                [ $# -ge 2 ] || err "--version needs a value"
                version=$2
                shift 2
                ;;
            --version=*)
                version=${1#*=}
                shift
                ;;
            --to)
                [ $# -ge 2 ] || err "--to needs a value"
                dir=$2
                shift 2
                ;;
            --to=*)
                dir=${1#*=}
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) err "unknown argument: $1 (see --help)" ;;
        esac
    done

    # An explicit version is installed even when it is older than the one already there.
    explicit=true
    [ "$version" != latest ] || explicit=false
    version=${version#v}

    check_tools
    platform=$(detect_platform)

    if [ ! -d "$KRY10_DIR" ]; then
        say "kos-tool installs the KOS SDK to $KRY10_DIR, which does not exist. Create it with:"
        say ""
        say "  sudo mkdir -p $KRY10_DIR && sudo chown \"\$(id -u)\" $KRY10_DIR"
        say ""
        case $dir in
            "$KRY10_DIR" | "$KRY10_DIR"/*) err "run that, then run this script again" ;;
        esac
    fi

    [ "$version" != latest ] || version=$(resolve_latest)

    bin="$dir/kos-tool"
    old=
    [ ! -x "$bin" ] || old=$(installed_version "$bin")

    if [ "$old" = "$version" ]; then
        say "kos-tool $version is already installed at $bin"
        exit 0
    fi
    if [ "$explicit" = false ] && [ -n "$old" ] && newer "$old" "$version"; then
        say "kos-tool $old at $bin is newer than the latest release $version. Pass --version $version to change to it."
        exit 0
    fi

    mkdir -p "$dir" 2> /dev/null || err "could not create $dir"
    [ -w "$dir" ] || err "$dir is not writable. Choose another directory with --to, or make it writable."

    asset="kos-tool-$version-$platform"
    url="$RELEASES_URL/download/v$version/$asset"

    # In the install directory, so the final mv is a rename and nobody sees a half-written binary.
    tmp=$(mktemp "$dir/.kos-tool.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    trap 'exit 1' HUP INT TERM

    say "1. Download kos-tool $version for $platform"
    say "   $url"
    curl -fsSL -o "$tmp" "$url" || err "could not download kos-tool $version for $platform from $url"

    say "2. Check the SHA-256 checksum"
    expected=$(curl -fsSL "$url.sha256" | cut -d ' ' -f 1) || err "could not download $url.sha256"
    actual=$(sha256 "$tmp")
    [ "$expected" = "$actual" ] || err "checksum mismatch for $asset: expected $expected, got $actual"
    say "   $actual"

    say "3. Move it to $bin"
    chmod 755 "$tmp"
    mv -f "$tmp" "$bin"
    trap - EXIT

    say ""

    if [ -n "$old" ]; then
        say "kos-tool $old → $version"
    else
        say "kos-tool $version installed to $bin"
    fi

    case ":$PATH:" in
        *":$dir:"*) ;;
        *)
            say ""
            say "$dir is not on your PATH. Add it with:"
            say ""
            say "  export PATH=\"$dir:\$PATH\""
            ;;
    esac
}

main "$@"
