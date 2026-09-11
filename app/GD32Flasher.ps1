# GD32Flasher — GUI поверх OpenOCD в духе STM32CubeProgrammer.
# Держит постоянную сессию OpenOCD и общается с ней по telnet 4444, поэтому в логе
# видны результаты команд (wrote/verified), которых нет при запуске цепочкой -c.
# Берёт на себя грабли: распаковку OpenOCD, пути без кириллицы, Tcl-escape, бэкап перед стиранием.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Прячем консоль только после успешной загрузки сборок: если что-то упадёт раньше,
# окно останется на экране вместе с текстом ошибки.
Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
$hWnd = [Native.Win]::GetConsoleWindow()
if ($hWnd -ne [IntPtr]::Zero) { [void][Native.Win]::ShowWindow($hWnd, 0) }

# Один экземпляр: параллельные запуски рвут друг другу распаковку OpenOCD.
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'GD32Flasher_singleton', [ref]$created)
if (-not $created) {
    [System.Windows.Forms.MessageBox]::Show('GD32Flasher уже запущен. Проверьте панель задач.', 'GD32Flasher', 'OK', 'Information') | Out-Null
    exit
}

$AppVersion = '1.6.1'
$Zip = Join-Path $PSScriptRoot 'tools\xpack-openocd-0.12.0-7-win32-x64.zip'

# Рабочая папка обязательно без кириллицы: OpenOCD и его Tcl не переваривают не-ASCII в путях.
$Base = if ($env:LOCALAPPDATA -match '^[\x20-\x7E]+$') { Join-Path $env:LOCALAPPDATA 'GD32Flasher' } else { 'C:\GD32Flasher' }
$Work = Join-Path $Base 'work'
New-Item -ItemType Directory -Force -Path $Work | Out-Null

$LastFile = Join-Path $Base 'last.txt'

$script:proc = $null
$script:tcp = $null
$script:fOut = Join-Path $Work 'ocd.out'
$script:fErr = Join-Path $Work 'ocd.err'
$script:pos = @{ out = 0; err = 0 }
# Хвост недописанной строки: файл читается, пока OpenOCD в него пишет, и последняя
# строка часто обрывается на середине (в логе было «Info : [s» + «tm32f1x.cpu]»).
$script:tail = @{ out = ''; err = '' }
# Всё, что OpenOCD написал в свой лог за время текущей команды: ошибки идут туда,
# а не в ответ telnet, и без их учёта провал операции выглядел как успех.
$script:pumped = New-Object Text.StringBuilder
$script:Lang = 'RU'
# Завершение работы: пока флаг поднят, никто не ждёт ответов от OpenOCD и не пишет
# в лог — иначе закрытие окна упирается в таймауты умирающей сессии.
$script:closing = $false
$script:busy = $false
# Выдернутый донгл заставляет OpenOCD сыпать одну и ту же ошибку сотнями строк:
# считаем их подряд и гасим сессию, а сам лог не даём засорить повторами.
$script:lostCount = 0
$script:lastLine = ''
$script:repeatCount = 0

# --- локализация ---

