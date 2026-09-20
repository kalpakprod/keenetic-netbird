#!/bin/sh
# NetBird на роутере: Keenetic (Entware) и OpenWrt.
# Использование: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]
# Переменные окружения:
#   NB_PLATFORM=keenetic|openwrt   принудительно выбрать платформу (по умолчанию автоопределение)
#   NB_NO_UP=1                     всё поставить, но не выполнять "netbird up" (для проверки/CI)
#   NB_SOURCE=auto|upstream|entware источник бинаря на Keenetic (по умолчанию auto: upstream, если
#                              архитектура известна, иначе пакет Entware)
#   NB_VERSION=0.79.0|latest       версия upstream-релиза (по умолчанию проверенная; latest резолвится
#                              через GitHub API с откатом на проверенную при неудаче)
#   NB_ARCH=arm64                  принудительно выбрать архитектуру upstream-бинаря (экспертный режим)
#   NB_SETUP_KEY_FILE=/path        файл с Setup Key (вместо первого аргумента)
#   NB_LAN=br0                     LAN-интерфейс Keenetic (по умолчанию br0)
#   NB_PORTS="22 222 80 443"       порты роутера, открываемые из сети NetBird (Keenetic)
#   NB_UP_FLAGS="..."              дополнительные флаги к "netbird up"
set -e

SCRIPT_KEY="$1"
MGMT="${2:-${NB_MANAGEMENT_URL:-https://api.netbird.io}}"
NB_LAN="${NB_LAN:-br0}"
NB_PORTS="${NB_PORTS:-22 222 80 443}"
NB_NET=100.64.0.0/10
NB_SOURCE="${NB_SOURCE:-auto}"
NB_VERSION="${NB_VERSION:-0.79.0}"
PINNED_VERSION=0.79.0
export PATH=/opt/bin:/opt/sbin:$PATH

log()  { printf '%s\n' "$*"; }
fail() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

detect_platform() {
  [ -n "$NB_PLATFORM" ] && { echo "$NB_PLATFORM"; return; }
  if [ -f /etc/openwrt_release ]; then echo openwrt; return; fi
  if [ -d /opt/etc/init.d ] && command -v opkg >/dev/null 2>&1; then echo keenetic; return; fi
  echo unknown
}

# Печатает суффикс upstream-архитектуры для netbird_${V}_linux_${ARCH}.tar.gz.
# Только проверенные соответствия; mips намеренно отсутствует (там только Entware):
# выбор soft/hard-float без железа небезопасен, а пакет Entware существует.
map_upstream_arch() {
  if [ -n "$NB_ARCH" ]; then echo "$NB_ARCH"; return 0; fi
  case "$(uname -m)" in
    aarch64) echo arm64 ;;
    x86_64) echo amd64 ;;
    armv7l|armv6l) echo armv6 ;;
    *) return 1 ;;
  esac
}

resolve_version() {
  if [ "$NB_VERSION" != latest ]; then echo "$NB_VERSION"; return 0; fi
  LATEST=$(curl -fsS --max-time 20 https://api.github.com/repos/netbirdio/netbird/releases/latest 2>/dev/null | \
    grep -o '"tag_name": *"v[^"]*' | head -1 | sed 's/.*v//')
  if [ -n "$LATEST" ]; then
    echo "$LATEST"
  else
    log "не смог узнать latest через GitHub API, беру проверенную $PINNED_VERSION" >&2
    echo "$PINNED_VERSION"
  fi
}

wait_daemon() {
  i=0
  until netbird status >/dev/null 2>&1 || [ $i -ge 20 ]; do sleep 1; i=$((i+1)); done
}

