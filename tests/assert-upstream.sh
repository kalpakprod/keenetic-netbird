#!/bin/sh
set -e
ok() { echo "  ok  $*"; }
die() { echo "  FAIL $*"; exit 1; }
B=/opt/lib/netbird/netbird
[ -x "$B" ] || die "нет $B"
V=$("$B" version 2>/dev/null) || die "upstream-бинарь не запускается"
[ "$V" = "${NB_VERSION:-0.79.0}" ] || die "версия $V != ${NB_VERSION:-0.79.0}"
ok "upstream netbird $V"
[ -x /opt/bin/netbird ] || die "нет враппера /opt/bin/netbird"
/opt/bin/netbird version >/dev/null 2>&1 || die "враппер не работает"
ok "враппер /opt/bin/netbird"
[ -x /opt/etc/init.d/S99netbird ] || die "нет S99netbird"
grep -q 'netbird-upstream.pid' /opt/etc/init.d/S99netbird || die "S99netbird не upstream-вариант"
ok "S99netbird (upstream-вариант)"
H=/opt/etc/ndm/netfilter.d/netbird.sh
[ -x "$H" ] || die "нет хука $H"
sh -n "$H" || die "хук не парсится"
grep -q 'rp_filter' "$H" || die "хук не выключает rp_filter"
# shellcheck disable=SC2016
grep -q -- '--dport "\$p"' "$H" || die "хук не открывает порты"
ok "хук netfilter.d синтаксически корректен"
table=filter sh "$H"; table=filter sh "$H"; table=nat sh "$H"; table=nat sh "$H"
n=$(/opt/sbin/iptables -S INPUT | grep -c -- '-i wt0 -p tcp -m tcp --dport 222'); [ "$n" = 1 ] || die "дубликаты правил INPUT: $n"
n=$(/opt/sbin/iptables -t nat -S POSTROUTING | grep -c MASQUERADE); [ "$n" = 1 ] || die "дубликаты MASQUERADE: $n"
ok "хук идемпотентен (правила не дублируются при повторном вызове ndm)"
[ -x /opt/etc/netbird/watchdog.sh ] || die "нет watchdog"
n=$(grep -c watchdog.sh /opt/etc/crontab); [ "$n" = 1 ] || die "crontab: $n записей watchdog"
ok "watchdog + cron (1 запись)"
sleep 3
pidof netbird >/dev/null || die "демон netbird не запущен через S99netbird"
ok "демон запущен (pid $(pidof netbird))"
/opt/bin/netbird status 2>&1 | head -3 | sed 's/^/      /'
/opt/etc/init.d/S99netbird stop >/dev/null; sleep 1
pidof netbird >/dev/null && die "демон не остановился"
[ -e /opt/var/run/netbird-upstream.pid ] && die "pidfile не убран после stop"
ok "S99netbird stop убирает демон и pidfile"
/opt/etc/init.d/S99netbird start >/dev/null; sleep 3
pidof netbird >/dev/null || die "демон не поднялся после S99netbird start"
ok "S99netbird start (эмуляция перезагрузки Entware)"