$Str = @{
    RU = @{
        subtitle    = 'OpenOCD + ST-Link'
        connected   = '● Подключено'
        disconnected= '● Не подключено'
        grpConn     = 'ПОДКЛЮЧЕНИЕ'
        capIface    = 'Программатор'
        capTarget   = 'Конфигурация цели'
        capSpeed    = 'Частота SWD, кГц'
        capReset    = 'Сброс'
        resetSoft   = 'Программный'
        resetHard   = 'Аппаратный (SRST)'
        btnDetect   = 'Определить чип'
        btnPinout   = 'Как подключить провода'
        ttlPinout   = 'Подключение программатора к плате'
        tabWires    = '  Провода  '
        tabPkg      = '  Корпуса  '
        tabHdr      = '  Разъём  '
        tabHelp     = '  Если связи нет  '
        pinoutWires = @"

   ЧТО СОЕДИНЯТЬ — четыре провода

      Программатор              Плата
      SWDIO   ──────────────    SWDIO     вывод PA13
      SWCLK   ──────────────    SWCLK     вывод PA14
      GND     ──────────────    GND
      3.3V    ──────────────    3.3V      только если плата не питается сама


   Землю вести ОТДЕЛЬНЫМ проводом рядом с SWDIO и SWCLK. Общая земля через
   корпус или дальний контакт даёт срывы связи на скорости.

   NRST нужен редко, и у многих клонов ST-Link V2 он просто не выведен.


   ST-LINK V2, КЛОН-ДОНГЛ

   Контакты подписаны прямо на корпусе, нужны только четыре: 3.3V, SWDIO,
   SWCLK, GND. SWIM рядом — это не SWD, а интерфейс STM8, с SWDIO не путать.
   5 В на цель не подавать.
"@
        pinoutPkg   = @"

   НОМЕРА ВЫВОДОВ ПО КОРПУСАМ — GD32F330, из даташита GigaDevice

   ┌───────────────────┬────────┬────────┬───────┬───────┬─────────┐
   │ Вывод             │ LQFP64 │ LQFP48 │ QFN32 │ QFN28 │ TSSOP20 │
   ├───────────────────┼────────┼────────┼───────┼───────┼─────────┤
   │ PA13   SWDIO      │   46   │   34   │  23   │  21   │   19    │
   │ PA14   SWCLK      │   49   │   37   │  24   │  22   │   20    │
   │ NRST   сброс      │    7   │    7   │   4   │   4   │    4    │
   │ BOOT0  загрузчик  │   60   │   44   │  31   │   1   │    1    │
   └───────────────────┴────────┴────────┴───────┴───────┴─────────┘

   Счёт выводов у LQFP и QFN — против часовой стрелки от ключевой точки
   (кружок или скошенный угол), у TSSOP — от метки рядом с первым выводом.

   У всех STM32 и GD32 серий F0, F1, F3 отладочные выводы одни и те же:
   SWDIO = PA13, SWCLK = PA14. Меняются только номера на корпусе — их и
   смотреть в даташите на свой чип.
"@
        pinoutHdr   = @"

   РАЗЪЁМ НА ПЛАТЕ — ARM Cortex Debug, 10 контактов, шаг 1.27 мм

                     ┌─────────┐
       1  VTref      │ ●     ● │   2  SWDIO
       3  GND        │ ●     ● │   4  SWCLK
       5  GND        │ ●     ● │   6  SWO
       7  KEY        │       ● │   8  NC
       9  GNDDetect  │ ●     ● │  10  nRESET
                     └─────────┘

   Контакт 7 — ключ: в вилке он отсутствует, в ответной части закрыт
   заглушкой. По нему и определяется, какой стороной вставлять.

   Первый контакт помечен точкой или квадратной площадкой. Шелкография
   врёт чаще, чем хотелось бы: если связи нет — прозвонить контакты до
   GND и до питания, а не верить надписям.
"@
        pinoutHelp  = @"

   ЕСЛИ СВЯЗИ НЕТ

   •  понизить частоту SWD до 480 кГц;

   •  провода короче 10-15 см, земля рядом с сигнальными;

   •  питать плату отдельно, а не от программатора: заметная нагрузка
      сажает донгл, и он перестаёт опознаваться даже на USB;

   •  если прошивка заняла PA13/PA14 под обычные GPIO, SWD пропадает
      сразу после старта — остаётся UART-загрузчик через BOOT0;

   •  «Error: open failed» — это не про провода, а про драйвер:
      поставить tools\stlink-driver\stlink_winusb_install.bat
      от имени администратора, до подключения программатора.
"@
        btnConnect  = 'Подключиться'
        btnDisconn  = 'Отключиться'
        grpInfo     = 'ИНФОРМАЦИЯ О ЦЕЛИ'
        capCore     = 'Ядро'
        capId       = 'Device ID'
        capFlash    = 'Объём Flash'
        capVolt     = 'Напряжение'
        hint        = "Не знаете, что выбрать в «Конфигурация цели» — нажмите «Определить чип».`r`n`r`nСвязь нестабильна — снизьте частоту до 480 кГц. Землю программатора вести отдельным проводом рядом с SWDIO/SWCLK."
        capFile     = 'Файл прошивки'
        btnBrowse   = 'Выбрать файл...'
        tipFile     = 'Файл .bin или .hex, который будет записан в микроконтроллер. Файл можно перетащить сюда мышью. Для чтения дампа файл не нужен.'
        capAddr     = 'Адрес'
        capSize     = 'Размер чтения'
        chkBackup   = 'Резервный дамп перед стиранием и прошивкой'
        btnProgram  = 'Прошить + проверить'
        btnVerify   = 'Только проверить'
        btnRead     = 'Считать дамп'
        btnErase    = 'Стереть'
        btnInfo     = 'Информация'
        btnUnlock   = 'Снять защиту'
        btnReset    = 'Сброс и запуск'
        btnFlashSz  = 'Объём Flash'
        btnClear    = 'Очистить лог'
        ttlFlashSz  = 'Определение объёма Flash'
        fsFromReg   = 'Регистр размера {0} сообщает: {1} КБ.'
        fsProbe     = 'Регистр размера не заполнен — проверяю чтением границ.'
        fsProbeHit  = 'Читается адрес до конца {0} КБ — объём не меньше этого.'
        fsSet       = 'Объём Flash: {0} КБ. Поле «Размер чтения» заполнено ({1}).'
        fsMirror    = 'Внимание: адрес за границей часто читается как зеркало начала Flash. Если объём получился больше ожидаемого — сверьтесь с маркировкой чипа.'
        fsFail      = 'Определить объём не удалось. Смотрите маркировку чипа: 8 = 64 КБ, B = 128 КБ, C = 256 КБ, E = 512 КБ.'
        capLang     = 'Язык'
        stReady     = 'Готов'
        stBusy      = 'Выполняется...'
        stPrepare   = 'Подготовка: распаковка OpenOCD (при первом запуске — до минуты)'
        stDetect    = 'Определение чипа...'
        stConnect   = 'Подключение...'
        logPrepare  = 'Распаковываю OpenOCD, при первом запуске это занимает до минуты...'
        logReady    = 'Готово: {0} программаторов, {1} конфигураций целей.'
        logOrder    = 'Порядок: подключить программатор → «Определить чип» → «Подключиться» → «Считать дамп» → выбрать файл → «Прошить + проверить».'
        logNames    = 'Имена конфигураций цели относятся к типу контроллера Flash, а не к марке чипа:'
        logNames2   = '  stm32f1x — это GD32F3x0 (в том числе GD32F330), GD32F1x0, F10x, E10x и STM32F1;'
        logNames3   = '  если марка неизвестна или сомневаетесь — просто нажмите «Определить чип».'
        logNoOcd    = 'Без OpenOCD работа невозможна. Проверьте, что рядом с программой лежит папка tools с архивом.'
        logNoFile   = 'Не выбран файл прошивки.'
        logNoConn   = 'Нет подключения к цели.'
        logSelected = 'Выбран файл: {0} ({1} байт)'
        logOk       = 'РЕЗУЛЬТАТ: успешно'
        logFail     = 'РЕЗУЛЬТАТ: ошибка'
        logNoProof  = 'OpenOCD не подтвердил выполнение: «{0}» не дала признака успеха.'
        logCopyFail = 'Не удалось подготовить прошивку: {0}'
        logFwReady  = 'Прошивка подготовлена: {0} -> {1} ({2} байт)'
        logOcdExit  = 'OpenOCD завершился с кодом {0} — смотрите строки выше.'
        logConnOk   = 'Подключено.'
        logConnFail = 'Подключиться не удалось. Проверьте кабель, питание платы и выбранный конфиг цели.'
        logDumpSave = 'Дамп сохранён: {0}'
        logDetect   = '=== Автоопределение чипа ==='
        logDetectId = 'Device ID {0}: семейство {1} — это {2}. Драйвер Flash: {3}.'
        logDetectIdNo = 'Device ID {0} (семейство {1}) в таблице не значится — перебираю конфигурации.'
        logDetectWhy= '  {0}: Device ID {1}, Flash {2} {3}'
        logDetectRetry = 'Первый запуск OpenOCD ничего не ответил (холодный старт) — повторяю.'
        updFound    = 'Доступна версия {0} (у вас {1}). Нажмите «Обновить», чтобы поставить её.'
        updNone     = 'Установлена последняя версия.'
        updBtn      = 'Обновить до {0}'
        updChecking = 'Проверяю обновления...'
        updDownload = 'Скачиваю обновление, это 8 МБ...'
        updApply    = 'Заменяю файлы программы...'
        updOk       = 'Обновление установлено: версия {0}. Закройте и запустите программу заново.'
        updFail     = 'Обновиться не удалось: {0}'
        updBadZip   = 'В скачанном архиве нет файлов программы — обновление отменено, ничего не тронуто.'
        logProbeDead= 'Программатор отвечает пустым идентификатором (VID:PID 0000:0000) — он «слетел» и работать не может. Выньте и вставьте донгл. Провода и питание платы тут ни при чём; если он питает плату, подключите её к отдельному источнику.'
        logDetectGo = 'Перебираю конфигурации, это занимает до полуминуты.'
        logDetectTry= '  проверяю: {0}'
        logDetectHit= '  подходит: {0} — ядро {1}, Flash {2} КБ'
        logDetectSet= 'Выбрана конфигурация цели: {0}. Теперь нажмите «Подключиться».'
        logDetectCpu= 'Ядро определилось ({0}), но подходящий драйвер Flash не найден среди типовых. Выберите конфигурацию вручную.'
        logDetectNo = 'Чип не отвечает. Проверьте питание платы, подключение SWDIO/SWCLK/GND и понизьте частоту до 480 кГц.'
        logBackupNo = 'Операция отменена: не удалось снять дамп.'
        logBackupFF = 'Дамп состоит из одних 0xFF — по адресу {0} нет содержимого. Проверьте поле «Адрес»: основная Flash начинается с 0x08000000. Это не резервная копия, продолжать нельзя.'
        logNoBank   = 'OpenOCD не нашёл банк Flash по этому адресу — записывать было некуда. Основная Flash начинается с 0x08000000.'
        logAddrFromImage = 'Образ {0} хранит адреса внутри себя — поле «Адрес» к нему не применяется, запись пойдёт по адресам из файла.'
        logProbeLost = 'Программатор отключён или потерян контакт с целью — сессия закрыта. Воткните донгл и нажмите «Подключиться».'
        logRepeat   = '  ... строка повторяется, дальнейшие повторы скрыты.'
        fiSummary   = 'Flash: {0}, {1}, {2} КБ, секторов {3} по {4} КБ, защиты нет.'
        fiSummaryP  = 'Flash: {0}, {1}, {2} КБ, секторов {3} по {4} КБ.'
        fiProtected = 'ЗАЩИЩЕНЫ ОТ ЗАПИСИ: секторы {0} ({1})'
        fiUnprotOk  = 'Защита записи снята. Снимите и подайте питание платы: option bytes применяются только по power-on reset.'
        msgUnprotect= "Снять защиту записи с секторов {0}? Чип при этом НЕ стирается.`r`n`r`nЗащита хранится в option bytes, поэтому после снятия нужно снять и подать питание платы."
        ttlUnprotect= 'Снятие защиты записи'
        msgCloseBusy= "Идёт операция с Flash. Если прервать её сейчас, в чипе останется недописанная прошивка и плата не запустится.`r`n`r`nЗакрыть всё равно?"
        ttlPrepare  = '=== Подготовка ==='
        ttlHalt     = 'Остановка ядра'
        ttlWrite    = 'Запись прошивки'
        ttlVerify   = 'Проверка (verify)'
        ttlRun      = 'Запуск'
        ttlRead     = 'Чтение памяти'
        ttlErase    = 'Стирание Flash'
        ttlCheck    = 'Контроль первых слов'
        ttlFlashInfo= 'Состояние Flash'
        ttlUnlock   = 'Снятие защиты'
        ttlBackup   = 'Резервный дамп -> {0}'
        ttlConn     = '=== Подключение: {0} / {1} / {2} кГц ==='
        msgErase    = 'Стереть Flash полностью? Данные будут потеряны.'
        msgUnlock   = "Снятие защиты выполняет полное стирание кристалла (mass erase). Продолжить?`r`n`r`nСтирание произойдёт при следующей подаче питания: option bytes применяются только по power-on reset. Если прошивка нужна — СНАЧАЛА снимите дамп и убедитесь, что файл не пустой. После обесточивания платы восстановить её будет уже нечем."
        msgConfirm  = 'Подтверждение'
        dlgFw       = 'Прошивка (*.bin;*.hex;*.elf)|*.bin;*.hex;*.elf|Все файлы (*.*)|*.*'
        dlgDump     = 'Дамп (*.bin)|*.bin'
        workdir     = 'Рабочая папка: {0}'
    }
    EN = @{
        subtitle    = 'OpenOCD + ST-Link'
        connected   = '● Connected'
        disconnected= '● Not connected'
        grpConn     = 'CONNECTION'
        capIface    = 'Debug probe'
        capTarget   = 'Target config'
        capSpeed    = 'SWD speed, kHz'
        capReset    = 'Reset'
        resetSoft   = 'Software'
        resetHard   = 'Hardware (SRST)'
        btnDetect   = 'Detect chip'
        btnPinout   = 'How to wire it up'
        ttlPinout   = 'Wiring the probe to the board'
        tabWires    = '  Wires  '
        tabPkg      = '  Packages  '
        tabHdr      = '  Connector  '
        tabHelp     = '  No link  '
        pinoutWires = @"

   WHAT TO CONNECT - four wires

      Probe                     Board
      SWDIO   ──────────────    SWDIO     pin PA13
      SWCLK   ──────────────    SWCLK     pin PA14
      GND     ──────────────    GND
      3.3V    ──────────────    3.3V      only if the board has no power itself


   Run the ground as a SEPARATE wire next to SWDIO and SWCLK. A shared ground
   through the case or a distant pin causes dropouts at speed.

   NRST is rarely needed, and many ST-Link V2 clones do not expose it at all.


   ST-LINK V2 DONGLE CLONE

   The pins are labelled on the case itself; only four are needed: 3.3V,
   SWDIO, SWCLK, GND. SWIM next to them is not SWD - it is the STM8 interface,
   do not confuse it with SWDIO. Never feed 5 V to the target.
"@
        pinoutPkg   = @"

   PIN NUMBERS BY PACKAGE - GD32F330, from the GigaDevice datasheet

   ┌───────────────────┬────────┬────────┬───────┬───────┬─────────┐
   │ Pin               │ LQFP64 │ LQFP48 │ QFN32 │ QFN28 │ TSSOP20 │
   ├───────────────────┼────────┼────────┼───────┼───────┼─────────┤
   │ PA13   SWDIO      │   46   │   34   │  23   │  21   │   19    │
   │ PA14   SWCLK      │   49   │   37   │  24   │  22   │   20    │
   │ NRST   reset      │    7   │    7   │   4   │   4   │    4    │
   │ BOOT0  bootloader │   60   │   44   │  31   │   1   │    1    │
   └───────────────────┴────────┴────────┴───────┴───────┴─────────┘

   LQFP and QFN pins count counter-clockwise from the key mark (a dot or a
   bevelled corner); TSSOP counts from the mark next to pin 1.

   Every STM32 and GD32 in the F0, F1 and F3 families uses the same debug
   pins: SWDIO = PA13, SWCLK = PA14. Only the package numbers differ - look
   those up in the datasheet for your own chip.
"@
        pinoutHdr   = @"

   BOARD CONNECTOR - ARM Cortex Debug, 10 pins, 1.27 mm pitch

                     ┌─────────┐
       1  VTref      │ ●     ● │   2  SWDIO
       3  GND        │ ●     ● │   4  SWCLK
       5  GND        │ ●     ● │   6  SWO
       7  KEY        │       ● │   8  NC
       9  GNDDetect  │ ●     ● │  10  nRESET
                     └─────────┘

   Pin 7 is the key: missing on the header, blocked on the mating plug.
   That is what tells you which way round it goes.

   Pin 1 is marked with a dot or a square pad. Silkscreen lies more often
   than you would like: if there is no link, ring the pins out against GND
   and power instead of trusting the labels.
"@
        pinoutHelp  = @"

   IF THERE IS NO LINK

   -  lower the SWD speed to 480 kHz;

   -  keep wires under 10-15 cm, ground next to the signals;

   -  power the board separately: a noticeable load drags the dongle down
      and it stops enumerating on USB at all;

   -  if the firmware took PA13/PA14 as ordinary GPIO, SWD disappears right
      after startup - the UART bootloader via BOOT0 is what is left;

   -  "Error: open failed" is not about the wiring but about the driver:
      run tools\stlink-driver\stlink_winusb_install.bat as administrator,
      before plugging the probe in.
"@
        btnConnect  = 'Connect'
        btnDisconn  = 'Disconnect'
        grpInfo     = 'TARGET INFORMATION'
        capCore     = 'Core'
        capId       = 'Device ID'
        capFlash    = 'Flash size'
        capVolt     = 'Voltage'
        hint        = "Not sure what to pick in Target config? Press Detect chip.`r`n`r`nUnstable link: lower the speed to 480 kHz. Run the probe ground as a separate wire next to SWDIO/SWCLK."
        capFile     = 'Firmware file'
        btnBrowse   = 'Choose file...'
        tipFile     = 'The .bin or .hex file to be written into the microcontroller. You can drag and drop a file here. Not needed for reading a dump.'
        capAddr     = 'Address'
        capSize     = 'Read size'
        chkBackup   = 'Back up flash before erase and program'
        btnProgram  = 'Program + verify'
        btnVerify   = 'Verify only'
        btnRead     = 'Read dump'
        btnErase    = 'Erase'
        btnInfo     = 'Information'
        btnUnlock   = 'Remove protection'
        btnReset    = 'Reset and run'
        btnFlashSz  = 'Flash size'
        btnClear    = 'Clear log'
        ttlFlashSz  = 'Detecting flash size'
        fsFromReg   = 'Size register {0} reports: {1} KB.'
        fsProbe     = 'The size register is empty - probing by reading boundaries.'
        fsProbeHit  = 'Address at the end of {0} KB reads fine - the flash is at least that big.'
        fsSet       = 'Flash size: {0} KB. The read size field is filled in ({1}).'
        fsMirror    = 'Note: past the end, flash often mirrors its beginning. If the size looks larger than expected, check the chip marking.'
        fsFail      = 'Could not determine the size. Check the chip marking: 8 = 64 KB, B = 128 KB, C = 256 KB, E = 512 KB.'
        capLang     = 'Language'
        stReady     = 'Ready'
        stBusy      = 'Working...'
        stPrepare   = 'Preparing: unpacking OpenOCD (first run takes up to a minute)'
        stDetect    = 'Detecting chip...'
        stConnect   = 'Connecting...'
        logPrepare  = 'Unpacking OpenOCD, the first run takes up to a minute...'
        logReady    = 'Ready: {0} probes, {1} target configs.'
        logOrder    = 'Order: attach the probe -> Detect chip -> Connect -> Read dump -> pick a file -> Program + verify.'
        logNames    = 'Target config names refer to the flash controller type, not to the chip brand:'
        logNames2   = '  stm32f1x covers GD32F3x0 (including GD32F330), GD32F1x0, F10x, E10x and STM32F1;'
        logNames3   = '  if the marking is unknown or you are unsure, just press Detect chip.'
        logNoOcd    = 'OpenOCD is required. Make sure the tools folder with the archive sits next to the program.'
        logNoFile   = 'No firmware file selected.'
        logNoConn   = 'Not connected to a target.'
        logSelected = 'Selected file: {0} ({1} bytes)'
        logOk       = 'RESULT: success'
        logFail     = 'RESULT: failed'
        logNoProof  = 'OpenOCD did not confirm the operation: "{0}" produced no success marker.'
        logCopyFail = 'Could not prepare the firmware: {0}'
        logFwReady  = 'Firmware prepared: {0} -> {1} ({2} bytes)'
        logOcdExit  = 'OpenOCD exited with code {0} - see the lines above.'
        logConnOk   = 'Connected.'
        logConnFail = 'Connection failed. Check the cable, board power and the selected target config.'
        logDumpSave = 'Dump saved: {0}'
        logDetect   = '=== Chip autodetection ==='
        logDetectId = 'Device ID {0}: family {1} - that is {2}. Flash driver: {3}.'
        logDetectIdNo = 'Device ID {0} (family {1}) is not in the table - falling back to trying configs.'
        logDetectWhy= '  {0}: Device ID {1}, flash {2} {3}'
        logDetectRetry = 'The first OpenOCD run answered nothing (cold start) - trying again.'
        updFound    = 'Version {0} is available (you have {1}). Press Update to install it.'
        updNone     = 'You are on the latest version.'
        updBtn      = 'Update to {0}'
        updChecking = 'Checking for updates...'
        updDownload = 'Downloading the update, 8 MB...'
        updApply    = 'Replacing the program files...'
        updOk       = 'Update installed: version {0}. Close the program and start it again.'
        updFail     = 'The update failed: {0}'
        updBadZip   = 'The downloaded archive has no program files - update cancelled, nothing was touched.'
        logProbeDead= 'The probe reports an empty identifier (VID:PID 0000:0000) - it has fallen over and cannot work. Unplug the dongle and plug it back in. This is not about the wiring or the board power; if the dongle feeds the board, give the board its own supply.'
        logDetectGo = 'Trying configs, this takes up to half a minute.'
        logDetectTry= '  trying: {0}'
        logDetectHit= '  match: {0} - core {1}, flash {2} KB'
        logDetectSet= 'Target config set to {0}. Now press Connect.'
        logDetectCpu= 'Core detected ({0}), but no matching flash driver among the common ones. Pick a config manually.'
        logDetectNo = 'No response from the chip. Check board power, SWDIO/SWCLK/GND wiring and lower the speed to 480 kHz.'
        logBackupNo = 'Operation cancelled: the backup dump failed.'
        logBackupFF = 'The dump is all 0xFF - there is nothing at address {0}. Check the Address field: the main flash starts at 0x08000000. This is not a backup, so the operation cannot continue.'
        logNoBank   = 'OpenOCD found no flash bank at this address - there was nowhere to write. The main flash starts at 0x08000000.'
        logAddrFromImage = 'A {0} image carries its own addresses - the Address field does not apply to it, the data goes where the file says.'
        logProbeLost = 'The probe was unplugged or the link to the target is gone - the session is closed. Plug the dongle back in and press Connect.'
        logRepeat   = '  ... the line repeats, further repeats are hidden.'
        fiSummary   = 'Flash: {0}, {1}, {2} KB, {3} sectors of {4} KB, no protection.'
        fiSummaryP  = 'Flash: {0}, {1}, {2} KB, {3} sectors of {4} KB.'
        fiProtected = 'WRITE PROTECTED: sectors {0} ({1})'
        fiUnprotOk  = 'Write protection removed. Power-cycle the board: option bytes only apply on a power-on reset.'
        msgUnprotect= "Remove write protection from sectors {0}? The chip is NOT erased.`r`n`r`nThe protection lives in the option bytes, so the board has to be power-cycled afterwards."
        ttlUnprotect= 'Removing write protection'
        msgCloseBusy= "A flash operation is running. Interrupting it now leaves half-written firmware in the chip and the board will not start.`r`n`r`nClose anyway?"
        ttlPrepare  = '=== Preparing ==='
        ttlHalt     = 'Halting the core'
        ttlWrite    = 'Programming'
        ttlVerify   = 'Verify'
        ttlRun      = 'Run'
        ttlRead     = 'Reading memory'
        ttlErase    = 'Erasing flash'
        ttlCheck    = 'Checking the first words'
        ttlFlashInfo= 'Flash state'
        ttlUnlock   = 'Removing protection'
        ttlBackup   = 'Backup dump -> {0}'
        ttlConn     = '=== Connecting: {0} / {1} / {2} kHz ==='
        msgErase    = 'Erase the whole flash? The data will be lost.'
        msgUnlock   = "Removing protection performs a full chip erase (mass erase). Continue?`r`n`r`nThe erase happens on the next power-up: option bytes only apply on a power-on reset. If you need the firmware, read a dump FIRST and check the file is not empty. Once the board is powered down there will be nothing left to restore it from."
        msgConfirm  = 'Confirm'
        dlgFw       = 'Firmware (*.bin;*.hex;*.elf)|*.bin;*.hex;*.elf|All files (*.*)|*.*'
        dlgDump     = 'Dump (*.bin)|*.bin'
        workdir     = 'Working folder: {0}'
    }
}

