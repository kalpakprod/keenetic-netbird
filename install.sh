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
#   NB_LOG_LEVEL=warning           уровень лога демона на Keenetic: trace|debug|info|warn|warning|error
#   NB_COMPRESS=1                сжать upstream-бинарь через UPX (~40 МБ -> ~13-15 МБ) для тесного /opt
#   NB_HOSTNAME=peer-01            имя пира в панели NetBird (A-Z a-z 0-9 . _ -)
#   NB_SETUP_KEY_FILE=/path        файл с Setup Key (вместо первого аргумента)
#   NB_LAN=br0                     LAN-интерфейс Keenetic (по умолчанию br0)
#   NB_PORTS="22 222 80 443"       порты роутера, открываемые из сети NetBird (Keenetic)
#   NB_UP_FLAGS="..."              дополнительные флаги к "netbird up"
#   NB_SKIP_PREFLIGHT=1            не останавливаться, если management недоступен (экспертный режим)
set -e

SCRIPT_KEY="$1"
MGMT="${2:-${NB_MANAGEMENT_URL:-https://api.netbird.io}}"
NB_LAN="${NB_LAN:-br0}"
NB_PORTS="${NB_PORTS:-22 222 80 443}"
NB_NET=100.64.0.0/10
NB_SOURCE="${NB_SOURCE:-auto}"
NB_VERSION="${NB_VERSION:-0.79.0}"
NB_LOG_LEVEL="${NB_LOG_LEVEL:-warning}"
PINNED_VERSION=0.79.0
export PATH="/opt/bin:/opt/sbin:$PATH"

# Цвета только на живом терминале; в логах, CI и тестах их нет.
if [ -t 1 ]; then
  C_GREEN=$(printf '\033[32m'); C_RED=$(printf '\033[31m')
  C_YELLOW=$(printf '\033[33m'); C_CYAN=$(printf '\033[36m')
  C_NC=$(printf '\033[0m')
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_NC=""
fi

log()  { printf '%s\n' "$*"; }
fail() { printf '%sОШИБКА%s: %s\n' "$C_RED" "$C_NC" "$*" >&2; exit 1; }
banner()   { printf '\n%s%s%s\n\n' "$C_CYAN" "$1" "$C_NC"; }
pre_ok()   { printf '%s  [OK] %s%s %s\n' "$C_GREEN" "$C_NC" "$1" "$2"; }
pre_warn() { printf '%s  [!!] %s%s %s\n' "$C_YELLOW" "$C_NC" "$1" "$2"; }
pre_skip() { printf '  [--] %s %s\n' "$1" "$2"; }

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

check_hostname() {
  if [ -n "${NB_HOSTNAME:-}" ]; then
    case "$NB_HOSTNAME" in *[!A-Za-z0-9._-]*) fail "NB_HOSTNAME: только A-Z a-z 0-9 . _ -" ;; esac
  fi
}

# Возвращает 0, если URL отвечает по HTTP. Код 2: нечем проверить (нет curl/wget).
http_ok() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSI --max-time 15 -o /dev/null "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget -q --spider --timeout=15 "$1" 2>/dev/null
  else
    return 2
  fi
}