# Использует $SCRIPT_KEY или $NB_SETUP_KEY_FILE; значение ключа никогда не печатает.
# Ключ из аргумента кладётся в 600-файл и удаляется сразу после вызова "up".
register_peer() {
  [ -n "$NB_NO_UP" ] && { log "NB_NO_UP задан: пропускаю netbird up"; return; }
  KEYFILE="${NB_SETUP_KEY_FILE:-}"
  STAGED=0
  if [ -z "$KEYFILE" ] && [ -n "$SCRIPT_KEY" ]; then
    umask 077
    KEYFILE=$(mktemp /tmp/netbird-setup-key.XXXXXX)
    chmod 600 "$KEYFILE"
    printf '%s' "$SCRIPT_KEY" > "$KEYFILE"
    STAGED=1
  fi
  if [ ! -s "$KEYFILE" ]; then fail "нужен Setup Key: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]"; fi
  wait_daemon
  # На медленных роутерах CLI может отвалиться по таймауту gRPC (DeadlineExceeded),
  # хотя демон продолжает регистрацию. Поэтому код возврата up не решает; решают
  # адрес на wt0 и "Management: Connected" в netbird status.
  # shellcheck disable=SC2086
  netbird up --setup-key-file "$KEYFILE" --management-url "$MGMT" --disable-dns $NB_UP_FLAGS || \
    log "netbird up вернул ошибку, жду фактического подключения до 120 с"
  if [ "$STAGED" = 1 ]; then rm -f "$KEYFILE"; fi
  IP=""; i=0
  while [ $i -lt 120 ]; do
    IP=$(ip -4 addr show wt0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
    if [ -n "$IP" ] && netbird status 2>/dev/null | grep -q 'Management: Connected'; then break; fi
    sleep 3; i=$((i+3))
  done
  echo
  netbird status 2>/dev/null || true
  if [ -z "$IP" ]; then fail "wt0 без адреса через 120 с. Смотри лог: $1"; fi
  if ! netbird status 2>/dev/null | grep -q 'Management: Connected'; then
    fail "wt0 получил адрес, но Management не Connected. Смотри лог: $1"
  fi
  echo
  log "Готово. NetBird-IP роутера: $IP"
  log "Проверка: reboot, через 2 мин с другого пира NetBird: ssh $2@$IP"
}

install_hook() {
  HOOK=/opt/etc/ndm/netfilter.d/netbird.sh
  log "хук netfilter -> $HOOK"
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
}

install_watchdog() {
  WD=/opt/etc/netbird/watchdog.sh
  log "watchdog -> $WD (cron каждые 2 мин)"
  mkdir -p /opt/etc/netbird /opt/var/log
  cat > "$WD" <<'EOF_WD'
#!/bin/sh
pidof netbird >/dev/null && exit 0
echo "$(date) netbird not running, restarting" >> /opt/var/log/netbird_watchdog.log
/opt/etc/init.d/S99netbird restart
EOF_WD
  chmod +x "$WD"
  touch /opt/etc/crontab
  grep -q "$WD" /opt/etc/crontab || echo "*/2 * * * * root $WD" >> /opt/etc/crontab
  if [ -x /opt/etc/init.d/S10cron ]; then /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true; fi
}

# ---------------------------------------------------------------- Keenetic (Entware)
install_keenetic() {
  [ "$(id -u)" = 0 ] || fail "нужен root"
  [ -d /opt/etc/init.d ] || fail "нужен Entware"
  [ -c /dev/net/tun ] || [ -n "$NB_NO_UP" ] || \
    fail "нет /dev/net/tun: установи компонент 'WireGuard VPN' (Параметры системы -> Компоненты) и повтори"
  if [ -z "$NB_NO_UP" ]; then
    if [ -z "$SCRIPT_KEY" ] && [ ! -s "${NB_SETUP_KEY_FILE:-}" ]; then
      fail "нужен Setup Key: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]"
    fi
  fi
  case "$NB_SOURCE" in auto|upstream|entware) ;; *) fail "NB_SOURCE: auto|upstream|entware" ;; esac

  SOURCE="$NB_SOURCE"
  UARCH=""
  if [ "$SOURCE" = auto ]; then
    if UARCH=$(map_upstream_arch 2>/dev/null); then SOURCE=upstream; else SOURCE=entware; fi
  elif [ "$SOURCE" = upstream ]; then
    UARCH=$(map_upstream_arch 2>/dev/null) || \
      fail "для $(uname -m) нет проверенного upstream-бинаря; убери NB_SOURCE=upstream (авто выберет Entware) или задай NB_ARCH вручную"
  fi

  log "[1/5] Keenetic/Entware, архитектура $(uname -m), ядро $(uname -r), источник: $SOURCE"
  if [ "$SOURCE" = upstream ]; then
    install_upstream_binary
  else
    install_entware_binary
  fi

  log "[3/5] фаервол и watchdog"
  install_hook
  install_watchdog

  log "[4/5] запуск демона"
  /opt/etc/init.d/S99netbird restart
  netbird version

  log "[5/5] регистрация пира"
  register_peer "tail -50 /opt/var/log/netbird.log" "-p 222 root"
}