function T([string]$key) { return $Str[$script:Lang][$key] }

# --- палитра в духе CubeProgrammer ---
$clrBack   = [System.Drawing.Color]::FromArgb(222, 229, 235)
$clrPanel  = [System.Drawing.Color]::FromArgb(247, 249, 251)
$clrHeader = [System.Drawing.Color]::FromArgb(0, 39, 73)
$clrHeader2= [System.Drawing.Color]::FromArgb(0, 52, 94)
$clrBtn    = [System.Drawing.Color]::FromArgb(31, 165, 207)
$clrBtnAlt = [System.Drawing.Color]::FromArgb(30, 75, 111)
$clrGreen  = [System.Drawing.Color]::FromArgb(183, 207, 0)
$clrRed    = [System.Drawing.Color]::FromArgb(191, 73, 73)
$clrText   = [System.Drawing.Color]::FromArgb(20, 30, 38)
$clrDim    = [System.Drawing.Color]::FromArgb(96, 110, 126)
$clrLogBg  = [System.Drawing.Color]::FromArgb(247, 249, 250)
$clrAccent = [System.Drawing.Color]::FromArgb(72, 194, 236)
$clrSide   = [System.Drawing.Color]::FromArgb(0, 43, 78)
$clrSide2  = [System.Drawing.Color]::FromArgb(0, 34, 63)
$clrLine   = [System.Drawing.Color]::FromArgb(46, 104, 143)
$clrFocus  = [System.Drawing.Color]::FromArgb(107, 206, 239)
$clrSideText = [System.Drawing.Color]::FromArgb(230, 239, 247)
$clrSideDim  = [System.Drawing.Color]::FromArgb(157, 183, 205)
$clrTool    = [System.Drawing.Color]::FromArgb(0, 47, 84)
$clrToolHot = [System.Drawing.Color]::FromArgb(0, 78, 126)
$clrIcon    = [System.Drawing.Color]::FromArgb(208, 228, 28)
$clrDangerIcon = [System.Drawing.Color]::FromArgb(255, 179, 103)

function Get-OpenOcd {
    $exe = Get-ChildItem -Path $Base -Filter openocd.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) {
        if (-not (Test-Path $Zip)) { throw "Не найден архив OpenOCD: $Zip" }
        Expand-Archive -Path $Zip -DestinationPath $Base -Force
        $exe = Get-ChildItem -Path $Base -Filter openocd.exe -Recurse | Select-Object -First 1
    }
    if (-not $exe) { throw 'openocd.exe не найден после распаковки' }
    $scripts = Join-Path (Split-Path (Split-Path $exe.FullName -Parent) -Parent) 'openocd\scripts'
    if (-not (Test-Path $scripts)) { throw "Не найдена папка scripts: $scripts" }
    [pscustomobject]@{ Exe = $exe.FullName; Scripts = $scripts }
}

# Путь для Tcl: только прямые слэши, иначе \f, \n и т.п. трактуются как escape-последовательности.
function ConvertTo-TclPath([string]$p) { $p -replace '\\', '/' }

function Log([string]$text, [System.Drawing.Color]$color) {
    if ($null -eq $text) { return }
    if ($script:closing) { return }
    # Одна и та же строка подряд: три раза печатаем, дальше молчим. Сотни одинаковых
    # «Polling failed» не несут информации, зато вешают RichTextBox.
    if ($text -eq $script:lastLine) {
        $script:repeatCount++
        if ($script:repeatCount -eq 3) { $log.AppendText((T 'logRepeat') + "`r`n") }
        if ($script:repeatCount -ge 3) { return }
    } else {
        $script:lastLine = $text
        $script:repeatCount = 0
    }
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = $color
    $log.AppendText("$text`r`n")
    $log.ScrollToCaret()
}

function LogInfo([string]$t) { Log $t ([System.Drawing.Color]::FromArgb(25, 30, 38)) }
function LogOk([string]$t)   { Log $t ([System.Drawing.Color]::FromArgb(0, 110, 30)) }
function LogErr([string]$t)  { Log $t ([System.Drawing.Color]::FromArgb(180, 0, 0)) }
function LogHead([string]$t) { Log $t ([System.Drawing.Color]::FromArgb(10, 60, 140)) }

function Line-Color([string]$line) {
    if ($line -match 'Error:')  { return [System.Drawing.Color]::FromArgb(180, 0, 0) }
    if ($line -match '^Warn')   { return [System.Drawing.Color]::FromArgb(170, 95, 0) }
    if ($line -match '^Info')   { return [System.Drawing.Color]::FromArgb(85, 95, 105) }
    return [System.Drawing.Color]::FromArgb(25, 30, 38)
}

# Разбирает вывод OpenOCD и заполняет панель информации о цели.
function Parse-Target([string]$line) {
    if ($line -match 'Cortex-(M\d\+?)\s*(r\dp\d)?') { $lblCpu.Text  = "Cortex-$($Matches[1]) $($Matches[2])".Trim() }
    if ($line -match 'device id = (0x[0-9a-fA-F]+)') { $lblId.Text   = $Matches[1] }
    if ($line -match 'Target voltage: ([\d\.]+)')    { $lblVolt.Text = '{0:N2} V' -f [double]$Matches[1] }
    if ($line -match 'flash size = (\d+)\s*KiB') {
        $kb = [int]$Matches[1]
        $lblFlash.Text = "$kb KB"
        $txtSize.Text = '0x{0:X}' -f ($kb * 1024)
    }
}

# Признаки того, что программатор больше не разговаривает с целью. Поодиночке такая
# строка бывает и при живой связи, поэтому решение принимается по серии подряд.
$script:lostPattern = 'Fail reading CTRL/STAT|Polling failed|Examination failed|Force reconnect|open failed'

function Pump-Log([switch]$Final) {
    if ($script:closing) { return }
    foreach ($key in @('out', 'err')) {
        $f = if ($key -eq 'out') { $script:fOut } else { $script:fErr }
        if (-not (Test-Path $f)) { continue }
        try {
            $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
            $fs.Position = $script:pos[$key]
            $sr = New-Object IO.StreamReader($fs)
            $chunk = $sr.ReadToEnd()
            $script:pos[$key] = $fs.Position
            $sr.Close(); $fs.Close()
        } catch { continue }
        if ($chunk -eq '' -and -not ($Final -and $script:tail[$key] -ne '')) { continue }

        $lines = @(($script:tail[$key] + $chunk) -split "`r?`n")
        if ($Final) {
            $script:tail[$key] = ''
        } else {
            # последнюю строку придерживаем: перевода строки ещё не было, она дописывается
            $script:tail[$key] = $lines[-1]
            $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() }
        }
        foreach ($line in $lines) {
            if ($line -ne '') {
                Log $line (Line-Color $line)
                Parse-Target $line
                [void]$script:pumped.AppendLine($line)
                if ($line -match $script:lostPattern) { $script:lostCount++ } else { $script:lostCount = 0 }
            }
        }
    }
    # Три подряд — связи нет. Держать сессию дальше незачем: она только копит ошибки,
    # а пользователю нужно воткнуть донгл обратно и подключиться заново.
    if ($script:lostCount -ge 3 -and (Ocd-Connected)) {
        $script:lostCount = 0
        LogErr ((T 'logProbeLost') + "`r`n")
        Stop-Session
    }
}

