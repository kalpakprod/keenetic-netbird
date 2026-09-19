#!/bin/sh
# Полное удаление NetBird с Keenetic (Entware)
netbird down 2>/dev/null || true
/opt/etc/init.d/S99netbird stop 2>/dev/null || true
sed -i '\#/opt/etc/netbird/watchdog.sh#d' /opt/etc/crontab 2>/dev/null || true
rm -f /opt/etc/ndm/netfilter.d/netbird.sh /opt/etc/netbird/watchdog.sh /opt/etc/netbird/env
opkg remove netbird
rm -rf /opt/var/lib/netbird /opt/etc/netbird
echo "Удалено. Правила iptables для wt0 исчезнут при следующей пересборке фаервола или после reboot."
