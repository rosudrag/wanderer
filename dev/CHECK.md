# Wanderer Verification Harness: `dev/check.ps1`

One-command proof that a change works or fails. Run from Windows PowerShell.

## Quick Start

```powershell
cd I:\Development\github\wanderer
.\dev\check.ps1 -All
```

Expected: summary table with `PASS` for all checks, exit code **0**.

## Prerequisites

Exact toolchain from a previous session:

- **Erlang/OTP 26.2.5.5** at `C:\erl26\bin`
- **Elixir 1.17.3** at `C:\elixir1173\bin`
- **PostgreSQL 17** listening on localhost:5432, user `postgres`, password `postgres`

### Verify Prerequisites

```powershell
C:\erl26\bin\erl -version
C:\elixir1173\bin\elixir --version
psql -U postgres -h 127.0.0.1 -c "SELECT version();"
```

### Provisioning (if missing)

1. **Erlang/OTP 26.2.5.5**: https://www.erlang.org/downloads → Install to `C:\erl26`
2. **Elixir 1.17.3**: https://github.com/elixir-lang/elixir/releases → Unzip to `C:\elixir1173`
3. **PostgreSQL 17**: https://www.postgresql.org/download/windows/ → Install with standard settings

## Available Checks

Run individual checks with `-Compile`, `-Format`, `-Db`, `-Seed`, `-Test`, `-Boot`, or `-All`.

### `-Compile`

```powershell
.\dev\check.ps1 -Compile
```

Runs `mix compile --force` and fails on any warning or error. The `--force` flag is essential: it detects when the `is_struct/2` guard pattern in `lib/wanderer_app/api/policies/map_scoped.ex:31-56` breaks (an intentional pattern to catch deadlock issues).

**Expected output:**
```
  [PASS] Compilation succeeded
```

### `-Format`

```powershell
.\dev\check.ps1 -Format
```

Runs `mix format --check-formatted` **scoped to changed files only** (vs `origin/chewy` or `HEAD`). Never runs on the whole repo.

**CRLF Trap (Important)**

This Windows checkout uses CRLF line endings. The Elixir formatter reports every CRLF file as unformatted until CR is stripped. A previous agent ran `mix format` unscoped and reformatted ~550 unrelated files.

The scoped check prevents this, but if you accidentally run `mix format` unscoped, revert with:

```powershell
git checkout -- .
```

To strip CRLFs from a file:

```powershell
(Get-Content .\file.ex -Raw).Replace("`r`n", "`n") | Set-Content .\file.ex -NoNewline
```

**Expected output (no changes):**
```
  [SKIP] No Elixir files changed
```

**Expected output (formatted files):**
```
  [PASS] All files formatted
```

### `-Db`

```powershell
.\dev\check.ps1 -Db
```

Idempotent. Creates the dev database and runs all migrations.

**Expected output:**
```
  [INFO] Database OK
  [PASS] Migrations completed
```

### `-Seed`

```powershell
.\dev\check.ps1 -Seed
```

Seeds identity suite fixtures: one `OwnedCorporation`, one user with two characters (one in the corp, one not), and the standard dev map with systems and connections. Reuses existing fixtures on re-run.

**Expected output:**
```
  [PASS] Seeded successfully
```

### `-Test [pattern]`

```powershell
.\dev\check.ps1 -Test
.\dev\check.ps1 -Test "test/unit/controllers/auth_controller_test.exs"
```

Runs ExUnit. Default pattern is the identity suite:
- `test/unit/controllers/auth_controller_test.exs`
- `test/integration/corp_identity_live_test.exs`

Override with a pattern argument (space-separated file paths or glob patterns).

**Expected output:**
```
  [PASS] Tests passed
    test/unit/controllers/auth_controller_test.exs (passed)
    test/integration/corp_identity_live_test.exs (passed)
```

### `-Boot`

```powershell
.\dev\check.ps1 -Boot
```

Starts the app on port 4444, waits for it to respond, runs route tests (see below), then stops it cleanly and kills any orphan `beam.smp` processes.

The `-Boot` check also runs `-Routes` internally and is the only way to test live routes.

**Expected output:**
```
  [PASS] Boot successful
  [PASS] /corp returns 404 when disabled
  [PASS] /corp returns 200 when enabled
  [PASS] /corp/identity body OK
