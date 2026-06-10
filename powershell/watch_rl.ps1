# ============================================================================
#  watch_rl.ps1 -- rldash, PowerShell flavor: live ASCII dashboard for RL
#  training that runs INSIDE WSL, watched from a native Windows console.
#  Tails the training log via a WSL-side snapshot script + nvidia-smi and
#  draws bars, a sparkline, and a GPU gauge. Ctrl-C to quit.
#
#  Setup:    copy wsl_snapshot.sh into WSL, e.g.
#              wsl cp /mnt/c/path/to/wsl_snapshot.sh ~/myproj/
#  Run it:   powershell -NoExit -ExecutionPolicy Bypass -File watch_rl.ps1 `
#              -Snapshot '~/myproj/wsl_snapshot.sh' -Title 'MY RUN'
#  Test it:  watch_rl.ps1 -Plain -Iterations 1
# ============================================================================
param(
  [int]$Iterations = 0,        # 0 = run forever
  [int]$IntervalMs = 2500,
  [switch]$Plain,              # no cursor control (for testing / piping)
  [string]$Title = 'R L   T R A I N I N G',
  # WSL-side snapshot helper (see wsl_snapshot.sh in this folder)
  [string]$Snapshot = '~/pendchain/scripts/watch_snapshot.sh',
  # AUTO = follow the most recently written log (whatever is training now)
  [string]$Log  = 'AUTO',
  [string]$Drv  = 'AUTO',
  [string]$Distro = 'Ubuntu-22.04'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$e = [char]27

# enable ANSI / virtual-terminal processing so colours + cursor codes work
# even in old conhost (Windows Terminal already has it on).
try {
  $sig = '[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h,out uint m);' +
         '[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h,uint m);' +
         '[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);'
  $k = Add-Type -MemberDefinition $sig -Name VT -Namespace Win32 -PassThru
  $h = $k::GetStdHandle(-11); $m = 0
  [void]$k::GetConsoleMode($h, [ref]$m)
  [void]$k::SetConsoleMode($h, $m -bor 0x4)
} catch { }

$C = @{ cyan="$e[96m"; green="$e[92m"; yellow="$e[93m"; red="$e[91m";
        gray="$e[90m"; mag="$e[95m"; bold="$e[1m"; dim="$e[2m"; rst="$e[0m";
        blue="$e[94m" }

function Bar($val, $max, $w) {
  if ($max -le 0) { $max = 1 }
  $frac = [math]::Max(0.0, [math]::Min(1.0, $val / $max))
  $full = [int][math]::Floor($frac * $w)
  $parts = ' ','▏','▎','▍','▌','▋','▊','▉','█'
  $p = ''
  if ($full -lt $w) { $p = $parts[[int][math]::Round((($frac * $w) - $full) * 8)] }
  $bar = ('█' * $full) + $p
  if ($bar.Length -gt $w) { $bar = $bar.Substring(0, $w) }
  return $bar.PadRight($w, '░')
}

function Spark($arr) {
  $ch = ' ','▁','▂','▃','▄','▅','▆','▇','█'
  if ($arr.Count -eq 0) { return '' }
  $mn = ($arr | Measure-Object -Minimum).Minimum
  $mx = ($arr | Measure-Object -Maximum).Maximum
  $rng = $mx - $mn; if ($rng -le 0) { $rng = 1 }
  -join ($arr | ForEach-Object { $ch[[int][math]::Round(((($_ - $mn) / $rng)) * 8)] })
}

function Get-Snapshot {
  # All selection logic lives in a WSL-side script -- inline bash through
  # wsl.exe arg-quoting is a minefield (see repo history). AUTO = newest log.
  $args = @('-d', $Distro, '--', 'bash', $Snapshot)
  if ($Log -ne 'AUTO') { $args += $Log }
  $raw = (wsl.exe @args) -join "`n"
  $parts = $raw -split '@@@'
  if ($parts.Count -lt 4) { return @{ name=''; upd=''; gpu=''; mark='' } }
  return @{ name = $parts[0].Trim(); upd = $parts[1].Trim();
            gpu = ($parts[2]).Trim(); mark = ($parts[3]).Trim() }
}

function Parse-Upd($line) {
  $d = @{}
  $pat = @{
    upd='upd\s+(\d+)/(\d+)'; step='step\s+([\d,]+)'; sps='SPS\s+([\d,]+)';
    epret='ep_ret\s+(-?[\d.]+)'; eplen='ep_len\s+([\d.]+)'; sang='start_ang\s+([\d.]+)';
    rps='rps\s+(-?[\d.]+)'; vloss='v_loss\s+(-?[\d.]+)'; ev='EV\s+([+\-]?[\d.]+)';
    logstd='logstd\s+([+\-]?[\d.]+)'
  }
  foreach ($k in $pat.Keys) {
    $mm = [regex]::Match($line, $pat[$k])
    if ($mm.Success) { $d[$k] = $mm.Groups[1].Value; if ($k -eq 'upd') { $d['updtot'] = $mm.Groups[2].Value } }
  }
  return $d
}

$hist = New-Object System.Collections.ArrayList
$start = Get-Date
$iter = 0
$lastName = ''
if (-not $Plain) { Write-Host "$e[2J$e[H" -NoNewline }

while ($true) {
  $iter++
  $snap = Get-Snapshot
  if ($snap.name -ne $lastName) { $hist.Clear(); $lastName = $snap.name }
  $u = Parse-Upd $snap.upd

  $g = $snap.gpu -split '\s*,\s*'
  $temp = if ($g.Count -ge 1 -and $g[0]) { [int]($g[0]) } else { -1 }
  $pow  = if ($g.Count -ge 2 -and $g[1]) { [double]($g[1]) } else { 0 }
  $util = if ($g.Count -ge 3 -and $g[2]) { [int]($g[2]) } else { 0 }

  $lines = New-Object System.Collections.ArrayList
  $w = 30
  $bb = "$($C.blue)"
  $runName = if ($snap.name) { $snap.name } else { '(no run)' }
  [void]$lines.Add("$($C.cyan)$($C.bold)╔══════════════════════════════════════════════════════════════════╗$($C.rst)")
  [void]$lines.Add(("$($C.cyan)$($C.bold)║   {0,-52}$($C.mag)rldash$($C.cyan)      ║$($C.rst)" -f $Title))
  [void]$lines.Add(("$($C.cyan)$($C.bold)║   $($C.mag){0,-58}$($C.cyan)     ║$($C.rst)" -f $runName))
  [void]$lines.Add("$($C.cyan)$($C.bold)╚══════════════════════════════════════════════════════════════════╝$($C.rst)")
  [void]$lines.Add('')

  if (-not $u.ContainsKey('upd')) {
    [void]$lines.Add("  $($C.yellow)waiting for the first update line...$($C.rst)")
  } else {
    $upd = [int]$u.upd; $tot = [int]$u.updtot
    $epret = [double]$u.epret; $rps = [double]$u.rps; $eplen = [double]$u.eplen
    [void]$hist.Add($epret)
    while ($hist.Count -gt 48) { $hist.RemoveAt(0) }
    $maxret = ([double]($hist | Measure-Object -Maximum).Maximum)
    if ($maxret -lt 1) { $maxret = 1 }

    $pct = if ($tot -gt 0) { 100.0 * $upd / $tot } else { 0 }
    $stepM = if ($u.ContainsKey('step')) { [double]($u.step -replace ',','') / 1e6 } else { 0 }
    $sps = if ($u.ContainsKey('sps')) { '{0:N0}' -f [double]($u.sps -replace ',','') } else { '?' }
    $sang = if ($u.ContainsKey('sang')) { [double]$u.sang } else { 0 }
    $sangLbl = if ($sang -gt 3.0) { 'hang' } elseif ($sang -lt 0.2) { 'near-up' } else { ('{0:N2}' -f $sang) }

    [void]$lines.Add(("  $($C.bold)update$($C.rst)   {0,5} / {1,-5} $($C.gray)▕$($C.green){2}$($C.gray)▏$($C.rst) {3,5:N1}%" -f $upd,$tot,(Bar $upd $tot $w),$pct))
    $totM = if ($upd -gt 0) { $stepM * $tot / $upd } else { 0 }
    [void]$lines.Add(("  $($C.bold)steps$($C.rst)    {0,7:N1}M / {1:N0}M        $($C.gray)SPS$($C.rst) {2}" -f $stepM,$totM,$sps))
    [void]$lines.Add('')
    [void]$lines.Add(("  $($C.bold)ep_ret$($C.rst)   $($C.gray)▕$($C.cyan){0}$($C.gray)▏$($C.rst) {1,7:N1}   $($C.dim)(peak {2:N0})$($C.rst)" -f (Bar $epret $maxret $w),$epret,$maxret))
    [void]$lines.Add(("  $($C.bold)rps$($C.rst)      $($C.gray)▕$($C.yellow){0}$($C.gray)▏$($C.rst) {1,7:N2}   $($C.dim)/ 6.0 max$($C.rst)" -f (Bar $rps 6.0 $w),$rps))
    [void]$lines.Add(("  $($C.bold)ep_len$($C.rst)   $($C.gray)▕$($C.green){0}$($C.gray)▏$($C.rst) {1,7:N0}   $($C.dim)(trunc ~650)$($C.rst)" -f (Bar $eplen 650 $w),$eplen))
    [void]$lines.Add('')
    [void]$lines.Add("  $($C.bold)ep_ret trend$($C.rst)  $($C.cyan)$(Spark $hist)$($C.rst)  $($C.dim)(last $($hist.Count))$($C.rst)")
    [void]$lines.Add('')

    $tcol = if ($temp -ge 75) { $C.red } elseif ($temp -ge 65) { $C.yellow } else { $C.green }
    $tbar = if ($temp -ge 0) { Bar $temp 80 20 } else { ('?' * 20) }
    [void]$lines.Add("  $($C.gray)┌─ GPU ───────────────────────────────────────────────┐$($C.rst)")
    [void]$lines.Add(("  $($C.gray)│$($C.rst) $($C.bold)temp$($C.rst)  {0}{1,2}°C$($C.rst) $($C.gray)▕{2}{3}$($C.gray)▏$($C.rst) $($C.dim)limit 80$($C.rst)    $($C.gray)│$($C.rst)" -f $tcol,$temp,$tcol,$tbar))
    [void]$lines.Add(("  $($C.gray)│$($C.rst) $($C.bold)power$($C.rst) {0,3:N0} W   $($C.bold)util$($C.rst) {1,3}%   $($C.dim)of 575 W$($C.rst)              $($C.gray)│$($C.rst)" -f $pow,$util))
    [void]$lines.Add("  $($C.gray)└──────────────────────────────────────────────────────┘$($C.rst)")
    [void]$lines.Add('')
    $ev = if ($u.ContainsKey('ev')) { $u.ev } else { '?' }
    $ls = if ($u.ContainsKey('logstd')) { $u.logstd } else { '?' }
    $vl = if ($u.ContainsKey('vloss')) { $u.vloss } else { '?' }
    [void]$lines.Add("  $($C.dim)logstd $ls   v_loss $vl   EV $ev   start_ang $sangLbl$($C.rst)")
  }

  $el = (Get-Date) - $start
  $elS = '{0:d2}:{1:d2}:{2:d2}' -f [int]$el.TotalHours,$el.Minutes,$el.Seconds
  $stamp = (Get-Date).ToString('HH:mm:ss')
  # GPU util tells live vs idle; the driver marker is history, not state.
  $status = if ($util -ge 20) { "$($C.green)training$($C.rst)" }
            elseif ($snap.mark -match 'ABORT') { "$($C.red)$($C.bold)ABORTED$($C.rst)" }
            elseif ($snap.mark -match 'COMPLETE') {
              "$($C.cyan)last run COMPLETE - waiting for next$($C.rst)" }
            else { "$($C.gray)idle$($C.rst)" }
  [void]$lines.Add("  $($C.gray)elapsed $elS  ·  $stamp  ·  $status  ·  Ctrl-C to quit$($C.rst)")

  if ($Plain) {
    $lines | ForEach-Object { Write-Host $_ }
    Write-Host ('-' * 60)
  } else {
    $out = "$e[H"
    foreach ($ln in $lines) { $out += $ln + "$e[K`n" }
    $out += "$e[J"
    Write-Host $out -NoNewline
  }

  # Never exit on COMPLETE/ABORT: in auto-follow mode the dashboard stays up
  # through idle gaps and latches onto the next run. Ctrl-C to quit.
  if ($Iterations -gt 0 -and $iter -ge $Iterations) { break }
  Start-Sleep -Milliseconds $IntervalMs
}
