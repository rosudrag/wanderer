# Wanderer Verification Harness: `dev/check.ps1`

One-command proof that a chewy feature keeps its contract (AGENTS.md rule 6):
**flag off ⇒ upstream behaviour, unchanged; flag on ⇒ the feature works.**
Run from Windows PowerShell.

## Quick Start

```powershell
cd I:\Development\github\wanderer
.\dev\check.ps1 -All
```

Expected: a summary table with `PASS` for all seven checks, exit code **0**.

## Prerequisites

Exact toolchain from a previous session:

- **Erlang/OTP 26.2.5.5** at `C:\erl26\bin`
- **Elixir 1.17.3** at `C:\elixir1173\bin`
- **PostgreSQL 17** listening on localhost:5432, user `postgres`, password `postgres`

`check.ps1` probes `PATH` first — if `mix` already resolves, it uses whatever
is on `PATH` and never touches the above. It only falls back to
`C:\erl26\bin`/`C:\elixir1173\bin` (or `$Env:WANDERER_TOOLCHAIN_PATHS`, a
`;`-separated list, if set) when `mix` isn't already reachable, and it fails
immediately with a clear message — not a 30-second timeout on the first
`mix` call — if those fallback dirs don't exist either.

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

Run individually with `-Compile`, `-Format`, `-Db`, `-Seed`, `-Test [pattern]`,
`-Boot`, `-Routes`, or all of them with `-All`. Every switch is independently
runnable — `-Boot`/`-Routes` do not depend on each other or on `-Db`/`-Seed`
having run first in the same invocation, though `-Routes`' dev-login flow
does need a migrated dev database to exist (run `-Db` at least once).

### `-Compile`

```powershell
.\dev\check.ps1 -Compile
```

Runs `mix compile --force --warnings-as-errors`.

- `--force` re-runs the full compile graph every time (a cached incremental
  compile would not re-trigger it) — this is what catches the compile-time
  struct-dependency deadlock guarded against in
  `lib/wanderer_app/api/policies/map_scoped.ex:31-56`.
- `--warnings-as-errors` makes a new warning a hard failure, not silent log
  noise.

**Expected output:**
```
  [PASS] Compilation succeeded (20.8s)
```

### `-Format`

```powershell
.\dev\check.ps1 -Format
```

Runs `mix format --check-formatted` **scoped to `.ex`/`.exs` files changed
vs `origin/chewy` (falling back to `HEAD` if that ref doesn't exist) plus
any new untracked files.** Never repo-wide.

**CRLF Trap (Important)**

This Windows checkout has `core.autocrlf=true`: every committed file is
CRLF on disk, while `mix format` always emits LF. An unscoped
`mix format --check-formatted` (or worse, `mix format`) treats that
CRLF/LF byte difference as "unformatted" for **every single file in the
repo**, whether or not its content actually violates any style rule. A
previous agent ran `mix format` unscoped this way and it rewrote ~550
unrelated files. The scoped check sidesteps this because files written or
edited by an agent's own tools land on disk as LF already (verified: `write`
output is byte-for-byte LF, no CR), so they format cleanly; it is *only*
safe because it never reaches into the CRLF-committed remainder of the repo.

If you ever run `mix format` unscoped by mistake, revert with:

```powershell
git checkout -- .
```

**Expected output (no changes):**
```
  [SKIP] No .ex/.exs files changed vs origin/chewy
```

**Expected output (formatted files):**
```
  [PASS] 3 file(s) formatted (vs origin/chewy, 0.8s)
```

### `-Db`

```powershell
.\dev\check.ps1 -Db
```

Idempotent: `mix ecto.create --quiet` + `mix ecto.migrate --quiet` against
`wanderer_dev`.

**Expected output:**
```
  [PASS] Created + migrated (2.0s)
```

### `-Seed`

```powershell
.\dev\check.ps1 -Seed
```