install_entware_binary() {
  if [ -x /opt/lib/netbird/netbird ]; then
    fail "найден upstream-бинарь /opt/lib/netbird/netbird; сначала удали его через uninstall.sh"
  fi
  opkg update >/dev/null
  opkg list 2>/dev/null | grep -q '^netbird ' || fail "пакета netbird нет в репозитории Entware для $(uname -m)"
  log "[2/5] пакеты: netbird iptables cron"
  opkg install netbird iptables cron
  log "флаги демона -> /opt/etc/netbird/env"
  mkdir -p /opt/etc/netbird /opt/var/log
  cat > /opt/etc/netbird/env <<'EOF_FLAGS'
# читается штатным /opt/etc/init.d/S99netbird из пакета Entware
FLAGS="--log-file /opt/var/log/netbird.log --log-level info"
EOF_FLAGS
}

install_upstream_binary() {
  if opkg list-installed 2>/dev/null | grep -q '^netbird '; then
    fail "установлен пакет netbird из Entware; удали его (opkg remove netbird), сохранив identity, или убери NB_SOURCE=upstream"
  fi
  if pidof netbird >/dev/null; then fail "останови NetBird перед переустановкой: /opt/etc/init.d/S99netbird stop"; fi
  for cmd in sha256sum tar awk mktemp sysctl; do
    command -v "$cmd" >/dev/null || fail "нет утилиты: $cmd"
  done
  if ! command -v curl >/dev/null; then opkg update >/dev/null; opkg install curl ca-bundle; fi
  command -v curl >/dev/null || fail "не ставится curl"
  if ! command -v timeout >/dev/null; then opkg update >/dev/null; opkg install coreutils-timeout; fi
  command -v timeout >/dev/null || fail "coreutils-timeout не дал timeout"
  opkg install iptables cron >/dev/null

  VERSION=$(resolve_version)
  case "$VERSION" in ''|*[!0-9.]*) fail "неверная версия релиза: $VERSION";; esac

  LOCK=/opt/var/lock/netbird-install
  mkdir -p /opt/var/lock
  mkdir "$LOCK" 2>/dev/null || fail "установщик уже запущен или остался lock $LOCK"
  TMP=""
  STAGE=""
  # shellcheck disable=SC2317
  cleanup() {
    if [ -n "$STAGE" ]; then rm -f "$STAGE"; fi
    if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
    rmdir "$LOCK"
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  log "[2/5] upstream $VERSION ($UARCH)"
  TMP=$(mktemp -d /tmp/netbird-install.XXXXXX)
  NAME="netbird_${VERSION}_linux_${UARCH}.tar.gz"
  BASE="https://github.com/netbirdio/netbird/releases/download/v${VERSION}"
  fetch() { curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fLsS --connect-timeout 15 --max-time 180 --retry 2 "$1" -o "$2"; }
  fetch "$BASE/$NAME" "$TMP/$NAME" || fail "не скачался $NAME (версия $VERSION, архитектура $UARCH)"
  fetch "$BASE/netbird_${VERSION}_checksums.txt" "$TMP/checksums" || fail "не скачался checksums для $VERSION"
  HASH=$(awk -v name="$NAME" '$2 == name || $2 == "*" name {print $1; n++} END {if(n!=1) exit 1}' "$TMP/checksums") || fail "нет однозначной контрольной суммы для $NAME"
  [ "${#HASH}" = 64 ] || fail "неверный SHA256"
  case "$HASH" in *[!0-9a-fA-F]*) fail "неверный SHA256";; esac
  printf '%s  %s\n' "$HASH" "$TMP/$NAME" | sha256sum -c -
  [ "$(tar -tzf "$TMP/$NAME" | grep -cx netbird)" = 1 ] || fail "в архиве должен быть ровно один файл netbird"
  # Извлекаем только бинарь потоком: пути и симлинки из архива не создаются.
  tar -xOzf "$TMP/$NAME" netbird > "$TMP/netbird"
  chmod 700 "$TMP/netbird"
  ACTUAL=$(timeout 15 "$TMP/netbird" version) || fail "бинарь не запустился (возможно, чужая архитектура $UARCH)"
  [ "$ACTUAL" = "$VERSION" ] || fail "версия бинаря $ACTUAL не совпала с $VERSION"
  BYTES=$(wc -c < "$TMP/netbird")
  free_kib() { df -k /opt | awk 'END {print $4}'; }
  FS=$(awk '$2 == "/opt" {print $3}' /proc/mounts)
  FREE=$(free_kib)
  # UBIFS сжимает при записи; меряем занятое место, а не гадаем коэффициент.
  if [ "$FS" != ubifs ]; then
    [ "$FREE" -gt "$(( (BYTES + 1023) / 1024 + 4096 ))" ] || fail "мало места: нужен атомарный инсталл плюс резерв 4 MiB"
  fi
  mkdir -p /opt/lib/netbird /opt/bin /opt/var/lib/netbird /opt/var/run
  chmod 700 /opt/var/lib/netbird
  STAGE=$(mktemp /opt/lib/netbird/.netbird-new.XXXXXX)
  if [ "$FS" = ubifs ]; then
    OFFSET=0
    CHUNKS=$(( (BYTES + 1048575) / 1048576 ))
    while [ "$OFFSET" -lt "$CHUNKS" ]; do
      # Резерв 4 MiB плюс 2 MiB на следующий кусок в 1 MiB и накладные расходы ФС.
      [ "$(free_kib)" -ge 6144 ] || fail "достигнут резерв UBIFS; стейджинг удалён, прежний бинарь цел"
      dd if="$TMP/netbird" bs=1048576 skip="$OFFSET" count=1 >> "$STAGE" 2>/dev/null || fail "ошибка записи стейджинга"
      sync
      [ "$(free_kib)" -ge 4096 ] || fail "на UBIFS меньше резерва 4 MiB"
      OFFSET=$((OFFSET+1))
    done
  else
    cp "$TMP/netbird" "$STAGE"
  fi
  EXPECTED=$(sha256sum "$TMP/netbird" | awk '{print $1}')
  printf '%s  %s\n' "$EXPECTED" "$STAGE" | sha256sum -c -
  chmod 755 "$STAGE"
  mv "$STAGE" /opt/lib/netbird/netbird
  STAGE=
  cat > /opt/bin/netbird <<'WRAPPER'
