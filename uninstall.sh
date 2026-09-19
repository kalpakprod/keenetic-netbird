#!/bin/sh
# Полное удаление NetBird, поставленного install.sh (Keenetic/Entware или OpenWrt)
netbird down 2>/dev/null || true
if [ -f /etc/openwrt_release ] && [ -z "$NB_PLATFORM" ] || [ "$NB_PLATFORM" = openwrt ]; then
  /etc/init.d/netbird stop 2>/dev/null || true
  /etc/init.d/netbird disable 2>/dev/null || true
  for k in firewall.netbird_lan firewall.lan_netbird firewall.netbird network.netbird; do uci -q delete "$k" || true; done
  uci commit firewall; uci commit network
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  if command -v apk >/dev/null 2>&1; then apk del netbird; else opkg remove netbird; fi
  rm -rf /etc/netbird /root/.config/netbird /var/lib/netbird
else
  /opt/etc/init.d/S99netbird stop 2>/dev/null || true
  sed -i '\#/opt/etc/netbird/watchdog.sh#d' /opt/etc/crontab 2>/dev/null || true
  rm -f /opt/etc/ndm/netfilter.d/netbird.sh /opt/etc/netbird/watchdog.sh
  opkg remove netbird
  rm -rf /opt/var/lib/netbird /opt/etc/netbird
  echo "Правила iptables для wt0 исчезнут при следующей пересборке фаервола или после reboot."
fi
echo "Удалено."
