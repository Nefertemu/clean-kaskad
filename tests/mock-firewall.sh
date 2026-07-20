#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../cleankaskad.sh
source "$ROOT/cleankaskad.sh"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
STATE_DIR="$TMPDIR_TEST/state"
RULES_FILE="$STATE_DIR/rules.tsv"
BACKUP_DIR="$STATE_DIR/backups"
SYSCTL_FILE="$TMPDIR_TEST/sysctl.conf"
LOG="$TMPDIR_TEST/apply.log"

write_sysctl(){ :; }
flush_own_rules(){ :; }
valid_iface(){ return 0; }
resolve_ipv4(){ printf '%s\n' "$1"; }
route_iface(){ printf 'eth0\n'; }
apply_runtime_rule(){ printf '%s\n' "$*" >>"$LOG"; }

ensure_state
printf 'rule-1\tawg\tudp\t585\t89.124.251.231\t585\tany\tauto\tdataforest\t2026-07-20T00:00:00Z\n' >"$RULES_FILE"
restore_rules 1

grep -q '^rule-1 awg udp 585 89.124.251.231 585 any eth0 dataforest 2026-07-20T00:00:00Z 89.124.251.231$' "$LOG"
echo 'mock firewall test: OK'
