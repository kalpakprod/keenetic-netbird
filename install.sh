#!/bin/sh
# NetBird на роутере: Keenetic (Entware) и OpenWrt.
# Использование: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]
# Переменные окружения:
#   NB_PLATFORM=keenetic|openwrt   принудительно выбрать платформу (по умолчанию автоопределение)
#   NB_NO_UP=1                     всё поставить, но не выполнять "netbird up" (для проверки/CI)
#   NB_LAN=br0                     LAN-интерфейс Keenetic (по умолчанию br0)
#   NB_UP_FLAGS="..."              дополнительные флаги к "netbird up" (например --disable-firewall)
#   NB_PORTS="22 222 80 443"       порты роутера, открываемые из сети NetBird (Keenetic)
set -e

KEY="$1"
MGMT="${2:-https://api.netbird.io}"
NB_LAN="${NB_LAN:-br0}"
NB_PORTS="${NB_PORTS:-22 222 80 443}"
NB_NET=100.64.0.0/10

log()  { printf '%s\n' "$*"; }
fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

detect_platform() {
  [ -n "$NB_PLATFORM" ] && { echo "$NB_PLATFORM"; return; }
  if [ -f /etc/openwrt_release ]; then echo openwrt; return; fi
  if [ -d /opt/etc/init.d ] && command -v opkg >/dev/null 2>&1; then echo keenetic; return; fi
  echo unknown
}

wait_daemon() {
  i=0
  until netbird status >/dev/null 2>&1 || [ $i -ge 20 ]; do sleep 1; i=$((i+1)); done
}

register_peer() {
  [ -n "$NB_NO_UP" ] && { log "NB_NO_UP задан: пропускаю netbird up"; return; }
  [ -n "$KEY" ] || fail "нужен Setup Key: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]"
  wait_daemon
  # shellcheck disable=SC2086
  netbird up --setup-key "$KEY" --management-url "$MGMT" --disable-dns $NB_UP_FLAGS
  sleep 5
  echo
  netbird status
  IP=$(ip -4 addr show wt0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
  [ -n "$IP" ] || fail "wt0 без адреса. Смотри лог: $1"
  echo
  log "Готово. NetBird-IP роутера: $IP"
  log "Проверка: reboot, через 2 мин с другого пира NetBird: ssh $2@$IP"
}

# ---------------------------------------------------------------- Keenetic (Entware)
install_keenetic() {
  FLAGS_FILE=/opt/etc/netbird/env
  HOOK=/opt/etc/ndm/netfilter.d/netbird.sh
  WD=/opt/etc/netbird/watchdog.sh

  [ -c /dev/net/tun ] || fail "нет /dev/net/tun: установи компонент 'WireGuard VPN' (Параметры системы -> Компоненты) и повтори"

  log "[1/6] Keenetic/Entware, архитектура $(uname -m), ядро $(uname -r)"
  opkg update >/dev/null
  opkg list 2>/dev/null | grep -q '^netbird ' || fail "пакета netbird нет в репозитории Entware для $(uname -m)"

  log "[2/6] пакеты: netbird iptables cron"
  opkg install netbird iptables cron

  log "[3/6] флаги демона -> $FLAGS_FILE"
  mkdir -p /opt/etc/netbird /opt/var/log
  cat > "$FLAGS_FILE" <<'EOF_FLAGS'
# читается штатным /opt/etc/init.d/S99netbird из пакета Entware
FLAGS="--log-file /opt/var/log/netbird.log --log-level info"
EOF_FLAGS

  log "[4/6] хук netfilter -> $HOOK"
  mkdir -p /opt/etc/ndm/netfilter.d
  {
    printf '#!/bin/sh\n'
    # shellcheck disable=SC2016
    printf '# Вызывается ndm с переменной $table при каждой пересборке netfilter (загрузка, смена WAN, изменения в веб-интерфейсе)\n'
    printf 'IPT=/opt/sbin/iptables\nNB_NET=%s\nLAN=%s\nPORTS="%s"\n' "$NB_NET" "$NB_LAN" "$NB_PORTS"
    cat <<'EOF_HOOK'
add() { $IPT "$@" 2>/dev/null; }
case "$table" in
  filter)
    # ответы через туннель не должны отбрасываться как асимметричные
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null; done
    # доступ к самому роутеру из сети NetBird
    add -C INPUT -i wt0 -p icmp -j ACCEPT || add -I INPUT 1 -i wt0 -p icmp -j ACCEPT
    for p in $PORTS; do
      add -C INPUT -i wt0 -p tcp --dport "$p" -j ACCEPT || add -I INPUT 1 -i wt0 -p tcp --dport "$p" -j ACCEPT
    done
    # доступ из NetBird в домашнюю сеть
    add -C FORWARD -i wt0 -o "$LAN" -j ACCEPT || add -I FORWARD 1 -i wt0 -o "$LAN" -j ACCEPT
    add -C FORWARD -i "$LAN" -o wt0 -m state --state RELATED,ESTABLISHED -j ACCEPT || \
      add -I FORWARD 1 -i "$LAN" -o wt0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    ;;
  nat)
    add -t nat -C POSTROUTING -s "$NB_NET" -o "$LAN" -j MASQUERADE || \
      add -t nat -I POSTROUTING 1 -s "$NB_NET" -o "$LAN" -j MASQUERADE
    ;;
esac
exit 0
EOF_HOOK
  } > "$HOOK"
  chmod +x "$HOOK"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  table=filter "$HOOK"
  table=nat "$HOOK"

  log "[5/6] watchdog -> $WD (cron каждые 2 мин)"
  cat > "$WD" <<'EOF_WD'