```

### Routes (Internal to `-Boot`)

The routes check verifies the `WANDERER_IDENTITY_SUITE` feature flag contract:

1. **With flag off:** `GET /corp` and `GET /corp/identity` return **404** (the plug returns 404 before LiveView mounts).
2. **With flag on + authenticated session:** Both return **200**, and identity page contains `id="corp-identity-state"`.

Authentication uses `GET /dev/login?token=$env:WANDERER_DEV_AUTH_TOKEN`. The token must be at least 16 bytes; shorter tokens get a 404 (see `lib/wanderer_app/env.ex:50-59`).

The script auto-generates a token if `WANDERER_DEV_AUTH_TOKEN` is unset.

### `-All`

```powershell
.\dev\check.ps1 -All
```

Runs all checks in sequence and prints a summary table.

**Expected output:**
```
  Check       | Result
  ────────────────────────────────────────
  Compile     | PASS
  Format      | SKIP
  Database    | PASS
  Seed        | PASS
  Tests       | PASS
  Boot        | PASS

  Total: 5/5 passed in 42.3s

[PASS] All checks passed
```

Exit code: **0**

## Scratch Directory

Logs go to `dev/.check-scratch/logs/`:

```
dev/.check-scratch/
├── logs/
│   ├── compile.log
│   ├── boot.log
│   └── boot.err
```

The directory is git-ignored via `.git/info/exclude` (added automatically on first run).

## Exit Codes

- **0**: All checks passed
- **1**: One or more checks failed

## Traps

### 1. CRLF Line Endings

See `-Format` above. This Windows checkout carries CRLF. Scoped checks prevent accidental whole-repo reformatting.

### 2. Orphan `beam.smp` Processes

The `-Boot` check kills the server and waits for graceful shutdown. If shutdown fails, `beam.smp` processes remain and block the next boot with "Address already in use" on port 4444.

**Manual fix:**
```powershell
Get-Process beam.smp -ErrorAction SilentlyContinue | Stop-Process -Force
```

The harness handles this automatically on exit.

### 3. `rpc` vs `eval`

The seed check uses `mix eval` (compile-time, doesn't start applications). Don't use `eval` for ESI calls or inter-process communication; you'll get `unknown registry: Req.Finch`. Use `bin/wanderer_app rpc` for compiled releases.

### 4. `localStorage.wandererLastVersion`

**Affects map canvas only, not `/corp/*` routes.** When testing the map UI in a browser, set it before loading:

```javascript
localStorage.setItem('wandererLastVersion', '1.103.4-chewy.24');
location.reload();
```

## Typical Workflow

```powershell
# Setup (first time)
.\dev\check.ps1 -Db
.\dev\check.ps1 -Seed

# Development
.\dev\check.ps1 -Compile        # Quick check
.\dev\check.ps1 -Format         # Format changed files
.\dev\check.ps1 -Test           # Test identity suite

# Before commit
.\dev\check.ps1 -All            # Full suite

# Debugging test failures
.\dev\check.ps1 -Test "test/integration/corp_identity_live_test.exs"
```

## Reference: Feature Flag Under Test

The identity suite is gated by:

- **Env:** `WANDERER_IDENTITY_SUITE` (default `false`)
- **Plug:** `lib/wanderer_app_web/controllers/plugs/check_identity_suite_disabled.ex`
- **Router:** `lib/wanderer_app_web/router.ex` (routes in `/corp` scope)
- **LiveViews:** `lib/wanderer_app_web/live/corp/{corp_shell_live.ex,corp_identity_live.ex}`

## See Also

- `dev/README.md` — Docker-based (throwaway) environment
- `lib/wanderer_app_web/controllers/dev_auth_controller.ex` — Dev auth endpoint
- `lib/wanderer_app/dev/seed.ex` — Seeding
- `AGENTS.md` — Version bumping, upstream merge strategy