function Set-Busy([bool]$busy, [string]$status) {
    $script:busy = $busy
    $lblStatus.Text = $status
    $progress.Style = if ($busy) { 'Marquee' } else { 'Blocks' }
    if (-not $busy) { $progress.Value = 0 }
    $form.Cursor = if ($busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    [System.Windows.Forms.Application]::DoEvents()
}

# --- сессия OpenOCD ---

function Ocd-Connected { return ($script:tcp -and $script:tcp.Connected) }

function Require-Connection {
    if (Ocd-Connected) { return $true }
    LogErr (T 'logNoConn')
    return $false
}

function Ocd-Send([string]$cmd, [int]$timeoutSec = 300, [switch]$Quiet) {
    if (-not (Ocd-Connected)) { LogErr (T 'logNoConn'); return $null }
    $ns = $script:tcp.GetStream()
    # OpenOCD шлёт в telnet и асинхронные сообщения (external reset detected и т.п.).
    # Если не выбрать их до отправки, они попадают в ответ вместе с лишними промптами,
    # и результаты команд съезжают на команду вперёд. В лог они всё равно приходят
    # вторым путём — из файла лога OpenOCD.
    while ($ns.DataAvailable) { $drain = New-Object byte[] 4096; [void]$ns.Read($drain, 0, $drain.Length) }
    $bytes = [Text.Encoding]::ASCII.GetBytes("$cmd`n")
    $ns.Write($bytes, 0, $bytes.Length); $ns.Flush()

    $sb = New-Object Text.StringBuilder
    $buf = New-Object byte[] 8192
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        # Закрываемся — не досиживаем таймаут: сессию всё равно гасят.
        if ($script:closing) { return $null }
        if ($ns.DataAvailable) {
            $n = $ns.Read($buf, 0, $buf.Length)
            [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf, 0, $n))
            if ($sb.ToString() -match '>\s$') { break }
        } else {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }
    }
    $text = $sb.ToString() -replace '>\s*$', ''
    # Возврат каретки телнет ставит и в середине потока: без его вычистки эхо
    # команды остаётся в логе строкой вида «> reset halt».
    $lines = @($text -split "`r?`n" | ForEach-Object { ($_ -replace "`r", '') -replace '^>\s*', '' } | Where-Object { $_ -ne '' -and $_ -ne $cmd })
    foreach ($l in $lines) {
        if (-not $Quiet) { Log $l (Line-Color $l) }
        Parse-Target $l
    }
    return ($lines -join "`n")
}

# $expect — обязательный признак успеха (wrote N bytes, verified N bytes и т.п.).
# Без него операция считается успешной по отсутствию ошибок, а этого мало: запись
# падала с «Error: couldn't open ...», ошибка уходила в лог OpenOCD мимо ответа
# telnet, и результат рапортовался как успешный.
# Число байт в признаке — строго ненулевое: «wrote 0 bytes» означает, что банк для
# адреса не нашёлся и записывать было некуда.
function Ocd-Run([string]$cmd, [string]$title, [int]$timeoutSec = 300, [string]$expect = '') {
    LogHead "=== $title ==="
    Set-Busy $true $title
    [void]$script:pumped.Clear()
    try {
        $out = Ocd-Send $cmd $timeoutSec
        Pump-Log
    } finally { Set-Busy $false (T 'stReady') }
    if ($null -eq $out) { return $false }

    # Известный шум, который ошибкой не является:
    # «checksum mismatch» — следом идёт побайтовое сравнение и штатное «verified»;
    # «STM32 flash size failed» — норма для GD32, и в ответ telnet она приходит
    # голой, без префикса Warn, поэтому фильтром по уровню её не отсечь.
    $noise = 'checksum mismatch - attempting binary compare|STM32 flash size failed'
    $logged = (($script:pumped.ToString() -split "`r?`n") | Where-Object { $_ -notmatch $noise }) -join "`n"
    # Info/Warn ошибками не считаем: «Warn : STM32 flash size failed» — норма для GD32.
    $answer = (($out -split "`r?`n") | Where-Object { $_ -notmatch $noise -and $_ -notmatch '(?i)^\s*(info|warn|debug)\s*:' }) -join "`n"
    # В логе OpenOCD ошибка — строго строка «Error: ...».
    $ok = ($answer -notmatch '(?im)^\s*(error\b|.*\bfailed\b|.*timed out)') -and ($logged -notmatch '(?m)^\s*Error:')
    # «no flash bank found for address ...» приходит уровнем Warn и фильтром выше не
    # ловится, а означает, что писать было некуда: адрес вне карты Flash. После него
    # любая операция бессмысленна, каким бы ни был ответ команды.
    if ($ok -and (($out + "`n" + $logged) -match 'no flash bank found')) { $ok = $false; LogErr (T 'logNoBank') }
    if ($ok -and $expect -ne '') {
        $ok = (($out + "`n" + $logged) -match $expect)
        if (-not $ok) { LogErr ((T 'logNoProof') -f $title) }
    }
    if ($ok) { LogOk ((T 'logOk') + "`r`n") } else { LogErr ((T 'logFail') + "`r`n") }
    return $ok
}

# Разовый запуск OpenOCD с заданным конфигом цели — для перебора при автоопределении.
function Invoke-OpenOcdOnce([string]$targetCfg, [string[]]$cmds, [int]$waitSec = 15) {
    try { $ocd = Get-OpenOcd } catch { LogErr $_.Exception.Message; return '' }
    $out = Join-Path $Work 'probe.out'
    $err = Join-Path $Work 'probe.err'
    Remove-Item $out, $err -ErrorAction SilentlyContinue

    # Пробный запуск не должен занимать порты рабочей сессии: иначе следующее
    # «Подключиться» не получит 4444 и молча отваливается по таймауту.
    $argList = @(
        '-s', "`"$($ocd.Scripts)`"",
        '-f', "interface/$($cmbIface.Text).cfg",
        '-f', "target/$targetCfg.cfg",
        '-c', "`"adapter speed $($cmbSpeed.Text)`"",
        '-c', '"gdb port disabled"',
        '-c', '"tcl port disabled"',
        '-c', '"telnet port disabled"'
    )
    foreach ($c in $cmds) { $argList += @('-c', "`"$c`"") }

    try {
        $p = Start-Process -FilePath $ocd.Exe -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
    } catch { return '' }

    $deadline = (Get-Date).AddSeconds($waitSec)
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    # ждём фактического выхода: пока процесс жив, он держит ST-Link, и следующий
    # запуск получит «open failed»
    try { [void]$p.WaitForExit(3000) } catch { }

    $text = ''
    foreach ($f in @($out, $err)) {
        if (Test-Path $f) { $text += (Get-Content $f -Raw -ErrorAction SilentlyContinue) }
    }
    return $text
}

# --- обновление из репозитория ---
# Программа раздаётся копированием папки, без git, поэтому обновляется сама: смотрит
# версию в публичном репозитории и по кнопке подтягивает архив ветки main.
$RepoRaw = 'https://raw.githubusercontent.com/MaxSmych/gd32-flasher/main/app/VERSION'
$RepoZip = 'https://github.com/MaxSmych/gd32-flasher/archive/refs/heads/main.zip'

# Тихо: нет сети, закрыт GitHub, корпоративный прокси — молча возвращаем $null.
# Утилита должна запускаться одинаково быстро и в цеху без интернета.
function Get-LatestVersion {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -Uri $RepoRaw -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        $v = ([string]$r.Content).Trim()
        if ($v -match '^\d+\.\d+\.\d+$') { return $v }
    } catch { }
    return $null
}

function Test-UpdateAvailable {
    $latest = Get-LatestVersion
    if (-not $latest) { return $null }
    try { if ([version]$latest -gt [version]$AppVersion) { return $latest } } catch { }
    return $null
}

# Скачиваем архив целиком и кладём поверх папки программы. Пофайловая синхронизация
# тут не нужна: 8 МБ проще и не оставляет полуобновлённого состояния.
function Install-Update([string]$version, [string]$dest) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gd32f_" + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'main.zip'
        LogInfo (T 'updDownload')
        Set-Busy $true (T 'updDownload')
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $RepoZip -OutFile $zip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        Expand-Archive -Path $zip -DestinationPath $tmp -Force

        # Внутри архива — папка вида gd32-flasher-main, внутри неё app. Проверяем, что она на месте
        # и не пуста, ПРЕЖДЕ чем трогать рабочие файлы.
        $src = Get-ChildItem -Path $tmp -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'app\GD32Flasher.ps1') } | Select-Object -First 1
        if (-not $src) { LogErr (T 'updBadZip'); return $false }
        $appSrc = Join-Path $src.FullName 'app'
        if ((Get-Item (Join-Path $appSrc 'GD32Flasher.ps1')).Length -lt 1000) { LogErr (T 'updBadZip'); return $false }

        LogInfo (T 'updApply')
        Set-Busy $true (T 'updApply')
        Copy-Item -Path (Join-Path $appSrc '*') -Destination $dest -Recurse -Force -ErrorAction Stop
        LogOk (((T 'updOk') -f $version) + "`r`n")
        return $true
    } catch {
        LogErr (((T 'updFail') -f $_.Exception.Message) + "`r`n")
        return $false
    } finally {
        Set-Busy $false (T 'stReady')
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Младшие 12 бит DEVICE ID — это семейство контроллера Flash, то есть ровно то, что
# выбирает драйвер. GD32 отдают коды своих прототипов STM32: GD32E103 и GD32F330 оба
# дают 0x410, medium-density F1. Замер 11.09.2026 на GD32E103CBT6: конфиги stm32f1x,
# stm32f0x и stm32f3x ОДИНАКОВО отвечали «flash size = 128 KiB», поэтому перебор
# выбирал первого согласившегося — то есть случайного из трёх. Device ID у всех трёх
# был один и тот же и указывал на stm32f1x.
$script:IdTable = @{
    0x410 = @{ Name = 'STM32F1 / GD32 medium-density'; Cfg = 'stm32f1x' }
    0x412 = @{ Name = 'STM32F1 low-density';           Cfg = 'stm32f1x' }
    0x414 = @{ Name = 'STM32F1 high-density';          Cfg = 'stm32f1x' }
    0x418 = @{ Name = 'STM32F1 connectivity line';     Cfg = 'stm32f1x' }
    0x420 = @{ Name = 'STM32F1 value line';            Cfg = 'stm32f1x' }
    0x428 = @{ Name = 'STM32F1 high-density value';    Cfg = 'stm32f1x' }
    0x430 = @{ Name = 'STM32F1 XL-density';            Cfg = 'stm32f1x' }
    0x440 = @{ Name = 'STM32F0';                       Cfg = 'stm32f0x' }
    0x442 = @{ Name = 'STM32F09x';                     Cfg = 'stm32f0x' }
    0x444 = @{ Name = 'STM32F03x';                     Cfg = 'stm32f0x' }
    0x445 = @{ Name = 'STM32F04x';                     Cfg = 'stm32f0x' }
    0x448 = @{ Name = 'STM32F07x';                     Cfg = 'stm32f0x' }
    0x422 = @{ Name = 'STM32F303/F358';                Cfg = 'stm32f3x' }
    0x432 = @{ Name = 'STM32F37x';                     Cfg = 'stm32f3x' }
    0x438 = @{ Name = 'STM32F334';                     Cfg = 'stm32f3x' }
    0x439 = @{ Name = 'STM32F301/F302';                Cfg = 'stm32f3x' }
    0x446 = @{ Name = 'STM32F303xE';                   Cfg = 'stm32f3x' }
}

# Нулевой VID:PID — донгл слетел: Windows его показывает, а дескриптор читается мусором.
# Лечится только физическим переподключением, никакие провода и питание тут ни при чём.
function Test-ProbeAlive([string]$txt) {
    if ($txt -match 'VID:PID 0000:0000' -or $txt -match 'API v0\)') { LogErr ((T 'logProbeDead') + "`r`n"); return $false }
    return $true
}

# Device ID из вывода OpenOCD → конфиг по таблице семейств. Возвращает $null, если id
# в выводе нет или семейство незнакомое.
function Get-CfgByDeviceId([string]$txt) {
    if ($txt -notmatch 'device id = (0x[0-9a-fA-F]+)') { return $null }
    $id = [Convert]::ToUInt32($Matches[1], 16)
    $fam = $id -band 0xFFF
    $hit = $script:IdTable[[int]$fam]
    if ($hit) {
        LogOk ((T 'logDetectId') -f ('0x{0:X8}' -f $id), ('0x{0:X3}' -f $fam), $hit.Name, $hit.Cfg)
        return $hit.Cfg
    }
    LogInfo ((T 'logDetectIdNo') -f ('0x{0:X8}' -f $id), ('0x{0:X3}' -f $fam))
    return $null
}

# Короткая выжимка из вывода кандидата: что ответил OpenOCD и почему это не подошло.
function Show-CandidateResult([string]$name, [string]$txt) {
    $id = if ($txt -match 'device id = (0x[0-9a-fA-F]+)') { $Matches[1] } else { '--' }
    $sz = if ($txt -match 'flash size = (\d+)\s*KiB') { "$($Matches[1]) KB" } else { '--' }
    $er = ($txt -split "`r?`n" | Where-Object { $_ -match '^\s*Error' } | Select-Object -First 1)
    LogInfo ((T 'logDetectWhy') -f $name, $id, $sz, $er)
}

# Подбирает конфигурацию цели: сначала по DEVICE ID (один запуск, однозначный ответ),
# и только если чип неизвестен — перебором, как раньше, но с причиной по каждому кандидату.
function Find-Target {
    LogHead (T 'logDetect')
    Set-Busy $true (T 'stDetect')
    $found = $null
    $cpuSeen = $null
    try {
        # Шаг 1: DEVICE ID. Читаем его через flash probe: mdw в разовом запуске молчит,
        # его вывод идёт через command_print и до stdout не доходит.
        # Первый за сеанс запуск OpenOCD часто возвращает пустоту — холодный старт exe
        # сразу после распаковки. Пустой вывод это не ответ, а несостоявшаяся попытка:
        # повторяем, иначе определение срывается именно на первом нажатии.
        $txt = Invoke-OpenOcdOnce 'stm32f1x' @('init; flash probe 0; shutdown')
        if ($txt.Trim() -eq '') {
            LogInfo (T 'logDetectRetry')
            $txt = Invoke-OpenOcdOnce 'stm32f1x' @('init; flash probe 0; shutdown')
        }
        if (-not (Test-ProbeAlive $txt)) { return }
        if ($txt -match 'Cortex-(M\d\+?)') { $cpuSeen = "Cortex-$($Matches[1])" }
        $found = Get-CfgByDeviceId $txt

        # Шаг 2: id не прочитался или семейство незнакомое — перебор. Но Device ID
        # главнее имени согласившегося конфига: 11.09.2026 первый запуск вернул пустоту,
        # перебор дошёл до stm32f0x, тот отдал 0x17120410 — и программа выбрала stm32f0x,
        # хотя id в этой же строке означал stm32f1x.
        if (-not $found) {
            LogInfo (T 'logDetectGo')
            foreach ($t in @('stm32f1x', 'stm32f0x', 'stm32f3x', 'stm32f2x', 'stm32f4x', 'stm32g0x', 'stm32l4x', 'stm32h7x')) {
                $txt = Invoke-OpenOcdOnce $t @('init; flash probe 0; shutdown')
                Show-CandidateResult $t $txt
                if ($txt -match 'Cortex-(M\d\+?)') { $cpuSeen = "Cortex-$($Matches[1])" }
                $found = Get-CfgByDeviceId $txt
                if ($found) { break }
                if ($txt -match 'flash size = (\d+)\s*KiB' -and $txt -notmatch 'probe failed') {
                    $found = $t
                    LogOk ((T 'logDetectHit') -f $t, $cpuSeen, $Matches[1])
                    break
                }
            }
        }
    } finally { Set-Busy $false (T 'stReady') }

    if ($found) {
        $cmbTarget.Text = $found
        LogOk (((T 'logDetectSet') -f $found) + "`r`n")
    } elseif ($cpuSeen) {
        LogErr (((T 'logDetectCpu') -f $cpuSeen) + "`r`n")
    } else {
        LogErr ((T 'logDetectNo') + "`r`n")
    }
}

function Ocd-Connect {
    if (Ocd-Connected) { return $true }
    try { $ocd = Get-OpenOcd } catch { LogErr $_.Exception.Message; return $false }

    Remove-Item $script:fOut, $script:fErr -ErrorAction SilentlyContinue
    $script:pos = @{ out = 0; err = 0 }
    $script:tail = @{ out = ''; err = '' }

    $argList = @(
        '-s', "`"$($ocd.Scripts)`"",
        '-f', "interface/$($cmbIface.Text).cfg",
        '-f', "target/$($cmbTarget.Text).cfg",
        '-c', "`"adapter speed $($cmbSpeed.Text)`""
    )
    if ($cmbReset.SelectedIndex -eq 1) { $argList += @('-c', '"reset_config srst_only srst_nogate"') }

    LogHead ((T 'ttlConn') -f $cmbIface.Text, $cmbTarget.Text, $cmbSpeed.Text)
    Set-Busy $true (T 'stConnect')
    try {
        $script:proc = Start-Process -FilePath $ocd.Exe -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardOutput $script:fOut -RedirectStandardError $script:fErr

        # ждём реальной готовности порта 4444, а не фиксированной паузы
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            Pump-Log
            if ($script:proc.HasExited) { break }
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $c.Connect('127.0.0.1', 4444)
                $script:tcp = $c
                break
            } catch { }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
        }
    } finally { Set-Busy $false (T 'stReady') }

    Pump-Log -Final
    if (Ocd-Connected) {
        Start-Sleep -Milliseconds 200
        $ns = $script:tcp.GetStream()
        while ($ns.DataAvailable) { $b = New-Object byte[] 4096; [void]$ns.Read($b, 0, $b.Length) }  # приветствие
        Set-Connected $true
        Ocd-Send 'reset halt' 30 | Out-Null
        Show-FlashInfo
        LogOk ((T 'logConnOk') + "`r`n")
        return $true
    }
    # Раньше провал подключения выглядел как пустой лог: OpenOCD успевал написать
    # причину, но её никто не показывал.
    if ($script:proc -and $script:proc.HasExited) { LogErr ((T 'logOcdExit') -f $script:proc.ExitCode) }
    LogErr ((T 'logConnFail') + "`r`n")
    Ocd-Disconnect
    return $false
}

# Завершение сессии с жёстким бюджетом времени. Раньше закрытие окна ждало ответа на
# «shutdown» до 5 секунд, крутя DoEvents, и ещё 3 секунды выхода процесса — а при
# выдернутом донгле OpenOCD в это время висит в USB-вызове и сыплет ошибки в лог.
# Замер 11.09.2026 на живой сессии: по «shutdown» из telnet процесс НЕ завершается
# вовсе — ни за 800 мс, ни за 10 секунд, и закрытие сокета его тоже не трогает.
# Выход всегда делает Kill, поэтому ждать и нечего: команду отправляем (вдруг сборка
# другая), даём 200 мс на удачу и убиваем.
# $Quiet — закрытие программы: лог и панель уже не нужны.
function Stop-Session([switch]$Quiet) {
    if ($Quiet) { $script:closing = $true }
    if ($script:timer) { $script:timer.Stop() }

    if ($script:tcp) {
        try {
            if ($script:tcp.Connected) {
                $ns = $script:tcp.GetStream()
                $bytes = [Text.Encoding]::ASCII.GetBytes("shutdown`n")
                $ns.Write($bytes, 0, $bytes.Length); $ns.Flush()
            }
        } catch { }
        try { $script:tcp.Close() } catch { }
    }
    $script:tcp = $null

    if ($script:proc) {
        try {
            if (-not $script:proc.WaitForExit(200)) {
                try { $script:proc.Kill() } catch { }
                [void]$script:proc.WaitForExit(1500)
            }
        } catch { }
    }
    $script:proc = $null
    $script:lostCount = 0

    if (-not $Quiet) {
        Pump-Log -Final
        Set-Connected $false
        if ($script:timer) { $script:timer.Start() }
    }
}

