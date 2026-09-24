#!/usr/bin/env bash
# FWMgr bootstrap installer. Downloads and installs the latest stable release.
set -euo pipefail

GITHUB_REPOSITORY="MaXa0H/fwmgr"
RELEASE_BASE_URL="https://github.com/${GITHUB_REPOSITORY}/releases/latest/download"

die() { printf 'FWMgr installer: %s\n' "$*" >&2; exit 1; }
info() { printf 'FWMgr installer: %s\n' "$*"; }

download() {
    local url="$1" out="$2"
    rm -f -- "$out"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 30 --retry 1 -o "$out" "$url" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=2 -O "$out" "$url" && return 0
    fi
    return 1
}

TMP_DIR="$(mktemp -d /tmp/fwmgr-install.XXXXXX)"
trap 'rm -rf -- "$TMP_DIR"' EXIT INT TERM
SCRIPT="$TMP_DIR/fwmgr.sh"
VERSION_FILE="$TMP_DIR/VERSION"
SUMS_FILE="$TMP_DIR/SHA256SUMS"

info "получение последнего стабильного релиза..."
download "${RELEASE_BASE_URL}/VERSION" "$VERSION_FILE" || die "не удалось скачать VERSION"
download "${RELEASE_BASE_URL}/fwmgr.sh" "$SCRIPT" || die "не удалось скачать fwmgr.sh"
download "${RELEASE_BASE_URL}/SHA256SUMS" "$SUMS_FILE" || die "не удалось скачать SHA256SUMS"

LATEST="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
[[ "$LATEST" =~ ^[0-9]+([.][0-9A-Za-z+-]+)+$ ]] || die "некорректный VERSION: $LATEST"
bash -n "$SCRIPT" || die "fwmgr.sh не прошёл bash -n"
EMBEDDED="$(grep -m1 -E '^VERSION="[^"]+"$' "$SCRIPT" | sed -E 's/^VERSION="([^"]+)"$/\1/' || true)"
[[ "$EMBEDDED" == "$LATEST" ]] || die "VERSION=$LATEST, но внутри fwmgr.sh указана версия $EMBEDDED"
EXPECTED="$(awk '$2=="fwmgr.sh" || $2=="*fwmgr.sh" {print $1; exit}' "$SUMS_FILE")"
[[ -n "$EXPECTED" ]] || die "в SHA256SUMS отсутствует fwmgr.sh"
ACTUAL="$(sha256sum "$SCRIPT" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || die "SHA256 fwmgr.sh не совпадает с SHA256SUMS"
chmod 0755 "$SCRIPT"

info "установка FWMgr v${LATEST}..."
if (( EUID == 0 )); then
    bash "$SCRIPT" --install
elif command -v sudo >/dev/null 2>&1; then
    sudo bash "$SCRIPT" --install
else
    die "нужны права root; sudo не найден"
fi

info "готово. Запуск: sudo fwmgr"
