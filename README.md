# Autoforge

Autoforge is a platform for spinning up isolated, Docker-based development
environments from reusable templates — with built-in AI chat, a browser-based
code editor, terminal access, and one-click deployment to Google Cloud.

## Features

### Project Sandboxes

Create fully isolated development environments in seconds. Each project gets its
own Docker containers, a PostgreSQL database with generated credentials, and
pre-configured tooling — all defined by a reusable project template.

- **Docker-based isolation** — each project runs in its own container with a
  dedicated database
- **Browser-based editor** — VS Code in the browser via code-server, with
  configurable extensions per template
- **Terminal access** — full shell access with multiple concurrent sessions over
  WebSocket
- **Dev server management** — start/stop the project's dev server from the UI
  with live-streamed output
- **Template file rendering** — files support Liquid template syntax for
  variable substitution (project name, DB credentials, etc.)
- **Bootstrap & startup scripts** — templates define scripts that run during
  provisioning and on every container start
- **Environment variables** — per-project key/value pairs, synced to the
  container as an env file
- **Template push** — push updated template files to all running and stopped
  projects using a template, or push individual files/folders selectively
- **GitHub integration** — configure a remote repo during provisioning and push
  automatically

### Project Templates

Reusable blueprints that define everything about a project's environment:

- Base Docker image and database image
- Template files with Liquid variable rendering
- Bootstrap script (runs once during provisioning)
- Startup script (runs on every container start)
- Dev server script (defines how to start the dev server)
- Dockerfile template (for deployments)
- Code-server extensions to pre-install
- User group access control

### AI Chat

Create AI bots backed by multiple LLM providers and have multi-user
conversations with tool integration.

- **Multi-model support** — configure each bot with a specific LLM model
  (Anthropic, OpenAI, etc.) via ReqLLM
- **Per-user provider keys** — each user stores their own encrypted API keys
- **Custom tools** — define tools with JSON schemas that bots can invoke
- **Conversations** — persistent multi-user chat sessions with full message
  history
- **MCP server** — Model Context Protocol endpoint for external tool
  integration

### Deployments

Deploy projects to Google Cloud VMs with automated image building, reverse proxy
configuration, and domain management.

- **VM provisioning** — create Google Compute Engine instances from configurable
  templates (OS, machine type, disk, region, network)
- **Image building** — build Docker images on remote VMs via Tailscale, push to
  Google Artifact Registry
- **Reverse proxy** — Caddy configuration management for routing multiple
  deployments per VM
- **Domain assignment** — automatic Cloud DNS record management
- **Per-deployment env vars and database** — isolated configuration for each
  deployment

### Networking

- **Tailscale integration** — optional sidecar container for HTTPS access to
  project sandboxes on your tailnet, without exposing public ports
- **Remote Docker** — manage containers on remote VMs over Tailscale

### Administration

- **User management** — Auth0 OAuth, magic links, API keys
- **User groups** — organize users for template and resource access control
- **Ash Admin** — data management dashboard (dev only)
- **Oban dashboard** — background job monitoring (dev only)
- **Live Dashboard** — Phoenix telemetry and metrics (dev only)

## Tech Stack

| Layer | Technology |
|---|---|
| Web framework | Phoenix 1.8, LiveView |
| Domain framework | Ash (AshPostgres, AshStateMachine, AshCloak, AshPaperTrail, AshAuthentication) |
| Background jobs | Oban |
| Database | PostgreSQL |
| UI | Fluxon components, Tailwind CSS v4 |
| LLM client | ReqLLM |
| HTTP client | Req |
| Containers | Docker Engine API (Unix socket / TCP) |
| Infrastructure | Google Cloud (Compute Engine, Artifact Registry, Cloud DNS) |
| Networking | Tailscale |
| Reverse proxy | Caddy |
| Authentication | Auth0 OAuth2 |
| Encryption | Cloak (AES-GCM) |
| Template engine | Solid (Liquid) |

## Prerequisites

- Elixir 1.15+
- Erlang/OTP 24+
- PostgreSQL 13+
- Docker with the daemon running (for project sandboxes)

## Setup

### 1. Install dependencies

```bash
mix setup
```

This runs `deps.get`, database creation/migration, seeds, and asset
compilation.

### 2. Configure environment variables

Copy the example env file and fill in your values:

```bash
cp .env.example .env
```

**Required for all environments:**

| Variable | Description |
|---|---|
| `DATABASE_URL` | PostgreSQL connection string (e.g. `ecto://user:pass@localhost/autoforge_dev`). Not needed in dev if using default Postgres credentials. |

