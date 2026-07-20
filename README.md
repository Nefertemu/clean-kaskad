# CleanKaskad 3

CleanKaskad превращает российский VPS в прозрачный TCP/UDP-мост до зарубежного сервера.

Главная идея максимально простая:

```text
клиент → RU_IP:PORT → FOREIGN_IP:PORT
```

Порт на российском сервере в обычном режиме **всегда совпадает** с портом зарубежного сервиса. Поэтому в готовой конфигурации клиента меняется только IP:

```ini
# Было
Endpoint = 89.124.251.231:585

# Стало
Endpoint = RU_PUBLIC_IP:585
```

Ключи, параметры AmneziaWG и порт остаются прежними.

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/Nefertemu/clean-kaskad/main/install.sh | sudo bash
```

Повторный запуск:

```bash
sudo kaskad
```

## Быстрый режим AWG/WireGuard

1. Выберите `AWG / WireGuard`.
2. Вставьте зарубежный endpoint целиком:

```text
89.124.251.231:585
```

Также можно вставить строку из конфига:

```ini
Endpoint = 89.124.251.231:585
```

CleanKaskad автоматически создаст:

```text
UDP RU_PUBLIC_IP:585 → 89.124.251.231:585
```

Входящий и выходящий интерфейсы определяются автоматически. Скрипт не спрашивает их в обычном режиме.

## Возможности

- зеркальный порт по умолчанию: порт не нужно вводить второй раз;
- готовая строка `Endpoint = RU_IP:PORT` после создания;
- AWG/WireGuard, VLESS/Xray, MTProto и универсальный TCP/UDP;
- отдельный advanced-режим для намеренной замены порта;
- hostname и IPv4 в качестве зарубежного endpoint;
- автоматическое повторное разрешение hostname при восстановлении;
- собственные цепочки iptables без глобального `iptables -F`;
- совместимость с UFW, Docker и существующими VPN-правилами;
- транзакционное изменение конфигурации с автоматическим откатом;
- резервные копии последних 20 версий правил;
- systemd-восстановление после перезагрузки;
- счётчики пакетов и трафика;
- диагностика маршрута, публичного IP и firewall hooks;
- предупреждение о конфликте с локальным сервисом на том же порту;
- обновление из GitHub командой `sudo kaskad update`;
- CLI для автоматизации.

## CLI

```bash
sudo kaskad add awg 89.124.251.231:585 dataforest
sudo kaskad add vless vpn.example.com:443 europe
sudo kaskad add mtproto 1.2.3.4:443 telegram
sudo kaskad add mirror udp 1.2.3.4:585 custom
```

Только в advanced-режиме указывается отдельный российский порт:

```bash
sudo kaskad add advanced udp 40443 1.2.3.4:585 translated
```

Остальные команды:

```bash
sudo kaskad list
sudo kaskad endpoints
sudo kaskad diagnose
sudo kaskad heal
sudo kaskad restore
sudo kaskad backup
sudo kaskad update
sudo kaskad reset
sudo kaskad uninstall
```

## Как это работает

CleanKaskad создаёт только собственные цепочки:

```text
CK_PREROUTING
CK_POSTROUTING
CK_FORWARD
```

В них находятся правила DNAT, MASQUERADE и разрешение обратного трафика. Остальные цепочки и политики firewall не очищаются.

Конфигурация хранится в:

```text
/etc/cleankaskad/rules.tsv
```

Systemd unit:

```text
cleankaskad.service
```

## Firewall хостинга

На российском VPS нужно разрешить входящий порт и протокол, совпадающие с зарубежным endpoint.

Например, для:

```ini
Endpoint = 89.124.251.231:585
```

разрешите:

```text
UDP 585
```

## Проверка

После подключения клиента:

```bash
sudo kaskad diagnose
```

Если счётчик пакетов остаётся равным нулю, трафик не дошёл до российского VPS. Обычно нужно проверить:

- IP в клиентском Endpoint;
- порт и протокол;
- firewall/security group российского хостинга;
- доступность RU-IP из сети клиента.

Если пакеты растут, но handshake отсутствует, проверяйте зарубежный endpoint и работающий на нём сервис.

## Поддерживаемые системы

- Ubuntu 20.04 и новее;
- Debian 11 и новее;
- IPv4;
- iptables legacy и iptables-nft backend.

IPv6 forwarding в текущей версии намеренно не настраивается.

## Безопасность

Перед установкой из `curl | bash` можно прочитать код:

```bash
curl -fsSL https://raw.githubusercontent.com/Nefertemu/clean-kaskad/main/cleankaskad.sh | less
```

CleanKaskad не отправляет телеметрию и не содержит рекламных ссылок.

## Лицензия

MIT.