Runs `mix run dev/seed_identity.exs` (new script — seeding for the identity
suite does NOT live in `lib/wanderer_app/dev/seed.ex`, which seeds an
unrelated 15-system map fixture for the map-canvas smoke flow in
`dev/README.md`). Idempotent: finds existing rows by identity key
(`eve_corporation_id`, `hash`, `eve_id`) and updates them in place.

Seeds:
- one `WandererApp.Api.OwnedCorporation`
- one `WandererApp.Api.User` with two `WandererApp.Api.Character`s: one
  whose `corporation_id` matches the seeded corp (main-eligible), one that
  does not (guest-only)

Plain `mix run` (not `mix eval`) is required here, not just permitted:
Ash/Ecto need the Repo pool actually running to talk to Postgres, and
`mix eval` never starts the application (see Trap 3 below). It's still
safe from the npm watcher — Phoenix only starts `watchers:` when
`server?` is true, and plain `mix run` never sets that.

**Expected output:**
```
  [PASS] Seeded (2.7s)
```

### `-Test [pattern]`

```powershell
.\dev\check.ps1 -Test
.\dev\check.ps1 -Test "test/integration/corp_identity_live_test.exs"
```

Runs `mix test` (temporarily forcing `MIX_ENV=test` for just this check —
see Trap 5). Default target is the `test/integration/` **directory** plus
`test/unit/controllers/auth_controller_test.exs`. A pattern argument
(space-separated file paths/globs) overrides it entirely.

It reports **ExUnit's own count**, not a file count, and it invokes mix
through `cmd /c` with the paths joined into one string. Both of those are
load-bearing, and the reason is Trap 7 below: this step used to hand mix a
discovered list of ~34 separate path arguments, which silently ran only the
last file — 18 tests instead of 384 — while printing "34 file(s) passed"
and a green PASS.

**Expected output:**
```
  [PASS] 384 tests, 0 failures, 65 excluded (109.4s)
    test/integration
    test/unit/controllers/auth_controller_test.exs
```

The 65 exclusions are the `:integration`/`:pending` tags configured in
`test/test_helper.exs`, not a harness decision.

### `-Boot`

```powershell
.\dev\check.ps1 -Boot
```

Boots the real application on the fixed port **4444** (from
`config/dev.exs`), confirms `GET /` answers HTTP 200, then shuts it down
and verifies no orphan process survives. See "How -Boot/-Routes avoid the
npm watcher" below for how it avoids `mix phx.server` entirely.

**Expected output:**
```
  [PASS] Started, answered HTTP 200, shut down cleanly (4.8s)
```

### `-Routes`

```powershell
.\dev\check.ps1 -Routes
```

Proves the `WANDERER_IDENTITY_SUITE` flag contract end-to-end by booting
the app **twice**, each probe reported on its own line:

1. **Flag unset** (upstream/default behaviour): `GET /corp` and
   `GET /corp/identity` must both be **404** — the plug
   (`WandererAppWeb.Plugs.CheckIdentitySuiteDisabled`) returns 404 before
   LiveView ever mounts.
2. **`WANDERER_IDENTITY_SUITE=true`** + a `WANDERER_DEV_AUTH_TOKEN`-based
   dev-login session (cookie jar via `-SessionVariable`/`-WebSession`):
   `GET /corp` and `GET /corp/identity` must both be **200**, and
   `/corp/identity`'s body must contain `id="corp-identity-state"`.

Each boot is independent (its own `Start-Boot`/`Stop-Boot` cycle, its own
log file), so a failure in one phase doesn't cross-contaminate the other.

**Expected output:**
```
  [PASS] flag off: GET /corp -> 404
  [PASS] flag off: GET /corp/identity -> 404
  [PASS] flag on: GET /dev/login -> 200 (session established)
  [PASS] flag on: GET /corp -> 200
  [PASS] flag on: GET /corp/identity -> 200
  [PASS] flag on: /corp/identity body contains id="corp-identity-state"
```

