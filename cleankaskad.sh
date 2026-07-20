#!/usr/bin/env bash
# CleanKaskad — безопасный TCP/UDP DNAT-мост для Ubuntu/Debian.
# Без рекламы, телеметрии и сброса чужих правил firewall.
set -Eeuo pipefail
umask 077

VERSION="2.1.0"
REPO="Nefertemu/clean-kaskad"
SELF="/usr/local/sbin/cleankaskad"
LINK="/usr/local/bin/kaskad"
DIR="/etc/cleankaskad"
RULES="$DIR/rules.tsv"
SERVICE="/etc/systemd/system/cleankaskad.service"
SYSCTL="/etc/sysctl.d/99-cleankaskad.conf"
PRE="CK_PREROUTING"
POST="CK_POSTROUTING"
FWD="CK_FORWARD"
IPT=(iptables -w 10)

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; D='\033[2m'; N='\033[0m'
ok(){ printf '%b[OK]%b %s\n' "$G" "$N" "$*"; }
warn(){ printf '%b[!]%b %s\n' "$Y" "$N" "$*" >&2; }
die(){ printf '%b[ERROR]%b %s\n' "$R" "$N" "$*" >&2; exit 1; }
root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите через sudo."; }
pause(){ [[ -t 0 ]] && read -r -p "Нажмите Enter..." _ || true; }

header(){
  clear 2>/dev/null || true
  printf '%bCleanKaskad %s%b\n' "$C$B" "$VERSION" "$N"
  printf '%bБез рекламы · интерфейсы определяются автоматически · чужой firewall не стирается%b\n\n' "$D" "$N"
}

