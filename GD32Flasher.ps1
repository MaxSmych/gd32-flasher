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

$AppVersion = '1.3.0'
$Zip = Join-Path $PSScriptRoot 'tools\xpack-openocd-0.12.0-7-win32-x64.zip'

# Рабочая папка обязательно без кириллицы: OpenOCD и его Tcl не переваривают не-ASCII в путях.
$Base = if ($env:LOCALAPPDATA -match '^[\x20-\x7E]+$') { Join-Path $env:LOCALAPPDATA 'GD32Flasher' } else { 'C:\GD32Flasher' }
$Work = Join-Path $Base 'work'
New-Item -ItemType Directory -Force -Path $Work | Out-Null

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
        pinoutText  = @"
ЧТО СОЕДИНЯТЬ — четыре провода

    Программатор              Плата
    SWDIO   ───────────────   SWDIO    у GD32 и STM32 это вывод PA13
    SWCLK   ───────────────   SWCLK    PA14
    GND     ───────────────   GND
    3.3V    ───────────────   3.3V     только если плата не питается сама

  Землю вести ОТДЕЛЬНЫМ проводом рядом с SWDIO и SWCLK. Общая земля через
  корпус или дальний контакт даёт срывы связи на скорости.

  NRST нужен редко, и у многих клонов ST-Link V2 он просто не выведен.


РАЗЪЁМ НА ПЛАТЕ — стандарт ARM Cortex Debug, 10 контактов, шаг 1.27 мм

      1  VTref      ●  ●    2  SWDIO
      3  GND        ●  ●    4  SWCLK
      5  GND        ●  ●    6  SWO
      7  KEY        ●  ●    8  NC
      9  GNDDetect  ●  ●   10  nRESET

  Первый контакт помечен точкой или квадратной площадкой, ключ разъёма —
  со стороны выреза. Шелкография врёт чаще, чем хотелось бы: если связи
  нет, прозвонить контакты до GND и питания.


ST-LINK V2, клон-донгл

  Контакты подписаны прямо на корпусе, нужны только четыре: 3.3V, SWDIO,
  SWCLK, GND. SWIM рядом — это не SWD, а интерфейс STM8, с SWDIO не путать.
  5 В на цель не подавать.


ЕСЛИ СВЯЗИ НЕТ

  • понизить частоту SWD до 480 кГц;
  • провода короче 10-15 см, земля рядом с сигнальными;
  • питать плату отдельно, а не от программатора: заметная нагрузка сажает
    донгл, и он перестаёт опознаваться даже на USB;
  • если прошивка заняла PA13/PA14 под обычные GPIO, SWD пропадает сразу
    после старта — остаётся UART-загрузчик через BOOT0.
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
        logDetectGo = 'Перебираю конфигурации, это занимает до полуминуты.'
        logDetectTry= '  проверяю: {0}'
        logDetectHit= '  подходит: {0} — ядро {1}, Flash {2} КБ'
        logDetectSet= 'Выбрана конфигурация цели: {0}. Теперь нажмите «Подключиться».'
        logDetectCpu= 'Ядро определилось ({0}), но подходящий драйвер Flash не найден среди типовых. Выберите конфигурацию вручную.'
        logDetectNo = 'Чип не отвечает. Проверьте питание платы, подключение SWDIO/SWCLK/GND и понизьте частоту до 480 кГц.'
        logBackupNo = 'Операция отменена: не удалось снять дамп.'
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
        msgUnlock   = "Снятие защиты выполняет полное стирание кристалла (mass erase). Продолжить?`r`n`r`nПосле операции обязательно снять и подать питание платы: option bytes применяются только по power-on reset."
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
        pinoutText  = @"
WHAT TO CONNECT - four wires

    Probe                     Board
    SWDIO   ───────────────   SWDIO    on GD32 and STM32 this is pin PA13
    SWCLK   ───────────────   SWCLK    PA14
    GND     ───────────────   GND
    3.3V    ───────────────   3.3V     only if the board has no power of its own

  Run the ground as a SEPARATE wire next to SWDIO and SWCLK. A shared ground
  through the case or a distant pin causes dropouts at speed.

  NRST is rarely needed, and many ST-Link V2 clones do not expose it at all.


