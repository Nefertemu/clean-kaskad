# CleanKaskad

Чистый менеджер TCP/UDP-переадресаций через российский VPS. Без рекламы, QR-кодов, донатов, телеметрии и сброса чужих правил firewall.

Основной сценарий для AmneziaWG 2.0:

```text
AWG-клиент → RU_SERVER_IP:40443 → FOREIGN_AWG_IP:585
```

На российский сервер **не требуется устанавливать AmneziaWG**. CleanKaskad пересылает уже зашифрованные пакеты через DNAT + MASQUERADE.

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/Nefertemu/clean-kaskad/main/install.sh | sudo bash
```

После установки меню запускается так:

```bash
sudo kaskad
```

## Что есть в меню

- отдельные мастера для AWG/WireGuard, VLESS/Xray, MTProto/TProxy и произвольного TCP/UDP;
- запрос протокола, входного порта, IP и порта зарубежного сервера;
- автоматическое определение сетевых интерфейсов с возможностью изменить их;
- просмотр, изменение и удаление отдельных мостов;
- диагностика, счётчики пакетов и восстановление после перезагрузки;
- обновление из GitHub;
- безопасный сброс только собственных цепочек.

## Пример AWG 2.0

Допустим:

- зарубежный AWG: `203.0.113.10:585`;
- клиент должен подключаться к российскому серверу на UDP `40443`.

Откройте меню:

```bash
sudo kaskad
```

Выберите `Добавить мост` → `AmneziaWG / WireGuard` и введите данные. Затем в клиентском AWG-конфиге замените только endpoint:

```ini
Endpoint = RU_SERVER_IP:40443
```

Ключи и параметры AWG 2.0 остаются от зарубежного сервера.

Командный вариант:

```bash
sudo kaskad add udp 40443 203.0.113.10 585 eth0 eth0 "AWG Germany"
```

## Команды

```bash
sudo kaskad              # меню
sudo kaskad list         # список мостов
sudo kaskad status       # диагностика и счётчики
sudo kaskad restore      # восстановить правила
sudo kaskad update       # обновить из GitHub
sudo kaskad delete ID    # удалить мост по ID
sudo kaskad reset        # удалить только мосты CleanKaskad
sudo kaskad uninstall    # удалить программу и её правила
```

## Безопасность

CleanKaskad использует только собственные цепочки:

- `CK_PREROUTING`;
- `CK_POSTROUTING`;
- `CK_FORWARD`.

Скрипт не выполняет общий `iptables -F`, не меняет политики `INPUT/FORWARD/OUTPUT`, не очищает Docker/UFW и не включает BBR без необходимости.

Правила хранятся в `/etc/cleankaskad/rules.tsv`, резервные копии — в `/etc/cleankaskad/backups/`. После загрузки системы правила восстанавливает `cleankaskad.service`.

## Требования

- Ubuntu или Debian;
- IPv4;
- root/sudo;
- открытый входящий порт в firewall/security group хостинга.

## Удаление

```bash
sudo kaskad uninstall
```

Удаляются только CleanKaskad и созданные им цепочки.
