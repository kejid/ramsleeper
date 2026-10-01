# RAM Sleeper tray companion for Windows.
#
# Shows the total memory of all Claude Code sessions in the notification area.
# Left click opens a popup with every session and an Unload button; right click
# offers the full dashboard, start-at-login and exit. All data comes from the
# plugin's sessions.mjs, so the tray and the plugin always agree.
#
# Run:  powershell -NoProfile -STA -WindowStyle Hidden -File ramsleeper-tray.ps1
#       ... -File ramsleeper-tray.ps1 -Autostart on|off   (set start at sign-in and exit)

# -Snapshot <png> draws the popup (and the icon in its three colors next to it)
# into an image and exits; used for the README screenshots.
param([ValidateSet('on', 'off')][string]$Autostart, [string]$Snapshot)

$ErrorActionPreference = 'Stop'

# State lives outside the plugin folder, whose path changes with every version.
$StateDir = Join-Path $env:LOCALAPPDATA 'ramsleeper'
$PidFile = Join-Path $StateDir 'tray.pid'
$Launcher = Join-Path $StateDir 'start-tray.ps1'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'RAM Sleeper.lnk'

# Start at sign-in goes through a small launcher that picks the newest
# installed plugin version, so a plugin update does not break the shortcut.
# The plugin can live in two places: Claude Code's own cache (installed with
# `claude plugin install`) and the desktop app's folder for plugins added from
# the directory on claude.ai. The launcher reads plugin.json in each and runs
# the highest version.
function Set-Autostart([bool]$on) {
    if (-not $on) {
        Remove-Item $StartupLnk, $Launcher -ErrorAction SilentlyContinue
        return
    }
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    $fallback = $PSCommandPath -replace "'", "''"
    $cliCache = (Join-Path $env:USERPROFILE '.claude\plugins\cache\ramsleeper\ramsleeper\*') -replace "'", "''"
    $appDir = (Join-Path $env:APPDATA 'Claude\local-agent-mode-sessions\*\*\rpm\plugin_*') -replace "'", "''"
    @"
# Written by RAM Sleeper. Starts the newest installed tray script.
`$tray = Get-Item '$cliCache', '$appDir' -ErrorAction SilentlyContinue | ForEach-Object {
    `$script = Join-Path `$_.FullName 'companion\windows-tray\ramsleeper-tray.ps1'
    `$manifest = Join-Path `$_.FullName '.claude-plugin\plugin.json'
    if ((Test-Path `$script) -and (Test-Path `$manifest)) {
        try {
            `$m = Get-Content `$manifest -Raw | ConvertFrom-Json
            if (`$m.name -eq 'ramsleeper') { [pscustomobject]@{ Script = `$script; Version = [version]`$m.version } }
        } catch { }
    }
} | Sort-Object Version -Descending | Select-Object -First 1 -ExpandProperty Script
if (-not `$tray) { `$tray = '$fallback' }
& `$tray
"@ | Set-Content -Path $Launcher -Encoding UTF8
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($StartupLnk)
    $lnk.TargetPath = (Get-Command powershell.exe).Source
    $lnk.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Launcher`""
    $lnk.WorkingDirectory = $StateDir
    $lnk.Save()
}

if ($Autostart) { Set-Autostart ($Autostart -eq 'on'); exit 0 }
# Without this Windows bitmap-stretches the popup on scaled displays and it looks blurry.
Add-Type -Namespace RamSleeper -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[RamSleeper.Dpi]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# One tray icon per user: a second copy just exits.
if (-not $Snapshot) {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\RamSleeperTray')
    if (-not $mutex.WaitOne(0)) { exit }
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    Set-Content -Path $PidFile -Value $PID
}

$Script = Join-Path $PSScriptRoot '..\..\skills\ramsleeper\scripts\sessions.mjs' | Resolve-Path | ForEach-Object Path
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $Node) {
    [System.Windows.Forms.MessageBox]::Show('RAM Sleeper needs Node.js 18 or newer on PATH.', 'RAM Sleeper') | Out-Null
    exit 1
}