# Проверка доступности management. Любой HTTP-ответ (даже 401/404) означает,
# что весь стек (DNS, TCP, TLS, HTTP) работает. TLS-ошибка = предупреждение
# (похоже на самоподписанный серт self-hosted); DNS/сеть/таймаут = фатально.
mgmt_probe() {
  if [ -n "${NB_SKIP_PREFLIGHT:-}" ]; then pre_skip "management $MGMT" "(пропуск по NB_SKIP_PREFLIGHT)"; return 0; fi
  if command -v curl >/dev/null 2>&1; then
    rc=0; out=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$MGMT/api/peers" 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ]; then pre_ok "management $MGMT" "(HTTP $out)"; return 0; fi
    if [ "$rc" = 60 ] || [ "$rc" = 51 ]; then
      pre_warn "management $MGMT" "(TLS-сертификат не проверен; для self-hosted с самоподписанным — нормально)"
      return 0
    fi
    fail "management $MGMT недоступен (curl код $rc): проверь интернет на роутере и адрес; регистрация не выйдет. Обход: NB_SKIP_PREFLIGHT=1"
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --spider --timeout=15 "$MGMT/api/peers" 2>/dev/null; then pre_ok "management $MGMT" ""; return 0; fi
    if wget -q --spider --no-check-certificate --timeout=15 "$MGMT/api/peers" 2>/dev/null; then
      pre_warn "management $MGMT" "(TLS-сертификат не проверен; для self-hosted с самоподписанным — нормально)"
      return 0
    fi
    fail "management $MGMT недоступен: проверь интернет на роутере и адрес; регистрация не выйдет. Обход: NB_SKIP_PREFLIGHT=1"
  else
    pre_warn "management $MGMT" "(нечем проверить: нет curl/wget)"
    return 0
  fi
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
  HN_FLAGS=""
  check_hostname
  if [ -n "${NB_HOSTNAME:-}" ]; then HN_FLAGS="--hostname $NB_HOSTNAME"; fi
  wait_daemon
  # На медленных роутерах CLI может отвалиться по таймауту gRPC (DeadlineExceeded),
  # хотя демон продолжает регистрацию. Поэтому код возврата up не решает; решают
  # адрес на wt0 и "Management: Connected" в netbird status.
  # shellcheck disable=SC2086
  netbird up --setup-key-file "$KEYFILE" --management-url "$MGMT" --disable-dns $NB_UP_FLAGS $HN_FLAGS || \
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
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Под cron PATH обрезан и там нет ни pidof, ни date: без этой строки watchdog
# рестартит живой демон каждые 2 минуты (поймано на железе).
# Пока установщик держит lock, демона не трогаем: рестарт посреди стейджинга
# меняет бинарь под живым процессом и портит pidfile (поймано на железе).
[ -d /opt/var/lock/netbird-install ] && exit 0
# Лог без ротации за сутки съедает маленькую флешь: режем свыше 1 МБ до 512 КБ.
# Копированием в тот же inode (copytruncate): демон продолжает писать в тот же файл.
LOG=/opt/var/log/netbird.log
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 1048576 ]; then
  tail -c 524288 "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG"
  rm -f "$LOG.tmp"
