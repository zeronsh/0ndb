param(
	[string]$Seeds = "1-20",
	[string]$Lanes = "default,until-run",
	[int]$Jobs = 2,
	[string]$Odin = "",
	[string]$Root = ""
)
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }
$Bin = Join-Path $Root ".xplat"
New-Item -ItemType Directory -Force $Bin | Out-Null
Set-Location $Root
if ($Odin -eq "") {
	$c = Get-Command odin -ErrorAction SilentlyContinue
	if ($c) { $Odin = $c.Source } else { $Odin = "C:\Users\wing_\dev-tools\odin\dist\odin.exe" }
}
if (-not (Test-Path $Odin)) {
	"XPLAT-ERROR no odin"
	exit 2
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$exe = Join-Path $Bin "sim.exe"
$p = Start-Process -FilePath $Odin -ArgumentList @("build", "tests\sim", "-build-mode:test", "-o:speed", "-define:ODIN_TEST_NAMES=sim.simulate", "-out:$exe") -RedirectStandardOutput (Join-Path $Bin "build.log") -RedirectStandardError (Join-Path $Bin "build.err") -NoNewWindow -PassThru
$null = $p.Handle
if (-not $p.WaitForExit(1500 * 1000)) {
	Stop-Process -Id $p.Id -Force
	"XPLAT-ERROR build timed out"
	exit 2
}
if ($p.ExitCode -ne 0) {
	"XPLAT-ERROR build " + ((Get-Content (Join-Path $Bin "build.err") -Tail 3) -join " ")
	exit 2
}
"XPLAT-BUILD $([int]$sw.Elapsed.TotalSeconds)"
$lo, $hi = $Seeds.Split("-") | ForEach-Object { [int]$_ }
$queue = New-Object System.Collections.Queue
foreach ($lane in $Lanes.Split(",")) {
	foreach ($s in $lo..$hi) { $queue.Enqueue(@($lane, $s)) }
}
$envs = @{ "default" = @{}; "until-run" = @{ SIM_STORAGE = "until-run" }; "async" = @{ SIM_DURABILITY = "async" }; "byzantine" = @{ SIM_BYZANTINE = "1" } }
$sw = [Diagnostics.Stopwatch]::StartNew()
$running = @()
function Finish($r) {
	if (-not $r.p.HasExited) {
		Stop-Process -Id $r.p.Id -Force
		$rc = 124
	} else {
		$rc = $r.p.ExitCode
	}
	$m = Get-Content $r.log, "$($r.log).err" -ErrorAction SilentlyContinue | Select-String "^sim: events=(\d+) loop_steps=\d+ disk_ops=(\d+)" | Select-Object -First 1
	if ($m) { $ev = $m.Matches[0].Groups[1].Value; $ops = $m.Matches[0].Groups[2].Value } else { $ev = "-"; $ops = "-" }
	"XPLAT $($r.lane) $($r.seed) $ev $ops $rc"
}
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
	while ($running.Count -lt $Jobs -and $queue.Count -gt 0) {
		$x = $queue.Dequeue()
		$lane = $x[0]
		$seed = $x[1]
		$e = $envs[$lane]
		if ($null -eq $e) { $e = @{} }
		$env:SIM_SEED = "$seed"
		foreach ($k in $e.Keys) { Set-Item "env:$k" $e[$k] }
		$log = Join-Path $Bin "$lane-$seed.log"
		$proc = Start-Process -FilePath $exe -RedirectStandardOutput $log -RedirectStandardError "$log.err" -NoNewWindow -PassThru
		$null = $proc.Handle
		foreach ($k in $e.Keys) { Remove-Item "env:$k" }
		Remove-Item env:SIM_SEED
		$running += , @{ p = $proc; lane = $lane; seed = $seed; log = $log; t = [Diagnostics.Stopwatch]::StartNew() }
	}
	Start-Sleep -Milliseconds 300
	$still = @()
	foreach ($r in $running) {
		if ($r.p.HasExited -or $r.t.Elapsed.TotalSeconds -gt 1500) { Finish $r } else { $still += , $r }
	}
	$running = $still
}
"XPLAT-WALL $([int]$sw.Elapsed.TotalSeconds)"
