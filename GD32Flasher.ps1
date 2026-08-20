# GD32Flasher — простой GUI поверх OpenOCD для прошивки GD32F3x0 через ST-Link V2.
# Берёт на себя грабли: распаковку OpenOCD, пути без кириллицы, Tcl-escape в путях, бэкап перед стиранием.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Zip = Join-Path $PSScriptRoot 'tools\xpack-openocd-0.12.0-7-win32-x64.zip'

# Рабочая папка обязательно без кириллицы: OpenOCD и его Tcl не переваривают не-ASCII в путях.
$Base = if ($env:LOCALAPPDATA -match '^[\x20-\x7E]+$') { Join-Path $env:LOCALAPPDATA 'GD32Flasher' } else { 'C:\GD32Flasher' }
$Work = Join-Path $Base 'work'
New-Item -ItemType Directory -Force -Path $Work | Out-Null

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
function To-Tcl([string]$p) { $p -replace '\\', '/' }

function Write-Log([string]$text, [string]$color = 'Black') {
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = $color
    $log.AppendText("$text`r`n")
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-OpenOcd([string[]]$Commands, [string]$Title) {
    Write-Log "=== $Title ===" 'Navy'
    try { $ocd = Get-OpenOcd } catch { Write-Log $_.Exception.Message 'Red'; return $false }

    $argLine = "-s `"$($ocd.Scripts)`" -f interface/stlink.cfg -f target/stm32f1x.cfg -c `"adapter speed $($cmbSpeed.Text)`""
    foreach ($c in $Commands) { $argLine += " -c `"$c`"" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ocd.Exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $lblStatus.Text = 'Выполняется...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $tOut = $p.StandardOutput.ReadToEndAsync()
        $tErr = $p.StandardError.ReadToEndAsync()
        while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        $text = ($tOut.Result + $tErr.Result).TrimEnd()
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    foreach ($line in $text -split "`r?`n") {
        $c = if ($line -match '^Error:') { 'Red' } elseif ($line -match '^Warn') { 'DarkOrange' } else { 'Black' }
        Write-Log $line $c
    }

    # OpenOCD не печатает "wrote/verified" при запуске цепочкой -c (это command_print, не лог).
    # Признак успеха: ни одной строки Error и выполнение дошло до shutdown.
    $ok = ($text -notmatch '(?m)^Error:') -and ($text -match 'shutdown command invoked')
    if ($ok) { Write-Log "РЕЗУЛЬТАТ: успешно`r`n" 'Green'; $lblStatus.Text = 'Готово' }
    else     { Write-Log "РЕЗУЛЬТАТ: ошибка`r`n" 'Red';   $lblStatus.Text = 'Ошибка' }
    return $ok
}

function Get-Fw {
    if (-not (Test-Path $txtFile.Text)) { Write-Log 'Не выбран файл прошивки.' 'Red'; return $null }
    # Копия в латинский путь без пробелов — снимает проблемы с кириллицей и длинными именами.
    $dst = Join-Path $Work 'fw.bin'
    Copy-Item $txtFile.Text $dst -Force
    return $dst
}

function Invoke-Backup {
    $name = 'backup_{0:yyyyMMdd_HHmmss}.bin' -f (Get-Date)
    $dst = Join-Path $Work $name
    $ok = Invoke-OpenOcd @("init; reset halt; dump_image $(To-Tcl $dst) $($txtAddr.Text) 0x20000; shutdown") "Резервный дамп -> $name"
    if ($ok) { Write-Log "Дамп сохранён: $dst" 'Green' }
    return $ok
}

# --- UI ---

$form = New-Object System.Windows.Forms.Form
$form.Text = 'GD32Flasher — прошивка GD32F3x0 через ST-Link'
$form.Size = New-Object System.Drawing.Size(940, 660)
$form.StartPosition = 'CenterScreen'

function New-Label($text, $x, $y, $w) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, 20)
    $form.Controls.Add($l); return $l
}
function New-Button($text, $x, $y, $w, $action) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, 34)
    $b.Add_Click($action)
    $form.Controls.Add($b); return $b
}

New-Label 'Файл прошивки (.bin):' 12 15 140 | Out-Null
$txtFile = New-Object System.Windows.Forms.TextBox
$txtFile.Location = New-Object System.Drawing.Point(160, 12)
$txtFile.Size = New-Object System.Drawing.Size(650, 24)
$form.Controls.Add($txtFile)

New-Button 'Обзор...' 820 10 90 {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = 'Прошивка (*.bin;*.hex)|*.bin;*.hex|Все файлы (*.*)|*.*'
    if ($d.ShowDialog() -eq 'OK') {
        $txtFile.Text = $d.FileName
        Write-Log "Выбран файл: $($d.FileName) ($((Get-Item $d.FileName).Length) байт)" 'Navy'
    }
} | Out-Null

New-Label 'Адрес:' 12 52 50 | Out-Null
$txtAddr = New-Object System.Windows.Forms.TextBox
$txtAddr.Location = New-Object System.Drawing.Point(62, 49)
$txtAddr.Size = New-Object System.Drawing.Size(100, 24)
$txtAddr.Text = '0x08000000'
$form.Controls.Add($txtAddr)

New-Label 'SWD, кГц:' 180 52 70 | Out-Null
$cmbSpeed = New-Object System.Windows.Forms.ComboBox
$cmbSpeed.Location = New-Object System.Drawing.Point(250, 49)
$cmbSpeed.Size = New-Object System.Drawing.Size(80, 24)
$cmbSpeed.DropDownStyle = 'DropDownList'
@('480', '950', '1800', '4000') | ForEach-Object { [void]$cmbSpeed.Items.Add($_) }
$cmbSpeed.SelectedItem = '950'
$form.Controls.Add($cmbSpeed)

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = 'Снимать резервный дамп перед стиранием и прошивкой'
$chkBackup.Location = New-Object System.Drawing.Point(350, 50)
$chkBackup.Size = New-Object System.Drawing.Size(420, 24)
$chkBackup.Checked = $true
$form.Controls.Add($chkBackup)

New-Button 'Проверить связь' 12 85 150 {
    Invoke-OpenOcd @("init; reset halt; flash info 0; mdw $($txtAddr.Text) 4; shutdown") 'Связь и состояние Flash' | Out-Null
} | Out-Null

New-Button 'Считать дамп' 170 85 130 {
    $d = New-Object System.Windows.Forms.SaveFileDialog
    $d.Filter = 'Дамп (*.bin)|*.bin'; $d.FileName = 'dump.bin'
    if ($d.ShowDialog() -ne 'OK') { return }
    $tmp = Join-Path $Work 'dump.bin'
    if (Invoke-OpenOcd @("init; reset halt; dump_image $(To-Tcl $tmp) $($txtAddr.Text) 0x20000; shutdown") 'Чтение Flash (128 КБ)') {
        Copy-Item $tmp $d.FileName -Force
        Write-Log "Дамп сохранён: $($d.FileName)" 'Green'
    }
} | Out-Null

New-Button 'Стереть' 308 85 100 {
    if ([System.Windows.Forms.MessageBox]::Show('Стереть Flash полностью? Данные будут потеряны.', 'Подтверждение', 'YesNo', 'Warning') -ne 'Yes') { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { Write-Log 'Стирание отменено: не удалось снять дамп.' 'Red'; return }
    Invoke-OpenOcd @("init; reset halt; flash erase_sector 0 0 last; mdw $($txtAddr.Text) 4; shutdown") 'Стирание Flash' | Out-Null
} | Out-Null

New-Button 'Прошить + проверить' 416 85 170 {
    $fw = Get-Fw; if (-not $fw) { return }
    if ($chkBackup.Checked -and -not (Invoke-Backup)) { Write-Log 'Прошивка отменена: не удалось снять дамп.' 'Red'; return }
    $t = To-Tcl $fw
    $a = $txtAddr.Text
    Invoke-OpenOcd @("init; reset halt; flash write_image erase $t $a; verify_image $t $a; reset run; shutdown") 'Прошивка и проверка' | Out-Null
} | Out-Null

New-Button 'Только проверить' 594 85 150 {
    $fw = Get-Fw; if (-not $fw) { return }
    Invoke-OpenOcd @("init; reset halt; verify_image $(To-Tcl $fw) $($txtAddr.Text); shutdown") 'Проверка (verify)' | Out-Null
} | Out-Null

New-Button 'Очистить лог' 752 85 120 { $log.Clear() } | Out-Null

$log = New-Object System.Windows.Forms.RichTextBox
$log.Location = New-Object System.Drawing.Point(12, 130)
$log.Size = New-Object System.Drawing.Size(900, 450)
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.ReadOnly = $true
$log.Anchor = 'Top,Left,Right,Bottom'
$form.Controls.Add($log)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 590)
$lblStatus.Size = New-Object System.Drawing.Size(900, 20)
$lblStatus.Anchor = 'Left,Right,Bottom'
$lblStatus.Text = 'Готов'
$form.Controls.Add($lblStatus)

Write-Log "GD32Flasher. Рабочая папка: $Work" 'Gray'
Write-Log 'Порядок: подключить ST-Link -> "Проверить связь" -> "Считать дамп" -> "Прошить + проверить".' 'Gray'

[void]$form.ShowDialog()
