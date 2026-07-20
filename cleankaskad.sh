#!/usr/bin/env bash
# CleanKaskad — безопасный каскадный TCP/UDP DNAT-мост для Ubuntu/Debian.
# Главный сценарий: берём Endpoint зарубежного сервера и заменяем только IP на российский.
set -Eeuo pipefail
umask 077

VERSION="3.0.0"
REPO="Nefertemu/clean-kaskad"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
SELF="/usr/local/sbin/cleankaskad"
LINK="/usr/local/bin/kaskad"
STATE_DIR="/etc/cleankaskad"
RULES_FILE="${STATE_DIR}/rules.tsv"
BACKUP_DIR="${STATE_DIR}/backups"
LOCK_FILE="/run/lock/cleankaskad.lock"
SERVICE_FILE="/etc/systemd/system/cleankaskad.service"
SYSCTL_FILE="/etc/sysctl.d/99-cleankaskad.conf"

CHAIN_PRE="CK_PREROUTING"
CHAIN_POST="CK_POSTROUTING"
CHAIN_FWD="CK_FORWARD"
HOOK_COMMENT="cleankaskad:hook"
IPT=(iptables -w 10)

# id preset proto listen_port target_host target_port bind_iface out_iface name created_at
RULE_FIELDS=10

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'
B='\033[1m'; D='\033[2m'; N='\033[0m'

ok()    { printf '%b[OK]%b %s\n' "$G" "$N" "$*"; }
info()  { printf '%b[i]%b %s\n' "$C" "$N" "$*"; }
warn()  { printf '%b[!]%b %s\n' "$Y" "$N" "$*" >&2; }
die()   { printf '%b[ERROR]%b %s\n' "$R" "$N" "$*" >&2; exit 1; }

header() {
  clear 2>/dev/null || true
  printf '%bCleanKaskad %s%b\n' "$C$B" "$VERSION" "$N"
  printf '%bОдин Endpoint · тот же порт · меняется только IP%b\n' "$D" "$N"
  printf '%bБез рекламы, телеметрии и сброса чужого firewall%b\n\n' "$D" "$N"
}

pause() {
  [[ -t 0 ]] && read -r -p "Нажмите Enter..." _ || true
}

confirm() {
  local prompt=${1:-"Продолжить?"} default=${2:-yes} answer
  if [[ $default == yes ]]; then
    read -r -p "$prompt [Y/n]: " answer
    [[ ${answer:-y} =~ ^[YyДд]$ ]]
  else
    read -r -p "$prompt [y/N]: " answer
    [[ ${answer:-n} =~ ^[YyДд]$ ]]
  fi
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите через sudo."
}