function Ocd-Disconnect { Stop-Session }

function Set-Connected([bool]$on) {
    $lblConn.Text = if ($on) { T 'connected' } else { T 'disconnected' }
    $lblConn.ForeColor = if ($on) { [System.Drawing.Color]::FromArgb(120, 220, 120) } else { [System.Drawing.Color]::FromArgb(220, 130, 130) }
    $btnConnect.Text = if ($on) { T 'btnDisconn' } else { T 'btnConnect' }
    $btnConnect.BackColor = if ($on) { $clrRed } else { $clrGreen }
    foreach ($b in $opButtons) { $b.Enabled = $on }
    $cmbIface.Enabled = -not $on; $cmbTarget.Enabled = -not $on
    $cmbSpeed.Enabled = -not $on; $cmbReset.Enabled = -not $on
    $btnDetect.Enabled = -not $on
    if (-not $on) { $lblCpu.Text = '--'; $lblId.Text = '--'; $lblFlash.Text = '--'; $lblVolt.Text = '--' }
}

# Путь к прошивке переживает перезапуск: файлы лежат в одном и том же месте на сервере,
# и набирать путь заново каждый раз незачем.
function Set-FwPath([string]$path) {
    $txtFile.Text = $path
    LogInfo ((T 'logSelected') -f $path, (Get-Item -LiteralPath $path).Length)
    try { Set-Content -LiteralPath $LastFile -Value $path -Encoding UTF8 -ErrorAction Stop } catch { }
}

function Get-Fw {
    # -PathType Leaf: у папки Test-Path тоже истинен, и её копия делала из fw.bin
    # каталог — OpenOCD отвечал «couldn't open», а операция считалась успешной.
    if (-not (Test-Path -LiteralPath $txtFile.Text -PathType Leaf)) { LogErr (T 'logNoFile'); return $null }
    # копия в латинский путь без пробелов — снимает проблемы с кириллицей и длинными именами.
    # Расширение сохраняем: по нему видно формат образа, и OpenOCD не приходится гадать.
    $ext = [IO.Path]::GetExtension($txtFile.Text).ToLower()
    if ($ext -notmatch '^\.[a-z0-9]+$') { $ext = '.bin' }
    $dst = Join-Path $Work "fw$ext"
    try {
        Copy-Item -LiteralPath $txtFile.Text -Destination $dst -Force -ErrorAction Stop
    } catch {
        LogErr ((T 'logCopyFail') -f $_.Exception.Message)
        return $null
    }
    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) { LogErr ((T 'logCopyFail') -f $dst); return $null }
    LogInfo ((T 'logFwReady') -f $txtFile.Text, $dst, (Get-Item -LiteralPath $dst).Length)
    return $dst
}

# Отдельной функцией, чтобы ветку с защитой можно было проверить на стенде: статический
# MessageBox там подменить нечем, и тест открывал бы настоящее окно.
function Confirm-YesNo([string]$text) {
    return ([System.Windows.Forms.MessageBox]::Show($text, (T 'msgConfirm'), 'YesNo', 'Warning') -eq 'Yes')
}

