#!/bin/sh
# NetBird на Keenetic (Entware). Архитектуры: aarch64, armv7, mipsel, mips.
# Запуск: sh install.sh <SETUP_KEY> [MANAGEMENT_URL]
# Источники: пакет netbird из официального репозитория Entware (bin.entware.net),
# хук netfilter.d: forum.keenetic.ru/topic/21273-netbird
set -e
KEY="$1"
MGMT="${2:-https://api.netbird.io}"
NB_FLAGS=/opt/etc/netbird/env
HOOK=/opt/etc/ndm/netfilter.d/netbird.sh
WD=/opt/etc/netbird/watchdog.sh

fail() { echo "ОШИБКА: $*" >&2; exit 1; }

[ -n "$KEY" ] || fail "использование: sh install.sh <NETBIRD_SETUP_KEY> [MANAGEMENT_URL]"
[ -d /opt/etc/init.d ] || fail "Entware не найден в /opt. Установи Entware: help.keenetic.com/hc/ru/articles/360021214160"
command -v opkg >/dev/null || fail "opkg не найден, это не Entware-шелл (порт 222)"
[ -c /dev/net/tun ] || fail "нет /dev/net/tun: установи компонент 'WireGuard VPN' в веб-интерфейсе Keenetic (Параметры системы -> Компоненты) и повтори"

echo "[1/6] архитектура: $(uname -m), ядро $(uname -r)"
opkg update >/dev/null
opkg list 2>/dev/null | grep -q '^netbird ' || fail "пакета netbird нет в репозитории Entware для этой архитектуры"

echo "[2/6] пакеты netbird iptables cron"
opkg install netbird iptables cron

echo "[3/6] флаги демона -> $NB_FLAGS"
mkdir -p /opt/etc/netbird /opt/var/log
cat > "$NB_FLAGS" <<'FLAGSFILE'
# читается штатным /opt/etc/init.d/S99netbird
FLAGS="--log-file /opt/var/log/netbird.log --log-level info"
FLAGSFILE

echo "[4/6] хук netfilter -> $HOOK (правила переприменяются при каждой пересборке фаервола KeeneticOS)"
mkdir -p /opt/etc/ndm/netfilter.d
cat > "$HOOK" <<'HOOKSH'
#!/bin/sh
# Вызывается ndm с переменной $table при каждой пересборке netfilter (загрузка, смена WAN, изменения в веб-интерфейсе)
IPT=/opt/sbin/iptables
NB_NET=100.64.0.0/10
LAN=br0
add() { $IPT "$@" 2>/dev/null; }
case "$table" in
  filter)
    # ответы через туннель не должны отбрасываться как асимметричные
    for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null; done
    # доступ к самому роутеру из сети NetBird: ping, ssh KeeneticOS(22), ssh Entware(222), web(80/443)
    for spec in "-p icmp" "-p tcp --dport 22" "-p tcp --dport 222" "-p tcp --dport 80" "-p tcp --dport 443"; do
      add -C INPUT -i wt0 $spec -j ACCEPT || add -I INPUT 1 -i wt0 $spec -j ACCEPT
    done
    # доступ из NetBird в домашнюю сеть
    add -C FORWARD -i wt0 -o $LAN -j ACCEPT || add -I FORWARD 1 -i wt0 -o $LAN -j ACCEPT
    add -C FORWARD -i $LAN -o wt0 -m state --state RELATED,ESTABLISHED -j ACCEPT || \
      add -I FORWARD 1 -i $LAN -o wt0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    ;;
  nat)
    add -t nat -C POSTROUTING -s $NB_NET -o $LAN -j MASQUERADE || \
      add -t nat -I POSTROUTING 1 -s $NB_NET -o $LAN -j MASQUERADE
    ;;
esac
exit 0
HOOKSH
chmod +x "$HOOK"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
table=filter "$HOOK"
table=nat "$HOOK"

echo "[5/6] watchdog -> $WD (cron каждые 2 мин)"
cat > "$WD" <<'WDSH'
#!/bin/sh
pidof netbird >/dev/null && exit 0
echo "$(date) netbird not running, restarting" >> /opt/var/log/netbird_watchdog.log
/opt/etc/init.d/S99netbird restart
WDSH
chmod +x "$WD"
touch /opt/etc/crontab
grep -q "$WD" /opt/etc/crontab || echo "*/2 * * * * root $WD" >> /opt/etc/crontab
[ -x /opt/etc/init.d/S10cron ] && /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true

echo "[6/6] запуск демона и регистрация пира"
/opt/etc/init.d/S99netbird restart
i=0; until [ -S /opt/var/run/netbird.sock ] || [ -S /var/run/netbird.sock ] || [ $i -ge 15 ]; do sleep 1; i=$((i+1)); done
netbird up --setup-key "$KEY" --management-url "$MGMT" --disable-dns
sleep 5
echo
netbird status
IP=$(ip -4 addr show wt0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p')
[ -n "$IP" ] || fail "wt0 без адреса. Лог: tail -50 /opt/var/log/netbird.log"
echo
echo "Готово. NetBird-IP роутера: $IP"
echo "Проверка после reboot: подожди 2 мин, затем с другого пира:  ssh -p 222 root@$IP"
