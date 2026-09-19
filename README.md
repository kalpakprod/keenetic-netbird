# NetBird на Keenetic (Entware)

Установка одной командой. После перезагрузки роутер сам поднимает NetBird и остаётся доступен через туннель.

Архитектуры: aarch64, armv7, mipsel, mips (пакет `netbird` есть в официальном репозитории Entware для всех).

## Требования (веб-интерфейс Keenetic)

1. Установлен [Entware на USB](https://help.keenetic.com/hc/ru/articles/360021214160).
2. Установлен компонент **WireGuard VPN** (Параметры системы -> Компоненты). Он даёт `/dev/net/tun`.
3. В панели NetBird создан **Setup Key**.

## Установка

SSH в Entware (порт 222, пользователь root):

```sh
opkg update && opkg install curl ca-bundle
curl -fsSL https://raw.githubusercontent.com/kalpakprod/keenetic-netbird/main/install.sh -o /tmp/nb.sh
sh /tmp/nb.sh <SETUP_KEY>
```

Self-hosted NetBird: `sh /tmp/nb.sh <SETUP_KEY> https://netbird.example.com`

## Проверка

```sh
netbird status        # Management: Connected
reboot
```

Через 2 минуты с любого другого пира NetBird: `ssh -p 222 root@<NetBird-IP роутера>`.

## Что ставится и почему это живёт после перезагрузки

| Файл | Назначение |
|---|---|
| `/opt/etc/init.d/S99netbird` | штатный автозапуск из пакета Entware; состояние и ключи в `/opt/var/lib/netbird` на USB |
| `/opt/etc/netbird/env` | флаги демона (лог в `/opt/var/log/netbird.log`) |
| `/opt/etc/ndm/netfilter.d/netbird.sh` | хук KeeneticOS: при каждой пересборке фаервола (загрузка, смена WAN, любое изменение в веб-интерфейсе) заново разрешает INPUT на `wt0` (22, 222, 80, 443, icmp), FORWARD wt0<->br0, MASQUERADE и ставит `rp_filter=0`. Без него демон живёт, но зайти на роутер нельзя |
| `/opt/etc/netbird/watchdog.sh` + cron | каждые 2 минуты перезапускает демон, если процесс умер (OOM на роутере) |

`--disable-dns`: NetBird не трогает DNS роутера, домашняя сеть не теряет резолв.

## Удаление

```sh
curl -fsSL https://raw.githubusercontent.com/kalpakprod/keenetic-netbird/main/uninstall.sh | sh
```

## Источники

- Пакет: официальный репозиторий Entware, `bin.entware.net/<arch>/Packages`, Maintainer: Entware team.
- Хук netfilter: [forum.keenetic.ru/topic/21273-netbird](https://forum.keenetic.ru/topic/21273-netbird/).
- Entware и скрипты ndm: [help.keenetic.com](https://help.keenetic.com/hc/ru/articles/360021214160).
