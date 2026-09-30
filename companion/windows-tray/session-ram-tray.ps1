# Session RAM tray companion for Windows.
#
# Shows the total memory of all Claude Code sessions in the notification area.
# Left click opens a popup with every session and an Unload button; right click
# offers the full dashboard, start-at-login and exit. All data comes from the
# plugin's sessions.mjs, so the tray and the plugin always agree.
#
# Run:  powershell -NoProfile -STA -WindowStyle Hidden -File session-ram-tray.ps1

$ErrorActionPreference = 'Stop'
# Without this Windows bitmap-stretches the popup on scaled displays and it looks blurry.
Add-Type -Namespace SessionRam -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[SessionRam.Dpi]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# One tray icon per user: a second copy just exits.
$mutex = New-Object System.Threading.Mutex($false, 'Local\SessionRamTray')
if (-not $mutex.WaitOne(0)) { exit }

$Script = Join-Path $PSScriptRoot '..\..\skills\session-ram\scripts\sessions.mjs' | Resolve-Path | ForEach-Object Path
$Node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $Node) {
    [System.Windows.Forms.MessageBox]::Show('Session RAM needs Node.js 18 or newer on PATH.', 'Session RAM') | Out-Null
    exit 1
}

$RU = (Get-UICulture).TwoLetterISOLanguageName -eq 'ru'
$T = if ($RU) { @{
    title = 'Сессии Claude Code'; unload = 'Выгрузить'; busy = 'работает'; idle = 'ждёт'; mb = 'МБ'; gb = 'ГБ'
    refresh = 'Обновить'; dashboard = 'Открыть панель'; autostart = 'Запускать при входе в Windows'; exit = 'Выход'
    none = 'Запущенных сессий нет'; loading = 'Загрузка…'; updated = 'обновлено'; app = 'приложение Claude'
    confirmTitle = 'Выгрузить сессию?'; frees = 'Освободится около {0} ({1} процессов).'
    flagged = 'Остановится и это (не MCP-сервер):'; keep = 'Переписка останется в транскрипте.'
    resume = 'Чтобы продолжить: откройте сессию в боковой панели приложения Claude и отправьте сообщение.'
    done = 'Выгружено: {0}, освобождено ~{1}'; failed = 'Не удалось: {0}'; procs = 'проц.'
} } else { @{
    title = 'Claude Code sessions'; unload = 'Unload'; busy = 'busy'; idle = 'idle'; mb = 'MB'; gb = 'GB'
    refresh = 'Refresh'; dashboard = 'Open dashboard'; autostart = 'Start at Windows sign-in'; exit = 'Exit'
    none = 'No running sessions'; loading = 'Loading…'; updated = 'updated'; app = 'Claude app'
    confirmTitle = 'Unload this session?'; frees = 'Frees about {0} ({1} processes).'
    flagged = 'This stops too (not an MCP server):'; keep = 'The conversation stays in its transcript.'
    resume = 'To continue: open the session in the Claude app sidebar and send a message.'
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
# whole gigabytes as one or two crisp digits; the exact figure is in the
# tooltip. The background shows how much of the machine's RAM the sessions
# hold: green under 15 %, amber under 30 %, red above.
$Level = @{
    ok   = [Drawing.Color]::FromArgb(46, 160, 67)
    warn = [Drawing.Color]::FromArgb(210, 140, 20)
    high = [Drawing.Color]::FromArgb(200, 50, 45)
    none = [Drawing.Color]::FromArgb(110, 110, 110)
}

function New-TrayIcon([string]$text, [Drawing.Color]$bg) {
    $n = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
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
    # Pixel-snapped text without anti-aliasing stays sharp at 16 px.
    $g.TextRenderingHint = 'SingleBitPerPixelGridFit'
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
$tray.Text = 'Session RAM'
$tray.Visible = $true

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
    $popup.Controls.Clear()
    $popup.Width = 440
    $pad = 14; $y = 12; $w = $popup.Width
    $sessions = @()
    if ($script:data) { $sessions = @($script:data.sessions) }
    $total = ($sessions | Measure-Object memBytes -Sum).Sum
    Add-Label $popup $T.title $FontHead $C.fg $pad $y 250 | Out-Null
    if ($script:data) { Add-Label $popup (Format-Size $total) $FontHead $C.fg ($w - 150 - $pad) $y 150 'MiddleRight' | Out-Null }
    $y += 30

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
            Add-Label $popup $s.title $FontBold $C.fg $pad $y ($w - 2 * $pad - 100) | Out-Null
            $status = if ($s.status -eq 'busy') { $T.busy } else { $T.idle }
            $info = '{0} · {1} {2} · ' -f (Format-Size $s.memBytes), $s.processCount, $T.procs
            $l = Add-Label $popup ($info + $status) $FontUi $C.muted $pad ($y + 20) 230
            if ($s.status -eq 'busy') { $l.ForeColor = $C.busy }
            $bar = New-Object System.Windows.Forms.Panel
            $bar.BackColor = $C.bar
            $bar.SetBounds($pad, $y + 44, [Math]::Max(4, [int](($w - 2 * $pad - 100) * $s.memBytes / $max)), 4)
            $popup.Controls.Add($bar)
            if ($s.status -ne 'busy' -and -not $s.current) {
                $b = Add-Button $popup $T.unload ($w - $pad - 90) ($y + 10) 90 { Confirm-Unload ([int]$this.Tag) }
                $b.Tag = [int]$s.pid
            }
            $y += 56
        }
    }

    $sep = New-Object System.Windows.Forms.Panel
    $sep.BackColor = $C.line; $sep.SetBounds(0, $y, $w, 1); $popup.Controls.Add($sep)
    $y += 10
    $foot = if ($script:updatedAt) { '{0} {1:HH:mm:ss}' -f $T.updated, $script:updatedAt } else { '' }
    if ($script:data -and $script:data.app) { $foot = '{0} {1} · {2}' -f $T.app, (Format-Size $script:data.app.memBytes), $foot }
    Add-Label $popup $foot $FontUi $C.muted $pad ($y + 3) 200 | Out-Null
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
    $script:ticks++
    if ($script:ticks -ge 60) { $script:ticks = 0; Start-Refresh }   # every 30 s
    if ($script:job -and $script:job.handle.IsCompleted) {
        try {
            $out = ($script:job.ps.EndInvoke($script:job.handle) | Out-String)
            $script:data = $out | ConvertFrom-Json
            $script:updatedAt = Get-Date
            $total = (@($script:data.sessions) | Measure-Object memBytes -Sum).Sum
            $gb = [Math]::Round($total / 1GB)
            $label = if ($gb -gt 99) { '99' } else { [string][int]$gb }
            $share = if ($script:data.systemMemBytes) { $total / $script:data.systemMemBytes } else { 0 }
            $bg = if ($share -ge 0.30) { $Level.high } elseif ($share -ge 0.15) { $Level.warn } else { $Level.ok }
            $old = $tray.Icon
            $tray.Icon = New-TrayIcon $label $bg
            $old.Dispose()
            $tip = 'Session RAM · {0} · {1} ({2:0}% RAM)' -f @($script:data.sessions).Count, (Format-Size $total), ($share * 100)
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
    $lines = @($s.title, '', ($T.frees -f (Format-Size $s.memBytes), $s.processCount))
    $flagged = @($s.children | Where-Object { $_.cmd -notmatch 'mcp' -and $_.name -notmatch '^(conhost|cmd|powershell|pwsh|bash|uv|uvx|npx|npm|node|python\d?)(\.exe)?$' })
    if ($flagged.Count) { $lines += ''; $lines += $T.flagged; $lines += ($flagged | ForEach-Object { '  ' + ($(if ($_.cmd) { $_.cmd } else { $_.name })) }) }
    $lines += ''; $lines += $T.keep; $lines += $T.resume
    $popup.TopMost = $false
    $answer = [System.Windows.Forms.MessageBox]::Show(($lines -join "`n"), $T.confirmTitle, 'YesNo', 'Question', 'Button2')
    $popup.TopMost = $true
    if ($answer -ne 'Yes') { return }
    # Same checks as the plugin: the script refuses busy sessions and re-verifies the PID.
    $result = Invoke-Sessions @('unload', $s.pid, '--yes', '--json') | ConvertFrom-Json
    if ($result.ok) {
        $tray.ShowBalloonTip(5000, 'Session RAM', ($T.done -f $s.title, (Format-Size $result.freedBytes)), 'Info')
    } else {
        $tray.ShowBalloonTip(5000, 'Session RAM', ($T.failed -f $result.error), 'Warning')
    }
    Start-Refresh
}

function Open-Dashboard {
    $popup.Hide()
    Start-Process -FilePath $Node -ArgumentList "`"$Script`"", 'serve' -WindowStyle Hidden
}

$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Session RAM.lnk'
function Set-Autostart([bool]$on) {
    if ($on) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($startup)
        $lnk.TargetPath = (Get-Command powershell.exe).Source
        $lnk.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.Save()
    } elseif (Test-Path $startup) {
        Remove-Item $startup
    }
}

# ------------------------------------------------------------------ menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add($T.dashboard, $null, { Open-Dashboard }) | Out-Null
$menu.Items.Add($T.refresh, $null, { Start-Refresh }) | Out-Null
$auto = New-Object System.Windows.Forms.ToolStripMenuItem($T.autostart)
$auto.Checked = Test-Path $startup
$auto.Add_Click({ Set-Autostart (-not $auto.Checked); $auto.Checked = Test-Path $startup })
$menu.Items.Add($auto) | Out-Null
$menu.Items.Add('-') | Out-Null
$menu.Items.Add($T.exit, $null, { $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() }) | Out-Null
$tray.ContextMenuStrip = $menu

$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq 'Left') { if ($popup.Visible) { $popup.Hide() } else { Show-Popup } }
})

Start-Refresh
[System.Windows.Forms.Application]::Run()
$tray.Dispose()
$rs.Close()
$mutex.ReleaseMutex()