valid_port(){ [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
valid_ip(){
  local IFS=. a b c d x
  read -r a b c d x <<<"${1:-}"
  [[ -z ${x:-} && -n ${d:-} ]] || return 1
  for x in "$a" "$b" "$c" "$d"; do [[ $x =~ ^[0-9]{1,3}$ ]] && ((10#$x<=255)) || return 1; done
  [[ $1 != 0.0.0.0 && $1 != 255.255.255.255 ]]
}
valid_proto(){ [[ ${1:-} == tcp || ${1:-} == udp ]]; }
valid_iface(){ [[ -n ${1:-} ]] && ip link show dev "$1" >/dev/null 2>&1; }
def_iface(){ ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
out_iface(){ ip -4 route get "$1" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
ensure(){ install -d -m 700 "$DIR"; touch "$RULES"; chmod 600 "$RULES"; }
clean_name(){ local x=${1:-Bridge}; x=${x//$'\t'/ }; x=${x//$'\n'/ }; printf '%s' "${x:0:64}"; }

chains(){
  "${IPT[@]}" -t nat -N "$PRE" 2>/dev/null || true
  "${IPT[@]}" -t nat -N "$POST" 2>/dev/null || true
  "${IPT[@]}" -N "$FWD" 2>/dev/null || true
  "${IPT[@]}" -t nat -C PREROUTING -j "$PRE" 2>/dev/null || "${IPT[@]}" -t nat -I PREROUTING 1 -j "$PRE"
  "${IPT[@]}" -t nat -C POSTROUTING -j "$POST" 2>/dev/null || "${IPT[@]}" -t nat -I POSTROUTING 1 -j "$POST"
  "${IPT[@]}" -C FORWARD -j "$FWD" 2>/dev/null || "${IPT[@]}" -I FORWARD 1 -j "$FWD"
}
flush_own(){ chains; "${IPT[@]}" -t nat -F "$PRE"; "${IPT[@]}" -t nat -F "$POST"; "${IPT[@]}" -F "$FWD"; }
apply(){
  local id=$1 p=$2 rp=$3 ip=$4 dp=$5 i=$6 o=$7 tag="cleankaskad:$1"
  "${IPT[@]}" -t nat -A "$PRE" -i "$i" -p "$p" --dport "$rp" -m comment --comment "$tag" -j DNAT --to-destination "$ip:$dp"
  "${IPT[@]}" -t nat -A "$POST" -o "$o" -p "$p" -d "$ip" --dport "$dp" -m comment --comment "$tag" -j MASQUERADE
  "${IPT[@]}" -A "$FWD" -i "$i" -o "$o" -p "$p" -d "$ip" --dport "$dp" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "$tag" -j ACCEPT
  "${IPT[@]}" -A "$FWD" -i "$o" -o "$i" -p "$p" -s "$ip" --sport "$dp" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$tag" -j ACCEPT
}
restore(){
  ensure
  cat >"$SYSCTL" <<'SYS'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
SYS
  sysctl -p "$SYSCTL" >/dev/null
  flush_own
  local id p rp ip dp i o name n=0
  while IFS=$'\t' read -r id p rp ip dp i o name || [[ -n ${id:-} ]]; do
    [[ -z ${id:-} ]] && continue
    valid_proto "$p" && valid_port "$rp" && valid_ip "$ip" && valid_port "$dp" && valid_iface "$i" && valid_iface "$o" || { warn "Пропущено повреждённое правило ID $id"; continue; }
    apply "$id" "$p" "$rp" "$ip" "$dp" "$i" "$o"; ((n+=1))
  done <"$RULES"
  [[ ${QUIET:-0} == 1 ]] || ok "Восстановлено мостов: $n"
}

conflict(){ awk -F '\t' -v p="$1" -v rp="$2" -v i="$3" -v skip="${4:-}" '$1!=skip&&$2==p&&$3==rp&&$6==i{found=1} END{exit !found}' "$RULES"; }
add(){
  ensure
  local p=${1,,} rp=$2 ip=$3 dp=$4 i=${5:-} o=${6:-} name=${7:-Bridge} id
  valid_proto "$p" || die "Протокол: tcp или udp."
  valid_port "$rp" || die "Неверный порт на RU-сервере."
  valid_ip "$ip" || die "Неверный IPv4."
  valid_port "$dp" || die "Неверный порт зарубежного сервиса."
  [[ -n $i ]] || i=$(def_iface); [[ -n $o ]] || o=$(out_iface "$ip"); [[ -n $o ]] || o=$i
  valid_iface "$i" || die "Не найден входящий интерфейс $i"
  valid_iface "$o" || die "Не найден выходящий интерфейс $o"
  conflict "$p" "$rp" "$i" && die "${p^^}/$rp уже занят другим мостом CleanKaskad."
  id="$(date +%s)$((RANDOM%100000))"; name=$(clean_name "$name")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$p" "$rp" "$ip" "$dp" "$i" "$o" "$name" >>"$RULES"
  restore
  ok "Создано: ${p^^} RU_IP:$rp → $ip:$dp"
  warn "Откройте ${p^^}/$rp в firewall/security group российского VPS."
}

count(){ awk -F '\t' 'NF>=7{n++}END{print n+0}' "$RULES" 2>/dev/null; }
list(){
  ensure; [[ -s $RULES ]] || { warn "Мостов нет."; return; }
  printf '%-3s %-5s %-8s %-22s %-13s %s\n' № PROTO RU_PORT TARGET INTERFACES NAME
  local n=0 id p rp ip dp i o name
  while IFS=$'\t' read -r id p rp ip dp i o name; do ((n+=1)); printf '%-3s %-5s %-8s %-22s %-13s %s\n' "$n" "${p^^}" "$rp" "$ip:$dp" "$i→$o" "$name"; done <"$RULES"
}
id_by_num(){ awk -F '\t' -v n="$1" 'NF>=7{c++;if(c==n){print $1;exit}}' "$RULES"; }
SELECTED_ID=""
choose_id(){
  local n
  SELECTED_ID=""
  list || true
  [[ $(count) -gt 0 ]] || return 1
  read -r -p "Номер правила: " n
  [[ $n =~ ^[0-9]+$ ]] || return 1
  SELECTED_ID=$(id_by_num "$n")
  [[ -n $SELECTED_ID ]]
}
del(){ local id=$1 tmp; grep -q "^${id}"$'\t' "$RULES" || die "ID не найден."; tmp=$(mktemp); awk -F '\t' -v id="$id" '$1!=id' "$RULES" >"$tmp"; mv "$tmp" "$RULES"; chmod 600 "$RULES"; restore; ok "Мост удалён."; }

ask(){ local q=$1 d=${2:-} v; if [[ -n $d ]]; then read -r -p "$q [$d]: " v; else read -r -p "$q: " v; fi; printf '%s' "${v:-$d}"; }
ask_proto(){
  local d=${1:-udp} v
  while true; do
    printf 'Протокол: 1) UDP  2) TCP\n' >&2
    v=$(ask "Выбор" "$([[ $d == udp ]] && echo 1 || echo 2)")
    case ${v,,} in 1|udp) printf udp; return;; 2|tcp) printf tcp; return;; *) warn "Введите 1/udp или 2/tcp.";; esac
  done
}
ask_port(){ local q=$1 d=${2:-} v; while true; do v=$(ask "$q" "$d"); valid_port "$v" && { printf '%s' "$v"; return; }; warn "Порт должен быть от 1 до 65535."; done; }
ask_ip(){ local v; while true; do v=$(ask "IPv4 зарубежного сервера"); valid_ip "$v" && { printf '%s' "$v"; return; }; warn "Некорректный IPv4."; done; }

wizard(){
  local type=$1 p=udp rp_default="" name="Custom" manual=0
  case $type in
    awg) p=udp; rp_default=40443; name="AWG/WireGuard";;
    vless) p=tcp; rp_default=443; name="VLESS/Xray";;
    mtproto) p=tcp; rp_default=443; name="MTProto";;
    custom) ;;
    advanced) manual=1; name="Advanced";;
  esac
  header; printf '%bСоздание моста%b\n\n' "$B" "$N"
  p=$(ask_proto "$p")
  local rp ip dp i o n confirm
  rp=$(ask_port "Порт на российском сервере" "$rp_default")
  ip=$(ask_ip)
  # ВАЖНО: целевой порт всегда спрашивается и не подставляется автоматически.
  dp=$(ask_port "Порт сервиса на зарубежном сервере")
  i=$(def_iface); [[ -n $i ]] || die "Не удалось определить WAN-интерфейс."
  o=$(out_iface "$ip"); [[ -n $o ]] || o=$i
  if ((manual)); then i=$(ask "Входящий интерфейс" "$i"); o=$(ask "Выходящий интерфейс" "$o"); valid_iface "$i" && valid_iface "$o" || die "Интерфейс не найден."; fi
  n=$(ask "Название" "$name")
  printf '\n%bПроверка%b\n' "$B" "$N"
  printf '  Протокол: %s\n  Вход:     RU_IP:%s\n  Выход:    %s:%s\n  Маршрут:  %s → %s %b(автоматически)%b\n  Название: %s\n\n' "${p^^}" "$rp" "$ip" "$dp" "$i" "$o" "$D" "$N" "$n"
  read -r -p "Применить? [Y/n]: " confirm
  [[ ${confirm:-y} =~ ^[YyДд]$ ]] && add "$p" "$rp" "$ip" "$dp" "$i" "$o" "$n" || warn "Отменено."
}

