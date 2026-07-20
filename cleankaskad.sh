#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="2.0.0"
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

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
ok(){ printf '%b[OK]%b %s\n' "$G" "$N" "$*"; }
warn(){ printf '%b[!]%b %s\n' "$Y" "$N" "$*" >&2; }
die(){ printf '%b[ERROR]%b %s\n' "$R" "$N" "$*" >&2; exit 1; }
root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите через sudo."; }
pause(){ [[ -t 0 ]] && read -r -p "Нажмите Enter..." _ || true; }

valid_port(){ [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
valid_ip(){ local IFS=. a b c d x; read -r a b c d x <<<"${1:-}"; [[ -z ${x:-} && -n ${d:-} ]] || return 1; for x in "$a" "$b" "$c" "$d"; do [[ $x =~ ^[0-9]{1,3}$ ]] && ((10#$x<=255)) || return 1; done; }
valid_proto(){ [[ ${1:-} == tcp || ${1:-} == udp ]]; }
def_iface(){ ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
out_iface(){ ip -4 route get "$1" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'; }
ensure(){ install -d -m 700 "$DIR"; touch "$RULES"; chmod 600 "$RULES"; }

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
  local id=$1 p=$2 rp=$3 ip=$4 dp=$5 inif=$6 outif=$7 tag="cleankaskad:$1"
  "${IPT[@]}" -t nat -A "$PRE" -i "$inif" -p "$p" --dport "$rp" -m comment --comment "$tag" -j DNAT --to-destination "$ip:$dp"
  "${IPT[@]}" -t nat -A "$POST" -o "$outif" -p "$p" -d "$ip" --dport "$dp" -m comment --comment "$tag" -j MASQUERADE
  "${IPT[@]}" -A "$FWD" -i "$inif" -o "$outif" -p "$p" -d "$ip" --dport "$dp" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -m comment --comment "$tag" -j ACCEPT
  "${IPT[@]}" -A "$FWD" -i "$outif" -o "$inif" -p "$p" -s "$ip" --sport "$dp" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$tag" -j ACCEPT
}
restore(){
  ensure
  printf 'net.ipv4.ip_forward = 1\n' >"$SYSCTL"; sysctl -p "$SYSCTL" >/dev/null
  flush_own
  local id p rp ip dp i o name n=0
  while IFS=$'\t' read -r id p rp ip dp i o name || [[ -n ${id:-} ]]; do
    [[ -z ${id:-} ]] && continue
    apply "$id" "$p" "$rp" "$ip" "$dp" "$i" "$o"; ((n+=1))
  done <"$RULES"
  [[ ${QUIET:-0} == 1 ]] || ok "Восстановлено мостов: $n"
}

add(){
  local p=${1,,} rp=$2 ip=$3 dp=$4 i=${5:-} o=${6:-} name=${7:-Bridge} id
  valid_proto "$p" || die "Протокол: tcp или udp."
  valid_port "$rp" || die "Неверный входящий порт."
  valid_ip "$ip" || die "Неверный IPv4."
  valid_port "$dp" || die "Неверный порт назначения."
  [[ -n $i ]] || i=$(def_iface); [[ -n $o ]] || o=$(out_iface "$ip"); [[ -n $o ]] || o=$i
  ip link show "$i" >/dev/null 2>&1 || die "Нет интерфейса $i"
  ip link show "$o" >/dev/null 2>&1 || die "Нет интерфейса $o"
  awk -F '\t' -v p="$p" -v rp="$rp" -v i="$i" '$2==p&&$3==rp&&$6==i{exit 1}' "$RULES" || die "Этот порт уже занят другим мостом CleanKaskad."
  id="$(date +%s)$RANDOM"; name=${name//$'\t'/ }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$p" "$rp" "$ip" "$dp" "$i" "$o" "${name:0:64}" >>"$RULES"
  restore; ok "Создано: ${p^^} $rp → $ip:$dp (ID $id)"
}
list(){
  ensure
  [[ -s $RULES ]] || { warn "Мостов нет."; return; }
  printf '%-20s %-5s %-8s %-22s %-12s %s\n' ID PROTO RU_PORT TARGET INTERFACES NAME
  local id p rp ip dp i o name
  while IFS=$'\t' read -r id p rp ip dp i o name; do printf '%-20s %-5s %-8s %-22s %-12s %s\n' "$id" "$p" "$rp" "$ip:$dp" "$i→$o" "$name"; done <"$RULES"
}
del(){
  local id=$1 tmp; grep -q "^${id}"$'\t' "$RULES" || die "ID не найден."
  tmp=$(mktemp); awk -F '\t' -v id="$id" '$1!=id' "$RULES" >"$tmp"; mv "$tmp" "$RULES"; chmod 600 "$RULES"; restore; ok "Удалено."
}
reset(){ : >"$RULES"; restore; ok "Все мосты CleanKaskad удалены."; }
status(){ echo "CleanKaskad $VERSION"; echo "ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"; echo; list || true; echo; "${IPT[@]}" -t nat -L "$PRE" -n -v --line-numbers 2>/dev/null || true; }

install_app(){
  ensure; install -m 755 "${BASH_SOURCE[0]}" "$SELF"; ln -sfn "$SELF" "$LINK"
  cat >"$SERVICE" <<EOF
[Unit]
Description=CleanKaskad forwarding rules
After=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF restore --quiet
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable cleankaskad.service >/dev/null; restore; ok "Установлено. Запуск: sudo kaskad"
}
update(){ local t; t=$(mktemp); curl -fsSL "https://raw.githubusercontent.com/$REPO/main/cleankaskad.sh" -o "$t"; bash -n "$t"; install -m755 "$t" "$SELF"; rm -f "$t"; "$SELF" restore; ok "Обновлено."; }
uninstall_app(){ systemctl disable --now cleankaskad.service >/dev/null 2>&1 || true; reset; rm -f "$SERVICE" "$SYSCTL" "$LINK" "$SELF"; rm -rf "$DIR"; systemctl daemon-reload; ok "Удалено."; }

ask(){ local q=$1 d=${2:-} v; read -r -p "$q${d:+ [$d]}: " v; printf '%s' "${v:-$d}"; }
wizard(){
  local type=$1 p=udp rp=40443 dp=585 name="AWG/WireGuard" ip i o
  case $type in vless) p=tcp; rp=443; dp=443; name="VLESS/Xray";; mtproto) p=tcp; rp=443; dp=443; name="MTProto";; custom) p=$(ask "Протокол tcp/udp" udp); rp=""; dp=""; name="Custom";; esac
  p=$(ask "Протокол tcp/udp" "$p")
  until valid_port "${rp:-}"; do rp=$(ask "Порт на RU-сервере" "${rp:-40443}"); done
  until valid_ip "${ip:-}"; do ip=$(ask "IP зарубежного сервера"); done
  until valid_port "${dp:-}"; do dp=$(ask "Порт зарубежного сервера" "${dp:-585}"); done
  i=$(ask "Входящий интерфейс" "$(def_iface)"); o=$(ask "Выходящий интерфейс" "$(out_iface "$ip")"); [[ -n $o ]] || o=$i
  name=$(ask "Название" "$name")
  echo; echo "${p^^} $i:$rp → $ip:$dp через $o"; read -r -p "Применить? [Y/n]: " x; [[ ${x:-y} =~ ^[YyДд]$ ]] && add "$p" "$rp" "$ip" "$dp" "$i" "$o" "$name"
}
menu(){
  while true; do
    clear || true; printf '%bCleanKaskad %s%b\nБез рекламы и сброса чужого firewall.\n\n' "$C$B" "$VERSION" "$N"
    echo '1) Добавить AWG/WireGuard'; echo '2) Добавить VLESS/Xray'; echo '3) Добавить MTProto'; echo '4) Добавить custom TCP/UDP'; echo '5) Список'; echo '6) Удалить мост'; echo '7) Диагностика'; echo '8) Восстановить правила'; echo '9) Обновить'; echo '10) Удалить все мосты'; echo '11) Удалить программу'; echo '0) Выход'; echo
    read -r -p 'Выбор: ' x
    case $x in 1) wizard awg;;2) wizard vless;;3) wizard mtproto;;4) wizard custom;;5) list;pause;;6) list; id=$(ask 'ID'); del "$id";pause;;7) status;pause;;8) restore;pause;;9) update;pause;;10) read -r -p 'Точно? [y/N]: ' z; [[ $z =~ ^[YyДд]$ ]] && reset;pause;;11) read -r -p 'Точно? [y/N]: ' z; [[ $z =~ ^[YyДд]$ ]] && { uninstall_app; return; };;0) return;;esac
  done
}
help(){ cat <<EOF
CleanKaskad $VERSION
kaskad                     меню
kaskad add udp 40443 IP 585 [IN] [OUT] [NAME]
kaskad list|status|restore|update|reset|uninstall
kaskad delete ID
EOF
}
main(){
  case ${1:-} in --version|-v) echo "$VERSION"; exit;; --help|-h|help) help; exit;; esac
  root; command -v iptables >/dev/null || { apt-get update -y; apt-get install -y iptables iproute2 curl; }; ensure
  case ${1:-} in install) install_app;; add) [[ $# -ge 5 ]] || die "Недостаточно аргументов"; add "$2" "$3" "$4" "$5" "${6:-}" "${7:-}" "${8:-Bridge}";; list) list;; delete) del "${2:?ID}";; restore) [[ ${2:-} == --quiet ]] && QUIET=1; restore;; status) status;; update) update;; reset) reset;; uninstall) uninstall_app;; '') [[ -x $SELF ]] || install_app; menu;; *) die "Неизвестная команда";; esac
}
main "$@"