#!/bin/sh
pidof netbird >/dev/null && exit 0
echo "$(date) netbird not running, restarting" >> /opt/var/log/netbird_watchdog.log
/opt/etc/init.d/S99netbird restart
EOF_WD
  chmod +x "$WD"
  touch /opt/etc/crontab
  grep -q "$WD" /opt/etc/crontab || echo "*/2 * * * * root $WD" >> /opt/etc/crontab
  [ -x /opt/etc/init.d/S10cron ] && /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true

  log "[6/6] запуск демона и регистрация пира"
  /opt/etc/init.d/S99netbird restart
  register_peer "tail -50 /opt/var/log/netbird.log" "-p 222 root"
}

# ---------------------------------------------------------------- OpenWrt
install_openwrt() {
  # shellcheck disable=SC1091
  . /etc/openwrt_release
  log "[1/5] OpenWrt $DISTRIB_RELEASE ($DISTRIB_ARCH)"
  [ -c /dev/net/tun ] || [ -n "$NB_NO_UP" ] || fail "нет /dev/net/tun (нужен kmod-tun)"

  log "[2/5] пакет netbird"
  if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null
    apk add netbird
  else
    opkg update >/dev/null
    opkg install netbird
  fi

  log "[3/5] интерфейс и зона firewall через uci (сохраняется в /etc/config, переживает reboot)"
  uci -q delete network.netbird || true
  uci set network.netbird=interface
  uci set network.netbird.proto='unmanaged'
  uci set network.netbird.device='wt0'
  uci commit network

  uci -q delete firewall.netbird || true
  uci set firewall.netbird=zone
  uci set firewall.netbird.name='netbird'
  uci set firewall.netbird.input='ACCEPT'
  uci set firewall.netbird.output='ACCEPT'
  uci set firewall.netbird.forward='ACCEPT'
  uci set firewall.netbird.masq='1'
  uci add_list firewall.netbird.network='netbird'
  uci -q delete firewall.netbird_lan || true
  uci set firewall.netbird_lan=forwarding
  uci set firewall.netbird_lan.src='netbird'
  uci set firewall.netbird_lan.dest='lan'
  uci -q delete firewall.lan_netbird || true
  uci set firewall.lan_netbird=forwarding
  uci set firewall.lan_netbird.src='lan'
  uci set firewall.lan_netbird.dest='netbird'
  uci commit firewall
  /etc/init.d/network reload >/dev/null 2>&1 || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true

  log "[4/5] автозапуск procd"
  /etc/init.d/netbird enable
  /etc/init.d/netbird restart >/dev/null 2>&1 || [ -n "$NB_NO_UP" ] || fail "/etc/init.d/netbird restart не удался: logread -e netbird"

  log "[5/5] регистрация пира"
  register_peer "logread -e netbird" "root"
}

PLATFORM=$(detect_platform)
case "$PLATFORM" in
  keenetic) install_keenetic ;;
  openwrt)  install_openwrt ;;
  *) fail "платформа не распознана. Keenetic: зайди по SSH в Entware (порт 222). OpenWrt: нужен /etc/openwrt_release. Можно задать NB_PLATFORM=keenetic|openwrt" ;;
esac