fi
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
# Все проверки до любых изменений: в конце известны SOURCE, UARCH и VERSION.
preflight_keenetic() {
  banner "Предпроверки: убеждаемся, что установка вообще возможна"
  [ "$(id -u)" = 0 ] || fail "нужен root"
  pre_ok "root" ""
  [ -d /opt/etc/init.d ] || fail "нужен Entware"
  pre_ok "Entware" ""
  if [ -c /dev/net/tun ]; then
    pre_ok "/dev/net/tun" ""
  elif [ -n "$NB_NO_UP" ]; then
    pre_skip "/dev/net/tun" "(нет, но NB_NO_UP)"
  else
    fail "нет /dev/net/tun: установи компонент 'WireGuard VPN' (Параметры системы -> Компоненты) и повтори"
  fi
  if [ -z "$NB_NO_UP" ]; then
    if [ -z "$SCRIPT_KEY" ] && [ ! -s "${NB_SETUP_KEY_FILE:-}" ]; then
      fail "нужен Setup Key: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]"
    fi
    pre_ok "Setup Key" "(значение не показываю)"
  else
    pre_skip "Setup Key" "(не нужен: NB_NO_UP)"
  fi
  case "$NB_SOURCE" in auto|upstream|entware) ;; *) fail "NB_SOURCE: auto|upstream|entware" ;; esac
  case "$NB_LOG_LEVEL" in trace|debug|info|warn|warning|error) ;; *) fail "NB_LOG_LEVEL: trace|debug|info|warn|warning|error" ;; esac
  check_hostname
  pre_ok "переменные" "SOURCE=$NB_SOURCE VERSION=$NB_VERSION LOG=$NB_LOG_LEVEL"
  SOURCE="$NB_SOURCE"
  UARCH=""
  if [ "$SOURCE" = auto ]; then
    if UARCH=$(map_upstream_arch 2>/dev/null); then SOURCE=upstream; else SOURCE=entware; fi
  elif [ "$SOURCE" = upstream ]; then
    UARCH=$(map_upstream_arch 2>/dev/null) || \
      fail "для $(uname -m) нет проверенного upstream-бинаря; убери NB_SOURCE=upstream (авто выберет Entware) или задай NB_ARCH вручную"
  fi
  if [ "$SOURCE" = upstream ]; then
    pre_ok "источник" "upstream ($UARCH)"
  else
    pre_ok "источник" "пакет Entware"
  fi
  if [ -n "${NB_COMPRESS:-}" ] && [ "$SOURCE" = entware ]; then
    pre_warn "NB_COMPRESS=1" "(действует только на upstream-источник; пакет Entware ставится как есть)"
  fi
  opkg update >/dev/null 2>&1 || fail "opkg update не удался: проверь интернет на роутере"
  pre_ok "opkg update" ""
  if [ "$SOURCE" = upstream ]; then
    if ! command -v curl >/dev/null 2>&1; then
      opkg install curl ca-bundle >/dev/null 2>&1 || fail "не ставится curl: проверь интернет и свободное место"
    fi
    command -v curl >/dev/null || fail "не ставится curl"
    pre_ok "curl" ""
    VERSION=$(resolve_version)
    case "$VERSION" in ''|*[!0-9.]*) fail "неверная версия релиза: $VERSION";; esac
    pre_ok "версия" "$VERSION"
    NAME="netbird_${VERSION}_linux_${UARCH}.tar.gz"
    BASE="https://github.com/netbirdio/netbird/releases/download/v${VERSION}"
    if curl -fsSI --max-time 20 -o /dev/null "$BASE/$NAME" 2>/dev/null; then
      pre_ok "релиз на GitHub" "$NAME"
    else
      if http_ok "https://github.com" 2>/dev/null; then
        fail "на GitHub нет $NAME (версия $VERSION, архитектура $UARCH): проверь NB_VERSION/NB_ARCH"
      else
        fail "GitHub недоступен: проверь интернет на роутере"
      fi
    fi
  else
    opkg list 2>/dev/null | grep -q '^netbird ' || fail "пакета netbird нет в репозитории Entware для $(uname -m)"
    pre_ok "пакет netbird в репозитории" ""
  fi
  FREE_KB=$(df -k /opt | awk 'END {print $4}')
  if [ -n "${NB_COMPRESS:-}" ]; then NEED_WARN_KB=20000; else NEED_WARN_KB=40000; fi
  if [ "${FREE_KB:-0}" -lt "$NEED_WARN_KB" ]; then
    pre_warn "/opt свободно" "${FREE_KB} КБ (маловато; выручает NB_COMPRESS=1)"
  else
    pre_ok "/opt свободно" "${FREE_KB} КБ"
  fi
  if [ -z "$NB_NO_UP" ]; then
    mgmt_probe
  else
    pre_skip "management $MGMT" "(не нужен: NB_NO_UP)"
  fi
}