acquire_lock() {
  install -d -m 755 "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "CleanKaskad уже выполняется в другом процессе."
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

valid_port() {
  [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_ipv4() {
  local IFS=. a b c d extra octet
  read -r a b c d extra <<<"${1:-}"
  [[ -z ${extra:-} && -n ${d:-} ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ $octet =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
  [[ $1 != 0.0.0.0 && $1 != 255.255.255.255 ]]
}

valid_hostname() {
  local host=${1:-}
  [[ ${#host} -ge 1 && ${#host} -le 253 ]] || return 1
  [[ $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  [[ $host != *..* ]]
}

valid_host() { valid_ipv4 "${1:-}" || valid_hostname "${1:-}"; }
valid_proto() { [[ ${1:-} == udp || ${1:-} == tcp ]]; }
valid_iface() { [[ ${1:-} == any || ${1:-} == auto ]] || ip link show dev "${1:-}" >/dev/null 2>&1; }

sanitize_name() {
  local value=${1:-Bridge}
  value=${value//$'\t'/ }
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  printf '%s' "${value:0:64}"
}

resolve_ipv4() {
  local host=${1:-} ip
  if valid_ipv4 "$host"; then
    printf '%s\n' "$host"
    return 0
  fi
  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '$1 ~ /^[0-9.]+$/ {print $1; exit}')
  valid_ipv4 "$ip" || return 1
  printf '%s\n' "$ip"
}

default_iface() {
  ip -4 route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'
}

route_iface() {
  local ip=${1:-}
  ip -4 route get "$ip" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'
}

route_source() {
  local ip=${1:-}
  ip -4 route get "$ip" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'
}

is_private_ipv4() {
  local ip=${1:-}
  valid_ipv4 "$ip" || return 0
  case "$ip" in
    10.*|127.*|169.254.*|192.168.*) return 0 ;;
    172.*)
      local second=${ip#172.}; second=${second%%.*}
      ((10#$second >= 16 && 10#$second <= 31)) && return 0
      ;;
    100.*)
      local second=${ip#100.}; second=${second%%.*}
      ((10#$second >= 64 && 10#$second <= 127)) && return 0
      ;;
  esac
  return 1
}

PUBLIC_IP_CACHE=""
PUBLIC_IP_CHECKED=0
detect_public_ip() {
  local url ip
  if ((PUBLIC_IP_CHECKED)); then [[ -n $PUBLIC_IP_CACHE ]] && { printf '%s\n' "$PUBLIC_IP_CACHE"; return 0; }; return 1; fi
  PUBLIC_IP_CHECKED=1
  if [[ -r ${STATE_DIR}/public-ip ]]; then
    ip=$(tr -d '[:space:]' <"${STATE_DIR}/public-ip")
    if valid_ipv4 "$ip"; then PUBLIC_IP_CACHE=$ip; printf '%s\n' "$ip"; return 0; fi
  fi
  ip=$(route_source 1.1.1.1 || true)
  if valid_ipv4 "$ip" && ! is_private_ipv4 "$ip"; then PUBLIC_IP_CACHE=$ip; printf '%s\n' "$ip"; return 0; fi
  if command_exists curl; then
    for url in \
      "https://api.ipify.org" \
      "https://ifconfig.me/ip" \
      "https://icanhazip.com"; do
      ip=$(curl -4fsS --connect-timeout 2 --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]' || true)
      if valid_ipv4 "$ip"; then PUBLIC_IP_CACHE=$ip; printf '%s\n' "$ip"; return 0; fi
    done
  fi
  return 1
}

PARSED_HOST=""
PARSED_PORT=""
parse_endpoint() {
  local raw=${1:-} value lower host port
  PARSED_HOST=""; PARSED_PORT=""
  value=${raw%%#*}
  lower=${value,,}
  if [[ $lower =~ ^[[:space:]]*endpoint[[:space:]]*= ]]; then value=${value#*=}; fi
  value=${value#udp://}
  value=${value#tcp://}
  value=${value//[[:space:]]/}
  [[ -n $value ]] || return 1
  [[ $value != \[* ]] || return 1
  [[ $value == *:* ]] || return 1
  host=${value%:*}
  port=${value##*:}
  [[ $host != *:* ]] || return 1
  valid_host "$host" && valid_port "$port" || return 1
  PARSED_HOST=$host
  PARSED_PORT=$port
}

ensure_state() {
  install -d -m 700 "$STATE_DIR" "$BACKUP_DIR"
  touch "$RULES_FILE"
  chmod 600 "$RULES_FILE"
}

backup_rules() {
  ensure_state
  local stamp path
  stamp=$(date +%Y%m%d-%H%M%S)
  path="${BACKUP_DIR}/rules-${stamp}.tsv"
  cp -f "$RULES_FILE" "$path"
  chmod 600 "$path"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'rules-*.tsv' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk 'NR>20{$1="";sub(/^ /,"");print}' | xargs -r rm -f --
  printf '%s\n' "$path"
}

iptables_backend() {
  "${IPT[@]}" --version 2>/dev/null | sed 's/^iptables v[^ ]* //; s/[()]//g'
}

ensure_chain() {
  local table=$1 chain=$2
  if [[ $table == filter ]]; then
    "${IPT[@]}" -N "$chain" 2>/dev/null || true
  else
    "${IPT[@]}" -t "$table" -N "$chain" 2>/dev/null || true
  fi
}

ensure_hook_once() {
  local table=$1 parent=$2 child=$3
  local -a prefix=("${IPT[@]}")
  [[ $table == filter ]] || prefix+=( -t "$table" )
  while "${prefix[@]}" -C "$parent" -m comment --comment "$HOOK_COMMENT" -j "$child" 2>/dev/null; do
    "${prefix[@]}" -D "$parent" -m comment --comment "$HOOK_COMMENT" -j "$child" 2>/dev/null || break
  done
  "${prefix[@]}" -I "$parent" 1 -m comment --comment "$HOOK_COMMENT" -j "$child"
}

ensure_firewall_structure() {
  ensure_chain nat "$CHAIN_PRE"
  ensure_chain nat "$CHAIN_POST"
  ensure_chain filter "$CHAIN_FWD"
  ensure_hook_once nat PREROUTING "$CHAIN_PRE"
  ensure_hook_once nat POSTROUTING "$CHAIN_POST"
  ensure_hook_once filter FORWARD "$CHAIN_FWD"
}

flush_own_rules() {
  ensure_firewall_structure
  "${IPT[@]}" -t nat -F "$CHAIN_PRE"
  "${IPT[@]}" -t nat -F "$CHAIN_POST"
  "${IPT[@]}" -F "$CHAIN_FWD"
}

remove_hook_all() {
  local table=$1 parent=$2 child=$3
  local -a prefix=("${IPT[@]}")
  [[ $table == filter ]] || prefix+=( -t "$table" )
  while "${prefix[@]}" -C "$parent" -m comment --comment "$HOOK_COMMENT" -j "$child" 2>/dev/null; do
    "${prefix[@]}" -D "$parent" -m comment --comment "$HOOK_COMMENT" -j "$child" || true
  done
}

remove_firewall_structure() {
  remove_hook_all nat PREROUTING "$CHAIN_PRE"
  remove_hook_all nat POSTROUTING "$CHAIN_POST"
  remove_hook_all filter FORWARD "$CHAIN_FWD"
  "${IPT[@]}" -t nat -F "$CHAIN_PRE" 2>/dev/null || true
  "${IPT[@]}" -t nat -F "$CHAIN_POST" 2>/dev/null || true
  "${IPT[@]}" -F "$CHAIN_FWD" 2>/dev/null || true
  "${IPT[@]}" -t nat -X "$CHAIN_PRE" 2>/dev/null || true
  "${IPT[@]}" -t nat -X "$CHAIN_POST" 2>/dev/null || true
  "${IPT[@]}" -X "$CHAIN_FWD" 2>/dev/null || true
}

write_sysctl() {
  cat >"$SYSCTL_FILE" <<'SYSCTL'
# Managed by CleanKaskad. Loose rp_filter is safer for asymmetric routing.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
SYSCTL
  sysctl -p "$SYSCTL_FILE" >/dev/null
}

validate_rule_fields() {
  local id=$1 preset=$2 proto=$3 listen=$4 host=$5 target=$6 bind=$7 out=$8 name=$9 created=${10}
  [[ $id =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ $preset =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  valid_proto "$proto" && valid_port "$listen" && valid_host "$host" && valid_port "$target" || return 1
  valid_iface "$bind" && valid_iface "$out" || return 1
  [[ -n $name && -n $created ]]
}

RUNTIME_FILE=""
prepare_runtime() {
  ensure_state
  local tmp errors=0 line_no=0
  local id preset proto listen host target bind out name created ip actual_out
  tmp=$(mktemp /tmp/cleankaskad-runtime.XXXXXX)
  while IFS=$'\t' read -r id preset proto listen host target bind out name created extra || [[ -n ${id:-} ]]; do
    line_no=$((line_no + 1))
    [[ -z ${id:-} || ${id:0:1} == '#' ]] && continue
    if [[ -n ${extra:-} ]] || ! validate_rule_fields "$id" "$preset" "$proto" "$listen" "$host" "$target" "$bind" "$out" "$name" "$created"; then
      warn "Повреждённая строка правил №${line_no}."
      errors=$((errors + 1)); continue
    fi
    if ! ip=$(resolve_ipv4 "$host"); then
      warn "Не удалось разрешить ${host} для правила «${name}»."
      errors=$((errors + 1)); continue
    fi
    actual_out=$out
    [[ $actual_out != auto ]] || actual_out=$(route_iface "$ip" || true)
    if [[ -z $actual_out ]] || ! valid_iface "$actual_out"; then
      warn "Не удалось определить маршрут до ${ip} для правила «${name}»."
      errors=$((errors + 1)); continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$preset" "$proto" "$listen" "$host" "$target" "$bind" "$actual_out" "$name" "$created" "$ip" >>"$tmp"
  done <"$RULES_FILE"
  if ((errors > 0)); then
    rm -f "$tmp"
    return 1
  fi
  RUNTIME_FILE=$tmp
}

apply_runtime_rule() {
  local id=$1 preset=$2 proto=$3 listen=$4 host=$5 target=$6 bind=$7 out=$8 name=$9 created=${10} ip=${11}
  local tag="cleankaskad:${id}"; local -a in_args=()
  [[ $bind == any || $bind == auto ]] || in_args=( -i "$bind" )

  "${IPT[@]}" -t nat -A "$CHAIN_PRE" \
    "${in_args[@]}" -p "$proto" -m addrtype --dst-type LOCAL --dport "$listen" \
    -m comment --comment "$tag" -j DNAT --to-destination "${ip}:${target}"

  "${IPT[@]}" -t nat -A "$CHAIN_POST" \
    -o "$out" -p "$proto" -d "$ip" --dport "$target" \
    -m comment --comment "$tag" -j MASQUERADE

  "${IPT[@]}" -A "$CHAIN_FWD" \
    "${in_args[@]}" -o "$out" -p "$proto" -d "$ip" --dport "$target" \
    -m conntrack --ctstate NEW,ESTABLISHED,RELATED \
    -m comment --comment "$tag" -j ACCEPT

  "${IPT[@]}" -A "$CHAIN_FWD" \
    -i "$out" -p "$proto" -s "$ip" --sport "$target" \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment "$tag" -j ACCEPT
}

restore_rules() {
  local quiet=${1:-0} runtime count=0
  write_sysctl
  if ! prepare_runtime; then
    warn "Правила не изменены: сначала исправьте ошибки конфигурации."
    return 1
  fi
  runtime=$RUNTIME_FILE
  flush_own_rules
  local id preset proto listen host target bind out name created ip
  while IFS=$'\t' read -r id preset proto listen host target bind out name created ip; do
    [[ -n ${id:-} ]] || continue
    apply_runtime_rule "$id" "$preset" "$proto" "$listen" "$host" "$target" "$bind" "$out" "$name" "$created" "$ip"
    count=$((count + 1))
  done <"$runtime"
  rm -f "$runtime"
  [[ $quiet == 1 ]] || ok "Активировано мостов: ${count}."
}

rules_count() {
  awk -F '\t' 'NF>=10 && $1 !~ /^#/ {n++} END{print n+0}' "$RULES_FILE" 2>/dev/null
}

rule_conflicts() {
  local proto=$1 listen=$2 bind=$3 skip=${4:-}
  awk -F '\t' -v p="$proto" -v l="$listen" -v b="$bind" -v skip="$skip" '
    NF>=10 && $1!=skip && $3==p && $4==l {
      if ($7=="any" || $7=="auto" || b=="any" || b=="auto" || $7==b) found=1
    }
    END{exit !found}
  ' "$RULES_FILE"
}

port_listener_info() {
  local proto=$1 port=$2
  command_exists ss || return 1
  if [[ $proto == tcp ]]; then
    ss -H -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print; found=1} END{exit !found}'
  else
    ss -H -lnup 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print; found=1} END{exit !found}'
  fi
}

new_id() {
  printf '%s-%05d' "$(date +%s)" "$((RANDOM % 100000))"
}

append_rule_transaction() {
  local preset=$1 proto=$2 listen=$3 host=$4 target=$5 bind=$6 out=$7 name=$8
  local id created old backup
  ensure_state
  valid_proto "$proto" || die "Неверный протокол."
  valid_port "$listen" || die "Неверный входящий порт."
  valid_host "$host" || die "Неверный IP/hostname назначения."
  valid_port "$target" || die "Неверный порт назначения."
  valid_iface "$bind" || die "Не найден входящий интерфейс ${bind}."
  valid_iface "$out" || die "Не найден выходящий интерфейс ${out}."
  rule_conflicts "$proto" "$listen" "$bind" && die "${proto^^}/${listen} уже используется другим мостом CleanKaskad."

  id=$(new_id); created=$(date -u +%Y-%m-%dT%H:%M:%SZ); name=$(sanitize_name "$name")
  old=$(mktemp /tmp/cleankaskad-rules.XXXXXX)
  cp -f "$RULES_FILE" "$old"
  backup=$(backup_rules)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$preset" "$proto" "$listen" "$host" "$target" "$bind" "$out" "$name" "$created" >>"$RULES_FILE"
  if ! restore_rules 1; then
    cp -f "$old" "$RULES_FILE"
    restore_rules 1 || true
    rm -f "$old"
    die "Не удалось применить правило. Конфигурация возвращена из ${backup}."
  fi
  rm -f "$old"
  LAST_RULE_ID=$id
}

replace_rule_transaction() {
  local replace_id=$1 preset=$2 proto=$3 listen=$4 host=$5 target=$6 bind=$7 out=$8 name=$9
  local created old tmp backup
  created=$(awk -F '\t' -v id="$replace_id" '$1==id{print $10;exit}' "$RULES_FILE")
  [[ -n $created ]] || die "Правило не найдено."
  rule_conflicts "$proto" "$listen" "$bind" "$replace_id" && die "${proto^^}/${listen} уже используется другим мостом CleanKaskad."
  name=$(sanitize_name "$name")
  old=$(mktemp /tmp/cleankaskad-rules.XXXXXX); cp -f "$RULES_FILE" "$old"
  backup=$(backup_rules)
  tmp=$(mktemp /tmp/cleankaskad-edit.XXXXXX)
  awk -F '\t' -v OFS='\t' -v id="$replace_id" -v preset="$preset" -v proto="$proto" \
    -v listen="$listen" -v host="$host" -v target="$target" -v bind="$bind" -v out="$out" \
    -v name="$name" -v created="$created" '
      $1==id {$0=id OFS preset OFS proto OFS listen OFS host OFS target OFS bind OFS out OFS name OFS created}
      {print}
    ' "$RULES_FILE" >"$tmp"
  mv "$tmp" "$RULES_FILE"; chmod 600 "$RULES_FILE"
  if ! restore_rules 1; then
    cp -f "$old" "$RULES_FILE"; restore_rules 1 || true; rm -f "$old"
    die "Изменение отменено. Конфигурация возвращена из ${backup}."
  fi
  rm -f "$old"
}

delete_rule_transaction() {
  local id=$1 old tmp backup
  grep -q "^${id}"$'\t' "$RULES_FILE" || die "Правило не найдено."
  old=$(mktemp /tmp/cleankaskad-rules.XXXXXX); cp -f "$RULES_FILE" "$old"
  backup=$(backup_rules)
  tmp=$(mktemp /tmp/cleankaskad-delete.XXXXXX)
  awk -F '\t' -v id="$id" '$1!=id' "$RULES_FILE" >"$tmp"
  mv "$tmp" "$RULES_FILE"; chmod 600 "$RULES_FILE"
  if ! restore_rules 1; then
    cp -f "$old" "$RULES_FILE"; restore_rules 1 || true; rm -f "$old"
    die "Удаление отменено. Конфигурация возвращена из ${backup}."
  fi
  rm -f "$old"
}

reset_rules_transaction() {
  local old backup
  old=$(mktemp /tmp/cleankaskad-rules.XXXXXX); cp -f "$RULES_FILE" "$old"
  backup=$(backup_rules)
  : >"$RULES_FILE"
  if ! restore_rules 1; then
    cp -f "$old" "$RULES_FILE"; restore_rules 1 || true; rm -f "$old"
    die "Очистка отменена. Конфигурация возвращена из ${backup}."
  fi
  rm -f "$old"
}

public_endpoint() {
  local port=$1 ip
  if ip=$(detect_public_ip); then printf '%s:%s' "$ip" "$port"; else printf 'RU_PUBLIC_IP:%s' "$port"; fi
}

human_bytes() {
  local bytes=${1:-0}
  awk -v b="$bytes" 'BEGIN{split("B KiB MiB GiB TiB",u);i=1;while(b>=1024&&i<5){b/=1024;i++}printf (i==1?"%d %s":"%.1f %s"),b,u[i]}'
}

counter_for_id() {
  local id=$1 line counts
  line=$("${IPT[@]}" -t nat -L "$CHAIN_PRE" -n -v -x 2>/dev/null | grep -F "cleankaskad:${id}" | head -n1 || true)
  [[ -n $line ]] || { printf '0\t0'; return; }
  counts=$(awk '{print $1"\t"$2}' <<<"$line")
  printf '%s' "$counts"
}

list_rules() {
  ensure_state
  local total public ip_display id preset proto listen host target bind out name created n=0 pkts bytes mode
  total=$(rules_count)
  ((total > 0)) || { warn "Мостов пока нет."; return 1; }
  public=$(detect_public_ip || true); ip_display=${public:-RU_IP}
  printf '%-3s %-18s %-5s %-22s %-24s %-8s %s\n' "№" "НАЗВАНИЕ" "PROTO" "РОССИЙСКИЙ ENDPOINT" "ЗАРУБЕЖНЫЙ ENDPOINT" "ПАКЕТЫ" "РЕЖИМ"
  while IFS=$'\t' read -r id preset proto listen host target bind out name created; do
    [[ -n ${id:-} ]] || continue
    n=$((n + 1)); IFS=$'\t' read -r pkts bytes <<<"$(counter_for_id "$id")"
    [[ $listen == "$target" ]] && mode="зеркало" || mode="${listen}→${target}"
    printf '%-3s %-18.18s %-5s %-22s %-24s %-8s %s\n' \
      "$n" "$name" "${proto^^}" "${ip_display}:${listen}" "${host}:${target}" "${pkts:-0}" "$mode"
  done <"$RULES_FILE"
}

SELECTED_ID=""
select_rule() {
  local number
  SELECTED_ID=""
  list_rules || return 1
  read -r -p "Номер правила: " number
  [[ $number =~ ^[0-9]+$ ]] || return 1
  SELECTED_ID=$(awk -F '\t' -v n="$number" 'NF>=10{c++;if(c==n){print $1;exit}}' "$RULES_FILE")
  [[ -n $SELECTED_ID ]]
}

ask_value() {
  local prompt=$1 default=${2:-} value
  if [[ -n $default ]]; then read -r -p "$prompt [$default]: " value
  else read -r -p "$prompt: " value; fi
  printf '%s' "${value:-$default}"
}

ask_proto() {
  local default=${1:-udp} value default_number
  [[ $default == udp ]] && default_number=1 || default_number=2
  while true; do
    printf '1) UDP    2) TCP\n' >&2
    value=$(ask_value "Протокол" "$default_number")
    case ${value,,} in
      1|udp) printf udp; return ;;
      2|tcp) printf tcp; return ;;
      *) warn "Введите 1/udp или 2/tcp." ;;
    esac
  done
}

ask_endpoint() {
  local default=${1:-} value
  while true; do
    value=$(ask_value "Endpoint зарубежного сервера (IP:порт или строка Endpoint = ...)" "$default")
    if parse_endpoint "$value"; then return 0; fi
    warn "Пример правильного значения: 89.124.251.231:585"
  done
}

ask_port() {
  local prompt=$1 default=${2:-} value
  while true; do
    value=$(ask_value "$prompt" "$default")
    valid_port "$value" && { printf '%s' "$value"; return; }
    warn "Порт должен быть числом от 1 до 65535."
  done
}

check_target_route() {
  local host=$1 proto=$2 port=$3 ip out source
  if ! ip=$(resolve_ipv4 "$host"); then
    warn "Hostname ${host} сейчас не разрешается."
    return 1
  fi
  out=$(route_iface "$ip" || true); source=$(route_source "$ip" || true)
  [[ -n $out ]] || { warn "Нет маршрута до ${ip}."; return 1; }
  info "Маршрут до цели: ${source:-?} → ${out} → ${ip}:${port}/${proto}."
  if [[ $proto == tcp ]]; then
    if timeout 3 bash -c "</dev/tcp/${ip}/${port}" 2>/dev/null; then ok "TCP-порт зарубежного сервера отвечает."
    else warn "TCP-порт не ответил за 3 секунды. Это может быть firewall или сервис, который молчит до правильного handshake."; fi
  fi
}

show_ready_endpoint() {
  local port=$1 endpoint
  endpoint=$(public_endpoint "$port")
  printf '\n%bГотовая замена в клиентском конфиге:%b\n' "$B" "$N"
  printf '%bEndpoint = %s%b\n\n' "$G$B" "$endpoint" "$N"
  printf 'Ключи, AWG-параметры и порт остаются от зарубежной конфигурации.\n'
}

quick_wizard() {
  local preset=$1 proto=$2 default_name=$3 name host port listener
  header
  printf '%bБыстрый каскад: %s%b\n\n' "$B" "$default_name" "$N"
  printf 'Вставьте зарубежный Endpoint. CleanKaskad примет трафик на %bтом же порту%b.\n' "$B" "$N"
  printf 'В клиентском конфиге потребуется заменить только зарубежный IP на российский.\n\n'
  ask_endpoint
  host=$PARSED_HOST; port=$PARSED_PORT
  name=$(ask_value "Название" "$default_name")

  if listener=$(port_listener_info "$proto" "$port" 2>/dev/null); then
    warn "На ${proto^^}/${port} уже слушает локальный процесс:"
    printf '%s\n' "$listener"
    warn "DNAT перехватит внешний трафик на этом порту до локального сервиса."
  fi
  check_target_route "$host" "$proto" "$port" || true

  printf '\n%bБудет создано:%b\n' "$B" "$N"
  printf '  Клиент → %s/%s на RU-сервере → %s:%s\n' "$proto" "$port" "$host" "$port"
  printf '  Режим: зеркальный порт, интерфейсы и маршрут определяются автоматически.\n'
  printf '  Чужие правила firewall не изменяются.\n\n'
  confirm "Применить" yes || { warn "Отменено."; return; }

  append_rule_transaction "$preset" "$proto" "$port" "$host" "$port" any auto "$name"
  ok "Мост «${name}» создан."
  warn "Разрешите ${proto^^}/${port} в firewall/security group российского VPS."
  show_ready_endpoint "$port"
}

custom_mirror_wizard() {
  local proto
  header; printf '%bУниверсальный зеркальный мост%b\n\n' "$B" "$N"
  proto=$(ask_proto udp)
  quick_wizard custom "$proto" "Custom ${proto^^}"
}

advanced_wizard() {
  local proto host target listen bind=any out=auto name default_iface_value choice listener
  header
  printf '%bРасширенный мост%b\n\n' "$B" "$N"
  printf 'Здесь входящий порт может отличаться от зарубежного. Обычным пользователям этот режим не нужен.\n\n'
  proto=$(ask_proto udp)
  ask_endpoint
  host=$PARSED_HOST; target=$PARSED_PORT
  listen=$(ask_port "Порт на российском сервере" "$target")
  default_iface_value=$(default_iface || true)
  read -r -p "Ограничить конкретным входящим интерфейсом? [y/N]: " choice
  if [[ ${choice:-n} =~ ^[YyДд]$ ]]; then bind=$(ask_value "Входящий интерфейс" "$default_iface_value"); valid_iface "$bind" || die "Интерфейс не найден."; fi
  read -r -p "Задать выходящий интерфейс вручную? [y/N]: " choice
  if [[ ${choice:-n} =~ ^[YyДд]$ ]]; then
    local resolved default_out
    resolved=$(resolve_ipv4 "$host" || true)
    default_out=$(route_iface "$resolved" || true)
    out=$(ask_value "Выходящий интерфейс" "$default_out")
    valid_iface "$out" || die "Интерфейс не найден."
  fi
  name=$(ask_value "Название" "Advanced ${proto^^}")
  if listener=$(port_listener_info "$proto" "$listen" 2>/dev/null); then warn "На ${proto^^}/${listen} уже есть локальный listener:"; printf '%s\n' "$listener"; fi
  printf '\n%s RU_IP:%s → %s:%s  bind=%s  out=%s\n\n' "${proto^^}" "$listen" "$host" "$target" "$bind" "$out"
  confirm "Применить" yes || { warn "Отменено."; return; }
  append_rule_transaction advanced "$proto" "$listen" "$host" "$target" "$bind" "$out" "$name"
  ok "Расширенный мост создан."
  show_ready_endpoint "$listen"
}

edit_wizard() {
  local id line preset proto listen host target bind out name created endpoint_value new_proto new_host new_target new_listen new_name choice
  header
  select_rule || { warn "Правило не выбрано."; return; }
  id=$SELECTED_ID
  line=$(awk -F '\t' -v id="$id" '$1==id{print;exit}' "$RULES_FILE")
  IFS=$'\t' read -r _ preset proto listen host target bind out name created <<<"$line"
  header; printf '%bИзменение «%s»%b\n\n' "$B" "$name" "$N"
  new_proto=$(ask_proto "$proto")
  endpoint_value=$(ask_value "Endpoint зарубежного сервера" "${host}:${target}")
  while ! parse_endpoint "$endpoint_value"; do warn "Неверный Endpoint."; endpoint_value=$(ask_value "Endpoint зарубежного сервера" "${host}:${target}"); done
  new_host=$PARSED_HOST; new_target=$PARSED_PORT
  new_listen=$listen
  if [[ $listen == "$target" ]]; then
    read -r -p "Сохранить зеркальный порт ${new_target} на RU-сервере? [Y/n]: " choice
    if [[ ${choice:-y} =~ ^[YyДд]$ ]]; then new_listen=$new_target; else new_listen=$(ask_port "Порт на российском сервере" "$listen"); fi
  else
    new_listen=$(ask_port "Порт на российском сервере" "$listen")
  fi
  new_name=$(ask_value "Название" "$name")
  printf '\n%s RU_IP:%s → %s:%s\n\n' "${new_proto^^}" "$new_listen" "$new_host" "$new_target"
  confirm "Сохранить" yes || { warn "Отменено."; return; }
  replace_rule_transaction "$id" "$preset" "$new_proto" "$new_listen" "$new_host" "$new_target" "$bind" "$out" "$new_name"
  ok "Правило обновлено."
  show_ready_endpoint "$new_listen"
}

delete_wizard() {
  local id name
  header
  select_rule || { warn "Правило не выбрано."; return; }
  id=$SELECTED_ID
  name=$(awk -F '\t' -v id="$id" '$1==id{print $9;exit}' "$RULES_FILE")
  confirm "Удалить мост «${name}»" no || { warn "Отменено."; return; }
  delete_rule_transaction "$id"
  ok "Мост удалён."
}

show_endpoints() {
  local public id preset proto listen host target bind out name created
  public=$(detect_public_ip || true); public=${public:-RU_PUBLIC_IP}
  printf '%bГотовые строки для клиентских конфигов%b\n\n' "$B" "$N"
  while IFS=$'\t' read -r id preset proto listen host target bind out name created; do
    [[ -n ${id:-} ]] || continue
    printf '%-20s  Endpoint = %s:%s\n' "$name" "$public" "$listen"
  done <"$RULES_FILE"
}

diagnostics() {
  local public backend hooks=0 id preset proto listen host target bind out name created ip route pkts bytes listener
  header; printf '%bДиагностика%b\n\n' "$B" "$N"
  backend=$(iptables_backend || true); printf 'Версия:           %s\n' "$VERSION"
  printf 'iptables backend: %s\n' "${backend:-unknown}"
  printf 'ip_forward:       %s\n' "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  printf 'systemd service:  %s\n' "$(systemctl is-enabled cleankaskad.service 2>/dev/null || echo not-installed) / $(systemctl is-active cleankaskad.service 2>/dev/null || echo inactive)"
  if public=$(detect_public_ip); then printf 'Публичный RU IP:  %s\n' "$public"; else printf 'Публичный RU IP:  не определён\n'; fi
  "${IPT[@]}" -t nat -C PREROUTING -m comment --comment "$HOOK_COMMENT" -j "$CHAIN_PRE" 2>/dev/null && hooks=$((hooks+1))
  "${IPT[@]}" -t nat -C POSTROUTING -m comment --comment "$HOOK_COMMENT" -j "$CHAIN_POST" 2>/dev/null && hooks=$((hooks+1))
  "${IPT[@]}" -C FORWARD -m comment --comment "$HOOK_COMMENT" -j "$CHAIN_FWD" 2>/dev/null && hooks=$((hooks+1))
  printf 'Firewall hooks:   %s/3\n\n' "$hooks"

  if (( $(rules_count) == 0 )); then warn "Мостов нет."; return; fi
  while IFS=$'\t' read -r id preset proto listen host target bind out name created; do
    [[ -n ${id:-} ]] || continue
    printf '%b%s%b\n' "$B" "$name" "$N"
    if ip=$(resolve_ipv4 "$host"); then route=$(route_iface "$ip" || true); printf '  Цель:       %s:%s → %s, маршрут %s\n' "$host" "$target" "$ip" "${route:-нет}"
    else printf '  Цель:       %s:%s, DNS/IPv4 не разрешается\n' "$host" "$target"; fi
    IFS=$'\t' read -r pkts bytes <<<"$(counter_for_id "$id")"
    printf '  Вход:      %s/%s, пакетов %s, трафик %s\n' "${proto^^}" "$listen" "${pkts:-0}" "$(human_bytes "${bytes:-0}")"
    if listener=$(port_listener_info "$proto" "$listen" 2>/dev/null); then printf '  %bВнимание:%b локальный процесс также слушает этот порт\n' "$Y" "$N"; fi
    printf '  Endpoint:  Endpoint = %s\n\n' "$(public_endpoint "$listen")"
  done <"$RULES_FILE"
  printf '%bПодсказка:%b если пакеты = 0, трафик не дошёл до RU-сервера: проверьте Endpoint и security group.\n' "$C" "$N"
}

export_backup() {
  local path stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  path="/root/cleankaskad-backup-${stamp}.tar.gz"
  tar -C "$STATE_DIR" -czf "$path" rules.tsv public-ip 2>/dev/null || tar -C "$STATE_DIR" -czf "$path" rules.tsv
  chmod 600 "$path"
  ok "Резервная копия: ${path}"
}

set_public_ip_override() {
  local current value
  current=$(cat "${STATE_DIR}/public-ip" 2>/dev/null || true)
  value=$(ask_value "Публичный IPv4 российского сервера или auto" "${current:-auto}")
  if [[ ${value,,} == auto ]]; then rm -f "${STATE_DIR}/public-ip"; ok "Включено автоматическое определение."
  elif valid_ipv4 "$value"; then printf '%s\n' "$value" >"${STATE_DIR}/public-ip"; chmod 600 "${STATE_DIR}/public-ip"; ok "Сохранено."
  else warn "Некорректный IPv4."; return; fi
  PUBLIC_IP_CACHE=""; PUBLIC_IP_CHECKED=0
}

install_dependencies() {
  local missing=()
  command_exists iptables || missing+=(iptables)
  command_exists ip || missing+=(iproute2)
  command_exists curl || missing+=(curl)
  command_exists getent || missing+=(libc-bin)
  command_exists flock || missing+=(util-linux)
  command_exists ss || missing+=(iproute2)
  if ((${#missing[@]})); then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ca-certificates "${missing[@]}"
  fi
}

write_service() {
  cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=CleanKaskad forwarding rules
Wants=network-online.target
After=network-online.target ufw.service docker.service

[Service]
Type=oneshot
ExecStart=${SELF} restore --quiet
ExecReload=${SELF} restore --quiet
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload
  systemctl enable cleankaskad.service >/dev/null
}

install_app() {
  install_dependencies
  ensure_state
  install -m 755 "${BASH_SOURCE[0]}" "$SELF"
  ln -sfn "$SELF" "$LINK"
  write_service
  restore_rules 1
  systemctl reset-failed cleankaskad.service >/dev/null 2>&1 || true
  ok "CleanKaskad ${VERSION} установлен. Команда: sudo kaskad"
}

update_app() {
  local tmp remote_version backup
  command_exists curl || die "Для обновления нужен curl."
  tmp=$(mktemp /tmp/cleankaskad-update.XXXXXX)
  trap 'rm -f "${tmp:-}"' RETURN
  curl -fsSL --retry 3 --connect-timeout 5 "${RAW_BASE}/cleankaskad.sh" -o "$tmp"
  bash -n "$tmp" || die "Загруженный файл не прошёл bash -n."
  remote_version=$(awk -F '"' '/^VERSION=/{print $2;exit}' "$tmp")
  [[ $remote_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Не удалось определить версию обновления."
  backup="${SELF}.backup-${VERSION}"
  cp -f "$SELF" "$backup" 2>/dev/null || true
  install -m 755 "$tmp" "$SELF"
  write_service
  if ! restore_rules 1; then cp -f "$backup" "$SELF" 2>/dev/null || true; die "Обновление откатилось из-за ошибки восстановления."; fi
  rm -f "$backup" "$tmp"
  trap - RETURN
  ok "Обновлено: ${VERSION} → ${remote_version}."
}

heal_rules() {
  ensure_firewall_structure
  local configured active
  configured=$(rules_count)
  active=$("${IPT[@]}" -t nat -L "$CHAIN_PRE" -n 2>/dev/null | grep -c 'cleankaskad:' || true)
  if [[ $active -ne $configured ]]; then
    warn "Активных правил ${active}, ожидается ${configured}. Восстанавливаю."
    restore_rules 1
  else
    ok "Hooks и правила на месте (${active}/${configured})."
  fi
}

uninstall_app() {
  systemctl disable --now cleankaskad.service >/dev/null 2>&1 || true
  remove_firewall_structure
  rm -f "$SERVICE_FILE" "$SYSCTL_FILE" "$LINK" "$SELF"
  systemctl daemon-reload
  if confirm "Удалить также конфигурацию и резервные копии" no; then rm -rf "$STATE_DIR"; else info "Конфигурация оставлена в ${STATE_DIR}."; fi
  ok "CleanKaskad удалён."
}

menu() {
  local choice
  while true; do
    header
    printf '  %b1%b) AWG / WireGuard — вставить Endpoint\n' "$G" "$N"
    printf '  %b2%b) VLESS / Xray — вставить Endpoint\n' "$G" "$N"
    printf '  %b3%b) MTProto — вставить Endpoint\n' "$G" "$N"
    printf '  %b4%b) Универсальный зеркальный TCP/UDP\n' "$G" "$N"
    printf '  %b5%b) Расширенный режим с заменой порта\n\n' "$Y" "$N"
    printf '  6) Список мостов\n'
    printf '  7) Готовые Endpoint для клиентов\n'
    printf '  8) Изменить мост\n'
    printf '  9) Удалить мост\n'
    printf ' 10) Диагностика\n'
    printf ' 11) Восстановить / починить правила\n'
    printf ' 12) Резервная копия\n'
    printf ' 13) Указать публичный RU IP вручную\n'
    printf ' 14) Обновить CleanKaskad\n'
    printf ' 15) Удалить все мосты\n'
    printf ' 16) Удалить программу\n'
    printf '  0) Выход\n\n'
    read -r -p "Выбор: " choice
    case $choice in
      1) quick_wizard awg udp "AWG/WireGuard"; pause ;;
      2) quick_wizard vless tcp "VLESS/Xray"; pause ;;
      3) quick_wizard mtproto tcp "MTProto"; pause ;;
      4) custom_mirror_wizard; pause ;;
      5) advanced_wizard; pause ;;
      6) header; list_rules || true; pause ;;
      7) header; show_endpoints; pause ;;
      8) edit_wizard; pause ;;
      9) delete_wizard; pause ;;
      10) diagnostics; pause ;;
      11) header; heal_rules; pause ;;
      12) header; export_backup; pause ;;
      13) header; set_public_ip_override; pause ;;
      14) header; update_app; pause ;;
      15) header; confirm "Удалить все мосты CleanKaskad" no && { reset_rules_transaction; ok "Все мосты удалены."; }; pause ;;
      16) header; confirm "Полностью удалить CleanKaskad" no && { uninstall_app; return; }; pause ;;
      0) return ;;
      *) warn "Неизвестный пункт."; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<EOF_USAGE
CleanKaskad ${VERSION}

Интерактивно:
  sudo kaskad

CLI:
  sudo kaskad add awg 89.124.251.231:585 [NAME]
  sudo kaskad add vless example.com:443 [NAME]
  sudo kaskad add mtproto 1.2.3.4:443 [NAME]
  sudo kaskad add mirror udp 1.2.3.4:585 [NAME]
  sudo kaskad add advanced udp RU_PORT 1.2.3.4:TARGET_PORT [NAME]
  sudo kaskad list | endpoints | diagnose | restore | heal | update
  sudo kaskad delete ID
  sudo kaskad reset | backup | uninstall
EOF_USAGE
}

cli_add() {
  local mode=${1:-} proto endpoint name host port listen
  case $mode in
    awg) proto=udp; endpoint=${2:-}; name=${3:-AWG/WireGuard};;
    vless) proto=tcp; endpoint=${2:-}; name=${3:-VLESS/Xray};;
    mtproto) proto=tcp; endpoint=${2:-}; name=${3:-MTProto};;
    mirror) proto=${2:-}; endpoint=${3:-}; name=${4:-Custom}; valid_proto "$proto" || die "Протокол: udp или tcp.";;
    advanced) proto=${2:-}; listen=${3:-}; endpoint=${4:-}; name=${5:-Advanced}; valid_proto "$proto" || die "Протокол: udp или tcp."; valid_port "$listen" || die "Неверный RU_PORT.";;
    *) die "Режим add: awg, vless, mtproto, mirror или advanced.";;
  esac
  parse_endpoint "$endpoint" || die "Endpoint должен иметь вид IP:PORT."
  host=$PARSED_HOST; port=$PARSED_PORT
  [[ $mode == advanced ]] || listen=$port
  append_rule_transaction "$mode" "$proto" "$listen" "$host" "$port" any auto "$name"
  ok "Создано: ${proto^^} RU_IP:${listen} → ${host}:${port}"
  show_ready_endpoint "$listen"
}

main() {
  case ${1:-} in --version|-v) printf '%s\n' "$VERSION"; return;; --help|-h|help) usage; return;; esac
  require_root
  acquire_lock
  install_dependencies
  ensure_state
  case ${1:-} in
    install) install_app ;;
    add) shift; cli_add "$@" ;;
    list) list_rules ;;
    endpoints) show_endpoints ;;
    diagnose|diagnostics|status) diagnostics ;;
    restore) restore_rules "$([[ ${2:-} == --quiet ]] && echo 1 || echo 0)" ;;
    heal) heal_rules ;;
    delete) delete_rule_transaction "${2:?Укажите ID}"; ok "Удалено." ;;
    reset) reset_rules_transaction; ok "Все мосты удалены." ;;
    backup) export_backup ;;
    update) update_app ;;
    uninstall) uninstall_app ;;
    '') [[ -x $SELF ]] || install_app; menu ;;
    *) usage; die "Неизвестная команда: $1" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
