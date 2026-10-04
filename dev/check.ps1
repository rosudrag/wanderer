# Wanderer Verification Harness - one-command proof of pass/fail
#
# Proves, in one command, the contract every chewy feature flag makes
# (AGENTS.md rule 6): flag off => upstream behaviour, flag unchanged; flag
# on => the feature works. See dev/CHECK.md for the full runbook.
param(
    [switch]$All,
    [switch]$Compile,
    [switch]$Format,
    [switch]$Db,
    [switch]$Seed,
    [switch]$Test,
    [switch]$Boot,
    [switch]$Routes,
    [string]$TestPattern
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Path $PSScriptRoot -Parent
$ScratchDir = Join-Path $PSScriptRoot ".check-scratch"
$LogsDir = Join-Path $ScratchDir "logs"
New-Item -ItemType Directory -Path $LogsDir -Force -ErrorAction SilentlyContinue | Out-Null

# Scratch output is untracked via .git/info/exclude, NEVER .gitignore -- see
# AGENTS.md: our untracked paths live there so they cost nothing on an
# upstream merge (a .gitignore entry would itself be a merge conflict).
$excludeFile = Join-Path $RepoRoot ".git\info\exclude"
if (Test-Path $excludeFile) {
    $excludeContent = Get-Content $excludeFile -Raw -ErrorAction SilentlyContinue
    if ($excludeContent -notmatch [regex]::Escape("dev/.check-scratch/")) {
        Add-Content $excludeFile "`ndev/.check-scratch/"
    }
}

# ---------------------------------------------------------------------------
# Toolchain resolution. Probe PATH first -- do not assume any install
# location. Only fall back to this host's known dirs (documented in
# dev/CHECK.md, overridable via WANDERER_TOOLCHAIN_PATHS) if `mix` isn't
# already reachable, and fail loudly with a clear message if neither works,
# instead of limping into a 30-second timeout on the first `mix` call.
# ---------------------------------------------------------------------------
function Resolve-Toolchain {
    if (Get-Command mix -ErrorAction SilentlyContinue) { return }

    $candidates = @("C:\erl26\bin", "C:\elixir1173\bin")
    if ($Env:WANDERER_TOOLCHAIN_PATHS) {
        $candidates = $Env:WANDERER_TOOLCHAIN_PATHS -split ";"
    }

    $missing = @($candidates | Where-Object { -not (Test-Path $_) })
    if ($missing.Count -gt 0) {
        Write-Host "[FAIL] Elixir/Erlang toolchain not found." -ForegroundColor Red
        Write-Host "  `mix` is not on PATH, and these expected install dirs are missing:"
        $missing | ForEach-Object { Write-Host "    $_" }
        Write-Host "  See dev/CHECK.md 'Prerequisites' for install steps, or set"
        Write-Host "  WANDERER_TOOLCHAIN_PATHS to a ';'-separated list of bin dirs."
        exit 1
    }

    $Env:PATH = ($candidates -join ";") + ";" + $Env:PATH

    if (-not (Get-Command mix -ErrorAction SilentlyContinue)) {
        Write-Host "[FAIL] mix still not found after adding $($candidates -join ';') to PATH." -ForegroundColor Red
        exit 1
    }
}

Resolve-Toolchain
$Env:MIX_ENV = "dev"

# The identity-suite flag under test MUST NOT be forced on for the whole
# script: the flag-off half of its contract ("existing upstream behaviour")
# has to stay reachable, on purpose, or this harness could never prove it.
# Only the -Routes check (which explicitly needs both states) touches it,
# scoped to its own subprocess boots, and cleans up after itself.
Remove-Item Env:WANDERER_IDENTITY_SUITE -ErrorAction SilentlyContinue
Remove-Item Env:WANDERER_DEV_AUTH_TOKEN -ErrorAction SilentlyContinue

$results = @{}
$scriptStart = Get-Date

function Status([string]$status, [string]$msg) {
    $c = @{PASS="Green"; FAIL="Red"; SKIP="Yellow"; INFO="Cyan"}
    Write-Host "  [$status]" -ForegroundColor $c[$status] -NoNewline
    Write-Host " $msg"
}

function Show-LogTail([string]$path, [int]$n = 40) {
    if (Test-Path $path) {
        Write-Host "  --- tail of $path ---" -ForegroundColor DarkGray
        Get-Content $path -Tail $n | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
}

function Record([string]$name, [bool]$ok, [double]$elapsed, [string]$status) {
    $results[$name] = @{ Ok = $ok; Elapsed = $elapsed; Status = $status }
}

# ---------------------------------------------------------------------------
# `_build/<env>/lib/wanderer_app/priv` must be a real DIRECTORY on this box,
# never the symlink mix prefers.
#
# `Mix.Utils.symlink_or_copy/2` compares the stored link target against the
# path it would write; Windows stores backslashes where mix passed forward
# slashes, so the comparison NEVER matches and mix tries to replace the link
# on every start. Replacing it means `File.rm`, which Erlang refuses for a
# directory symlink -- hence
#   ** (Mix) Cannot remove symlink ".../priv" due to reason: not owner"
# on the second and every later invocation. (Most Windows boxes never see
# this: without the create-symlink privilege mix falls back to copying. This
# one has developer mode on, so it gets the symlink and the bug.)
#
# A real directory takes mix's OTHER branch: `read_link` answers `:einval`,
# `File.ln_s` fails, and it copies with an mtime/size `on_conflict` -- which
# is correct, incremental, and cannot raise. ~14 MB once per env, then only
# changed files. Phoenix's code reloader calls the same function on the FIRST
# REQUEST of a booted server, which is why -Boot/-Routes answered 500 on every
# probed route until this existed; clearing the link from PowerShell could not
# reach that call.
# ---------------------------------------------------------------------------
function Repair-PrivDir {
    foreach ($envName in @("dev", "test")) {
        $privDir = Join-Path $RepoRoot "_build\$envName\lib\wanderer_app\priv"
        if (-not (Test-Path $privDir)) { continue }
        $item = Get-Item $privDir -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            cmd /c "rmdir `"$privDir`"" 2>&1 | Out-Null
            Copy-Item (Join-Path $RepoRoot "priv") $privDir -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------------
# Boot helpers, shared by -Boot and -Routes. `mix phx.server` sets
# `server: true` itself, which is exactly what makes it start the
# `npm run watch` esbuild watcher configured in config/dev.exs's
# `watchers:` key -- and this checkout has no local `npm install`, so that
# watcher hangs forever and -Boot times out. dev/boot.exs avoids
# `mix phx.server` entirely: it overrides only `server:`/`watchers:` via
# `Application.put_env/3` before the app starts, so config/dev.exs itself
# is never touched. Booting under MIX_ENV=test would dodge the watcher too
# (config/test.exs never sets `watchers:` at all) but was NOT chosen here:
# it would boot against the `wanderer_test` database instead of the
# `wanderer_dev` one -Db/-Seed already provision, and -Routes' dev-login
# fixtures need to land somewhere `-Seed` actually seeds.
#
# On Windows, `mix.bat` does not exec(2) into `erl.exe` -- it launches it
# as a child process and its own process exits/detaches, so the PID
# Start-Process hands back is USELESS for shutdown: killing it leaves the
# real VM (`erl.exe`; there is no separate `beam.smp` binary on Windows,
# unlike Linux -- it's compiled into `erl.exe` itself) running as an
# orphan, permanently holding port 4444. The reliable PID is whichever
# process the OS says is actually listening on the port.
# ---------------------------------------------------------------------------
function Start-Boot([hashtable]$EnvOverrides, [string]$LogName) {
    foreach ($k in $EnvOverrides.Keys) {
        if ($null -eq $EnvOverrides[$k]) {
            Remove-Item "Env:$k" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:$k" $EnvOverrides[$k]
        }
    }

    $log = Join-Path $LogsDir "$LogName.log"
    $errLog = Join-Path $LogsDir "$LogName.err"
    Remove-Item $log, $errLog -ErrorAction SilentlyContinue

    Repair-PrivDir

    $proc = Start-Process -FilePath "mix.bat" `
        -ArgumentList @("run", "--no-start", "dev/boot.exs") `
        -NoNewWindow -PassThru -WorkingDirectory $RepoRoot `
        -RedirectStandardOutput $log -RedirectStandardError $errLog

    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:4444/" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop | Out-Null
            $ready = $true
            break
        } catch {
            if ($_.Exception.Response) { $ready = $true; break }
        }
        if ($proc.HasExited) { break }
    }

    @{ Proc = $proc; Ready = $ready; Log = $log; ErrLog = $errLog }
}

function Stop-Boot([hashtable]$boot) {
    # Windows' Bandit/Thousand Island listener sets SO_REUSEADDR, which lets
    # a second process bind the SAME port while the first is still up (this
    # is exactly how an earlier session's orphan went undetected: a stale
    # `erl.exe` kept accepting SOME connections on :4444 even after a fresh
    # one bound the same port). Get-NetTCPConnection can return one row per
    # OWNING PROCESS, not just one row total -- killing only the first
    # leaves the rest running forever. Kill every distinct PID it reports.
    $conn = Get-NetTCPConnection -LocalPort 4444 -State Listen -ErrorAction SilentlyContinue
    $erlPids = @($conn | Select-Object -ExpandProperty OwningProcess -Unique)

    foreach ($erlPid in $erlPids) {
        Stop-Process -Id $erlPid -Force -ErrorAction SilentlyContinue
    }
    if ($boot.Proc -and -not $boot.Proc.HasExited -and ($erlPids -notcontains $boot.Proc.Id)) {
        Stop-Process -Id $boot.Proc.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500

    $stillListening = Get-NetTCPConnection -LocalPort 4444 -State Listen -ErrorAction SilentlyContinue
    $stillRunning = @($erlPids | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }) | Where-Object { $_ }
    -not $stillListening -and -not $stillRunning
}

function Invoke-HttpProbe([string]$Url, [Microsoft.PowerShell.Commands.WebRequestSession]$Session) {
    try {
        if ($Session) {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -WebSession $Session -ErrorAction Stop
        } else {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        }
        @{ Status = [int]$r.StatusCode; Body = $r.Content }
    } catch {
        if ($_.Exception.Response) {
            @{ Status = [int]$_.Exception.Response.StatusCode; Body = "" }
        } else {
            @{ Status = -1; Body = "" }
        }
    }
}

# Compile
if ($Compile -or $All) {
    Write-Host ""; Write-Host "Compile" -ForegroundColor Cyan
    $t0 = Get-Date
    $log = Join-Path $LogsDir "compile.log"
    Push-Location $RepoRoot
    Repair-PrivDir
    # --force is essential: it re-runs the full compile graph every time,
    # which is what catches the compile-time struct-dependency deadlock
    # documented in lib/wanderer_app/api/policies/map_scoped.ex:31-56 (a
    # cached incremental compile would not re-trigger it).
    # --warnings-as-errors makes a new warning a hard failure, not just
    # noise in the log.
    mix compile --force --warnings-as-errors *> $log
    $ok = ($LASTEXITCODE -eq 0)
    Pop-Location
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Record "Compile" $ok $elapsed $(if ($ok) { "PASS" } else { "FAIL" })
    if ($ok) {
        Status "PASS" "Compilation succeeded (${elapsed}s)"
    } else {
        Status "FAIL" "See $log"
        Show-LogTail $log
        Write-Host "  NOTE: another agent may be concurrently editing lib/**/config/**/test/**" -ForegroundColor DarkGray
        Write-Host "  (WANDERER_GROUP_MAP_SYNC work) -- check the log before assuming this is yours." -ForegroundColor DarkGray
    }
}

# Format
if ($Format -or $All) {
    Write-Host ""; Write-Host "Format" -ForegroundColor Cyan
    $t0 = Get-Date
    Push-Location $RepoRoot

    $base = "origin/chewy"
    git rev-parse --verify $base *> $null
    if ($LASTEXITCODE -ne 0) { $base = "HEAD" }

    # Scoped to files changed vs $base -- committed or not -- plus new
    # untracked files. NEVER repo-wide: this Windows checkout has
    # core.autocrlf=true, so every unmodified committed file is CRLF on
    # disk while `mix format` always emits LF. An unscoped
    # `mix format --check-formatted` (or worse, `mix format`) treats that
    # CRLF/LF difference as "unformatted" for the ENTIRE repo -- a
    # previous agent ran it unscoped and it rewrote ~550 unrelated files.
    # `.heex` is in .formatter.exs's inputs (the LiveView HTMLFormatter
    # plugin), so it MUST be in this filter too: it was omitted at first
    # and four rewritten templates passed the gate unchecked.
    $diffFiles = @(git diff --name-only --diff-filter=ACMR $base -- '*.ex' '*.exs' '*.heex' 2>$null)
    $untrackedFiles = @(git ls-files --others --exclude-standard -- '*.ex' '*.exs' '*.heex' 2>$null)
    $changed = @($diffFiles + $untrackedFiles | Sort-Object -Unique |
        Where-Object { Test-Path (Join-Path $RepoRoot $_) })

    Pop-Location

    if ($changed.Count -eq 0) {
        $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        Record "Format" $true $elapsed "SKIP"
        Status "SKIP" "No .ex/.exs/.heex files changed vs $base"
    } else {
        $log = Join-Path $LogsDir "format.log"
        Push-Location $RepoRoot
        Repair-PrivDir
        mix format --check-formatted $changed *> $log
        $ok = ($LASTEXITCODE -eq 0)
        Pop-Location
        $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        Record "Format" $ok $elapsed $(if ($ok) { "PASS" } else { "FAIL" })
        if ($ok) {
            Status "PASS" "$($changed.Count) file(s) formatted (vs $base, ${elapsed}s)"
        } else {
            Status "FAIL" "See $log"
            Show-LogTail $log
        }
    }
}

# Database
if ($Db -or $All) {
    Write-Host ""; Write-Host "Database" -ForegroundColor Cyan
    $t0 = Get-Date
    $log = Join-Path $LogsDir "db.log"
    Push-Location $RepoRoot
    Repair-PrivDir
    mix ecto.create --quiet *> $log
    $createOk = ($LASTEXITCODE -eq 0)
    Repair-PrivDir
    mix ecto.migrate --quiet *>> $log
    $migrateOk = ($LASTEXITCODE -eq 0)
    Pop-Location
    $ok = $createOk -and $migrateOk
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Record "Database" $ok $elapsed $(if ($ok) { "PASS" } else { "FAIL" })
    if ($ok) { Status "PASS" "Created + migrated (${elapsed}s)" } else { Status "FAIL" "See $log"; Show-LogTail $log }
}

# Seed
if ($Seed -or $All) {
    Write-Host ""; Write-Host "Seed" -ForegroundColor Cyan
    $t0 = Get-Date
    $log = Join-Path $LogsDir "seed.log"
    Push-Location $RepoRoot
    Repair-PrivDir
    mix run dev/seed_identity.exs *> $log
    $ok = ($LASTEXITCODE -eq 0)
    Pop-Location
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Record "Seed" $ok $elapsed $(if ($ok) { "PASS" } else { "FAIL" })
    if ($ok) { Status "PASS" "Seeded (${elapsed}s)" } else { Status "FAIL" "See $log"; Show-LogTail $log }
}

# Tests
if ($Test -or $All) {
    Write-Host ""; Write-Host "Tests" -ForegroundColor Cyan
    $t0 = Get-Date

    if ([string]::IsNullOrEmpty($TestPattern)) {
        # DIRECTORY, not a discovered file list. Passing the ~34 discovered
        # .exs paths as separate arguments made `mix test` run only the LAST
        # one: 18 tests instead of 384, while this step still printed "34
        # file(s) passed" and a PASS. Measured 2026-09-29 -- the file-list
        # form reported 18 tests, the directory form 384 (65 excluded by the
        # :integration/:pending tags in test/test_helper.exs). A directory
        # also keeps covering new test files the moment they are added,
        # which was the original reason for discovering them.
        $testPaths = @("test/integration", "test/unit/controllers/auth_controller_test.exs")
    } else {
        $testPaths = $TestPattern -split '\s+' | Where-Object { $_ -ne "" }
    }

    $log = Join-Path $LogsDir "test.log"
    Push-Location $RepoRoot
    # `mix test` needs config/test.exs's Ecto.Adapters.SQL.Sandbox pool;
    # the script-wide MIX_ENV=dev (needed by every other check, since
    # they exercise the dev database) would otherwise leak in and mix
    # test would try to use Sandbox.mode/2 against a plain
    # DBConnection.ConnectionPool, raising immediately.
    $prevMixEnv = $Env:MIX_ENV
    $Env:MIX_ENV = "test"
    Repair-PrivDir
    # Through `cmd /c`, with the paths already joined into ONE string.
    # `mix test $testPaths` (array variable -> native command) silently
    # drops every argument but the last when the command is a .bat, which
    # `mix` is on Windows: measured 2026-09-29, the array form ran 18 tests
    # and the identical literal form ran 384. cmd re-splits the line itself,
    # so mix.bat sees every path. No path here contains a space.
    cmd /c "mix test $($testPaths -join ' ') > `"$log`" 2>&1"
    $ok = ($LASTEXITCODE -eq 0)
    $Env:MIX_ENV = $prevMixEnv
    Pop-Location
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Record "Tests" $ok $elapsed $(if ($ok) { "PASS" } else { "FAIL" })
    if ($ok) {
        # Report ExUnit's own count, not the number of paths handed to it.
        # "34 file(s) passed" was true and useless: it stayed green while
        # only one file's tests actually ran.
        $summary = (Select-String -Path $log -Pattern '^\s*\d+ tests?,' |
            Select-Object -Last 1).Line
        if ($summary) { $summary = $summary.Trim() } else { $summary = "see $log" }
        Status "PASS" "$summary (${elapsed}s)"
        $testPaths | ForEach-Object { Write-Host "    $_" }
    } else {
        Status "FAIL" "See $log"
        Show-LogTail $log 60
    }
}

# Boot
if ($Boot -or $All) {
    Write-Host ""; Write-Host "Boot" -ForegroundColor Cyan
    $t0 = Get-Date
    $bootResult = Start-Boot @{ WANDERER_IDENTITY_SUITE = $null; WANDERER_DEV_AUTH_TOKEN = $null } "boot"

    $ok = $bootResult.Ready
    if ($ok) {
        $probe = Invoke-HttpProbe "http://127.0.0.1:4444/"
        $ok = ($probe.Status -eq 200)
    }

    $cleanOk = Stop-Boot $bootResult
    $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Record "Boot" ($ok -and $cleanOk) $elapsed $(if ($ok -and $cleanOk) { "PASS" } else { "FAIL" })

    if (-not $bootResult.Ready) {
        Status "FAIL" "Timed out waiting for http://127.0.0.1:4444/"
        Show-LogTail $bootResult.Log
        Show-LogTail $bootResult.ErrLog
    } elseif (-not $ok) {
        Status "FAIL" "GET / did not return 200"
        Show-LogTail $bootResult.Log
    } elseif (-not $cleanOk) {
        Status "FAIL" "Orphan erl.exe/listener survived shutdown on port 4444"
    } else {
        Status "PASS" "Started, answered HTTP 200, shut down cleanly (${elapsed}s)"
    }
}

# Routes
if ($Routes -or $All) {
    Write-Host ""; Write-Host "Routes" -ForegroundColor Cyan
    $t0 = Get-Date
    $allOk = $true

    # --- Flag off: WANDERER_IDENTITY_SUITE unset => 404/404 -----------------
    $bootOff = Start-Boot @{ WANDERER_IDENTITY_SUITE = $null; WANDERER_DEV_AUTH_TOKEN = $null } "routes-off"
    if (-not $bootOff.Ready) {
        Status "FAIL" "Boot (flag off) timed out"
        Show-LogTail $bootOff.Log
        Show-LogTail $bootOff.ErrLog
        $allOk = $false
    } else {
        $offCorp = Invoke-HttpProbe "http://127.0.0.1:4444/corp"
        $offIdentity = Invoke-HttpProbe "http://127.0.0.1:4444/corp/identity"

        $offCorpOk = ($offCorp.Status -eq 404)
        $offIdentityOk = ($offIdentity.Status -eq 404)
        $allOk = $allOk -and $offCorpOk -and $offIdentityOk

        if ($offCorpOk) { Status "PASS" "flag off: GET /corp -> 404" } else { Status "FAIL" "flag off: GET /corp -> $($offCorp.Status), expected 404" }
        if ($offIdentityOk) { Status "PASS" "flag off: GET /corp/identity -> 404" } else { Status "FAIL" "flag off: GET /corp/identity -> $($offIdentity.Status), expected 404" }
    }
    $cleanOffOk = Stop-Boot $bootOff
    if (-not $cleanOffOk) { Status "FAIL" "Orphan listener after flag-off boot"; $allOk = $false }

    # --- Flag on + dev-login: 200/200 + body match --------------------------
    $devToken = "dev-check-routes-" + [guid]::NewGuid().ToString("N")
    $bootOn = Start-Boot @{ WANDERER_IDENTITY_SUITE = "true"; WANDERER_DEV_AUTH_TOKEN = $devToken } "routes-on"

    if (-not $bootOn.Ready) {
        Status "FAIL" "Boot (flag on) timed out"
        Show-LogTail $bootOn.Log
        Show-LogTail $bootOn.ErrLog
        $allOk = $false
    } else {
        $loginResp = $null
        $session = $null
        try {
            $loginResp = Invoke-WebRequest -Uri "http://127.0.0.1:4444/dev/login?token=$devToken" `
                -UseBasicParsing -TimeoutSec 5 -SessionVariable session -ErrorAction Stop
        } catch {
            if ($_.Exception.Response) { $loginResp = $_.Exception.Response }
        }
        $loginOk = ($loginResp -and [int]$loginResp.StatusCode -eq 200)
        $allOk = $allOk -and $loginOk
        if ($loginOk) { Status "PASS" "flag on: GET /dev/login -> 200 (session established)" } else { Status "FAIL" "flag on: GET /dev/login did not return 200" }

        $onCorp = Invoke-HttpProbe "http://127.0.0.1:4444/corp" $session
        $onIdentity = Invoke-HttpProbe "http://127.0.0.1:4444/corp/identity" $session

        $onCorpOk = ($onCorp.Status -eq 200)
        $onIdentityOk = ($onIdentity.Status -eq 200)
        $bodyOk = ($onIdentity.Body -match 'id="corp-identity-state"')
        $allOk = $allOk -and $onCorpOk -and $onIdentityOk -and $bodyOk

        if ($onCorpOk) { Status "PASS" "flag on: GET /corp -> 200" } else { Status "FAIL" "flag on: GET /corp -> $($onCorp.Status), expected 200" }
        if ($onIdentityOk) { Status "PASS" "flag on: GET /corp/identity -> 200" } else { Status "FAIL" "flag on: GET /corp/identity -> $($onIdentity.Status), expected 200" }
        if ($bodyOk) { Status "PASS" "flag on: /corp/identity body contains id=`"corp-identity-state`"" } else { Status "FAIL" "flag on: /corp/identity body missing id=`"corp-identity-state`"" }
    }
    $cleanOnOk = Stop-Boot $bootOn
    if (-not $cleanOnOk) { Status "FAIL" "Orphan listener after flag-on boot"; $allOk = $false }

    Remove-Item Env:WANDERER_IDENTITY_SUITE -ErrorAction SilentlyContinue
    Remove-Item Env:WANDERER_DEV_AUTH_TOKEN -ErrorAction SilentlyContinue

    $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Record "Routes" $allOk $elapsed $(if ($allOk) { "PASS" } else { "FAIL" })
}

# Summary
Write-Host ""; Write-Host "Summary" -ForegroundColor Cyan
$pass = 0
$total = $results.Count
foreach ($k in @("Compile", "Format", "Database", "Seed", "Tests", "Boot", "Routes")) {
    if ($results.ContainsKey($k)) {
        $r = $results[$k]
        $c = @{PASS="Green"; FAIL="Red"; SKIP="Yellow"}[$r.Status]
        if ($r.Ok) { $pass++ }
        Write-Host "  $($k.PadRight(12))" -NoNewline
        Write-Host " | $($r.Status.PadRight(4)) | $($r.Elapsed)s" -ForegroundColor $c
    }
}

$sec = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 1)
Write-Host ""
Write-Host "  Total: $pass/$total passed in ${sec}s"
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
