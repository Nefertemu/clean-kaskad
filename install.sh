#!/usr/bin/env bash
set -Eeuo pipefail
REPO="Nefertemu/clean-kaskad"
URL="https://raw.githubusercontent.com/$REPO/main/cleankaskad.sh"
TMP=$(mktemp /tmp/cleankaskad.XXXXXX)
trap 'rm -f "$TMP"' EXIT
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Запустите через sudo" >&2; exit 1; }
if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 "$URL" -o "$TMP"; else apt-get update -y; apt-get install -y curl; curl -fL --retry 3 "$URL" -o "$TMP"; fi
bash -n "$TMP"
chmod 755 "$TMP"
bash "$TMP" install
if [[ -r /dev/tty && -w /dev/tty ]]; then exec /usr/local/bin/kaskad </dev/tty >/dev/tty 2>/dev/tty; fi
