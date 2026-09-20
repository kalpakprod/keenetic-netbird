#!/bin/sh
set -e
ok() { echo "  ok  $*"; }
die() { echo "  FAIL $*"; exit 1; }
[ -x /opt/sbin/netbird ] || die "нет /opt/sbin/netbird"
ok "netbird $(/opt/sbin/netbird version 2>/dev/null || echo '?')"
[ -x /opt/etc/init.d/S99netbird ] || die "нет S99netbird (автозапуск Entware)"
grep -q 'FLAGS=' /opt/etc/netbird/env || die "нет /opt/etc/netbird/env"
grep -q -- '--log-level' /opt/etc/netbird/env || die "в env нет --log-level"
ok "S99netbird + env"
H=/opt/etc/ndm/netfilter.d/netbird.sh
[ -x "$H" ] || die "нет хука $H"
sh -n "$H" || die "хук не парсится"
grep -q 'rp_filter' "$H" || die "хук не выключает rp_filter"
# shellcheck disable=SC2016
grep -q -- '--dport "\$p"' "$H" || die "хук не открывает порты"
ok "хук netfilter.d синтаксически корректен"
# хук должен быть идемпотентным: -C проверка перед -I. Прогоняем дважды с реальным iptables
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
/opt/sbin/netbird status 2>&1 | head -3 | sed 's/^/      /'
# watchdog режет раздувшийся лог (защита маленькой флеши)
grep -q '1048576' /opt/etc/netbird/watchdog.sh || die "в watchdog нет трима лога"
head -c 1500000 /dev/zero > /opt/var/log/netbird.log
/opt/etc/netbird/watchdog.sh
[ "$(wc -c < /opt/var/log/netbird.log)" -lt 1048576 ] || die "watchdog не обрезал лог"
ok "watchdog режет лог свыше 1 МБ"
# перезапуск (эмуляция reboot Entware): S99 stop/start, состояние в /opt сохраняется
/opt/etc/init.d/S99netbird stop >/dev/null; sleep 1
pidof netbird >/dev/null && die "демон не остановился"
/opt/etc/init.d/S99netbird start >/dev/null; sleep 3
pidof netbird >/dev/null || die "демон не поднялся после S99netbird start"
ok "S99netbird stop/start (эмуляция перезагрузки Entware)"