# «flash info 0» печатает строку на каждый сектор — 32 строки одинакового «not
# protected» вместо ответа на вопрос, есть защита или нет. Показываем итог одной
# строкой, а перечисляем только то, что действительно защищено, и предлагаем снять.
# Снимается это через «flash protect ... off» и чип НЕ стирает — в отличие от
# «unlock», который снимает защиту чтения ценой mass erase.
function Show-FlashInfo {
    LogHead ('=== ' + (T 'ttlFlashInfo') + ' ===')
    $out = Ocd-Send 'flash info 0' 30 -Quiet
    if ($null -eq $out) { return }

    $bank = $null
    $sectors = @()
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '#\d+\s*:\s*(\S+)\s+at\s+(0x[0-9a-fA-F]+),\s*size\s+(0x[0-9a-fA-F]+)') {
            $bank = [pscustomobject]@{ Driver = $Matches[1]; Base = [uint32]$Matches[2]; Size = [uint32]$Matches[3] }
        } elseif ($line -match '^\s*#\s*(\d+):\s*(0x[0-9a-fA-F]+)\s*\((0x[0-9a-fA-F]+)[^)]*\)\s*(not\s+)?protected') {
            $sectors += [pscustomobject]@{ Num = [int]$Matches[1]; Offset = [uint32]$Matches[2]; Size = [uint32]$Matches[3]; Protected = ($Matches[4] -eq $null -or $Matches[4] -eq '') }
        }
    }
    # Не разобрали — показываем как есть, молчать хуже, чем показать лишнее.
    if (-not $bank -or $sectors.Count -eq 0) {
        foreach ($line in ($out -split "`r?`n")) { if ($line -ne '') { Log $line (Line-Color $line) } }
        return
    }

    $kb = [int]($bank.Size / 1024)
    $secKb = [int]($sectors[0].Size / 1024)
    $locked = @($sectors | Where-Object { $_.Protected })
    if ($locked.Count -eq 0) {
        LogOk ((T 'fiSummary') -f $bank.Driver, ('0x{0:X8}' -f $bank.Base), $kb, $sectors.Count, $secKb)
        return
    }

    LogInfo ((T 'fiSummaryP') -f $bank.Driver, ('0x{0:X8}' -f $bank.Base), $kb, $sectors.Count, $secKb)
    # Соседние секторы сводим в диапазоны: «0-3, 7» читается, а список из 32 номеров нет.
    $ranges = @()
    $from = $locked[0].Num; $prev = $from
    foreach ($s in $locked[1..($locked.Count - 1)]) {
        if ($s.Num -ne $prev + 1) { $ranges += ,@($from, $prev); $from = $s.Num }
        $prev = $s.Num
    }
    $ranges += ,@($from, $prev)

    $names = @(); $addrs = @()
    foreach ($r in $ranges) {
        $names += if ($r[0] -eq $r[1]) { "$($r[0])" } else { "$($r[0])-$($r[1])" }
        $a = $locked | Where-Object { $_.Num -eq $r[0] } | Select-Object -First 1
        $b = $locked | Where-Object { $_.Num -eq $r[1] } | Select-Object -First 1
        $addrs += '0x{0:X8}-0x{1:X8}' -f ($bank.Base + $a.Offset), ($bank.Base + $b.Offset + $b.Size - 1)
    }
    $names = $names -join ', '
    LogErr ((T 'fiProtected') -f $names, ($addrs -join ', '))

    if (-not (Confirm-YesNo ((T 'msgUnprotect') -f $names))) { return }
    $done = $true
    foreach ($r in $ranges) {
        if (-not (Ocd-Run "flash protect 0 $($r[0]) $($r[1]) off" (T 'ttlUnprotect') 60)) { $done = $false }
    }
    if ($done) { LogOk ((T 'fiUnprotOk') + "`r`n") }
}

# Аргумент offset у flash write_image и verify_image — не «куда писать», а смещение,
# которое ПРИБАВЛЯЕТСЯ к адресам из образа. У .bin адресов внутри нет, там offset и есть
# адрес записи. А у .hex, .elf и .s19 они свои: 10.09.2026 к 0x08000000 из hex-файла
# прибавилось 0x08000000 из поля «Адрес», запись ушла на 0x10000000, где банка нет,
# и OpenOCD написал «wrote 0 bytes». Для таких образов offset не передаём вовсе.
function Get-ImageOffset([string]$path) {
    if ([IO.Path]::GetExtension($path).ToLower() -eq '.bin') { return " $($txtAddr.Text)" }
    LogInfo ((T 'logAddrFromImage') -f [IO.Path]::GetExtension($path).TrimStart('.').ToUpper())
    return ''
}

# Стёртая Flash читается как сплошные 0xFF; так же читается и адрес, за которым
# памяти нет вовсе. И то и другое означает, что сохранять было нечего.
function Test-DumpHasData([string]$path) {
    try { $bytes = [IO.File]::ReadAllBytes($path) } catch { return $false }
    if ($bytes.Length -eq 0) { return $false }
    foreach ($b in $bytes) { if ($b -ne 0xFF) { return $true } }
    return $false
}

function Invoke-Backup {
    $name = 'backup_{0:yyyyMMdd_HHmmss}.bin' -f (Get-Date)
    $dst = Join-Path $Work $name
    $ok = Ocd-Run "dump_image $(ConvertTo-TclPath $dst) $($txtAddr.Text) $($txtSize.Text)" ((T 'ttlBackup') -f $name) 300 'dumped\s+[1-9]\d*\s+bytes'
    # бэкап без файла на диске — не бэкап, дальше идти нельзя
    if ($ok -and -not (Test-Path -LiteralPath $dst -PathType Leaf)) { $ok = $false; LogErr ((T 'logNoProof') -f $name) }
    # ...и файл из одних 0xFF — тоже не бэкап. 10.09.2026 адрес был задан 0x10000000,
    # где банка нет: dump_image отдал полновесные 131072 байта пустоты, «успешно», и
    # следом пошло снятие защиты уже без всякой резервной копии.
    if ($ok -and -not (Test-DumpHasData $dst)) { $ok = $false; LogErr ((T 'logBackupFF') -f $txtAddr.Text) }
    if ($ok) { LogOk ((T 'logDumpSave') -f $dst) }
    return $ok
}

# --- интерфейс ---

$form = New-Object System.Windows.Forms.Form
$form.Text = "GD32Flasher $AppVersion"
$form.Size = New-Object System.Drawing.Size(1040, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 640)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $clrBack
$form.ForeColor = $clrText
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.FormBorderStyle = 'Sizable'
$form.Padding = New-Object System.Windows.Forms.Padding(0)

function New-Btn($text, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size(120, 32)
    $b.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 128, 190)
    $b.BackColor = $color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    return $b
}
function New-Cap($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
     $l.ForeColor = $clrSideDim
    return $l
}
function New-Val($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
     $l.ForeColor = $clrSideText
    return $l
}
# Немодально: окно держат открытым, пока цепляют провода.
function Show-Pinout {
    if ($script:pinoutForm -and -not $script:pinoutForm.IsDisposed) { $script:pinoutForm.Activate(); return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = T 'ttlPinout'
    $f.StartPosition = 'CenterParent'
    $f.BackColor = $clrPanel
    $f.Padding = New-Object System.Windows.Forms.Padding(10)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'
    $tabs.Padding = New-Object System.Drawing.Point(10, 4)
    $mono = New-Object System.Drawing.Font('Consolas', 9)

    $width = 0; $height = 0
    foreach ($part in @(@('tabWires', 'pinoutWires'), @('tabPkg', 'pinoutPkg'), @('tabHdr', 'pinoutHdr'), @('tabHelp', 'pinoutHelp'))) {
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = T $part[0]
        $page.BackColor = $clrLogBg
        $page.Padding = New-Object System.Windows.Forms.Padding(4)
        $box = New-Object System.Windows.Forms.RichTextBox
        $box.Dock = 'Fill'
        $box.Font = $mono
        $box.ReadOnly = $true
        $box.BorderStyle = 'None'
        $box.BackColor = $clrLogBg
        $box.ForeColor = $clrText
        # Перенос строк ломает таблицы и схемы: при другом масштабе экрана строка
        # не влезает и разъезжается. Ширину окна считаем по тексту, чтобы этого
        # не случилось.
        $box.WordWrap = $false
        $box.Text = T $part[1]
        $box.Select(0, 0)
        $page.Controls.Add($box)
        [void]$tabs.TabPages.Add($page)

        $lines = ($box.Text -split "`r?`n")
        foreach ($line in $lines) {
            $w = [System.Windows.Forms.TextRenderer]::MeasureText($line, $mono).Width
            if ($w -gt $width) { $width = $w }
        }
        $h = $lines.Count * [System.Windows.Forms.TextRenderer]::MeasureText('0', $mono).Height
        if ($h -gt $height) { $height = $h }
    }
    $f.Controls.Add($tabs)

    $screen = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $f.ClientSize = New-Object System.Drawing.Size(
        [Math]::Min($width + 60, $screen.Width - 80),
        [Math]::Min($height + 80, $screen.Height - 90))
    $script:pinoutForm = $f
    $f.Show($form)
}

function New-Combo($x, $y, $w) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 24)
    $c.FlatStyle = 'Flat'
    return $c
}

# шапка
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 58; $header.BackColor = $clrHeader
$header.Padding = New-Object System.Windows.Forms.Padding(0)
$header.BorderStyle = 'FixedSingle'
$title = New-Object System.Windows.Forms.Label
$title.Text = "GD32Flasher $AppVersion"
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$title.ForeColor = [System.Drawing.Color]::White; $title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(16, 14)
$subtitle = New-Object System.Windows.Forms.Label
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(160, 182, 200); $subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(152, 21)

# правая часть шапки — потоком справа налево, чтобы не считать координаты вручную
$hdrRight = New-Object System.Windows.Forms.FlowLayoutPanel
$hdrRight.Dock = 'Right'
$hdrRight.FlowDirection = 'RightToLeft'
$hdrRight.WrapContents = $false
$hdrRight.Width = 440
$hdrRight.Padding = New-Object System.Windows.Forms.Padding(0, 16, 16, 0)
$hdrRight.BackColor = $clrHeader
$hdrRight.BorderStyle = 'None'

$lblConn = New-Object System.Windows.Forms.Label
$lblConn.AutoSize = $true
$lblConn.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)

$cmbLang = New-Object System.Windows.Forms.ComboBox
$cmbLang.Size = New-Object System.Drawing.Size(70, 24)
$cmbLang.FlatStyle = 'Flat'
$cmbLang.DropDownStyle = 'DropDownList'
$cmbLang.Margin = New-Object System.Windows.Forms.Padding(28, 0, 0, 0)
[void]$cmbLang.Items.AddRange(@('RU', 'EN'))
$cmbLang.SelectedItem = 'RU'
$cmbLang.Add_SelectedIndexChanged({ $script:Lang = $cmbLang.SelectedItem; Apply-Language })

$capLang = New-Object System.Windows.Forms.Label
$capLang.AutoSize = $true
$capLang.ForeColor = $clrDim
$capLang.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 0)

$hdrRight.Controls.AddRange(@($lblConn, $cmbLang, $capLang))
$header.Controls.AddRange(@($hdrRight, $title, $subtitle))

# правая панель — подключение и информация о цели
$side = New-Object System.Windows.Forms.Panel
$side.Dock = 'Right'; $side.Width = 306; $side.BackColor = $clrSide
$side.BorderStyle = 'FixedSingle'
$side.Padding = New-Object System.Windows.Forms.Padding(0)

$sideFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$sideFlow.Dock = 'Fill'
$sideFlow.FlowDirection = 'TopDown'
$sideFlow.WrapContents = $false
$sideFlow.AutoScroll = $true
$sideFlow.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 14)
$sideFlow.BackColor = $clrSide
$side.Controls.Add($sideFlow)

function New-SideHeading {
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Width = 270
    $label.Height = 24
    $label.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    $label.ForeColor = $clrAccent
    $label.TextAlign = 'MiddleLeft'
    $label.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
    return $label
}

function New-SideCaption {
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Width = 270
    $label.Height = 18
    $label.ForeColor = $clrSideDim
    $label.TextAlign = 'BottomLeft'
    $label.Margin = New-Object System.Windows.Forms.Padding(0, 3, 0, 1)
    return $label
}

function New-SideCombo {
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Width = 270
    $combo.Height = 28
    $combo.FlatStyle = 'Flat'
    $combo.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $combo.ForeColor = [System.Drawing.Color]::FromArgb(238, 246, 252)
    $combo.BackColor = [System.Drawing.Color]::FromArgb(13, 55, 86)
    $combo.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 5)
    $combo.Add_GotFocus({ $_.Sender.BackColor = [System.Drawing.Color]::FromArgb(18, 75, 113) })
    $combo.Add_LostFocus({ $_.Sender.BackColor = [System.Drawing.Color]::FromArgb(13, 55, 86) })
    return $combo
}

function New-SideInfoRow($caption, $value) {
    $row = New-Object System.Windows.Forms.FlowLayoutPanel
    $row.Width = 270
    $row.Height = 24
    $row.WrapContents = $false
    $row.Margin = New-Object System.Windows.Forms.Padding(0)
    $row.BackColor = $clrSide
    $caption.AutoSize = $false; $caption.Width = 110; $caption.Height = 24
    $caption.ForeColor = $clrSideDim; $caption.TextAlign = 'MiddleLeft'
    $caption.Margin = New-Object System.Windows.Forms.Padding(0)
    $value.AutoSize = $false; $value.Width = 160; $value.Height = 24
    $value.ForeColor = $clrSideText; $value.TextAlign = 'MiddleRight'
    $value.Margin = New-Object System.Windows.Forms.Padding(0)
    $row.Controls.AddRange(@($caption, $value))
    return $row
}