install_keenetic() {
  if [ -t 1 ]; then clear 2>/dev/null || true; fi
  banner "NetBird на Keenetic — установка"
  preflight_keenetic

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
  log "[2/5] пакеты: netbird iptables cron"
  opkg install netbird iptables cron
  log "флаги демона -> /opt/etc/netbird/env"
  mkdir -p /opt/etc/netbird /opt/var/log
  cat > /opt/etc/netbird/env <<EOF_FLAGS
# читается штатным /opt/etc/init.d/S99netbird из пакета Entware
FLAGS="--log-file /opt/var/log/netbird.log --log-level $NB_LOG_LEVEL"
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
  if ! command -v curl >/dev/null; then opkg install curl ca-bundle >/dev/null 2>&1 || fail "не ставится curl"; fi
  command -v curl >/dev/null || fail "не ставится curl"
  if ! command -v timeout >/dev/null; then opkg install coreutils-timeout >/dev/null 2>&1 || fail "не ставится coreutils-timeout"; fi
  command -v timeout >/dev/null || fail "coreutils-timeout не дал timeout"
  opkg install iptables cron >/dev/null

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
  NB_SRC_BIN="$TMP/netbird"
  if [ -n "${NB_COMPRESS:-}" ]; then
    log "мало места: сжимаю бинарь (UPX)"
    if ! command -v upx >/dev/null; then opkg install upx >/dev/null 2>&1 || fail "не ставится upx (нужен для NB_COMPRESS=1)"; fi
    command -v upx >/dev/null || fail "не ставится upx (нужен для NB_COMPRESS=1)"
    cp "$TMP/netbird" "$TMP/netbird-packed" || fail "нет места в /tmp для сжатия"
    # Дефолтный уровень: --best на слабом ARM пакует 40 МБ 30+ минут ради ~1 МБ (замерено на KN-1010).
    upx -q "$TMP/netbird-packed" || fail "upx не смог сжать бинарь"
    timeout 15 "$TMP/netbird-packed" version >/dev/null 2>&1 || fail "сжатый бинарь не запустился"
    NB_SRC_BIN="$TMP/netbird-packed"
    log "сжато: $(($(wc -c < "$TMP/netbird") / 1024)) -> $(($(wc -c < "$TMP/netbird-packed") / 1024)) КБ"
  fi
  BYTES=$(wc -c < "$NB_SRC_BIN")
  free_kib() { df -k /opt | awk 'END {print $4}'; }
  FS=$(awk '$2 == "/opt" {print $3}' /proc/mounts)
  OLD_BIN=/opt/lib/netbird/netbird
  FREE=$(free_kib)
  NEED_KB=$(( (BYTES + 1023) / 1024 + 4096 ))
  # Переустановка на забитом томе: демон уже остановлен проверкой выше, тарболл
  # проверен и лежит в /tmp — старый бинарь удаляем ДО записи нового, пик = один файл.
  # Identity в /opt/var/lib/netbird не трогаем; в худшем случае скрипт перезапускается.
  if [ -f "$OLD_BIN" ] && [ "${FREE:-0}" -le "$NEED_KB" ]; then
    log "места впритык (свободно ${FREE} КБ): удаляю старый бинарь до записи нового"
    rm -f "$OLD_BIN" || fail "не удаляется старый бинарь $OLD_BIN"
    FREE=$(free_kib)
  fi
  # UBIFS сжимает при записи; меряем занятое место, а не гадаем коэффициент.
  if [ "$FS" != ubifs ]; then
    [ "${FREE:-0}" -gt "$NEED_KB" ] || fail "мало места: свободно ${FREE:-?} КБ, нужно $NEED_KB КБ (NB_COMPRESS=1 ужмёт бинарь до ~13-15 МБ)"
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
      dd if="$NB_SRC_BIN" bs=1048576 skip="$OFFSET" count=1 >> "$STAGE" 2>/dev/null || fail "ошибка записи стейджинга"
      sync
      [ "$(free_kib)" -ge 4096 ] || fail "на UBIFS меньше резерва 4 MiB"
      OFFSET=$((OFFSET+1))
    done
  else
    cp "$NB_SRC_BIN" "$STAGE"
  fi
  EXPECTED=$(sha256sum "$NB_SRC_BIN" | awk '{print $1}')
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
  /opt/bin/netbird service run --log-file /opt/var/log/netbird.log --log-level @NB_LOG_LEVEL@ >/dev/null 2>&1 &
  echo "$!" > "$PIDFILE"
  i=0; UP=0
  while [ "$i" -lt 30 ]; do
    if timeout 3 /opt/bin/netbird status >/dev/null 2>&1; then UP=1; break; fi
    running || exit 1
    sleep 1; i=$((i+1))
  done
  [ "$UP" = 1 ] || exit 1
  running && exit 0
  # Сокет отвечает, а наш потомок мёртв (второй экземпляр не встал на занятый сокет):
  # забираем живой PID вместо мёртвого, иначе stop станет no-op навсегда.
  for p in $(pidof netbird 2>/dev/null); do
    case "$(readlink "/proc/$p/exe" 2>/dev/null)" in
      /opt/lib/netbird/netbird*) echo "$p" > "$PIDFILE"; exit 0;;
    esac
  done
  exit 1;;
 stop)
  if running; then
    kill "$PID" || exit 1
    i=0
    while running; do
      [ "$i" -lt 30 ] || exit 1
      sleep 1; i=$((i+1))
    done
  else
    # pidfile врёт (гонка, ручной kill): добиваем по exe, иначе restart плодит дубли.
    # Префикс покрывает и "(deleted)" после горячей замены бинаря.
    for p in $(pidof netbird 2>/dev/null); do
      case "$(readlink "/proc/$p/exe" 2>/dev/null)" in
        /opt/lib/netbird/netbird*) kill "$p" 2>/dev/null;;
      esac
    done
    i=0
    while pidof netbird >/dev/null 2>&1; do
      [ "$i" -lt 30 ] || exit 1
      sleep 1; i=$((i+1))
    done
  fi
  rm -f "$PIDFILE";;
 restart) "$0" stop && "$0" start;;
 status) running;;
 *) echo 'Usage: start|stop|restart|status' >&2; exit 2;;
