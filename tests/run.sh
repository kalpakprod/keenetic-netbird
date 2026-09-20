#!/bin/sh
# Локальные и CI-тесты в Docker. Запуск: sh tests/run.sh [openwrt-24|openwrt-25|entware|upstream|all]
set -e
cd "$(dirname "$0")/.."
T="${1:-all}"

run_openwrt() {
  tag="$1"
  echo "=== OpenWrt $tag"
  docker run --rm -v "$PWD:/src:ro" "openwrt/rootfs:$tag" sh -c '
    set -e
    mkdir -p /var/lock /var/run
    (ubusd &) ; sleep 1
    touch /etc/config/network
    cp /src/install.sh /src/uninstall.sh /tmp/
    NB_NO_UP=1 sh /tmp/install.sh
    sh /src/tests/assert-openwrt.sh
    sh /tmp/uninstall.sh
    ! test -f /etc/init.d/netbird || { echo "netbird init остался после uninstall"; exit 1; }
    uci -q get firewall.netbird && { echo "зона netbird осталась"; exit 1; } || true
    echo "OpenWrt '"$tag"': OK"
  '
}

build_entware_image() {
  docker build -q -t nb-entware-test -f tests/Dockerfile.entware . >/dev/null
}

run_entware() {
  echo "=== Entware x64, источник: пакет (эмуляция Keenetic: /opt + init.d, без ndm)"
  build_entware_image
  # --privileged: хук пишет rp_filter и правила iptables (legacy ip_tables); на хосте нужны модули ip_tables/iptable_filter/iptable_nat
  docker run --rm --privileged -v "$PWD:/src:ro" nb-entware-test sh -c '
    set -e
    cp /src/install.sh /src/uninstall.sh /tmp/
    NB_PLATFORM=keenetic NB_SOURCE=entware NB_NO_UP=1 sh /tmp/install.sh
    sh /src/tests/assert-entware.sh
    NB_PLATFORM=keenetic sh /tmp/uninstall.sh
    ! test -f /opt/etc/ndm/netfilter.d/netbird.sh || { echo "хук остался"; exit 1; }
    echo "Entware: OK"
  '
}

run_upstream() {
  echo "=== Entware x64, источник: upstream (эмуляция Keenetic: /opt + init.d, без ndm)"
  build_entware_image
  docker run --rm --privileged -v "$PWD:/src:ro" nb-entware-test sh -c '
    set -e
    cp /src/install.sh /src/uninstall.sh /tmp/
    opkg update >/dev/null && opkg install curl ca-bundle >/dev/null
    NB_PLATFORM=keenetic NB_SOURCE=upstream NB_NO_UP=1 sh /tmp/install.sh
    sh /src/tests/assert-upstream.sh
    NB_PLATFORM=keenetic sh /tmp/uninstall.sh
    ! test -e /opt/lib/netbird/netbird || { echo "upstream-бинарь остался"; exit 1; }
    ! test -e /opt/bin/netbird || { echo "враппер остался"; exit 1; }
    ! test -f /opt/etc/init.d/S99netbird || { echo "S99netbird остался"; exit 1; }
    ! test -f /opt/etc/ndm/netfilter.d/netbird.sh || { echo "хук остался"; exit 1; }
    echo "Upstream: OK"
  '
}

case "$T" in
  openwrt-24) run_openwrt x86-64-24.10.8 ;;
  openwrt-25) run_openwrt x86-64-25.12.4 ;;
  entware)    run_entware ;;
  upstream)   run_upstream ;;
  all)        run_openwrt x86-64-24.10.8; run_openwrt x86-64-25.12.4; run_entware; run_upstream ;;
  *) echo "unknown target $T"; exit 2 ;;
esac
