# GD32Flasher — GUI поверх OpenOCD в духе STM32CubeProgrammer.
# Держит постоянную сессию OpenOCD и общается с ней по telnet 4444, поэтому в логе
# видны результаты команд (wrote/verified), которых нет при запуске цепочкой -c.
# Берёт на себя грабли: распаковку OpenOCD, пути без кириллицы, Tcl-escape, бэкап перед стиранием.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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

# --- палитра в духе Cube ---
$clrBack   = [System.Drawing.Color]::FromArgb(30, 42, 56)
$clrPanel  = [System.Drawing.Color]::FromArgb(37, 53, 73)
$clrHeader = [System.Drawing.Color]::FromArgb(15, 42, 71)
$clrBtn    = [System.Drawing.Color]::FromArgb(46, 125, 178)
$clrGreen  = [System.Drawing.Color]::FromArgb(96, 160, 60)
$clrRed    = [System.Drawing.Color]::FromArgb(170, 60, 60)
$clrText   = [System.Drawing.Color]::White
$clrDim    = [System.Drawing.Color]::FromArgb(170, 190, 210)

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
    if (-not $text) { return }
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = $color
    $log.AppendText("$text`r`n")
    $log.ScrollToCaret()
}

function LogInfo([string]$t) { Log $t ([System.Drawing.Color]::Black) }
function LogOk([string]$t)   { Log $t ([System.Drawing.Color]::FromArgb(0, 128, 0)) }
function LogErr([string]$t)  { Log $t ([System.Drawing.Color]::FromArgb(200, 0, 0)) }
function LogHead([string]$t) { Log $t ([System.Drawing.Color]::FromArgb(0, 60, 140)) }

function Line-Color([string]$line) {
    if ($line -match '^Error:|Error:')     { return [System.Drawing.Color]::FromArgb(200, 0, 0) }
    if ($line -match '^Warn')              { return [System.Drawing.Color]::FromArgb(200, 110, 0) }
    if ($line -match '^Info')              { return [System.Drawing.Color]::FromArgb(70, 70, 70) }
    return [System.Drawing.Color]::Black
}

# Разбирает вывод OpenOCD и заполняет панель информации о цели.
function Parse-Target([string]$line) {
    if ($line -match 'Cortex-(M\d\+?)\s*(r\dp\d)?') { $lblCpu.Text  = "Cortex-$($Matches[1]) $($Matches[2])".Trim() }
    if ($line -match 'device id = (0x[0-9a-fA-F]+)') { $lblId.Text   = $Matches[1] }
    if ($line -match 'Target voltage: ([\d\.]+)')    { $lblVolt.Text = '{0:N2} В' -f [double]$Matches[1] }
    if ($line -match 'flash size = (\d+)\s*KiB') {
        $kb = [int]$Matches[1]
        $lblFlash.Text = "$kb КБ"
        $txtSize.Text = '0x{0:X}' -f ($kb * 1024)
    }
}

