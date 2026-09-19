#!/bin/sh
set -e
ok() { echo "  ok  $*"; }
die() { echo "  FAIL $*"; exit 1; }
command -v netbird >/dev/null || die "бинарь netbird не установлен"
ok "netbird $(netbird version 2>/dev/null || echo '?')"
[ -x /etc/init.d/netbird ] || die "нет /etc/init.d/netbird"
/etc/init.d/netbird enabled || die "netbird не включён в автозапуск (rc.d)"
for l in /etc/rc.d/S*netbird; do ok "автозапуск включён: $l"; break; done
[ "$(uci get network.netbird.device)" = wt0 ] || die "network.netbird.device != wt0"
[ "$(uci get network.netbird.proto)" = unmanaged ] || die "proto != unmanaged"
ok "uci network.netbird"
[ "$(uci get firewall.netbird.name)" = netbird ] || die "зона firewall.netbird отсутствует"
[ "$(uci get firewall.netbird.input)" = ACCEPT ] || die "input != ACCEPT"
uci get firewall.netbird.network | grep -q netbird || die "зона не привязана к сети netbird"
[ "$(uci get firewall.netbird_lan.dest)" = lan ] || die "forwarding netbird->lan отсутствует"
ok "uci firewall zone + forwarding"
# идемпотентность: повторный запуск не плодит дубликаты
NB_NO_UP=1 sh /tmp/install.sh >/dev/null
n=$(uci show firewall | grep -c "firewall.netbird=zone"); [ "$n" = 1 ] || die "дубликаты зоны: $n"
n=$(uci get firewall.netbird.network | wc -w); [ "$n" = 1 ] || die "дубликаты network в зоне: $n"
ok "идемпотентность (повторный install.sh не создаёт дубликатов)"
pidof netbird >/dev/null && ok "демон запущен (pid $(pidof netbird))" || echo "  warn демон не запущен (в контейнере без tun это допустимо)"