$RU = (Get-UICulture).TwoLetterISOLanguageName -eq 'ru'
$T = if ($RU) { @{
    title = 'Сессии Claude Code'; unload = 'Выгрузить'; interrupt = 'Прервать'
    busyWarn = 'Сессия сейчас работает: текущий ход оборвётся. Переписка до него сохранится.'
    busy = 'работает'; idle = 'ждёт'; mb = 'МБ'; gb = 'ГБ'
    self = 'claude — сама сессия'
    adviceMcp = '{0} запущен в {1} сессиях и занимает {2}. Если он нужен не везде, подключите его только в нужных проектах.'
    adviceLaunchers = 'Запускалки npx/uvx держат {0} в {1} сессиях. Установите MCP-серверы глобально, и эта память освободится.'
    launcherHint = '{0} здесь держат запускалки npx/uvx рядом с MCP-серверами. Если установить серверы глобально, эта память освободится.'
    refresh = 'Обновить'; dashboard = 'Открыть панель'; autostart = 'Запускать при входе в Windows'; exit = 'Выход'
    tip = 'Ждут {0} из {1} сессий · {2} ({3:0}% памяти)'
    legend = 'Цифра на значке — сколько сессий ждут {0}+ мин: их можно выгрузить. Цвет — какую долю всей памяти компьютера занимают сессии: зелёный до {1}%, жёлтый до {2}%, красный больше.'
    none = 'Запущенных сессий нет'; loading = 'Загрузка…'; updated = 'обновлено'; app = 'приложение Claude'
    confirmTitle = 'Выгрузить сессию?'; frees = 'Освободится около {0} ({1} процессов).'
    flagged = 'Остановится и это (не MCP-сервер):'; keep = 'Переписка останется в транскрипте.'
    resume = 'Чтобы вернуть: откройте сессию в приложении Claude и напишите сообщение — она снова загрузится в память с той же перепиской.'
    done = 'Выгружено: {0}, освобождено ~{1}'; failed = 'Не удалось: {0}'; procs = 'проц.'
} } else { @{
    title = 'Claude Code sessions'; unload = 'Unload'; interrupt = 'Interrupt'
    busyWarn = 'This session is working: the running turn will be cut off. The conversation up to it is kept.'
    busy = 'busy'; idle = 'idle'; mb = 'MB'; gb = 'GB'
    self = 'claude, the session itself'
    adviceMcp = '{0} runs in {1} sessions and holds {2}. If you don''t need it everywhere, enable it only in the projects that use it.'
    adviceLaunchers = 'npx/uvx launchers hold {0} across {1} sessions. Install the MCP servers globally to free it.'
    launcherHint = '{0} here is held by npx/uvx launchers next to the MCP servers. Installing the servers globally frees it.'
    refresh = 'Refresh'; dashboard = 'Open dashboard'; autostart = 'Start at Windows sign-in'; exit = 'Exit'
    tip = '{0} of {1} sessions idle · {2} ({3:0}% of memory)'
    legend = 'The number on the icon is how many sessions have been idle {0}+ minutes, ready to unload. The color is the share of the computer''s total memory all sessions hold: green under {1}%, amber under {2}%, red above.'
    none = 'No running sessions'; loading = 'Loading…'; updated = 'updated'; app = 'Claude app'
    confirmTitle = 'Unload this session?'; frees = 'Frees about {0} ({1} processes).'
    flagged = 'This stops too (not an MCP server):'; keep = 'The conversation stays in its transcript.'
    resume = 'To bring it back: open the session in the Claude app and send a message. It loads back into memory with the same conversation.'
    done = 'Unloaded {0}, ~{1} freed'; failed = 'Failed: {0}'; procs = 'proc.'
} }

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { '{0:0.0} {1}' -f ($bytes / 1GB), $T.gb } else { '{0:0} {1}' -f ($bytes / 1MB), $T.mb }
}