**Extending `-Routes` for the next feature flag.** `-Routes` currently
only proves the `WANDERER_IDENTITY_SUITE` contract. It intentionally does
NOT also probe `WANDERER_GROUP_MAP_SYNC`'s `/corp/map-grants` page (added
by the Phase 1 commit, `lib/wanderer_app_web/live/corp/group_map_grants_live.ex`)
— one flag's contract per probe keeps a failure unambiguous about which
feature broke. Note that page is gated differently from `/corp/identity`:
it sits inside the same `/corp` scope (so it's still 404 when
`WANDERER_IDENTITY_SUITE` is off, same as every other `/corp/*` route),
but its OWN flag check is a LiveView-`mount/3` redirect
(`push_navigate(to: ~p"/corp")` when `corp_flags[:group_map_sync_enabled?]`
is false), not a second router-level 404 plug — and it also requires
`current_user_role == :admin`, which the seeded dev-login user is not by
default. To add a probe for a flag like this, follow the same shape as
the existing `off`/`on` block in the `-Routes` section of `check.ps1`:

1. Pick the fixed dev-only route for the new flag (e.g. `/corp/map-grants`).
2. In the flag-off boot (`$bootOff`), the new flag is already unset (every
   env var not explicitly overridden stays cleared), so the existing
   `/corp` 404 assertion already covers "flag off" for any route nested
   under `/corp` — no new off-boot assertion is needed unless the new
   route has its OWN failure mode besides the shared 404 (like the
   redirect above).