**Required for production:**

| Variable | Description |
|---|---|
| `SECRET_KEY_BASE` | Phoenix secret — generate with `mix phx.gen.secret` |
| `TOKEN_SIGNING_SECRET` | Secret for signing authentication tokens |
| `CLOAK_KEY` | Base64-encoded 32-byte key for field encryption — generate with `32 \|> :crypto.strong_rand_bytes() \|> Base64.encode()` |
| `PHX_HOST` | Public hostname for the app |

**Auth0 (required for login):**

| Variable | Description |
|---|---|
| `AUTH0_CLIENT_ID` | Auth0 application client ID |
| `AUTH0_CLIENT_SECRET` | Auth0 application client secret |
| `AUTH0_BASE_URL` | Auth0 domain (e.g. `https://your-tenant.auth0.com`) |
| `AUTH0_REDIRECT_URI` | OAuth callback URL (e.g. `http://localhost:4000/auth/auth0/callback`) |

**Optional — AI chat:**

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | Default Anthropic API key (users can also add their own via the UI) |

**Optional — Google Cloud (for deployments and VMs):**

Google service account credentials are configured through the Settings UI at
runtime, not through environment variables.

**Optional — Tailscale (for HTTPS project access):**

Tailscale configuration is managed through the Settings UI at runtime.

**Optional — Fluxon (component library):**

| Variable | Description |
|---|---|
| `FLUXON_PUBLIC_KEY` | Fluxon Hex repo public key |
| `FLUXON_AUTH_KEY` | Fluxon Hex repo auth key |

### 3. Start the server

```bash
mix phx.server
```

Or with an IEx shell:

```bash
iex -S mix phx.server
```

Visit [localhost:4000](http://localhost:4000).

## Development

### Useful commands

```bash
# Run the precommit checks (compile warnings, format, test, unused deps)
mix precommit

# Run tests
mix test

# Run a specific test file or line
mix test test/path/to/test.exs:42

# Reset the database
mix ecto.reset

# Generate a new migration
mix ash_postgres.generate_migrations --name description_of_change
```

### Dev-only routes

| Path | Description |
|---|---|
| `/dev/dashboard` | Phoenix Live Dashboard |
| `/dev/mailbox` | Swoosh email preview |
| `/oban` | Oban job dashboard |
| `/admin` | Ash Admin data browser |

### Background job queues

| Queue | Workers | Purpose |
|---|---|---|
| `default` | 10 | General tasks |
| `ai` | 5 | LLM inference |
| `sandbox` | 3 | Project provisioning, template push |
| `github` | 3 | GitHub API operations |
| `deployments` | 3 | VM provisioning, image building |

Scheduled jobs:
- **Project cleanup** — every 5 minutes
- **VM maintenance** — daily at 3 AM

## Architecture

### Ash Domains

| Domain | Responsibility |
|---|---|
| `Accounts` | Users, authentication (Auth0 OAuth, magic links, API keys), LLM provider keys, user groups |
| `Projects` | Project templates, projects (with state machine), Docker sandbox orchestration, file management, Tailscale integration |
| `Deployments` | VM templates, VM instances (GCE), deployments, image building, Caddy reverse proxy, Cloud DNS |
| `Ai` | Bots, tools (JSON schema definitions) |
| `Chat` | Conversations, messages, participants, tool invocations |
| `Config` | Tailscale config, Google service account, GCS storage, Connecteam API keys |

### State Machines

**Project lifecycle:**

```
creating -> provisioning -> running <-> stopped
                |                         |
                v                         v
              error                   destroyed
```

**Deployment lifecycle:**

```
pending -> deploying -> running <-> stopped
               |                      |
               v                      v
             error                 destroyed
```

### Encryption

Sensitive fields are encrypted at rest using Cloak (AES-GCM):

- GitHub tokens, SSH keys (User)
- Database passwords (Project, Deployment)
- LLM API keys (LlmProviderKey)

## Production

Build a release and start with the server flag:

```bash
MIX_ENV=prod mix release
PHX_SERVER=true ./build/autoforge/bin/autoforge start
```

Required production environment variables: `DATABASE_URL`, `SECRET_KEY_BASE`,
`TOKEN_SIGNING_SECRET`, `CLOAK_KEY`, `PHX_HOST`, and the Auth0 variables.

In production, the database connection uses SSL by default (configured for
VPC/AlloyDB).
