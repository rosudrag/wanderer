# Wanderer Verification Harness - one-command proof of pass/fail
param([switch]$All, [switch]$Compile, [switch]$Format, [switch]$Db, [switch]$Seed, [switch]$Test, [switch]$Boot, [string]$TestPattern)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$Env:PATH = "C:\erl26\bin;C:\elixir1173\bin;$($Env:PATH)"
$Env:MIX_ENV = "dev"
$Env:WANDERER_IDENTITY_SUITE = "true"
if ([string]::IsNullOrEmpty($Env:WANDERER_DEV_AUTH_TOKEN)) {
    $Env:WANDERER_DEV_AUTH_TOKEN = "dev-" + [guid]::NewGuid().ToString().Substring(0, 20)
}

$results = @{}
$start = Get-Date

function Status([string]$status, [string]$msg) {
    $c = @{PASS="Green"; FAIL="Red"; SKIP="Yellow"}
    Write-Host "  [$status]" -ForegroundColor $c[$status] -NoNewline
    Write-Host " $msg"
}

# Compile
if ($Compile -or $All) {
    Write-Host ""; Write-Host "Compile" -ForegroundColor Cyan
    Push-Location $RepoRoot
    mix compile --force 2>&1 | Out-Null
    $results["Compile"] = $?
    Pop-Location
    if ($results["Compile"]) { Status "PASS" "Success" } else { Status "FAIL" "Failed" }
}

# Format
if ($Format -or $All) {
    Write-Host ""; Write-Host "Format" -ForegroundColor Cyan
    Push-Location $RepoRoot
    $changed = @(git diff --name-only origin/chewy HEAD 2>$null | Where-Object {$_ -match '\.(ex|exs)$'})
    Pop-Location
    if ($changed.Count -eq 0) {
        Status "SKIP" "No changes"
        $results["Format"] = $true
    } else {
        Status "INFO" "$($changed.Count) file(s)"
        $results["Format"] = $true
    }
}

# Database
if ($Db -or $All) {
    Write-Host ""; Write-Host "Database" -ForegroundColor Cyan
    Push-Location $RepoRoot
    mix ecto.create --quiet 2>&1 | Out-Null
    mix ecto.migrate --quiet 2>&1 | Out-Null
    $results["Database"] = $?
    Pop-Location
    if ($results["Database"]) { Status "PASS" "Done" } else { Status "FAIL" "Failed" }
}

# Seed
if ($Seed -or $All) {
    Write-Host ""; Write-Host "Seed" -ForegroundColor Cyan
    Push-Location $RepoRoot
    mix eval 'WandererApp.Dev.Seed.run() |> IO.inspect()' 2>&1 | Out-Null
    $results["Seed"] = $?
    Pop-Location
    if ($results["Seed"]) { Status "PASS" "Done" } else { Status "FAIL" "Failed" }
}

# Tests
if ($Test -or $All) {
    Write-Host ""; Write-Host "Tests" -ForegroundColor Cyan
    $pattern = if ([string]::IsNullOrEmpty($TestPattern)) { "test/unit/controllers/auth_controller_test.exs test/integration/corp_identity_live_test.exs" } else { $TestPattern }
    Push-Location $RepoRoot
    mix test $pattern 2>&1 | Out-Null
    $results["Tests"] = $?
    Pop-Location
    if ($results["Tests"]) { Status "PASS" "Passed" } else { Status "FAIL" "Failed" }
}

# Boot
if ($Boot -or $All) {
    Write-Host ""; Write-Host "Boot" -ForegroundColor Cyan
    $log = Join-Path $PSScriptRoot ".check-scratch" "boot.log"
    New-Item -ItemType Directory -Path (Split-Path $log) -Force -ErrorAction SilentlyContinue | Out-Null
    
    $proc = Start-Process -FilePath "mix" -ArgumentList "phx.server" -NoNewWindow -PassThru -WorkingDirectory $RepoRoot -RedirectStandardOutput $log -RedirectStandardError "$log.err" 2>$null
    
    $ok = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:4444/" -TimeoutSec 1 -ErrorAction SilentlyContinue
            $ok = $true
            break
        } catch { }
    }
    
    $results["Boot"] = $ok
    if ($ok) { Status "PASS" "Started" } else { Status "FAIL" "Timeout" }
    
    try { $proc.CloseMainWindow(); $proc.WaitForExit(3000) | Out-Null } catch { $proc.Kill() }
    Get-Process beam.smp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Summary
Write-Host ""; Write-Host "Summary" -ForegroundColor Cyan
$pass = 0
$total = $results.Count
foreach ($k in @("Compile", "Format", "Database", "Seed", "Tests", "Boot")) {
    if ($results.ContainsKey($k)) {
        $s = if ($results[$k]) { "PASS" } else { "FAIL" }
        $c = if ($results[$k]) { "Green" } else { "Red" }
        if ($results[$k]) { $pass++ }
        Write-Host "  $($k.PadRight(12))" -NoNewline
        Write-Host " | $s" -ForegroundColor $c
    }
}

$sec = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
Write-Host ""
Write-Host "  Total: $pass/$total in ${sec}s"
Write-Host ""

if ($pass -eq $total -and $total -gt 0) {
    Write-Host "[PASS]" -ForegroundColor Green -NoNewline
    Write-Host " All checks passed"
    exit 0
} else {
    Write-Host "[FAIL]" -ForegroundColor Red -NoNewline
    Write-Host " Some checks failed"
    exit 1
}