function Pump-Log {
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
        foreach ($line in ($chunk -split "`r?`n")) {
            if ($line -ne '') { Log $line (Line-Color $line); Parse-Target $line }
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

function Ocd-Send([string]$cmd, [int]$timeoutSec = 300) {
    if (-not (Ocd-Connected)) { LogErr 'Нет подключения к цели.'; return $null }
    $ns = $script:tcp.GetStream()
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
    # первая строка — эхо отправленной команды
    $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' -and $_ -ne $cmd })
    foreach ($l in $lines) { Log $l (Line-Color $l); Parse-Target $l }
    return ($lines -join "`n")
}

function Ocd-Run([string]$cmd, [string]$title, [int]$timeoutSec = 300) {
    LogHead "=== $title ==="
    Set-Busy $true $title
    try { $out = Ocd-Send $cmd $timeoutSec } finally { Set-Busy $false 'Готов' }
    if ($null -eq $out) { return $false }
    $ok = ($out -notmatch '(?im)^\s*error|failed|timed out')
    if ($ok) { LogOk "РЕЗУЛЬТАТ: успешно`r`n" } else { LogErr "РЕЗУЛЬТАТ: ошибка`r`n" }
    return $ok
}

function Ocd-Connect {
    if (Ocd-Connected) { return $true }
    try { $ocd = Get-OpenOcd } catch { LogErr $_.Exception.Message; return $false }

    Remove-Item $script:fOut, $script:fErr -ErrorAction SilentlyContinue
    $script:pos = @{ out = 0; err = 0 }

    $argList = @(
        '-s', "`"$($ocd.Scripts)`"",
        '-f', "interface/$($cmbIface.Text).cfg",
        '-f', "target/$($cmbTarget.Text).cfg",
        '-c', "`"adapter speed $($cmbSpeed.Text)`""
    )
    if ($cmbReset.SelectedIndex -eq 1) { $argList += @('-c', '"reset_config srst_only srst_nogate"') }

    LogHead "=== Подключение: $($cmbIface.Text) / $($cmbTarget.Text) / $($cmbSpeed.Text) кГц ==="
    Set-Busy $true 'Подключение...'
    try {
        $script:proc = Start-Process -FilePath $ocd.Exe -ArgumentList $argList -NoNewWindow -PassThru `
            -RedirectStandardOutput $script:fOut -RedirectStandardError $script:fErr

        # ждём реальной готовности порта 4444, а не фиксированной паузы
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline) {
            Pump-Log
            if ($script:proc.HasExited) { LogErr 'OpenOCD завершился, соединение не установлено.'; break }
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $c.Connect('127.0.0.1', 4444)
                $script:tcp = $c
                break
            } catch { }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
        }
    } finally { Set-Busy $false 'Готов' }

    Pump-Log
    if (Ocd-Connected) {
        Start-Sleep -Milliseconds 200
        $ns = $script:tcp.GetStream()
        while ($ns.DataAvailable) { $b = New-Object byte[] 4096; [void]$ns.Read($b, 0, $b.Length) }  # приветствие
        Set-Connected $true
        Ocd-Send 'reset halt' 30 | Out-Null
        Ocd-Send 'flash info 0' 30 | Out-Null
        LogOk "Подключено.`r`n"
        return $true
    }
    LogErr "Подключиться не удалось. Проверьте кабель, питание платы и выбранный конфиг цели.`r`n"
    Ocd-Disconnect
    return $false
}

function Ocd-Disconnect {
    if (Ocd-Connected) { try { Ocd-Send 'shutdown' 5 | Out-Null } catch { } ; $script:tcp.Close() }
    $script:tcp = $null
    if ($script:proc -and -not $script:proc.HasExited) { try { $script:proc.Kill() } catch { } }
    $script:proc = $null
    Set-Connected $false
}

function Set-Connected([bool]$on) {
    $lblConn.Text = if ($on) { '● Подключено' } else { '● Не подключено' }
    $lblConn.ForeColor = if ($on) { [System.Drawing.Color]::FromArgb(120, 220, 120) } else { [System.Drawing.Color]::FromArgb(220, 130, 130) }
    $btnConnect.Text = if ($on) { 'Отключиться' } else { 'Подключиться' }
    $btnConnect.BackColor = if ($on) { $clrRed } else { $clrGreen }
    foreach ($b in $opButtons) { $b.Enabled = $on }
    $cmbIface.Enabled = -not $on; $cmbTarget.Enabled = -not $on
    $cmbSpeed.Enabled = -not $on; $cmbReset.Enabled = -not $on
    if (-not $on) { $lblCpu.Text = '--'; $lblId.Text = '--'; $lblFlash.Text = '--'; $lblVolt.Text = '--' }
}

function Get-Fw {
    if (-not (Test-Path $txtFile.Text)) { LogErr 'Не выбран файл прошивки.'; return $null }
    # копия в латинский путь без пробелов — снимает проблемы с кириллицей и длинными именами
    $dst = Join-Path $Work 'fw.bin'
    Copy-Item $txtFile.Text $dst -Force
    return $dst
}

function Invoke-Backup {
    $name = 'backup_{0:yyyyMMdd_HHmmss}.bin' -f (Get-Date)
    $dst = Join-Path $Work $name
    $ok = Ocd-Run "dump_image $(ConvertTo-TclPath $dst) $($txtAddr.Text) $($txtSize.Text)" "Резервный дамп -> $name"
    if ($ok) { LogOk "Дамп сохранён: $dst" }
    return $ok
}

# --- интерфейс ---

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GD32Flasher'
$form.Size = New-Object System.Drawing.Size(1120, 750)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $clrBack
$form.ForeColor = $clrText
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)

function New-Btn($text, $w, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Width = $w; $b.Height = 34
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $color
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 8)
    return $b
}
function New-Cap($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.ForeColor = $clrDim
    return $l
}
function New-Val($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.ForeColor = $clrText
    return $l
}

# шапка
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 52; $header.BackColor = $clrHeader
$title = New-Object System.Windows.Forms.Label
$title.Text = 'GD32Flasher'
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$title.ForeColor = $clrText; $title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(16, 12)
$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'OpenOCD + ST-Link'
$subtitle.ForeColor = $clrDim; $subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(150, 19)
$lblConn = New-Object System.Windows.Forms.Label
$lblConn.Text = '● Не подключено'
$lblConn.AutoSize = $true; $lblConn.Anchor = 'Top,Right'
$lblConn.Location = New-Object System.Drawing.Point(940, 18)
$header.Controls.AddRange(@($title, $subtitle, $lblConn))
$form.Controls.Add($header)

# правая панель — подключение и информация о цели
$side = New-Object System.Windows.Forms.Panel
$side.Dock = 'Right'; $side.Width = 300; $side.BackColor = $clrPanel; $side.Padding = New-Object System.Windows.Forms.Padding(12)

$grpConn = New-Object System.Windows.Forms.Label
$grpConn.Text = 'ПОДКЛЮЧЕНИЕ'; $grpConn.AutoSize = $true
$grpConn.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$grpConn.ForeColor = [System.Drawing.Color]::FromArgb(120, 190, 240)
$grpConn.Location = New-Object System.Drawing.Point(14, 14)

function New-Combo($x, $y, $w) {
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, 24)
    $c.FlatStyle = 'Flat'
    return $c
}

$side.Controls.Add($grpConn)
$side.Controls.Add((New-Cap 'Программатор' 14 44))
$cmbIface = New-Combo 14 62 270
$cmbIface.DropDownStyle = 'DropDown'
$cmbIface.AutoCompleteMode = 'SuggestAppend'
$cmbIface.AutoCompleteSource = 'ListItems'
$side.Controls.Add($cmbIface)

$side.Controls.Add((New-Cap 'Конфигурация цели' 14 94))
$cmbTarget = New-Combo 14 112 270
$cmbTarget.DropDownStyle = 'DropDown'
$cmbTarget.AutoCompleteMode = 'SuggestAppend'
$cmbTarget.AutoCompleteSource = 'ListItems'
$side.Controls.Add($cmbTarget)

$side.Controls.Add((New-Cap 'Частота SWD, кГц' 14 144))
$cmbSpeed = New-Combo 14 162 120
$cmbSpeed.DropDownStyle = 'DropDownList'
@('100', '480', '950', '1800', '4000') | ForEach-Object { [void]$cmbSpeed.Items.Add($_) }
$cmbSpeed.SelectedItem = '950'
$side.Controls.Add($cmbSpeed)

$side.Controls.Add((New-Cap 'Сброс' 150 144))
$cmbReset = New-Combo 150 162 134
$cmbReset.DropDownStyle = 'DropDownList'
[void]$cmbReset.Items.AddRange(@('Программный', 'Аппаратный (SRST)'))
$cmbReset.SelectedIndex = 0
$side.Controls.Add($cmbReset)

$btnConnect = New-Btn 'Подключиться' 270 $clrGreen
$btnConnect.Location = New-Object System.Drawing.Point(14, 200)
$btnConnect.Add_Click({ if (Ocd-Connected) { Ocd-Disconnect } else { Ocd-Connect | Out-Null } })
$side.Controls.Add($btnConnect)

$grpInfo = New-Object System.Windows.Forms.Label
$grpInfo.Text = 'ИНФОРМАЦИЯ О ЦЕЛИ'; $grpInfo.AutoSize = $true
$grpInfo.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$grpInfo.ForeColor = [System.Drawing.Color]::FromArgb(120, 190, 240)
$grpInfo.Location = New-Object System.Drawing.Point(14, 258)
$side.Controls.Add($grpInfo)

$side.Controls.Add((New-Cap 'Ядро' 14 288));        $lblCpu   = New-Val '--' 150 288; $side.Controls.Add($lblCpu)
$side.Controls.Add((New-Cap 'Device ID' 14 314));   $lblId    = New-Val '--' 150 314; $side.Controls.Add($lblId)
$side.Controls.Add((New-Cap 'Объём Flash' 14 340)); $lblFlash = New-Val '--' 150 340; $side.Controls.Add($lblFlash)
$side.Controls.Add((New-Cap 'Напряжение' 14 366));  $lblVolt  = New-Val '--' 150 366; $side.Controls.Add($lblVolt)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "Связь нестабильна — снизьте частоту до 480 кГц." + [Environment]::NewLine + "Землю программатора вести отдельным проводом рядом с SWDIO/SWCLK."
$hint.ForeColor = $clrDim
$hint.Location = New-Object System.Drawing.Point(14, 410)
$hint.Size = New-Object System.Drawing.Size(270, 60)
$side.Controls.Add($hint)
$form.Controls.Add($side)

# центральная часть
$main = New-Object System.Windows.Forms.Panel
$main.Dock = 'Fill'; $main.Padding = New-Object System.Windows.Forms.Padding(14)
$form.Controls.Add($main)

$rowFile = New-Object System.Windows.Forms.Panel
$rowFile.Dock = 'Top'; $rowFile.Height = 36
$lblFile = New-Object System.Windows.Forms.Label
$lblFile.Text = 'Файл прошивки'; $lblFile.ForeColor = $clrDim; $lblFile.AutoSize = $true
$lblFile.Location = New-Object System.Drawing.Point(2, 8)
$txtFile = New-Object System.Windows.Forms.TextBox
$txtFile.Location = New-Object System.Drawing.Point(110, 5)
$txtFile.Size = New-Object System.Drawing.Size(560, 24)
$txtFile.Anchor = 'Top,Left,Right'
$btnBrowse = New-Btn 'Обзор...' 90 $clrBtn
$btnBrowse.Height = 26
$btnBrowse.Location = New-Object System.Drawing.Point(680, 4)
$btnBrowse.Anchor = 'Top,Right'
$btnBrowse.Add_Click({
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Прошивка (*.bin;*.hex;*.elf)|*.bin;*.hex;*.elf|Все файлы (*.*)|*.*'
    if ($d.ShowDialog() -eq 'OK') {
        $txtFile.Text = $d.FileName
        LogInfo "Выбран файл: $($d.FileName) ($((Get-Item $d.FileName).Length) байт)"
    }
})
$rowFile.Controls.AddRange(@($lblFile, $txtFile, $btnBrowse))

$rowAddr = New-Object System.Windows.Forms.Panel
$rowAddr.Dock = 'Top'; $rowAddr.Height = 36
$lblAddr = New-Object System.Windows.Forms.Label
$lblAddr.Text = 'Адрес'; $lblAddr.ForeColor = $clrDim; $lblAddr.AutoSize = $true
$lblAddr.Location = New-Object System.Drawing.Point(2, 8)
$txtAddr = New-Object System.Windows.Forms.TextBox
$txtAddr.Location = New-Object System.Drawing.Point(110, 5)
$txtAddr.Size = New-Object System.Drawing.Size(110, 24)
$txtAddr.Text = '0x08000000'
$lblSize = New-Object System.Windows.Forms.Label
$lblSize.Text = 'Размер чтения'; $lblSize.ForeColor = $clrDim; $lblSize.AutoSize = $true
$lblSize.Location = New-Object System.Drawing.Point(240, 8)
$txtSize = New-Object System.Windows.Forms.TextBox
$txtSize.Location = New-Object System.Drawing.Point(340, 5)
$txtSize.Size = New-Object System.Drawing.Size(110, 24)
$txtSize.Text = '0x20000'
$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = 'Резервный дамп перед стиранием и прошивкой'
$chkBackup.Location = New-Object System.Drawing.Point(470, 6)
$chkBackup.Size = New-Object System.Drawing.Size(340, 24)
$chkBackup.ForeColor = $clrText
$chkBackup.Checked = $true
$rowAddr.Controls.AddRange(@($lblAddr, $txtAddr, $lblSize, $txtSize, $chkBackup))

$rowBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$rowBtns.Dock = 'Top'; $rowBtns.Height = 88; $rowBtns.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)

$btnProgram = New-Btn 'Прошить + проверить' 170 $clrBtn
$btnProgram.Add_Click({
    $fw = Get-Fw; if (-not $fw) { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { LogErr 'Прошивка отменена: не удалось снять дамп.'; return }
    $t = ConvertTo-TclPath $fw
    if (Ocd-Run 'reset halt' 'Остановка ядра' 30) {
        if (Ocd-Run "flash write_image erase $t $($txtAddr.Text)" 'Запись прошивки') {
            if (Ocd-Run "verify_image $t $($txtAddr.Text)" 'Проверка (verify)') {
                Ocd-Run 'reset run' 'Запуск' 30 | Out-Null
            }
        }
    }
})

$btnVerify = New-Btn 'Только проверить' 150 $clrBtn
$btnVerify.Add_Click({
    $fw = Get-Fw; if (-not $fw) { return }
    Ocd-Run 'reset halt' 'Остановка ядра' 30 | Out-Null
    Ocd-Run "verify_image $(ConvertTo-TclPath $fw) $($txtAddr.Text)" 'Проверка (verify)' | Out-Null
})

$btnRead = New-Btn 'Считать дамп' 140 $clrBtn
$btnRead.Add_Click({
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter = 'Дамп (*.bin)|*.bin'; $d.FileName = 'dump.bin'
    if ($d.ShowDialog() -ne 'OK') { return }
    $tmp = Join-Path $Work 'dump.bin'
    Ocd-Run 'reset halt' 'Остановка ядра' 30 | Out-Null
    if (Ocd-Run "dump_image $(ConvertTo-TclPath $tmp) $($txtAddr.Text) $($txtSize.Text)" 'Чтение памяти') {
        Copy-Item $tmp $d.FileName -Force
        LogOk "Дамп сохранён: $($d.FileName)"
    }
})

$btnErase = New-Btn 'Стереть' 110 $clrBtn
$btnErase.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('Стереть Flash полностью? Данные будут потеряны.', 'Подтверждение', 'YesNo', 'Warning') -ne 'Yes') { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { LogErr 'Стирание отменено: не удалось снять дамп.'; return }
    Ocd-Run 'reset halt' 'Остановка ядра' 30 | Out-Null
    if (Ocd-Run 'flash erase_sector 0 0 last' 'Стирание Flash') {
        Ocd-Run "mdw $($txtAddr.Text) 8" 'Контроль первых слов' 30 | Out-Null
    }
})

$btnInfo = New-Btn 'Информация' 120 $clrBtn
$btnInfo.Add_Click({
    Ocd-Run 'reset halt' 'Остановка ядра' 30 | Out-Null
    Ocd-Run 'flash info 0' 'Состояние Flash' 30 | Out-Null
    Ocd-Run "mdw $($txtAddr.Text) 8" 'Первые слова памяти' 30 | Out-Null
})

$btnUnlock = New-Btn 'Снять защиту' 130 $clrBtn
$btnUnlock.Add_Click({
    $msg = 'Снятие защиты выполняет полное стирание кристалла (mass erase). Продолжить?' + [Environment]::NewLine + [Environment]::NewLine + 'После операции обязательно снять и подать питание платы: option bytes применяются только по power-on reset.'
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Подтверждение', 'YesNo', 'Warning') -ne 'Yes') { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { LogErr 'Операция отменена: не удалось снять дамп.'; return }
    $drv = ($cmbTarget.Text -replace '\d.*$', '') # stm32f1x -> stm32f1
    Ocd-Run 'reset halt' 'Остановка ядра' 30 | Out-Null
    Ocd-Run "$($cmbTarget.Text) unlock 0" 'Снятие защиты' | Out-Null
})

$btnReset = New-Btn 'Сброс и запуск' 140 $clrBtn
$btnReset.Add_Click({ Ocd-Run 'reset run' 'Сброс и запуск' 30 | Out-Null })

$btnClear = New-Btn 'Очистить лог' 120 ([System.Drawing.Color]::FromArgb(70, 90, 110))
$btnClear.Add_Click({ $log.Clear() })

$opButtons = @($btnProgram, $btnVerify, $btnRead, $btnErase, $btnInfo, $btnUnlock, $btnReset)
$rowBtns.Controls.AddRange(@($btnProgram, $btnVerify, $btnRead, $btnErase, $btnInfo, $btnUnlock, $btnReset, $btnClear))

$log = New-Object System.Windows.Forms.RichTextBox
$log.Dock = 'Fill'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.BackColor = [System.Drawing.Color]::White
$log.ForeColor = [System.Drawing.Color]::Black
$log.ReadOnly = $true
$log.BorderStyle = 'None'

$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 46; $statusBar.BackColor = $clrBack
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(2, 8)
$progress.Size = New-Object System.Drawing.Size(500, 16)
$progress.Anchor = 'Top,Left,Right'
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Готов'
$lblStatus.ForeColor = $clrDim; $lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(2, 28)
$statusBar.Controls.AddRange(@($progress, $lblStatus))

$main.Controls.Add($log)
$main.Controls.Add($rowBtns)
$main.Controls.Add($rowAddr)
$main.Controls.Add($rowFile)
$main.Controls.Add($statusBar)

# заполняем списки тем, что реально есть в поставке OpenOCD
try {
    $ocd = Get-OpenOcd
    Get-ChildItem (Join-Path $ocd.Scripts 'interface') -Filter *.cfg -Recurse |
        ForEach-Object { [void]$cmbIface.Items.Add($_.BaseName) }
    Get-ChildItem (Join-Path $ocd.Scripts 'target') -Filter *.cfg |
        ForEach-Object { [void]$cmbTarget.Items.Add($_.BaseName) }
    $cmbIface.Text = if ($cmbIface.Items.Contains('stlink')) { 'stlink' } else { $cmbIface.Items[0] }
    $cmbTarget.Text = 'stm32f1x'
} catch {
    LogErr $_.Exception.Message
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({ Pump-Log })
$timer.Start()

$form.Add_FormClosing({ $timer.Stop(); Ocd-Disconnect })

Set-Connected $false
LogHead 'GD32Flasher готов к работе.'
LogInfo "Рабочая папка: $Work"
LogInfo 'Порядок: подключить ST-Link → «Подключиться» → «Считать дамп» → выбрать файл → «Прошить + проверить».'
LogInfo 'Для GD32F3x0 / F1x0 / F10x / E10x и STM32F1 конфигурация цели — stm32f1x (значение по умолчанию).'
LogInfo ''

[void]$form.ShowDialog()
