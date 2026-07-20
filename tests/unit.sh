#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../cleankaskad.sh
source "$ROOT/cleankaskad.sh"

fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_eq(){ [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; }
assert_ok(){ "$@" || fail "command failed: $*"; }
assert_fail(){ if "$@"; then fail "command unexpectedly succeeded: $*"; fi; }

assert_ok valid_port 1
assert_ok valid_port 65535
assert_fail valid_port 0
assert_fail valid_port 65536
assert_fail valid_port abc

assert_ok valid_ipv4 89.124.251.231
assert_fail valid_ipv4 999.1.1.1
assert_ok valid_hostname vpn.example.com
assert_fail valid_hostname 'bad_host.example'

parse_endpoint '89.124.251.231:585'
assert_eq "$PARSED_HOST" '89.124.251.231'
assert_eq "$PARSED_PORT" '585'

parse_endpoint 'Endpoint = 89.124.251.231:40443'
assert_eq "$PARSED_HOST" '89.124.251.231'
assert_eq "$PARSED_PORT" '40443'

parse_endpoint 'udp://vpn.example.com:585'
assert_eq "$PARSED_HOST" 'vpn.example.com'
assert_eq "$PARSED_PORT" '585'

assert_fail parse_endpoint '89.124.251.231'
assert_fail parse_endpoint '[2001:db8::1]:585'
assert_fail parse_endpoint 'host:0'

assert_eq "$(sanitize_name $'test\tname\n')" 'test name '

echo 'unit tests: OK'