BOARD CONNECTOR - ARM Cortex Debug standard, 10 pins, 1.27 mm pitch

      1  VTref      ●  ●    2  SWDIO
      3  GND        ●  ●    4  SWCLK
      5  GND        ●  ●    6  SWO
      7  KEY        ●  ●    8  NC
      9  GNDDetect  ●  ●   10  nRESET

  Pin 1 is marked with a dot or a square pad, and the key sits on the notched
  side. Silkscreen lies more often than you would like: if there is no link,
  ring the pins out against GND and power.


ST-LINK V2 DONGLE CLONE

  The pins are labelled on the case itself; only four are needed: 3.3V, SWDIO,
  SWCLK, GND. SWIM next to them is not SWD - it is the STM8 interface, do not
  confuse it with SWDIO. Never feed 5 V to the target.


IF THERE IS NO LINK

  - lower the SWD speed to 480 kHz;
  - keep wires under 10-15 cm, ground next to the signals;
  - power the board separately: a noticeable load drags the dongle down and it
    stops enumerating on USB at all;
  - if the firmware took PA13/PA14 as ordinary GPIO, SWD disappears right after
    startup - the UART bootloader via BOOT0 is what is left.
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
        logDetectGo = 'Trying configs, this takes up to half a minute.'
        logDetectTry= '  trying: {0}'
        logDetectHit= '  match: {0} - core {1}, flash {2} KB'
        logDetectSet= 'Target config set to {0}. Now press Connect.'
        logDetectCpu= 'Core detected ({0}), but no matching flash driver among the common ones. Pick a config manually.'
        logDetectNo = 'No response from the chip. Check board power, SWDIO/SWCLK/GND wiring and lower the speed to 480 kHz.'
        logBackupNo = 'Operation cancelled: the backup dump failed.'
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
        msgUnlock   = "Removing protection performs a full chip erase (mass erase). Continue?`r`n`r`nAfter that, power-cycle the board: option bytes only apply on a power-on reset."
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

function Pump-Log([switch]$Final) {
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
            }
        }
    }
}