$grpConn = New-SideHeading
$sideFlow.Controls.Add($grpConn)

$capIface = New-SideCaption
$cmbIface = New-SideCombo
$cmbIface.DropDownStyle = 'DropDown'
$cmbIface.AutoCompleteMode = 'SuggestAppend'
$cmbIface.AutoCompleteSource = 'ListItems'
$sideFlow.Controls.AddRange(@($capIface, $cmbIface))

$capTarget = New-SideCaption
$cmbTarget = New-SideCombo
$cmbTarget.DropDownStyle = 'DropDown'
$cmbTarget.AutoCompleteMode = 'SuggestAppend'
$cmbTarget.AutoCompleteSource = 'ListItems'
$sideFlow.Controls.AddRange(@($capTarget, $cmbTarget))

$capSpeed = New-SideCaption
$cmbSpeed = New-SideCombo
$cmbSpeed.DropDownStyle = 'DropDownList'
@('100', '480', '950', '1800', '4000') | ForEach-Object { [void]$cmbSpeed.Items.Add($_) }
$cmbSpeed.SelectedItem = '950'
$sideFlow.Controls.AddRange(@($capSpeed, $cmbSpeed))

$capReset = New-SideCaption
$cmbReset = New-SideCombo
$cmbReset.DropDownStyle = 'DropDownList'
$sideFlow.Controls.AddRange(@($capReset, $cmbReset))

$btnDetect = New-Btn '' $clrBtnAlt
$btnDetect.AutoSize = $false
$btnDetect.Size = New-Object System.Drawing.Size(270, 34)
$btnDetect.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
$btnDetect.Add_Click({ Find-Target })
$sideFlow.Controls.Add($btnDetect)

$btnConnect = New-Btn '' $clrGreen
$btnConnect.AutoSize = $false
$btnConnect.Size = New-Object System.Drawing.Size(270, 38)
$btnConnect.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$btnConnect.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 14)
$btnConnect.Add_Click({ if (Ocd-Connected) { Ocd-Disconnect } else { Ocd-Connect | Out-Null } })
$sideFlow.Controls.Add($btnConnect)

$grpInfo = New-SideHeading
$grpInfo.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 3)
$sideFlow.Controls.Add($grpInfo)

$capCore = New-Object System.Windows.Forms.Label; $lblCpu = New-Object System.Windows.Forms.Label
$capId = New-Object System.Windows.Forms.Label; $lblId = New-Object System.Windows.Forms.Label
$capFlash = New-Object System.Windows.Forms.Label; $lblFlash = New-Object System.Windows.Forms.Label
$capVolt = New-Object System.Windows.Forms.Label; $lblVolt = New-Object System.Windows.Forms.Label
$sideFlow.Controls.AddRange(@(
    (New-SideInfoRow $capCore $lblCpu),
    (New-SideInfoRow $capId $lblId),
    (New-SideInfoRow $capFlash $lblFlash),
    (New-SideInfoRow $capVolt $lblVolt)
))

$hint = New-Object System.Windows.Forms.Label
$hint.ForeColor = $clrSideDim
$hint.AutoSize = $false
$hint.Width = 270
$hint.Height = 112
$hint.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
$sideFlow.Controls.Add($hint)

$btnPinout = New-Btn '' $clrBtnAlt
$btnPinout.AutoSize = $false
$btnPinout.Size = New-Object System.Drawing.Size(270, 32)
$btnPinout.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 8)
$btnPinout.Add_Click({ Show-Pinout })
$sideFlow.Controls.Add($btnPinout)

# центральная часть
$main = New-Object System.Windows.Forms.Panel
$main.Dock = 'Fill'
$main.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 8)
$main.BackColor = $clrBack
$main.BorderStyle = 'None'

# Докирование идёт в обратном порядке добавления: добавленный последним получает
# место первым. Поэтому Fill добавляем раньше всех, а шапку — последней, иначе
# центральная панель уезжает под шапку и под правую панель.
$form.Controls.Add($main)
$form.Controls.Add($side)
$form.Controls.Add($header)

$rowFile = New-Object System.Windows.Forms.TableLayoutPanel
$rowFile.Dock = 'Top'
$rowFile.Height = 50
$rowFile.AutoSize = $false
$rowFile.ColumnCount = 3
$rowFile.RowCount = 1
$rowFile.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 120)))
$rowFile.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$rowFile.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 128)))
$rowFile.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
$rowFile.Padding = New-Object System.Windows.Forms.Padding(8, 7, 8, 7)
$rowFile.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
$rowFile.BackColor = $clrPanel
$rowFile.BorderStyle = 'FixedSingle'

$capFile = New-Object System.Windows.Forms.Label
$capFile.ForeColor = $clrDim
$capFile.AutoSize = $false
$capFile.Dock = 'Fill'
$capFile.TextAlign = 'MiddleLeft'
$capFile.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)

$txtFile = New-Object System.Windows.Forms.TextBox
$txtFile.Dock = 'Fill'
$txtFile.Margin = New-Object System.Windows.Forms.Padding(0, 2, 8, 2)
$txtFile.BackColor = [System.Drawing.Color]::White
$txtFile.BorderStyle = 'FixedSingle'
$txtFile.AllowDrop = $true
$txtFile.Add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$txtFile.Add_DragDrop({
    $files = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files.Count -gt 0) { Set-FwPath $files[0] }
})

$btnBrowse = New-Btn '' $clrBtn
$btnBrowse.AutoSize = $false
$btnBrowse.Dock = 'Fill'
$btnBrowse.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$btnBrowse.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$btnBrowse.FlatAppearance.BorderSize = 0
$btnBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = T 'dlgFw'
    # Открываемся там, где брали прошивку в прошлый раз.
    if ($txtFile.Text -ne '') {
        $dir = Split-Path -LiteralPath $txtFile.Text -Parent
        if ($dir -and (Test-Path -LiteralPath $dir)) { $d.InitialDirectory = $dir }
    }
    if ($d.ShowDialog() -eq 'OK') { Set-FwPath $d.FileName }
})
$rowFile.Controls.Add($capFile, 0, 0)
$rowFile.Controls.Add($txtFile, 1, 0)
$rowFile.Controls.Add($btnBrowse, 2, 0)

$rowAddr = New-Object System.Windows.Forms.FlowLayoutPanel
$rowAddr.Dock = 'Top'
$rowAddr.AutoSize = $true
$rowAddr.AutoSizeMode = 'GrowAndShrink'
$rowAddr.WrapContents = $false
$rowAddr.FlowDirection = 'LeftToRight'
$rowAddr.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$rowAddr.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)

$capAddr = New-Object System.Windows.Forms.Label
$capAddr.ForeColor = $clrDim
$capAddr.AutoSize = $true
$capAddr.Width = 80
$capAddr.Height = 24
$capAddr.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 0)
$capAddr.TextAlign = 'MiddleLeft'

$txtAddr = New-Object System.Windows.Forms.TextBox
$txtAddr.Width = 120
$txtAddr.Height = 32
$txtAddr.Margin = New-Object System.Windows.Forms.Padding(0, 0, 16, 0)
$txtAddr.Text = '0x08000000'

$capSize = New-Object System.Windows.Forms.Label
$capSize.ForeColor = $clrDim
$capSize.AutoSize = $true
$capSize.Width = 94
$capSize.Height = 24
$capSize.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 0)
$capSize.TextAlign = 'MiddleLeft'

$txtSize = New-Object System.Windows.Forms.TextBox
$txtSize.Width = 120
$txtSize.Height = 32
$txtSize.Margin = New-Object System.Windows.Forms.Padding(0, 0, 16, 0)
$txtSize.Text = '0x20000'

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.AutoSize = $true
$chkBackup.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$chkBackup.ForeColor = $clrText
$chkBackup.Checked = $true
$rowAddr.Controls.AddRange(@($capAddr, $txtAddr, $capSize, $txtSize, $chkBackup))

# кнопки: автоподбор высоты, иначе при переносе на второй ряд часть уезжает за край
$rowBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$rowBtns.Dock = 'Left'
$rowBtns.Width = 166
$rowBtns.FlowDirection = 'TopDown'
$rowBtns.WrapContents = $false
$rowBtns.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)
$rowBtns.Margin = New-Object System.Windows.Forms.Padding(0)
$rowBtns.BackColor = $clrPanel
$rowBtns.BorderStyle = 'FixedSingle'

