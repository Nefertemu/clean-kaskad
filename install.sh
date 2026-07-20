#!/usr/bin/env bash
set -Eeuo pipefail

REPO="Nefertemu/clean-kaskad"
URL="https://raw.githubusercontent.com/${REPO}/main/cleankaskad.sh"
TMP=$(mktemp /tmp/cleankaskad-install.XXXXXX)
trap 'rm -f "$TMP"' EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
  echo "Запустите установку через sudo:" >&2
  echo "curl -fsSL ${URL%/cleankaskad.sh}/install.sh | sudo bash" >&2
  exit 1
}

if ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates
fi

curl -fsSL --retry 3 --connect-timeout 5 "$URL" -o "$TMP"
bash -n "$TMP"
grep -q '^VERSION="[0-9]\+\.[0-9]\+\.[0-9]\+"' "$TMP" || {
  echo "Загружен некорректный файл CleanKaskad." >&2
  exit 1
}
chmod 755 "$TMP"
bash "$TMP" install

if [[ -r /dev/tty && -w /dev/tty ]]; then
  exec /usr/local/bin/kaskad </dev/tty >/dev/tty 2>/dev/tty
fi