function Set-Busy([bool]$busy, [string]$status) {
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

function Ocd-Send([string]$cmd, [int]$timeoutSec = 300) {
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
    foreach ($l in $lines) { Log $l (Line-Color $l); Parse-Target $l }
    return ($lines -join "`n")
}

# $expect — обязательный признак успеха (wrote N bytes, verified N bytes и т.п.).
# Без него операция считается успешной по отсутствию ошибок, а этого мало: запись
# падала с «Error: couldn't open ...», ошибка уходила в лог OpenOCD мимо ответа
# telnet, и результат рапортовался как успешный.
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

# Подбирает конфигурацию цели перебором: пользователю не нужно знать, что GD32F330
# шьётся драйвером с именем stm32f1x.
function Find-Target {
    LogHead (T 'logDetect')
    LogInfo (T 'logDetectGo')
    Set-Busy $true (T 'stDetect')
    $found = $null
    $cpuSeen = $null
    try {
        foreach ($t in @('stm32f1x', 'stm32f0x', 'stm32f3x', 'stm32f2x', 'stm32f4x', 'stm32g0x', 'stm32l4x', 'stm32h7x')) {
            LogInfo ((T 'logDetectTry') -f $t)
            $txt = Invoke-OpenOcdOnce $t @('init; flash probe 0; shutdown')
            if ($txt -match 'Cortex-(M\d\+?)') { $cpuSeen = "Cortex-$($Matches[1])" }
            if ($txt -match 'flash size = (\d+)\s*KiB' -and $txt -notmatch 'probe failed') {
                $found = $t
                LogOk ((T 'logDetectHit') -f $t, $cpuSeen, $Matches[1])
                break
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
        Ocd-Send 'flash info 0' 30 | Out-Null
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

function Ocd-Disconnect {
    if (Ocd-Connected) { try { Ocd-Send 'shutdown' 5 | Out-Null } catch { } ; $script:tcp.Close() }
    $script:tcp = $null
    if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch { } }
    if ($script:proc) { try { [void]$script:proc.WaitForExit(3000) } catch { } }
    $script:proc = $null
    Pump-Log -Final
    Set-Connected $false
}

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

function Get-Fw {
    # -PathType Leaf: у папки Test-Path тоже истинен, и её копия делала из fw.bin
    # каталог — OpenOCD отвечал «couldn't open», а операция считалась успешной.
    if (-not (Test-Path -LiteralPath $txtFile.Text -PathType Leaf)) { LogErr (T 'logNoFile'); return $null }
    # копия в латинский путь без пробелов — снимает проблемы с кириллицей и длинными именами
    $dst = Join-Path $Work 'fw.bin'
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

function Invoke-Backup {
    $name = 'backup_{0:yyyyMMdd_HHmmss}.bin' -f (Get-Date)
    $dst = Join-Path $Work $name
    $ok = Ocd-Run "dump_image $(ConvertTo-TclPath $dst) $($txtAddr.Text) $($txtSize.Text)" ((T 'ttlBackup') -f $name) 300 'dumped\s+\d+\s+bytes'
    # бэкап без файла на диске — не бэкап, дальше идти нельзя
    if ($ok -and -not (Test-Path -LiteralPath $dst -PathType Leaf)) { $ok = $false; LogErr ((T 'logNoProof') -f $name) }
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
    # текст должен помещаться целиком, но не вылезать за экран на ноутбуке
    $screen = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $f.Size = New-Object System.Drawing.Size(660, [Math]::Min(700, $screen.Height - 60))
    $f.StartPosition = 'CenterParent'
    $f.BackColor = $clrPanel
    $f.Padding = New-Object System.Windows.Forms.Padding(10)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $box = New-Object System.Windows.Forms.RichTextBox
    $box.Dock = 'Fill'
    $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    $box.ReadOnly = $true
    $box.BorderStyle = 'None'
    $box.BackColor = $clrLogBg
    $box.ForeColor = $clrText
    $box.Text = T 'pinoutText'
    $box.Select(0, 0)
    $f.Controls.Add($box)
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
    if ($files -and $files.Count -gt 0) {
        $txtFile.Text = $files[0]
        LogInfo ((T 'logSelected') -f $files[0], (Get-Item $files[0]).Length)
    }
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
    if ($d.ShowDialog() -eq 'OK') {
        $txtFile.Text = $d.FileName
        LogInfo ((T 'logSelected') -f $d.FileName, (Get-Item $d.FileName).Length)
    }
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
    if (Ocd-Run 'reset halt' (T 'ttlHalt') 30) {
        if (Ocd-Run "flash write_image erase $t $($txtAddr.Text)" (T 'ttlWrite') 300 'wrote\s+\d+\s+bytes') {
            if (Ocd-Run "verify_image $t $($txtAddr.Text)" (T 'ttlVerify') 300 'verified\s+\d+\s+bytes') {
                Ocd-Run 'reset run' (T 'ttlRun') 30 | Out-Null
            }
        }
    }
})

$btnVerify = New-Btn '' $clrBtn
$btnVerify.Add_Click({
    if (-not (Require-Connection)) { return }
    $fw = Get-Fw; if (-not $fw) { return }
    Ocd-Run 'reset halt' (T 'ttlHalt') 30 | Out-Null
    Ocd-Run "verify_image $(ConvertTo-TclPath $fw) $($txtAddr.Text)" (T 'ttlVerify') 300 'verified\s+\d+\s+bytes' | Out-Null
})

$btnRead = New-Btn '' $clrBtn
$btnRead.Add_Click({
    if (-not (Require-Connection)) { return }
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter = T 'dlgDump'; $d.FileName = 'dump.bin'
    if ($d.ShowDialog() -ne 'OK') { return }
    $tmp = Join-Path $Work 'dump.bin'
    Ocd-Run 'reset halt' (T 'ttlHalt') 30 | Out-Null
    if (Ocd-Run "dump_image $(ConvertTo-TclPath $tmp) $($txtAddr.Text) $($txtSize.Text)" (T 'ttlRead') 300 'dumped\s+\d+\s+bytes') {
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
    Ocd-Run 'flash info 0' (T 'ttlFlashInfo') 30 | Out-Null
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
$rowBtns.Controls.AddRange(@($btnProgram, $btnVerify, $btnRead, $btnErase, $btnInfo, $btnFlashSz, $btnUnlock, $btnReset, $btnClear))

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

$form.Add_FormClosing({ $timer.Stop(); Ocd-Disconnect })

Apply-Language
Set-Connected $false
LogHead "GD32Flasher $AppVersion"
LogInfo "$($MyInvocation.MyCommand.Path)"
LogInfo ((T 'workdir') -f $Work)

[void]$form.ShowDialog()
$script:mutex.ReleaseMutex()
