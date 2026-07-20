#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash -n "$ROOT/cleankaskad.sh"
bash -n "$ROOT/install.sh"
! grep -Eiq 'donat|донат|promo|промо|boosty|taplink|cloudtips|anten[-_]?ka' "$ROOT/cleankaskad.sh" "$ROOT/install.sh"
grep -q 'Один Endpoint' "$ROOT/cleankaskad.sh"
grep -q 'listen.*target' "$ROOT/cleankaskad.sh"
echo 'static tests: OK'
