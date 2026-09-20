#!/bin/sh
# Юнит-тест выбора upstream-архитектуры без Docker.
# Запуск из корня репозитория: sh tests/test-source-select.sh
set -e
cd "$(dirname "$0")/.."
SRC=$(awk '/^PLATFORM=\$\(detect_platform\)$/ {exit} {print}' install.sh)
if [ -z "$SRC" ]; then echo "FAIL: не найден маркер PLATFORM=\$(detect_platform)"; exit 1; fi
pass=0
fail=0
arch_case() {
  if [ -n "$3" ]; then NBSET="NB_ARCH='$3'"; else NBSET="unset NB_ARCH"; fi
  STUB="uname() { echo '$2'; }
$NBSET
map_upstream_arch"
  code=0; got=$(printf '%s\n%s\n' "$SRC" "$STUB" | sh -s 2>&1) || code=$?
  if [ "$4" = FAIL ]; then
    if [ "$code" != 0 ]; then echo "  ok  $1 (отказ)"; pass=$((pass+1)); else echo "  FAIL $1: ожидался отказ, получен $got"; fail=$((fail+1)); fi
  else
    if [ "$code" = 0 ] && [ "$got" = "$4" ]; then echo "  ok  $1 -> $got"; pass=$((pass+1)); else echo "  FAIL $1: ожидался $4, получен '$got' (exit=$code)"; fail=$((fail+1)); fi
  fi
}
arch_case 'aarch64' 'aarch64' '' 'arm64'
arch_case 'x86_64' 'x86_64' '' 'amd64'
arch_case 'armv7l' 'armv7l' '' 'armv6'
arch_case 'armv6l' 'armv6l' '' 'armv6'
arch_case 'mips без оверрайда' 'mips' '' 'FAIL'
arch_case 'NB_ARCH побеждает' 'mips' 'mipsle_softfloat' 'mipsle_softfloat'
echo "source-select: pass=$pass fail=$fail"
[ "$fail" = 0 ]