# Runs sessions.mjs and returns its stdout as UTF-8 text.
function Invoke-Sessions([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Node
    $psi.Arguments = (@("`"$Script`"") + $Arguments) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $out
}

# ------------------------------------------------------------------ colors
$dark = $true
try { $dark = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme) -eq 0 } catch {}
if ($dark) {
    $C = @{ bg = [Drawing.Color]::FromArgb(32, 32, 32); fg = [Drawing.Color]::FromArgb(240, 240, 240); muted = [Drawing.Color]::FromArgb(160, 160, 160)
            line = [Drawing.Color]::FromArgb(60, 60, 60); bar = [Drawing.Color]::FromArgb(229, 138, 99); btn = [Drawing.Color]::FromArgb(50, 50, 50)
            busy = [Drawing.Color]::FromArgb(224, 168, 74); idle = [Drawing.Color]::FromArgb(108, 192, 141) }
} else {
    $C = @{ bg = [Drawing.Color]::FromArgb(250, 250, 250); fg = [Drawing.Color]::FromArgb(28, 28, 28); muted = [Drawing.Color]::FromArgb(110, 110, 110)
            line = [Drawing.Color]::FromArgb(225, 225, 225); bar = [Drawing.Color]::FromArgb(200, 100, 60); btn = [Drawing.Color]::FromArgb(236, 236, 236)
            busy = [Drawing.Color]::FromArgb(168, 107, 0); idle = [Drawing.Color]::FromArgb(47, 125, 79) }
}
$gfx = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:K = $gfx.DpiX / 96
$gfx.Dispose()
# Fonts are in points, which Windows already scales for DPI; Scale() handles the pixel layout.
$FontUi = New-Object Drawing.Font('Segoe UI', 9)
$FontBold = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
$FontHead = New-Object Drawing.Font('Segoe UI Semibold', 11)

# ------------------------------------------------------------------ tray icon
# The icon is drawn at the tray's native size (16 px at 100 % scaling) with
# one or two crisp digits: how many sessions have been idle for a few minutes,
# the ones worth unloading. The threshold comes from sessions.mjs (3 minutes by
# default, changed on the setup page or with RAMSLEEPER_IDLE_MINUTES), so the
# tray, the menu bar and the setup page always agree. The background shows how
# much of the machine's RAM all sessions hold: green under 15 %, amber under
# 30 %, red above. The tooltip has the exact figures.
function Get-IdleMinutes {
    if ($script:data -and $script:data.idleMinutes -gt 0) { [int]$script:data.idleMinutes } else { 3 }
}

# Color bands (share of total RAM), set on the setup page; 15 % and 30 % by default.
function Get-Levels {
    if ($script:data -and $script:data.levels) { @{ warn = [int]$script:data.levels.warnPct; high = [int]$script:data.levels.highPct } } else { @{ warn = 15; high = 30 } }
}

function Get-SleepySessions {
    $now = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $after = (Get-IdleMinutes) * 60 * 1000
    @($script:data.sessions) | Where-Object {
        $_ -and $_.status -eq 'idle' -and -not $_.current -and $_.lastActivityAt -and ($now - $_.lastActivityAt) -ge $after
    }
}
$Level = @{
    ok   = [Drawing.Color]::FromArgb(46, 160, 67)
    warn = [Drawing.Color]::FromArgb(210, 140, 20)
    high = [Drawing.Color]::FromArgb(200, 50, 45)
    none = [Drawing.Color]::FromArgb(110, 110, 110)
}

function New-TrayIcon([string]$text, [Drawing.Color]$bg, [int]$Size = 0) {
    $n = if ($Size -gt 0) { $Size } else { [System.Windows.Forms.SystemInformation]::SmallIconSize.Width }
    $bmp = New-Object Drawing.Bitmap $n, $n
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $r = [Math]::Max(3, [int]($n / 4))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($n - 1 - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($n - 1 - 2 * $r, $n - 1 - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc(0, $n - 1 - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush($bg)), $path)
    # Pixel-snapped text stays sharp at tray size; larger renders can be smooth.
    $g.TextRenderingHint = if ($n -ge 24) { 'AntiAliasGridFit' } else { 'SingleBitPerPixelGridFit' }
    $font = if ($text.Length -le 1) {
        New-Object Drawing.Font('Segoe UI', [float]($n * 0.94), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    } else {
        New-Object Drawing.Font('Arial Narrow', [float]($n * 0.82), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    }
    $sf = New-Object Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'; $sf.FormatFlags = 'NoWrap'
    $g.DrawString($text, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(-2, 0.5, ($n + 4), $n)), $sf)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon '·' $Level.none
$tray.Text = 'RAM Sleeper'
$tray.Visible = -not $Snapshot

# ------------------------------------------------------------------ popup
$popup = New-Object System.Windows.Forms.Form
$popup.FormBorderStyle = 'None'
$popup.ShowInTaskbar = $false
$popup.TopMost = $true
$popup.StartPosition = 'Manual'
$popup.BackColor = $C.bg
$popup.ForeColor = $C.fg
$popup.Width = 440
$popup.Padding = New-Object System.Windows.Forms.Padding(1)
$popup.Add_Deactivate({ $popup.Hide() })
$popup.Add_Paint({ param($s, $e) $e.Graphics.DrawRectangle((New-Object Drawing.Pen($C.line)), 0, 0, $popup.Width - 1, $popup.Height - 1) })

$script:data = $null
$script:updatedAt = $null
$script:openRows = @{}
$script:trash = New-Object System.Collections.ArrayList

function Add-Label($parent, [string]$text, $font, $color, [int]$x, [int]$y, [int]$w, [string]$align = 'MiddleLeft') {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.AutoSize = $false
    $l.AutoEllipsis = $true; $l.TextAlign = $align
    $l.SetBounds($x, $y, $w, 20)
    $parent.Controls.Add($l)
    $l
}

function Add-Button($parent, [string]$text, [int]$x, [int]$y, [int]$w, [scriptblock]$onClick) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Font = $FontUi; $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderColor = $C.line; $b.BackColor = $C.btn; $b.ForeColor = $C.fg
    $b.SetBounds($x, $y, $w, 26)
    $b.Add_Click($onClick)
    $parent.Controls.Add($b)
    $b
}

function Build-Popup {
    $popup.SuspendLayout()
    # Clear() only detaches controls; undisposed ones would leak window handles
    # in a process that runs for days. They are disposed a moment later from the
    # timer, because a rebuild can start inside a click on one of them.
    foreach ($old in @($popup.Controls)) { [void]$script:trash.Add($old) }
    $popup.Controls.Clear()
    $popup.Width = 440
    $pad = 14; $y = 12; $w = $popup.Width
    $sessions = @()
    if ($script:data) { $sessions = @($script:data.sessions) }
    $total = ($sessions | Measure-Object memBytes -Sum).Sum
    Add-Label $popup $T.title $FontHead $C.fg $pad $y 250 | Out-Null
    if ($script:data) { Add-Label $popup (Format-Size $total) $FontHead $C.fg ($w - 150 - $pad) $y 150 'MiddleRight' | Out-Null }
    $y += 26
    # Explains the tray icon, which is too small to label.
    $lv = Get-Levels
    $legend = $T.legend -f (Get-IdleMinutes), $lv.warn, $lv.high
    $lg = Add-Label $popup $legend $FontUi $C.muted $pad $y ($w - 2 * $pad)
    $lg.Height = [System.Windows.Forms.TextRenderer]::MeasureText($legend, $FontUi, (New-Object Drawing.Size(($w - 2 * $pad), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height + 4
    $y += $lg.Height + 6

    if (-not $script:data) {
        Add-Label $popup $T.loading $FontUi $C.muted $pad $y 300 | Out-Null; $y += 28
    } elseif ($sessions.Count -eq 0) {
        Add-Label $popup $T.none $FontUi $C.muted $pad $y 300 | Out-Null; $y += 28
    } else {
        $max = ($sessions | Measure-Object memBytes -Maximum).Maximum
        foreach ($s in $sessions) {
            $sep = New-Object System.Windows.Forms.Panel
            $sep.BackColor = $C.line; $sep.SetBounds($pad, $y, $w - 2 * $pad, 1); $popup.Controls.Add($sep)
            $y += 8
            # Clicking the title shows what the session's memory is made of.
            $isOpen = $script:openRows.ContainsKey([int]$s.pid)
            $mark = if ($isOpen) { [char]0x25BE } else { [char]0x25B8 }
            $tl = Add-Label $popup ("$mark " + $s.title) $FontBold $C.fg $pad $y ($w - 2 * $pad - 100)
            $tl.Cursor = [System.Windows.Forms.Cursors]::Hand
            $tl.Tag = [int]$s.pid
            $tl.Add_Click({
                $id = [int]$this.Tag
                if ($script:openRows.ContainsKey($id)) { $script:openRows.Remove($id) } else { $script:openRows[$id] = $true }
                Build-Popup
            })
            $status = if ($s.status -eq 'busy') { $T.busy } else { $T.idle }
            if ($s.status -ne 'busy' -and $s.lastActivityAt) {
                $mins = ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $s.lastActivityAt) / 60000
                if ($mins -ge 1) { $status += ' ' + $(if ($mins -lt 90) { '{0:0} min' -f $mins } elseif ($mins -lt 2160) { '{0:0} h' -f ($mins / 60) } else { '{0:0} d' -f ($mins / 1440) }) }
            }
            $info = '{0} · {1} {2} · ' -f (Format-Size $s.memBytes), $s.processCount, $T.procs
            $l = Add-Label $popup ($info + $status) $FontUi $C.muted $pad ($y + 20) 230
            if ($s.status -eq 'busy') { $l.ForeColor = $C.busy }
            $bar = New-Object System.Windows.Forms.Panel
            $bar.BackColor = $C.bar
            $bar.SetBounds($pad, $y + 44, [Math]::Max(4, [int](($w - 2 * $pad - 100) * $s.memBytes / $max)), 4)
            $popup.Controls.Add($bar)
            if (-not $s.current) {
                $label = if ($s.status -eq 'busy') { $T.interrupt } else { $T.unload }
                $b = Add-Button $popup $label ($w - $pad - 90) ($y + 10) 90 { Confirm-Unload ([int]$this.Tag) }
                $b.Tag = [int]$s.pid
            }
            $y += 56
            if ($isOpen) {
                $parts = @(@{ label = $T.self; memBytes = $s.ownMemBytes; processCount = 1 }) + @($s.groups)
                foreach ($g in $parts) {
                    Add-Label $popup ([string]$g.label) $FontUi $C.fg ($pad + 14) $y ($w - 2 * $pad - 150) | Out-Null
                    Add-Label $popup ('{0} · {1} {2}' -f (Format-Size $g.memBytes), $g.processCount, $T.procs) $FontUi $C.muted ($w - $pad - 136) $y 136 'MiddleRight' | Out-Null
                    $y += 20
                }
                if ($s.launcherBytes -ge 50MB) {
                    $hint = $T.launcherHint -f (Format-Size $s.launcherBytes)
                    $hl = Add-Label $popup $hint $FontUi $C.busy ($pad + 14) ($y + 2) ($w - 2 * $pad - 14)
                    $hl.Height = [System.Windows.Forms.TextRenderer]::MeasureText($hint, $FontUi, (New-Object Drawing.Size(($w - 2 * $pad - 14), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height + 4
                    $y += $hl.Height + 4
                }
                $y += 8
            }
        }
    }

    # Ways to save memory without unloading anything, worked out by sessions.mjs.
    if ($script:data) {
        foreach ($a in @($script:data.advice)) {
            if (-not $a) { continue }
            $text = if ($a.type -eq 'launchers') { $T.adviceLaunchers -f (Format-Size $a.memBytes), $a.sessions }
                    else { $T.adviceMcp -f $a.label, $a.sessions, (Format-Size $a.memBytes) }
            $al = Add-Label $popup $text $FontUi $C.busy $pad $y ($w - 2 * $pad)
            $al.Height = [System.Windows.Forms.TextRenderer]::MeasureText($text, $FontUi, (New-Object Drawing.Size(($w - 2 * $pad), 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height + 4
            $y += $al.Height + 6
        }
    }

    $sep = New-Object System.Windows.Forms.Panel
    $sep.BackColor = $C.line; $sep.SetBounds(0, $y, $w, 1); $popup.Controls.Add($sep)
    $y += 10
    $foot = if ($script:updatedAt) { '{0} {1:HH:mm:ss}' -f $T.updated, $script:updatedAt } else { '' }
    if ($script:data -and $script:data.app) { $foot = '{0} {1} · {2}' -f $T.app, (Format-Size $script:data.app.memBytes), $foot }
    # Own row at full width: next to the buttons the text did not fit.
    Add-Label $popup $foot $FontUi $C.muted $pad $y ($w - 2 * $pad) | Out-Null
    $y += 26
    Add-Button $popup $T.refresh ($w - $pad - 214) $y 90 { Start-Refresh } | Out-Null
    Add-Button $popup $T.dashboard ($w - $pad - 118) $y 118 { Open-Dashboard } | Out-Null
    $y += 38

    $popup.Height = $y
    # Layout is in 96-DPI pixels; scale it once for the screen's DPI.
    if ($script:K -ne 1) { $popup.Scale((New-Object Drawing.SizeF($script:K, $script:K))) }
    $area = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $popup.Location = New-Object Drawing.Point(($area.Right - $popup.Width - 12), ($area.Bottom - $popup.Height - 12))
    $popup.ResumeLayout()
}

function Show-Popup {
    Build-Popup
    $popup.Show()
    $popup.Activate()
    Start-Refresh
}

# ------------------------------------------------------------------ refresh
# The process query takes a few seconds, so it runs on a background runspace
# and a UI timer picks up the result.
$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$script:job = $null

function Start-Refresh {
    if ($script:job) { return }
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript({
        param($node, $script)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node; $psi.Arguments = "`"$script`" list --json"
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit(); $out
    }).AddArgument($Node).AddArgument($Script) | Out-Null
    $script:job = @{ ps = $ps; handle = $ps.BeginInvoke() }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$script:ticks = 0
$timer.Add_Tick({
    if ($script:trash.Count) { foreach ($old in @($script:trash)) { $old.Dispose() }; $script:trash.Clear() }
    $script:ticks++
    if ($script:ticks -ge 60) { $script:ticks = 0; Start-Refresh }   # every 30 s
    if ($script:job -and $script:job.handle.IsCompleted) {
        try {
            $out = ($script:job.ps.EndInvoke($script:job.handle) | Out-String)
            $script:data = $out | ConvertFrom-Json
            $script:updatedAt = Get-Date
            $total = (@($script:data.sessions) | Measure-Object memBytes -Sum).Sum
            $sleepy = @(Get-SleepySessions).Count
            $label = if ($sleepy -gt 99) { '99' } else { [string]$sleepy }
            $share = if ($script:data.systemMemBytes) { $total / $script:data.systemMemBytes } else { 0 }
            $lv = Get-Levels
            $bg = if ($share * 100 -ge $lv.high) { $Level.high } elseif ($share * 100 -ge $lv.warn) { $Level.warn } else { $Level.ok }
            $old = $tray.Icon
            $tray.Icon = New-TrayIcon $label $bg
            $old.Dispose()
            $tip = $T.tip -f $sleepy, @($script:data.sessions).Count, (Format-Size $total), ($share * 100)
            $tray.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
            if ($popup.Visible) { Build-Popup }
        } catch { }
        $script:job.ps.Dispose()
        $script:job = $null
    }
})
$timer.Start()

# ------------------------------------------------------------------ actions
function Confirm-Unload([int]$sessionPid) {
    $s = @($script:data.sessions) | Where-Object { $_.pid -eq $sessionPid } | Select-Object -First 1
    if (-not $s) { return }
    $busy = $s.status -eq 'busy'
    $lines = @($s.title, '')
    if ($busy) { $lines += $T.busyWarn; $lines += '' }
    $lines += ($T.frees -f (Format-Size $s.memBytes), $s.processCount)
    $flagged = @($s.children | Where-Object { $_.notable })
    if ($flagged.Count) { $lines += ''; $lines += $T.flagged; $lines += ($flagged | ForEach-Object { '  ' + ($(if ($_.cmd) { $_.cmd } else { $_.name })) }) }
    $lines += ''; $lines += $T.keep; $lines += $T.resume
    $popup.TopMost = $false
    $answer = [System.Windows.Forms.MessageBox]::Show(($lines -join "`n"), $T.confirmTitle, 'YesNo', 'Question', 'Button2')
    $popup.TopMost = $true
    if ($answer -ne 'Yes') { return }
    # Same checks as the plugin: the script refuses busy sessions and re-verifies the PID.
    # --expect binds the unload to the session that was shown, in case its PID changed hands.
    $argv = @('unload', $s.pid, "--expect=$($s.sessionId)", '--yes', '--json')
    if ($busy) { $argv += '--force' }
    $result = Invoke-Sessions $argv | ConvertFrom-Json
    if ($result.ok) {
        $tray.ShowBalloonTip(5000, 'RAM Sleeper', ($T.done -f $s.title, (Format-Size $result.freedBytes)), 'Info')
    } else {
        $tray.ShowBalloonTip(5000, 'RAM Sleeper', ($T.failed -f $result.error), 'Warning')
    }
    Start-Refresh
}

function Open-Dashboard {
    $popup.Hide()
    Start-Process -FilePath $Node -ArgumentList "`"$Script`"", 'serve' -WindowStyle Hidden
}

# ------------------------------------------------------------------ menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add($T.dashboard, $null, { Open-Dashboard }) | Out-Null
$menu.Items.Add($T.refresh, $null, { Start-Refresh }) | Out-Null
$auto = New-Object System.Windows.Forms.ToolStripMenuItem($T.autostart)
$auto.Checked = Test-Path $StartupLnk
$auto.Add_Click({ Set-Autostart (-not $auto.Checked); $auto.Checked = Test-Path $StartupLnk })
$menu.Items.Add($auto) | Out-Null
$menu.Items.Add('-') | Out-Null
$menu.Items.Add($T.exit, $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() }) | Out-Null
$tray.ContextMenuStrip = $menu

$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq 'Left') { if ($popup.Visible) { $popup.Hide() } else { Show-Popup } }
})

if ($Snapshot) {
    $script:data = Invoke-Sessions @('list', '--json') | ConvertFrom-Json
    $script:updatedAt = Get-Date
    # The first session is shown expanded, so the screenshot includes the breakdown.
    if (@($script:data.sessions).Count) { $script:openRows[[int]@($script:data.sessions)[0].pid] = $true }
    Build-Popup
    $popup.Location = New-Object Drawing.Point(-4000, -4000)
    $popup.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $pw = $popup.Width; $ph = $popup.Height
    $shot = New-Object Drawing.Bitmap($pw + 200), ([Math]::Max($ph, 400))
    $g = [Drawing.Graphics]::FromImage($shot)
    $g.Clear($C.bg)
    $pb = New-Object Drawing.Bitmap $pw, $ph
    $popup.DrawToBitmap($pb, (New-Object Drawing.Rectangle 0, 0, $pw, $ph))
    $g.DrawImage($pb, 0, 0)
    # Beside the popup: the icon in each color, drawn at 32 px (no upscaling), with what the color means.
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $cap = New-Object Drawing.SolidBrush($C.muted)
    $yy = 20
    $lv = Get-Levels
    foreach ($v in @(@('2', $Level.ok, ('< {0}% RAM' -f $lv.warn)), @('7', $Level.warn, ('< {0}% RAM' -f $lv.high)), @('12', $Level.high, ('{0}%+ RAM' -f $lv.high)))) {
        $ic = New-TrayIcon $v[0] $v[1] 32
        $g.DrawImage($ic.ToBitmap(), ($pw + 28), $yy)
        $g.DrawString($v[2], $FontUi, $cap, ($pw + 70), ($yy + 7))
        $yy += 52
    }
    $shot.Save($Snapshot, [Drawing.Imaging.ImageFormat]::Png)
    $popup.Close()
    exit 0
}
Start-Refresh
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$rs.Close()
Remove-Item $PidFile -ErrorAction SilentlyContinue
if ($mutex) { $mutex.ReleaseMutex() }
