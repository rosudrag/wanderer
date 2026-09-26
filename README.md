# ChewyTech — EVE Online Assistant

This is a private fork of [`wanderer-industries/wanderer`](https://github.com/wanderer-industries/wanderer), a distributed EVE Online mapper tool. It runs as a private instance requiring EVE Online SSO authentication.

## Getting Started

**This is not a public service.** The deployed instance is private. Self-hosting requires Elixir/OTP, Node.js, PostgreSQL, and EVE SSO application credentials.

### Prerequisites

Check `.tool-versions` for pinned Elixir, OTP, and Node.js versions. PostgreSQL 16 is required ([.devcontainer/docker-compose.yml](https://raw.githubusercontent.com/wanderer-industries/wanderer/main/.devcontainer/docker-compose.yml#L23)).

### Setup

```bash
cp .env.example .env
# Edit .env with your EVE SSO keys and database config
mix setup
```

The `setup` alias ([mix.exs:151](mix.exs#L151)) runs `deps.get`, `ecto.setup` (which loads [priv/repo/seeds.exs](priv/repo/seeds.exs)), and builds frontend assets.

### Run Locally

```bash
make start
```

or equivalently:

```bash
source .env && MIX_ENV=dev iex -S mix phx.server
```

([Makefile:22](Makefile#L22))

Server listens on `http://localhost:4444` ([config/dev.exs:22](config/dev.exs#L22)).

### Development Without EVE Account

See [dev/README.md](dev/README.md) for a Docker-based smoke environment that runs without EVE SSO. This lets you test the map UI with a throwaway authenticated session.

## Database

- **Reset:** `mix ecto.reset` ([mix.exs:153](mix.exs#L153))
- **Migrate:** `MIX_ENV=dev mix ash.migrate` ([Makefile:27](Makefile#L27))

## Technology

- **Backend:** Elixir/Phoenix, PostgreSQL
- **Frontend:** React + TypeScript, TailwindCSS, ReactFlow
- **Map:** Systems, connections, signatures, beautifier layout engine

## Deployment & Fork Rules

See [AGENTS.md](AGENTS.md) for fork operations, CI/CD, and deployment guidelines.

## Private Branding

When `WANDERER_PRIVATE_BRANDING=true` ([lib/wanderer_app/branding.ex](lib/wanderer_app/branding.ex)):
- Product name and title suffix change to ChewyTech / "EVE Online Assistant"
- Public newsboard (`/news`, `/news/:slug`) and contacts page (`/contacts`) return 404
- Google Analytics is disabled
- `/license` and `/changelog` remain accessible