edit(){
  local id line p rp ip dp i o name confirm tmp
  choose_id || { warn "Правило не выбрано."; return; }
  id=$SELECTED_ID
  line=$(awk -F '\t' -v id="$id" '$1==id{print;exit}' "$RULES")
  IFS=$'\t' read -r _ p rp ip dp i o name <<<"$line"
  header; printf '%bИзменение моста%b\n\n' "$B" "$N"
  p=$(ask_proto "$p")
  rp=$(ask_port "Порт на российском сервере" "$rp")
  while true; do ip=$(ask "IPv4 зарубежного сервера" "$ip"); valid_ip "$ip" && break; warn "Некорректный IPv4."; done
  dp=$(ask_port "Порт сервиса на зарубежном сервере" "$dp")
  i=$(def_iface); [[ -n $i ]] || die "Не удалось определить WAN-интерфейс."
  o=$(out_iface "$ip"); [[ -n $o ]] || o=$i
  name=$(ask "Название" "$name")
  conflict "$p" "$rp" "$i" "$id" && die "${p^^}/$rp уже занят другим мостом."
  read -r -p "Сохранить? [Y/n]: " confirm
  [[ ${confirm:-y} =~ ^[YyДд]$ ]] || { warn "Отменено."; return; }
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ ${line%%$'\t'*} == "$id" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$p" "$rp" "$ip" "$dp" "$i" "$o" "$(clean_name "$name")"
    else
      printf '%s\n' "$line"
    fi
  done <"$RULES" >"$tmp"
  mv "$tmp" "$RULES"; chmod 600 "$RULES"; restore; ok "Мост обновлён."
}

reset(){ : >"$RULES"; restore; ok "Все мосты CleanKaskad удалены."; }
status(){
  echo "CleanKaskad $VERSION"
  echo "ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  echo "Мостов: $(count)"
  echo; list || true; echo
  "${IPT[@]}" -t nat -L "$PRE" -n -v --line-numbers 2>/dev/null || true
}