esac
INIT
  sed -i "s/@NB_LOG_LEVEL@/$NB_LOG_LEVEL/" /opt/etc/init.d/S99netbird
  chmod 755 /opt/etc/init.d/S99netbird
}

# ---------------------------------------------------------------- OpenWrt
preflight_openwrt() {
  banner "Предпроверки: убеждаемся, что установка вообще возможна"
  [ "$(id -u)" = 0 ] || fail "нужен root"
  pre_ok "root" ""
  if [ -c /dev/net/tun ]; then
    pre_ok "/dev/net/tun" ""
  elif [ -n "$NB_NO_UP" ]; then
    pre_skip "/dev/net/tun" "(нет, но NB_NO_UP)"
  else
    fail "нет /dev/net/tun (нужен kmod-tun)"
  fi
  if [ -z "$NB_NO_UP" ]; then
    if [ -z "$SCRIPT_KEY" ] && [ ! -s "${NB_SETUP_KEY_FILE:-}" ]; then
      fail "нужен Setup Key: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]"
    fi
    pre_ok "Setup Key" "(значение не показываю)"
  else
    pre_skip "Setup Key" "(не нужен: NB_NO_UP)"
  fi
  check_hostname
  if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1 || fail "apk update не удался: проверь интернет на роутере"
    pre_ok "apk update" ""
  else
    opkg update >/dev/null 2>&1 || fail "opkg update не удался: проверь интернет на роутере"
    pre_ok "opkg update" ""
  fi
  if [ -z "$NB_NO_UP" ]; then
    mgmt_probe
  else
    pre_skip "management $MGMT" "(не нужен: NB_NO_UP)"
  fi
}

install_openwrt() {
  if [ "${NB_SOURCE:-auto}" = upstream ]; then fail "upstream-источник на OpenWrt пока не поддерживается; убери NB_SOURCE=upstream"; fi
  # shellcheck disable=SC1091
  . /etc/openwrt_release
  if [ -t 1 ]; then clear 2>/dev/null || true; fi
  banner "NetBird на OpenWrt — установка"
  preflight_openwrt
  log "[1/5] OpenWrt $DISTRIB_RELEASE ($DISTRIB_ARCH)"

  log "[2/5] пакет netbird"
  if command -v apk >/dev/null 2>&1; then
    apk add netbird
  else
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