3. In the flag-on boot (`$bootOn`), add the new flag's env var (e.g.
   `WANDERER_GROUP_MAP_SYNC = "true"`) to the `Start-Boot` call's
   hashtable alongside `WANDERER_IDENTITY_SUITE = "true"` — no new boot
   cycle needed, since both flags' contracts can be proven against the
   same authenticated session as long as they don't require mutually
   exclusive states. If the route also requires a role the dev-login user
   lacks (as `/corp/map-grants` does), promote that user first — e.g. via
   a small addition to `dev/seed_identity.exs` setting the seeded user's
   role, or a one-off `Ash.update!` in the probe boot itself — then probe
   with the same `$session` cookie jar and assert 200 (plus a
   distinguishing body substring, the way `id="corp-identity-state"`
   distinguishes the identity suite's page).
4. Print a `Status` row per new assertion — do not fold multiple flags'
   assertions into one row, or a failure stops being self-explanatory.

### `-All`

```powershell
.\dev\check.ps1 -All
```

Runs all seven checks in sequence and prints a summary table.

**Expected output:**
```
Summary
  Compile      | PASS | 20.8s
  Format       | PASS | 0.8s
  Database     | PASS | 2s
  Seed         | PASS | 2.7s
  Tests        | PASS | 2.8s
  Boot         | PASS | 4.8s
  Routes       | PASS | 9.4s

  Total: 7/7 passed in 43.4s

[PASS] All checks passed
```

Exit code: **0**

## How `-Boot`/`-Routes` avoid the npm watcher

`mix phx.server` sets `server: true` on the endpoint itself, and that is
exactly what makes Phoenix start the `npm run watch` esbuild watcher
configured in `config/dev.exs`'s `watchers:` key — which hangs forever on
a checkout with no local `npm install`, and is why `-Boot` used to time
out.

`config/dev.exs` is **never edited** to fix this. Instead `dev/boot.exs` is
run as `mix run --no-start dev/boot.exs`: `--no-start` delays starting the
OTP application, giving the script a chance to override just
`server: true` and `watchers: []` via `Application.put_env/3` *before*
calling `Application.ensure_all_started(:wanderer_app)` itself. Since
watchers only start when `server?` is true (or `force_watchers` is set —
see `Phoenix.Endpoint.Supervisor.watcher_children/3` in
`deps/phoenix/lib/phoenix/endpoint/supervisor.ex`), clearing `watchers:` in
the same override is required, not optional, once `server:` flips to true.

Booting under `MIX_ENV=test` instead (config/test.exs never configures
`watchers:` at all) would dodge the same problem, but was not chosen: it
would boot against the `wanderer_test` database rather than the
`wanderer_dev` one `-Db`/`-Seed` provision, and `-Routes`' dev-login
fixtures need to land in the database `-Seed` actually seeds.

## Scratch Directory

Logs go to `dev/.check-scratch/logs/`:

```
dev/.check-scratch/
└── logs/
    ├── compile.log
    ├── format.log
    ├── db.log
    ├── seed.log
    ├── test.log
    ├── boot.log / boot.err
    ├── routes-off.log / routes-off.err
    └── routes-on.log / routes-on.err
```

The directory is excluded via `.git/info/exclude`, **not** `.gitignore` —
see AGENTS.md: our untracked paths live there so they never conflict on an
upstream merge. `check.ps1` adds the entry itself on first run if missing.

## Exit Codes

- **0**: All requested checks passed
- **1**: One or more checks failed

## Traps

### 1. CRLF Line Endings / `mix format`

See `-Format` above. This Windows checkout carries CRLF
(`core.autocrlf=true`); the formatter always emits LF. Scoped checks
prevent an accidental whole-repo reformat. If you need to strip CR from a
single file by hand:

```powershell
(Get-Content .\file.ex -Raw).Replace("`r`n", "`n") | Set-Content .\file.ex -NoNewline
```

### 1a. `-Routes` asserts status codes, not layout

`-Routes` proves a page is *reachable* and that the feature flag gates it.
It cannot see that the page renders **underneath the sidebar**, or that a
nav link laid out below the visible area — both shipped to production
while `-Routes` was green, because both return `200`.

For any UI change, verify the rendered DOM, not just the status code:
boot, log in via `/dev/login`, and check element parentage and classes.
Two rules that each cost a release (they are in `AGENTS.md`'s corp-suite
navigation convention):

- a page root needs `p-4 pl-20 … overflow-auto`, like every upstream page,
  or the absolutely-positioned `<aside>` covers its content;
- sidebar entries must render **inside**
  `Layouts.sidebar_nav_links/1`'s `<ul>` — it is `h-full`, so a sibling
  after it lays out past the aside's bottom edge and is invisible.

Note the local boot serves an **empty stylesheet** (assets are not built
there), so pixel geometry measured locally is meaningless. DOM parentage
and class lists are still valid; screenshots are not.

### 2. Orphan `erl.exe` Processes (there is no `beam.smp` on Windows)

Windows Erlang has no separate `beam.smp` binary — the VM runs as
`erl.exe` itself (`beam.smp.dll` is a DLL loaded inside it). A cleanup
step that does `Get-Process beam.smp` on Windows matches nothing and is a
silent no-op.

Worse: Bandit/Thousand Island's listener sets `SO_REUSEADDR`, which lets a
**second** process bind port 4444 while an earlier one is still alive.
`Get-NetTCPConnection -LocalPort 4444 -State Listen` can return **one row
per distinct owning process**, not one row total — killing only the first
row leaves the rest running forever, silently answering some fraction of
future requests on the same port. `check.ps1`'s `Stop-Boot` kills every
distinct PID the port reports, not just the first, then verifies both
"nothing listening" and "no tracked PID still alive" before returning.

**Manual fix, if a boot is ever interrupted (e.g. Ctrl-C mid-run):**
```powershell
Get-Process erl -ErrorAction SilentlyContinue | Stop-Process -Force
```

### 3. `rpc` vs `eval`

`mix eval` never starts the OTP application (no Repo pool, no Finch pools,
no PubSub) — it's compile-time-only code execution. `dev/seed_identity.exs`
therefore runs via plain `mix run`, which does start the application, not
`mix eval`. For a *release* (the Docker throwaway stack in
`dev/README.md`), the equivalent distinction is `bin/wanderer_app rpc`
(applications running) vs `bin/wanderer_app eval` (they are not) —
`eval` there fails ESI/HTTP calls with `unknown registry: Req.Finch`.

### 4. `localStorage.wandererLastVersion`

**Affects the map canvas only, not `/corp/*` routes.** `-Routes` never
touches a browser or `localStorage`, so this never affects `check.ps1`.
It only matters if you separately open `/<map_slug>` in a real browser per
`dev/README.md`: a fresh profile has never set the version key, the
server never starts the map, and you get an "Update Required" splash with
an empty canvas and nothing in the logs. Set it to the running `@version`
from `mix.exs` before loading the map page:

```javascript
localStorage.setItem('wandererLastVersion', '<mix.exs @version>');
location.reload();
```

### 5. `MIX_ENV` for `-Test`

Every other check runs under `MIX_ENV=dev` (they exercise the dev
database). `mix test` needs `config/test.exs`'s
`Ecto.Adapters.SQL.Sandbox` pool — running it under `MIX_ENV=dev` fails
immediately with `cannot invoke sandbox operation with pool
DBConnection.ConnectionPool`. `check.ps1`'s `-Test` block sets
`$Env:MIX_ENV = "test"` for just that one check and restores `"dev"`
immediately after, so it never leaks into `-Db`/`-Seed`/`-Boot`/`-Routes`.

### 6. Concurrent in-flight work

Another agent may be committing to `lib/**`/`config/**`/`test/**`/
`AGENTS.md` at the same time (this repo intentionally allows it — see
AGENTS.md rule 4). A `-Compile`/`-Test` failure that mentions files this
harness doesn't touch is very likely theirs, not the harness's or your
own change's; check the log's file paths before assuming otherwise.

### 7. Passing an array of paths to `mix` runs only the LAST one

`mix` on Windows is `mix.bat`. Handing a PowerShell **array variable** to
it as arguments silently drops every element but the last:

```powershell
$tp = @('test/integration','test/unit/controllers/auth_controller_test.exs')
mix test $tp        # 18 tests, 0 failures      <- only the last path ran
mix test test/integration test/unit/controllers/auth_controller_test.exs
                    # 384 tests, 0 failures, 65 excluded
```

Both measured 2026-09-29. It is silent and it is green: `mix` exits 0, so
the harness reported PASS while running 5% of the suite, and the `-Test`
step had been doing exactly that (it discovered ~34 files and passed them
as an array). The fix is to join the paths into one string and go through
`cmd /c`, which re-splits the line itself:

```powershell
cmd /c "mix test $($testPaths -join ' ') > `"$log`" 2>&1"
```

The tell is wall-clock time: the real integration suite takes ~110s, so a
`Tests` row reading 2.9s means it did not run. That is why the step now
prints ExUnit's own `N tests, N failures` line instead of a file count —
a file count cannot distinguish the two cases.

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

Dev-only authentication bypass (needed by `-Routes`' flag-on boot):

- **Env:** `WANDERER_DEV_AUTH_TOKEN` (unset/short = plain 404, never set in production)
- **Route:** `GET /dev/login?token=…`
- **Controller:** `lib/wanderer_app_web/controllers/dev_auth_controller.ex`
- **Gate:** `lib/wanderer_app/env.ex:50-59` (`dev_auth_enabled?/0`, requires ≥16 bytes)

## See Also

- `dev/README.md` — Docker-based (throwaway) environment for manual browser smoke testing
- `dev/seed_identity.exs` — identity suite fixture seeding (this harness's `-Seed`)
- `dev/boot.exs` — watcher-free application boot (this harness's `-Boot`/`-Routes`)
- `lib/wanderer_app/dev/seed.ex` — unrelated map-canvas seeding, not used by this harness
- `AGENTS.md` — version bumping, upstream merge strategy, feature-flag contract
