#!/bin/sh
# Юнит-тест register_peer без Docker: моки netbird/ip/sleep, 4 кейса.
# Проверяет, что успех определяется адресом wt0 и "Management: Connected",
# а не кодом возврата "netbird up", и что рассинхрон завершается ошибкой.
# Запуск из корня репозитория: sh tests/test-register-peer.sh
set -e
cd "$(dirname "$0")/.."
SRC=$(awk '/^PLATFORM=\$\(detect_platform\)$/ {exit} {print}' install.sh)
if [ -z "$SRC" ]; then echo "FAIL: не найден маркер PLATFORM=\$(detect_platform)"; exit 1; fi
pass=0
fail=0
BEFORE_KEYS=$(ls /tmp/netbird-setup-key.* 2>/dev/null || true)
case_run() {
  if [ "$3" = 1 ]; then ADDR='    inet 100.64.1.2/16 scope global wt0'; else ADDR=''; fi
  STUB="netbird() { if [ \"\$1\" = up ]; then return $2; fi; echo 'Management: $4'; }
ip() { echo '$ADDR'; }
sleep() { :; }
register_peer test-log root"
  code=0; out=$(printf '%s\n%s\n' "$SRC" "$STUB" | sh -s dummy-key 2>&1) || code=$?
  if [ "$code" = 0 ]; then
    case "$out" in *Готово.*) s=1;; *) s=0;; esac
  else
    s=0
  fi
  if [ "$s" = "$5" ] && { [ "$5" = 1 ] || [ "$code" != 0 ]; }; then
    echo "  ok  $1 (exit=$code)"; pass=$((pass+1))
  else
    echo "  FAIL $1 (exit=$code)"; printf '%s\n' "$out" | head -5; fail=$((fail+1))
  fi
}
case_run 'connected' 0 1 'Connected' 1
case_run 'up error then connected' 1 1 'Connected' 1
case_run 'stale address disconnected' 1 1 'Disconnected' 0
case_run 'no address' 1 0 'Disconnected' 0
# NB_HOSTNAME пробрасывается в netbird up, мусор отвергается
STUB="netbird() { printf '%s\n' \"\$*\" >> \"\$CAPTURE\"; if [ \"\$1\" = up ]; then return 0; fi; echo 'Management: Connected'; }
ip() { echo '    inet 100.64.1.2/16 scope global wt0'; }
sleep() { :; }
register_peer test-log root"
CAPFILE=$(mktemp)
code=0; CAPTURE="$CAPFILE" NB_HOSTNAME=peer-test-01 sh -s dummy-key <<EOF_INNER >/dev/null 2>&1 || code=$?
$SRC
$STUB
EOF_INNER
if [ "$code" = 0 ] && grep -q -- '--hostname peer-test-01' "$CAPFILE"; then
  echo "  ok  hostname passed to up"; pass=$((pass+1))
else
  echo "  FAIL hostname not passed (exit=$code)"; fail=$((fail+1))
fi
: > "$CAPFILE"
code=0; CAPTURE="$CAPFILE" sh -s dummy-key <<EOF_INNER >/dev/null 2>&1 || code=$?
$SRC
$STUB
EOF_INNER
if [ "$code" = 0 ] && ! grep -q -- '--hostname' "$CAPFILE"; then
  echo "  ok  no hostname by default"; pass=$((pass+1))
else
  echo "  FAIL hostname leaked by default"; fail=$((fail+1))
fi
rm -f "$CAPFILE"
code=0; NB_HOSTNAME='bad name' sh -s dummy-key <<EOF_INNER >/dev/null 2>&1 || code=$?
$SRC
$STUB
EOF_INNER
if [ "$code" != 0 ]; then
  echo "  ok  bad hostname rejected"; pass=$((pass+1))
else
  echo "  FAIL bad hostname accepted"; fail=$((fail+1))
fi
AFTER_KEYS=$(ls /tmp/netbird-setup-key.* 2>/dev/null || true)
if [ "$BEFORE_KEYS" = "$AFTER_KEYS" ]; then
  echo "  ok  no staged key leaked"; pass=$((pass+1))
else
  echo "  FAIL staged key leaked"; fail=$((fail+1))
fi
echo "register_peer: pass=$pass fail=$fail"
[ "$fail" = 0 ]