#!/bin/sh
export NB_STATE_DIR=/opt/var/lib/netbird
exec /opt/lib/netbird/netbird --daemon-addr unix:///opt/var/run/netbird.sock "$@"
WRAPPER
  chmod 755 /opt/bin/netbird
  cat > /opt/etc/init.d/S99netbird <<'INIT'
#!/bin/sh
export PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
PIDFILE=/opt/var/run/netbird-upstream.pid
running() {
  [ -r "$PIDFILE" ] || return 1
  PID=$(cat "$PIDFILE")
  case "$PID" in ''|*[!0-9]*) return 1;; esac
  [ "$(readlink "/proc/$PID/exe")" = /opt/lib/netbird/netbird ] && kill -0 "$PID" 2>/dev/null
}
case "${1:-}" in
 start)
  running && exit 0
  mkdir -p /opt/var/run /opt/var/log
  umask 077
  /opt/bin/netbird service run --log-file /opt/var/log/netbird.log >/dev/null 2>&1 &
  echo "$!" > "$PIDFILE"
  i=0
  while [ "$i" -lt 30 ]; do
    if timeout 3 /opt/bin/netbird status >/dev/null 2>&1; then exit 0; fi
    running || exit 1
    sleep 1; i=$((i+1))
  done
  exit 1;;
 stop)
  running || exit 0
  kill "$PID" || exit 1
  i=0
  while running; do
    [ "$i" -lt 30 ] || exit 1
    sleep 1; i=$((i+1))
  done
  rm -f "$PIDFILE";;
 restart) "$0" stop && "$0" start;;
 status) running;;
 *) echo 'Usage: start|stop|restart|status' >&2; exit 2;;
esac
INIT
  chmod 755 /opt/etc/init.d/S99netbird
}

# ---------------------------------------------------------------- OpenWrt
install_openwrt() {
  if [ "${NB_SOURCE:-auto}" = upstream ]; then fail "upstream-источник на OpenWrt пока не поддерживается; убери NB_SOURCE=upstream"; fi
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
