# OpenOCD (portable) — прошивка GD32F330CBT6 через ST-Link V2

Портативная сборка OpenOCD. Установка не требуется — распакована, запускается как есть.

## Что здесь

| Путь | Что это |
|---|---|
| `xpack-openocd-0.12.0-7/bin/openocd.exe` | сам OpenOCD |
| `xpack-openocd-0.12.0-7/openocd/scripts/` | конфиги интерфейсов и целей |
| `xpack-openocd-0.12.0-7-win32-x64.zip` | исходный архив (на случай переустановки) |
| `xpack-openocd-0.12.0-7-win32-x64.zip.sha` | контрольная сумма, сверена — совпала |

Версия: xPack OpenOCD 0.12.0-7 (сборка 2025-10-04).
Источник: https://github.com/xpack-dev-tools/openocd-xpack/releases/tag/v0.12.0-7
SHA256: `6bfd3c97135aafef8affc9af1acf34fd0e2b9ca26044506f6abd7f95b7630052`

## Зачем понадобился

Турникет ASR100, микроконтроллер **GD32F330CBT6** (Cortex-M4, 84 МГц, 128 КБ Flash, 16 КБ SRAM, LQFP48).

STM32CubeProgrammer опознаёт этот чип как `STM32F101/F102/F103 Medium-density`, Device ID `0x410`, CPU Cortex-M3 — и применяет чужой профиль. Итог:

- чтение Flash — работает;
- стирание — работает (секторы 0–90 стираются до сплошных `FF`);
- **запись — падает**: `Error: failed to download Sector[0]` ровно через 61 с (таймаут), 0 %.

Option bytes проверены: RDP снят, WRP не активна — защита ни при чём.

Рабочая версия причины: запись Cube выполняет через flash loader, загружаемый в SRAM цели. Профиль STM32F1 Medium-density рассчитан на **20 КБ SRAM**, а у GD32F330CB её **16 КБ** — загрузчик уходит за границу памяти и виснет. Стиранию буфер в RAM не нужен, поэтому оно и проходит.

OpenOCD этой проблемы лишён: рабочая область в SRAM задаётся явно (`-work-area-size 0x1000`, укладывается в 16 КБ), а драйвер `stm32f1x` подходит GD32F3x0 по FMC (страница 1 КБ, те же ключи разблокировки).

## Прошивка

Из папки `xpack-openocd-0.12.0-7`. Прошивку положить в `C:\fw\ASR100.bin`.

PowerShell (одной строкой):

```powershell
.\bin\openocd.exe -f interface/stlink.cfg -f target/stm32f1x.cfg -c "adapter speed 950" -c "init; reset halt; flash write_image erase C:/fw/ASR100.bin 0x08000000; verify_image C:/fw/ASR100.bin 0x08000000; reset run; shutdown"
```

cmd.exe — то же самое, но с переносами через `^`:

```
bin\openocd.exe -f interface/stlink.cfg -f target/stm32f1x.cfg ^
  -c "adapter speed 950" ^
  -c "init; reset halt; flash write_image erase C:/fw/ASR100.bin 0x08000000; verify_image C:/fw/ASR100.bin 0x08000000; reset run; shutdown"
```

Два обязательных требования к пути `.bin`:

- **прямые слэши** `C:/fw/ASR100.bin`. Содержимое `-c` разбирает Tcl, где обратный слэш — escape-символ: `C:\fw\` превращается в form feed, и файл «не найден»;
- **латиница, без пробелов и кириллицы**.

## Интерактивный режим (диагностика)

Терминал 1:

```
bin\openocd.exe -f interface/stlink.cfg -f target/stm32f1x.cfg -c "adapter speed 950"
```

Терминал 2 — `telnet localhost 4444`, дальше команды:

```
reset halt
flash info 0                   # банки, размер, защита секторов
stm32f1x options_read 0        # RDP и WRP
mdw 0x08000000 16              # проверить, что после стирания там FFFFFFFF
mdw 0x1FFFF800 4               # option bytes напрямую
flash erase_sector 0 0 last    # стереть всё
dump_image dump.bin 0x08000000 0x20000   # снять дамп 128 КБ
```

Снятие защиты (**делает mass erase — сначала сохранить дамп!**):

```
stm32f1x unlock 0
```

После `unlock` или любой записи option bytes — **полностью обесточить плату и подать питание заново**. По NRST option bytes не применяются.

## Результат (проверено на практике)

Плата ASR100 прошита этим способом успешно с первой попытки: после прошивки турникет на столе реагирует на карту, биппер отрабатывает. OpenOCD, в отличие от Cube, определяет ядро верно — `Cortex-M4 r0p1`, `device id = 0x21050410`.

## Грабли

- **OpenOCD молчит об успехе записи.** Сообщения `wrote ... bytes` и `verified ... bytes` идут через `command_print` (результат команды), а не через лог, и при запуске цепочкой `-c` до консоли не доходят. Через лог видны только `Info:` / `Warn:` / `Error:`. **Отсутствие вывода — это норма, а не сбой.** Признаки успеха:
  - нет ни одной строки `Error:`, и выполнение дошло до `shutdown command invoked` (при ошибке Tcl оборвал бы цепочку и сессия повисла бы с gdb-сервером);
  - при `reset halt` регистры совпадают с первыми двумя словами образа: `msp` = стартовый SP, `pc` = reset vector минус thumb-бит (для ASR100: `msp: 0x20003828`, `pc: 0x080000c8`). На пустом флеше было бы `msp = 0xFFFFFFFF` и HardFault.
  - строгая проверка — обратный дамп и сравнение хэшей:
    `-c "init; reset halt; dump_image C:/fw/readback.bin 0x08000000 0x16ac8; shutdown"`,
    затем `Get-FileHash C:\fw\ASR100.bin, C:\fw\readback.bin -Algorithm SHA256`.
- **`Adding extra erase range, 0x08016ac8 .. 0x08016bff`** — не ошибка: конец образа не кратен странице 1 КБ, драйвер дотирает хвост страницы.
- **PowerShell ≠ cmd.** Перенос строки в PS — backtick `` ` ``, а не `^`; `^` в PS рвёт команду на куски и даёт `Unexpected command line argument: ^`. Запуск exe из текущей папки — только через `.\bin\openocd.exe`.
- **Обратные слэши в аргументах `-c`.** Их разбирает Tcl: `C:\fw\ASR100.bin` → `\f` = form feed. Всегда `C:/fw/ASR100.bin`.
- **Размер Flash определяется неверно.** GD32 отдаёт ID, которого драйвер не знает → в логе `STM32 flash size failed, probe inaccurate - assuming 128k flash`. Если мешает — объявить банк вручную:
  `-c "flash bank gd.flash stm32f1x 0x08000000 0x20000 0 0 $_TARGETNAME"`
- **Драйвер ST-Link.** OpenOCD ходит через libusb. Драйвер, поставленный вместе с CubeProgrammer, обычно подходит. Если `open failed` — подменять на WinUSB через Zadig, но тогда Cube перестанет видеть ST-Link, пока драйвер не вернуть обратно.
- **Частота SWD.** 4 МГц (дефолт Cube) для GD32 на проводах много. Ставить 950 кГц, землю — отдельным проводом рядом с SWDIO/SWCLK.
- **Клоны ST-Link V2** часто не имеют разведённой линии NRST — режим «connect under reset» на них не работает.
- **Распаковка на сетевой диск Z: очень медленная** (тысячи мелких файлов скриптов, ~5 минут). Быстрее распаковывать локально и копировать папку целиком.

## Запасной путь, если SWD не поддастся

Штатный UART-загрузчик GigaDevice (протокол тот же, что у ST — AN3155), обходит любые внешние flash loader'ы:

- BOOT0 подтянуть к VDD резистором 10 кОм, USB-UART на PA9 / PA10;
- шить `stm32flash` (portable, без установки): `stm32flash.exe -w fw.bin -v -g 0x0 COM<N>`.