$btnProgram = New-Btn '' $clrBtn
$btnProgram.Add_Click({
    if (-not (Require-Connection)) { return }
    $fw = Get-Fw; if (-not $fw) { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { LogErr (T 'logBackupNo'); return }
    $t = ConvertTo-TclPath $fw
    $off = Get-ImageOffset $fw
    if (Ocd-Run 'reset halt' (T 'ttlHalt') 30) {
        if (Ocd-Run "flash write_image erase $t$off" (T 'ttlWrite') 300 'wrote\s+[1-9]\d*\s+bytes') {
            if (Ocd-Run "verify_image $t$off" (T 'ttlVerify') 300 'verified\s+[1-9]\d*\s+bytes') {
                Ocd-Run 'reset run' (T 'ttlRun') 30 | Out-Null
            }
        }
    }
})

$btnVerify = New-Btn '' $clrBtn
$btnVerify.Add_Click({
    if (-not (Require-Connection)) { return }
    $fw = Get-Fw; if (-not $fw) { return }
    $off = Get-ImageOffset $fw
    Ocd-Run 'reset halt' (T 'ttlHalt') 30 | Out-Null
    Ocd-Run "verify_image $(ConvertTo-TclPath $fw)$off" (T 'ttlVerify') 300 'verified\s+[1-9]\d*\s+bytes' | Out-Null
})

$btnRead = New-Btn '' $clrBtn
$btnRead.Add_Click({
    if (-not (Require-Connection)) { return }
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter = T 'dlgDump'; $d.FileName = 'dump.bin'
    if ($d.ShowDialog() -ne 'OK') { return }
    $tmp = Join-Path $Work 'dump.bin'
    Ocd-Run 'reset halt' (T 'ttlHalt') 30 | Out-Null
    if (Ocd-Run "dump_image $(ConvertTo-TclPath $tmp) $($txtAddr.Text) $($txtSize.Text)" (T 'ttlRead') 300 'dumped\s+[1-9]\d*\s+bytes') {
        Copy-Item -LiteralPath $tmp -Destination $d.FileName -Force
        LogOk ((T 'logDumpSave') -f $d.FileName)
    }
})

$btnErase = New-Btn '' $clrBtn
$btnErase.Add_Click({
    if (-not (Require-Connection)) { return }
    if ([System.Windows.Forms.MessageBox]::Show((T 'msgErase'), (T 'msgConfirm'), 'YesNo', 'Warning') -ne 'Yes') { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { LogErr (T 'logBackupNo'); return }
    Ocd-Run 'reset halt' (T 'ttlHalt') 30 | Out-Null
    if (Ocd-Run 'flash erase_sector 0 0 last' (T 'ttlErase')) {
        Ocd-Run "mdw $($txtAddr.Text) 8" (T 'ttlCheck') 30 | Out-Null
    }
})

$btnInfo = New-Btn '' $clrBtn
$btnInfo.Add_Click({
    if (-not (Require-Connection)) { return }
    Ocd-Run 'reset halt' (T 'ttlHalt') 30 | Out-Null
    Show-FlashInfo
    Ocd-Run "mdw $($txtAddr.Text) 8" (T 'ttlCheck') 30 | Out-Null
})

$btnUnlock = New-Btn '' $clrBtn
$btnUnlock.Add_Click({
    if (-not (Require-Connection)) { return }
    if ([System.Windows.Forms.MessageBox]::Show((T 'msgUnlock'), (T 'msgConfirm'), 'YesNo', 'Warning') -ne 'Yes') { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { LogErr (T 'logBackupNo'); return }
    Ocd-Run 'reset halt' (T 'ttlHalt') 30 | Out-Null
    Ocd-Run "$($cmbTarget.Text) unlock 0" (T 'ttlUnlock') | Out-Null
})

$btnReset = New-Btn '' $clrBtn
$btnReset.Add_Click({ if (Require-Connection) { Ocd-Run 'reset run' (T 'ttlRun') 30 | Out-Null } })

# OpenOCD берёт объём Flash из регистра размера, а клоны его часто не заполняют
# («STM32 flash size failed, probe inaccurate»). Определяем сами: сначала регистр
# по адресам разных семейств, затем — чтением границ.
$btnFlashSz = New-Btn '' $clrBtn
$btnFlashSz.Add_Click({
    if (-not (Require-Connection)) { return }
    LogHead ('=== ' + (T 'ttlFlashSz') + ' ===')
    Set-Busy $true (T 'ttlFlashSz')
    $kb = 0
    try {
        Ocd-Send 'reset halt' 30 | Out-Null
        foreach ($reg in @('0x1FFFF7E0', '0x1FFFF7CC', '0x1FFF7A22', '0x1FFF75E0')) {
            $out = Ocd-Send "mdw $reg 1" 20
            if ($out -match ':\s*([0-9a-fA-F]{8})') {
                $v = [Convert]::ToUInt32($Matches[1], 16) -band 0xFFFF
                if ($v -ge 16 -and $v -le 4096) {
                    $kb = $v
                    LogOk ((T 'fsFromReg') -f $reg, $kb)
                    break
                }
            }
        }
        if ($kb -eq 0) {
            LogInfo (T 'fsProbe')
            $base = [uint32]$txtAddr.Text
            foreach ($try in @(1024, 512, 256, 128, 64, 32, 16)) {
                $addr = '0x{0:X8}' -f ($base + $try * 1024 - 4)
                $out = Ocd-Send "mdw $addr 1" 20
                if ($out -and $out -notmatch '(?i)error|failed|invalid') {
                    $kb = $try
                    LogInfo ((T 'fsProbeHit') -f $try)
                    LogInfo (T 'fsMirror')
                    break
                }
            }
        }
    } finally { Set-Busy $false (T 'stReady') }

    if ($kb -gt 0) {
        $hex = '0x{0:X}' -f ($kb * 1024)
        $txtSize.Text = $hex
        $lblFlash.Text = "$kb KB"
        LogOk (((T 'fsSet') -f $kb, $hex) + "`r`n")
    } else {
        LogErr ((T 'fsFail') + "`r`n")
    }
})

$btnClear = New-Btn '' $clrBtnAlt
$btnClear.Add_Click({ $log.Clear() })

# Кнопка появляется только когда обновление действительно есть: пустую кнопку
# «проверить» в интерфейсе держать незачем, проверка идёт сама при запуске.
$btnUpdate = New-Btn '' $clrGreen
$btnUpdate.Visible = $false
$btnUpdate.Add_Click({
    $btnUpdate.Enabled = $false
    if (Install-Update $script:newVersion $PSScriptRoot) { $btnUpdate.Visible = $false }
    $btnUpdate.Enabled = $true
})

$tip = New-Object System.Windows.Forms.ToolTip
$tip.AutoPopDelay = 15000
$tip.InitialDelay = 400

$opButtons = @($btnProgram, $btnVerify, $btnRead, $btnErase, $btnInfo, $btnFlashSz, $btnUnlock, $btnReset)
function Set-ActionButton($button, [System.Drawing.Color]$color) {
    $button.AutoSize = $false
    $button.Size = New-Object System.Drawing.Size(148, 34)
    $button.MinimumSize = New-Object System.Drawing.Size(148, 34)
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $button.Padding = New-Object System.Windows.Forms.Padding(8, 0, 8, 0)
    $button.TextAlign = 'MiddleLeft'
    $button.BackColor = $color
    $button.FlatAppearance.BorderSize = 0
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
}

Set-ActionButton $btnProgram $clrBtn
Set-ActionButton $btnVerify $clrBtn
Set-ActionButton $btnRead $clrBtn
Set-ActionButton $btnErase $clrRed
Set-ActionButton $btnInfo $clrBtnAlt
Set-ActionButton $btnFlashSz $clrBtnAlt
Set-ActionButton $btnUnlock $clrBtnAlt
Set-ActionButton $btnReset $clrBtnAlt
Set-ActionButton $btnClear $clrBtnAlt
Set-ActionButton $btnUpdate $clrGreen
$rowBtns.Controls.AddRange(@($btnProgram, $btnVerify, $btnRead, $btnErase, $btnInfo, $btnFlashSz, $btnUnlock, $btnReset, $btnClear, $btnUpdate))

$log = New-Object System.Windows.Forms.RichTextBox
$log.Dock = 'Fill'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.BackColor = [System.Drawing.Color]::FromArgb(240, 244, 248)
$log.ForeColor = [System.Drawing.Color]::FromArgb(25, 30, 38)
$log.ReadOnly = $true
$log.BorderStyle = 'FixedSingle'
$log.Margin = New-Object System.Windows.Forms.Padding(0)

$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 48; $statusBar.BackColor = $clrBack
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(2, 10)
$progress.Size = New-Object System.Drawing.Size(500, 14)
$progress.Anchor = 'Top,Left,Right'
$progress.Style = 'Blocks'
$progress.ForeColor = $clrBtn
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.ForeColor = $clrDim; $lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(2, 30)
$statusBar.Controls.AddRange(@($progress, $lblStatus))

# порядок важен: докированные сверху панели ложатся в обратном порядке добавления
$main.Controls.Add($log)
$main.Controls.Add($rowAddr)
$main.Controls.Add($rowFile)
$main.Controls.Add($statusBar)
$main.Controls.Add($rowBtns)

# Не расширяем окно ради разметки: на небольшом экране оно должно оставаться целиком видимым.
function Fit-Window {
    $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $form.Width = [Math]::Min($form.Width, $area.Width - 24)
    $form.Height = [Math]::Min($form.Height, $area.Height - 24)
    $form.Left = $area.X + [int](($area.Width - $form.Width) / 2)
    $form.Top = $area.Y + [int](($area.Height - $form.Height) / 2)
}

function Apply-Language {
    $subtitle.Text  = T 'subtitle'
    $subtitle.Left  = $title.Right + 14
    $capLang.Text   = T 'capLang'
    $grpConn.Text   = T 'grpConn'
    $capIface.Text  = T 'capIface'
    $capTarget.Text = T 'capTarget'
    $capSpeed.Text  = T 'capSpeed'
    $capReset.Text  = T 'capReset'
    $grpInfo.Text   = T 'grpInfo'
    $capCore.Text   = T 'capCore'
    $capId.Text     = T 'capId'
    $capFlash.Text  = T 'capFlash'
    $capVolt.Text   = T 'capVolt'
    $hint.Text      = T 'hint'
    $capFile.Text   = T 'capFile'
        $btnBrowse.Text = if ($script:Lang -eq 'RU') { 'Файл' } else { 'Browse' }
    $capAddr.Text   = T 'capAddr'
    $capSize.Text   = T 'capSize'
    $chkBackup.Text = T 'chkBackup'
        $btnProgram.Text = T 'btnProgram'
        $btnVerify.Text = T 'btnVerify'
        $btnRead.Text = T 'btnRead'
        $btnErase.Text = T 'btnErase'
        $btnInfo.Text = T 'btnInfo'
        $btnFlashSz.Text = T 'btnFlashSz'
        $btnUnlock.Text = T 'btnUnlock'
        $btnReset.Text = T 'btnReset'
        $btnClear.Text = T 'btnClear'
    if ($script:newVersion) { $btnUpdate.Text = (T 'updBtn') -f $script:newVersion }
    $btnDetect.Text = T 'btnDetect'
    $btnPinout.Text = T 'btnPinout'
    # окно распиновки живёт своей жизнью: пересоздадим его на новом языке
    if ($script:pinoutForm -and -not $script:pinoutForm.IsDisposed) { $script:pinoutForm.Close(); Show-Pinout }

    $idx = if ($cmbReset.SelectedIndex -ge 0) { $cmbReset.SelectedIndex } else { 0 }
    $cmbReset.Items.Clear()
    [void]$cmbReset.Items.AddRange(@((T 'resetSoft'), (T 'resetHard')))
    $cmbReset.SelectedIndex = $idx

    $lblConn.Text = if (Ocd-Connected) { T 'connected' } else { T 'disconnected' }
    $btnConnect.Text = if (Ocd-Connected) { T 'btnDisconn' } else { T 'btnConnect' }
    if ($lblStatus.Text -eq '' -or -not (Ocd-Connected)) { $lblStatus.Text = T 'stReady' }

    $tip.SetToolTip($txtFile, (T 'tipFile'))
    $tip.SetToolTip($btnBrowse, (T 'tipFile'))
    if ($form.Visible) { Fit-Window }
}

# Подготовка идёт ПОСЛЕ показа окна: на новой машине распаковка OpenOCD занимает
# до минуты, и раньше всё это время на экране не было ничего — казалось, что программа
# не запустилась.
$form.Add_Shown({
    $form.Activate()
    $btnDetect.Enabled = $false; $btnConnect.Enabled = $false
    Set-Busy $true (T 'stPrepare')
    LogHead (T 'ttlPrepare')
    LogInfo (T 'logPrepare')
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $ocd = Get-OpenOcd
        Get-ChildItem (Join-Path $ocd.Scripts 'interface') -Filter *.cfg -Recurse |
            ForEach-Object { [void]$cmbIface.Items.Add($_.BaseName) }
        Get-ChildItem (Join-Path $ocd.Scripts 'target') -Filter *.cfg |
            ForEach-Object { [void]$cmbTarget.Items.Add($_.BaseName) }
        $cmbIface.Text = if ($cmbIface.Items.Contains('stlink')) { 'stlink' } else { $cmbIface.Items[0] }
        $cmbTarget.Text = 'stm32f1x'
        LogOk ((T 'logReady') -f $cmbIface.Items.Count, $cmbTarget.Items.Count)
        LogInfo ''
        LogInfo (T 'logOrder')
        LogInfo (T 'logNames')
        LogInfo (T 'logNames2')
        LogInfo (T 'logNames3')
        LogInfo ''
        $btnConnect.Enabled = $true
        $btnDetect.Enabled = $true

        # Проверка обновления — тихая: три секунды на ответ, и ни строчки, если сети нет.
        $script:newVersion = Test-UpdateAvailable
        if ($script:newVersion) {
            LogOk ((T 'updFound') -f $script:newVersion, $AppVersion)
            $btnUpdate.Text = (T 'updBtn') -f $script:newVersion
            $btnUpdate.Visible = $true
        }
        # Прошивка из прошлого запуска — только если файл ещё на месте.
        if (Test-Path -LiteralPath $LastFile -PathType Leaf) {
            $prev = (Get-Content -LiteralPath $LastFile -Raw -ErrorAction SilentlyContinue).Trim()
            if ($prev -and (Test-Path -LiteralPath $prev -PathType Leaf)) {
                $txtFile.Text = $prev
                LogInfo ((T 'logSelected') -f $prev, (Get-Item -LiteralPath $prev).Length)
            }
        }
        Fit-Window
    } catch {
        LogErr $_.Exception.Message
        LogErr (T 'logNoOcd')
    } finally {
        Set-Busy $false (T 'stReady')
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({ Pump-Log })
$timer.Start()

$form.Add_FormClosing({
    # Единственный случай, когда крестик задаёт вопрос: оборванная запись оставляет
    # чип с недописанной прошивкой. В покое окно закрывается сразу.
    if ($script:busy -and (Ocd-Connected)) {
        if ([System.Windows.Forms.MessageBox]::Show((T 'msgCloseBusy'), (T 'msgConfirm'), 'YesNo', 'Warning') -ne 'Yes') {
            $_.Cancel = $true
            return
        }
    }
    $timer.Stop()
    Stop-Session -Quiet
})

Apply-Language
Set-Connected $false
LogHead "GD32Flasher $AppVersion"
LogInfo "$($MyInvocation.MyCommand.Path)"
LogInfo ((T 'workdir') -f $Work)

try {
    [void]$form.ShowDialog()
} finally {
    # Мьютекс отпускаем в любом случае: после аварийного выхода он оставался занятым,
    # и следующий запуск считал, что программа уже открыта.
    Stop-Session -Quiet
    try { $script:mutex.ReleaseMutex() } catch { }
    $script:mutex.Dispose()
}