install_app(){
  ensure
  local src; src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
  [[ -f $src ]] || die "Не удалось определить файл скрипта."
  install -m 755 "$src" "$SELF"; ln -sfn "$SELF" "$LINK"
  cat >"$SERVICE" <<EOF_SERVICE
[Unit]
Description=CleanKaskad forwarding rules
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF restore --quiet
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF_SERVICE
  systemctl daemon-reload; systemctl enable cleankaskad.service >/dev/null
  restore; ok "Установлено. Запуск: sudo kaskad"
}
update(){
  local t old=$VERSION new
  t=$(mktemp); curl -fsSL --retry 3 "https://raw.githubusercontent.com/$REPO/main/cleankaskad.sh" -o "$t"
  bash -n "$t" || die "Скачанный скрипт повреждён."
  new=$(bash "$t" --version 2>/dev/null || true); [[ $new =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Не удалось проверить версию."
  install -m 755 "$t" "$SELF"; rm -f "$t"; "$SELF" restore --quiet
  ok "Обновлено: $old → $new"
}
remove_runtime(){
  while "${IPT[@]}" -t nat -C PREROUTING -j "$PRE" 2>/dev/null; do "${IPT[@]}" -t nat -D PREROUTING -j "$PRE" || true; done
  while "${IPT[@]}" -t nat -C POSTROUTING -j "$POST" 2>/dev/null; do "${IPT[@]}" -t nat -D POSTROUTING -j "$POST" || true; done
  while "${IPT[@]}" -C FORWARD -j "$FWD" 2>/dev/null; do "${IPT[@]}" -D FORWARD -j "$FWD" || true; done
  "${IPT[@]}" -t nat -F "$PRE" 2>/dev/null || true; "${IPT[@]}" -t nat -X "$PRE" 2>/dev/null || true
  "${IPT[@]}" -t nat -F "$POST" 2>/dev/null || true; "${IPT[@]}" -t nat -X "$POST" 2>/dev/null || true
  "${IPT[@]}" -F "$FWD" 2>/dev/null || true; "${IPT[@]}" -X "$FWD" 2>/dev/null || true
}
uninstall_app(){
  systemctl disable --now cleankaskad.service >/dev/null 2>&1 || true
  remove_runtime; rm -f "$SERVICE" "$SYSCTL" "$LINK" "$SELF"; rm -rf "$DIR"; systemctl daemon-reload
  ok "CleanKaskad удалён. Чужие правила не затронуты."
}

menu(){
  while true; do
    header
    echo "1) Добавить AWG/WireGuard"
    echo "2) Добавить VLESS/Xray"
    echo "3) Добавить MTProto"
    echo "4) Добавить custom TCP/UDP"
    echo "5) Расширенное правило (ручные интерфейсы)"
    echo "6) Список"
    echo "7) Изменить мост"
    echo "8) Удалить мост"
    echo "9) Диагностика"
    echo "10) Восстановить правила"
    echo "11) Обновить"
    echo "12) Удалить все мосты"
    echo "13) Удалить программу"
    echo "0) Выход"
    echo
    read -r -p "Выбор: " x
    case $x in
      1) wizard awg; pause;; 2) wizard vless; pause;; 3) wizard mtproto; pause;; 4) wizard custom; pause;; 5) wizard advanced; pause;;
      6) list; pause;; 7) edit; pause;;
      8) choose_id || { warn "Правило не выбрано."; pause; continue; }; id=$SELECTED_ID; read -r -p "Удалить? [y/N]: " z; [[ ${z:-n} =~ ^[YyДд]$ ]] && del "$id"; pause;;
      9) status; pause;; 10) restore; pause;; 11) update; pause;;
      12) read -r -p "Удалить все мосты? [y/N]: " z; [[ ${z:-n} =~ ^[YyДд]$ ]] && reset; pause;;
      13) read -r -p "Удалить программу? [y/N]: " z; [[ ${z:-n} =~ ^[YyДд]$ ]] && { uninstall_app; return; };;
      0) return;; *) warn "Неверный пункт."; sleep 1;;
    esac
  done
}
help(){ cat <<EOF_HELP
CleanKaskad $VERSION
kaskad                         меню
kaskad add udp RU_PORT IP DST_PORT [IN] [OUT] [NAME]
kaskad list|status|restore|update|reset|uninstall
kaskad delete ID
EOF_HELP
}
main(){
  case ${1:-} in --version|-v) echo "$VERSION"; exit;; --help|-h|help) help; exit;; esac
  root
  command -v iptables >/dev/null || { apt-get update -y; apt-get install -y iptables iproute2 curl; }
  ensure
  case ${1:-} in
    install) install_app;;
    add) [[ $# -ge 5 ]] || die "Формат: kaskad add PROTO RU_PORT IP DST_PORT [IN] [OUT] [NAME]"; add "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" "${8:-Bridge}";;
    list) list;; delete) del "${2:?ID}";; edit) edit;;
    restore) [[ ${2:-} == --quiet ]] && QUIET=1; restore;; status) status;; update) update;; reset) reset;; uninstall) uninstall_app;;
    '') [[ -x $SELF ]] || install_app; menu;;
    *) die "Неизвестная команда. Используйте kaskad help";;
  esac
}
main "$@"
