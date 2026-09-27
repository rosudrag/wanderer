# ChewyTech Corp/Alliance Suite — Documentation Index

## The Decision

**This Wanderer fork becomes the alliance's SINGLE auth + management platform — no external SeAT or Alliance Auth installation.** The mapper's existing login (default SSO scope, 5 endpoints, no consent screen) must keep working unchanged when the suite is off. Phases 0–18 deliver full parity with SeAT and Alliance Auth: roster + activity, structures + timers, wallet visibility, SRP workflow, recruitment pipeline, fleet scheduling, Discord role sync, ESI-backed accounting, and all director-gated features. Every feature gates behind an env var defaulting to upstream behaviour; rollback costs a redeploy, not a code revert.

## Documents

| File | What | When to read | Audience |
|---|---|---|---|
| **inventory.md** | Verified facts about this codebase as of 2026-09-27 — Ash resources, ESI integration, permissions model, routes, background jobs | First, to learn what exists; then as a reference while designing | Owner + agents |
| **corp-suite-research.md** | Domain research: what corp/alliance management actually is, what's reusable in this codebase, ESI availability per feature, three scoped proposals, open questions for the owner | After inventory; to understand the problem space and feasibility | Owner (sections D–E), agents (sections A–C) |
| **seat-parity.md** | SeAT and Alliance Auth as reference implementations — module inventory, auth model data details, Discord mechanics, complete ESI scope catalogue with ETag/rate-limit facts, what they get wrong | When building a specific phase; to know exactly what endpoints to call and how to model auth/perms | Agents (sections 5–10); owner (section 7) |
| **corp-suite-plan.md** | The build plan: 19 phases ordered by value, architecture decisions (State/Group, ESI sync framework, Discord bot), data models, 11 numbered hooks to existing files, acceptance criteria per phase | Before implementing anything; then as each phase starts, for smoke procedures | Agents (primary); owner (§1 decision summary, phases 0–3) |

## Read This First (Owner)

**Owner decisions needed before implementation begins:**

| # | Question | Blocks | Default if owner says nothing |
|---|---|---|---|
| 1 | Who holds the director-scope token day one, and succession plan? | `OwnedCorporation.director_character_id` UI, Phases 4/6/7/13/16/17/18 staging | No default possible — real organizational fact |
| 2 | Approximate active member count, and expected growth | Poll cadence tuning across every Phase-2+ phase | Tens to low hundreds; re-tune above ~500 |
| 3 | Minimum-viable account-recovery/admin-disable action | Phase 1 go-live | Recommend: alongside Phase 1, not deferred |
| 4 | Acceptable ops budget (RAM/DB) on Hetzner EX44 for Phases 16/17 | Whether Phases 16/17 ship at daily cadence or cut entirely | Treat as tight — daily cadence; these cut first if budget is constrained |
| 5 | Reconciliation against `docs/chewy/seat-parity.md`'s ESI scope catalogue | Phase 0's `member_scope`/`director_scope` strings before implementation | Not a design blocker — only config-literal in hook #1 changes |


## Read This First (Implementing Agent)

**Non-negotiables from this codebase (`AGENTS.md`) and the plan:**

- **Additive files over hot-file edits.** A new module never conflicts; edits to existing files (especially `map_live.ex`, `router.ex`, `character.ex`) conflict on every upstream merge. Pattern: if you must edit existing code, add a **one-line hook** (numbered 1–11 in the plan), document it in the patch table, and keep the edit <3 lines.
- **One env var per feature, defaulting to upstream behaviour.** WANDERER_IDENTITY_SUITE, WANDERER_GROUP_MAP_SYNC, WANDERER_SYNC_FRAMEWORK, etc. Unset = feature is inert, no code path is taken.
- **`@version` bump in `mix.exs` in every behaviour-changing commit.** Deployed image tag derives from it (`1.103.4-chewy.2`). Skip the bump and two builds share a tag; Docker keeps the old image.
- **Commits prefixed `chewy:`** — e.g., `git commit -m "chewy: phase 2 sync framework"`. Makes `git log upstream/main..chewy` the honest patch list.
- **Merge upstream, never rebase `chewy`.** The branch is pushed and deployed as-is.
- **`mix ash.codegen` for every schema change.** Commit the resulting `priv/resource_snapshots/repo/*.json` — bad snapshot resolution silently desyncs the generator.
- **`mix format` at 100 columns with CR stripped.** Windows checkouts pick up CRLF; the formatter reports every file as unformatted until you strip CR.
- **Smoke on the `dev/` throwaway stack with `bin/wanderer_app rpc`, never `eval`** (eval starts no applications, so Finch has no pools). See `dev/README.md:43-47` and `84-96`.

## Phase Roadmap (0–18)

| Phase | Name | Env Var |
|---|---|---|
| **0** | Identity, state, groups foundation | `WANDERER_IDENTITY_SUITE` |
| **1** | Map-ACL-from-groups | `WANDERER_GROUP_MAP_SYNC` |
| **2** | ESI sync framework | `WANDERER_SYNC_FRAMEWORK` |
| **3** | Discord role sync | `WANDERER_DISCORD_SYNC` |
| **4** | Roster & corp member tracking | `WANDERER_CORP_ROSTER` |
| **5** | Corp wallet UI | `WANDERER_CORP_WALLET_UI` |
| **6** | Structure timers (owned, ESI-synced) | `WANDERER_CORP_STRUCTURES_SYNC` |
| **7** | Moon extraction tracking | `WANDERER_MOON_EXTRACTION` |
| **8** | Timerboard (unified board) | `WANDERER_TIMERBOARD` |
| **9** | Recruitment / application pipeline | `WANDERER_RECRUITMENT_PIPELINE` |
| **10** | Fleet ops + attendance (FAT) | `WANDERER_FLEET_OPS` |
| **11** | SRP approval workflow | `WANDERER_SRP_WORKFLOW` |
| **12** | Doctrines + fitting/skill compliance | `WANDERER_DOCTRINE_FIT` |
| **13** | Contracts | `WANDERER_CORP_CONTRACTS_SYNC` |
| **14** | Killboard / kill-loss stats | `WANDERER_ALLIANCE_KILL_STATS` |
| **15** | ESI notifications / pings | `WANDERER_ESI_NOTIFICATIONS` |
| **16** | Corp/character asset ledger | `WANDERER_CORP_ASSETS_SYNC` |
| **17** | Industry + mining ledger | `WANDERER_INDUSTRY_SYNC` |
| **18** | Market orders | `WANDERER_MARKET_ORDERS` |

*Phases 0–18 are specified/designed in `corp-suite-plan.md` §9. Phases 0–3 are the foundation; start there.*

## Current Status

**No implementation has started.** Phase 0 (Identity foundation) is the next executable unit. All upstream merges, backports, and non-suite bugfixes continue in parallel; they never conflict with additive suite code if the hook discipline is kept.
