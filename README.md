# Kaneo for Cloudron

A [Cloudron](https://www.cloudron.io) community package for [Kaneo](https://kaneo.app), the open
source project management tool, with its built-in **MCP server** ready for Claude, Cursor and
other MCP clients.

| | |
|---|---|
| Package | `io.github.ravolar.kaneo` |
| Upstream | [usekaneo/kaneo](https://github.com/usekaneo/kaneo) (MIT) |
| Install URL | `https://raw.githubusercontent.com/ravolar/cloudron-kaneo/main/CloudronVersions.json` |
| Image | `ghcr.io/ravolar/cloudron-kaneo` |

## What you get

* Kaneo's official build, unmodified: the API and the web app on one domain, real-time boards,
  REST API, integrations (GitHub, GitLab, Gitea, Slack, Discord, Telegram, Mattermost, webhooks).
* **MCP server** at `https://<app domain>/api/mcp` with OAuth 2.1 sign-in, plus the discovery
  documents MCP clients look for at the domain root.
* **Sign in with Cloudron** (OpenID Connect) when the app uses Cloudron user management.
* **PostgreSQL** and **outgoing email** provided by Cloudron, configured automatically.
* Cloudron backups, restore, clone and updates; releases are smoke-tested before publishing.

## Requirements

* Cloudron 10.0 or later.
* About 300–400 MB of RAM in use (the package's limit is 1 GB).
* Optional: S3-compatible object storage for attachments (AWS S3, Cloudflare R2, MinIO, ...).

## Installation

1. In the Cloudron dashboard open **App Store → Add custom app → Community app** and enter:

   ```
   https://raw.githubusercontent.com/ravolar/cloudron-kaneo/main/CloudronVersions.json
   ```

   (CLI: `cloudron install --versions-url <url> --location kaneo.example.com`)
2. Choose whether the app uses **Cloudron user management** (recommended) and who may access it.
3. Open the app right away and create the **first account**: it becomes the instance
   administrator. With Cloudron user management, use **Continue with OIDC**.

If your domain's DNS is not managed by Cloudron (provider "manual" or "no-op"), create the DNS
record for the app's hostname yourself **before** installing, so the certificate can be issued.

## Users and sign-in

|  | With Cloudron user management (recommended) | Without |
|---|---|---|
| Sign in | **Continue with OIDC** (Cloudron account) only | email (codes or password) |
| New users | any Cloudron user the app's access settings allow | by invitation only |
| Invitations | add Cloudron users to workspaces | create the account and add it to the workspace |
| Package defaults | `DISABLE_LOGIN_FORM="true"`, `DISABLE_PASSWORD_REGISTRATION="true"` | `DISABLE_REGISTRATION="true"` |

Anonymous guest access is off in both modes (`DISABLE_GUEST_ACCESS="true"`). Invitations, sign-in
codes and password resets are sent through Cloudron's mail server; when SMTP is available Kaneo
signs in with emailed codes by default (`DISABLE_EMAIL_OTP_SIGN_IN="true"` switches to passwords).

**The first account becomes the instance administrator**, and Kaneo accepts the first sign-up
whatever the `DISABLE_*` settings say. With Cloudron user management the package therefore also
closes local password sign-up at its proxy, so only a Cloudron user can become the first account.
Without it, anyone who reaches a fresh installation first could claim the admin account: create
yours right after installing and check under Admin that you are the only user.

With Cloudron user management, people who should not get a Cloudron account (outside
collaborators) cannot join by default. To allow local accounts next to Cloudron sign-in, set
`DISABLE_LOGIN_FORM="false"` and, for invited people to create a password account,
`DISABLE_PASSWORD_REGISTRATION="false"`. Then set `DISABLE_REGISTRATION="true"` so that
newcomers still need an invitation. `CUSTOM_OAUTH_AUTO_LOGIN="true"` skips the sign-in page and
goes straight to Cloudron.

If you switch an installation that already has local accounts to Cloudron sign-in only, make sure
those accounts have verified email addresses first, otherwise their OIDC sign-in can't be linked
(`account_not_linked`); see [upstream's note](https://kaneo.app/docs/core/installation/environment-variables).

## MCP

Every installation serves Kaneo's MCP endpoint:

```
https://<app domain>/api/mcp
```

* **Claude** (claude.ai / desktop): Settings → Connectors → Add custom connector, enter the URL.
* **Claude Code**: `claude mcp add --transport http kaneo https://<app domain>/api/mcp`
* **Cursor** and other clients: add a remote (Streamable HTTP) MCP server with the URL.

The client registers itself and opens Kaneo in the browser; sign in and approve the client. Tools
then run as you, with your workspace permissions: workspaces, projects, columns, tasks, comments,
labels, time entries, task relations, search and notifications.

Clients that only speak stdio can use upstream's [`@kaneo/mcp`](https://kaneo.app/docs/core/integrations/mcp)
package with `--api-url https://<app domain>`; it signs in with a device code. Nothing has to be
configured on the server for either way.

The package serves `/.well-known/oauth-protected-resource/api/mcp` and
`/.well-known/oauth-authorization-server/api` (and the same under `/api/.well-known/`) from the
API; other `/.well-known/` paths return 404.

## Configuration

Operator settings live in `/app/data/env.sh` (File Manager). The file is created on first start
with every supported option commented out; **restart** the app after editing.

Only plain assignments are accepted, one per line:

```bash
S3_BUCKET="kaneo"
GITHUB_PRIVATE_KEY_BASE64='LS0tLS1C...'   # single quotes if the value contains $, ` or \
```

A file with anything else (commands, `export`, CRLF line endings, control characters) is
rejected and the app does not start; the log names the offending lines.

Set by the package on every start (values in `env.sh` are ignored): `DATABASE_URL`,
`KANEO_CLIENT_URL`, `KANEO_API_URL`, `CORS_ORIGINS`, `TRUSTED_PROXIES`, the `SMTP_*` settings (from
Cloudron's mail server) and, with Cloudron user management, `CUSTOM_OAUTH_*` (Cloudron's OpenID
Connect provider). Without Cloudron user management you can set `CUSTOM_OAUTH_*` yourself to use
another identity provider.

All other [Kaneo environment variables](https://kaneo.app/docs/core/installation/environment-variables)
can be set in `env.sh`: sign-up controls, GitHub/Google sign-in, the GitHub App integration,
Cloudflare Turnstile, Sentry and so on.

### Secrets

`AUTH_SECRET` (sessions) and `NOTIFICATION_SECRET_ENCRYPTION_KEY` (stored integration tokens and
webhook secrets) are generated on first start into `/app/data/.secrets/secrets.env` (root-only)
and never regenerated. They are part of the app's backup. Changing `AUTH_SECRET` signs everyone
out; losing the encryption key makes stored notification secrets unreadable.

## Attachments (object storage)

Files in task descriptions and comments are stored in S3-compatible storage. Kaneo has no
local-disk option and Cloudron has no S3 addon, so without this configuration attachments are
simply disabled; everything else works.

```bash
S3_ENDPOINT="https://s3.example.com"
S3_BUCKET="kaneo"
S3_ACCESS_KEY_ID="..."
S3_SECRET_ACCESS_KEY="..."
S3_REGION="us-east-1"
S3_FORCE_PATH_STYLE="true"
```

Browsers upload **directly** to `S3_ENDPOINT` with presigned URLs, so the endpoint must be
reachable from users' browsers over HTTPS and its CORS rules must allow `PUT` from
`https://<app domain>`. Downloads go through the API. A MinIO app on the same Cloudron works.
Use a key restricted to the bucket.

## Security model

* **Privilege separation.** `start.sh` runs as root, never sources a file and never acts on a path
  the app user can rename or replace: `/app/data` and `env.sh` are root-owned (the app can only
  read `env.sh`), `.secrets` is root-only, `/run/kaneo` (runtime files and the web app) is
  recreated root-owned on every start, and symlinks in place of these files make the app refuse to
  start. Operator settings are loaded by `app-env.sh` as the app user, right before each process
  starts, so values such as `NODE_OPTIONS` never reach root.
* **Loopback API.** Upstream's API listens on every interface; `loopback.mjs` binds it to
  `127.0.0.1:1337`, so other containers on the Cloudron network can only reach Kaneo through
  nginx on port 8000. The API trusts only that nginx for `X-Forwarded-For`; nginx takes the client
  address from `X-Real-IP` only when the request comes from Cloudron's reverse proxy
  (`CLOUDRON_PROXY_IP`).
* **MCP `whoami` patched.** Upstream's built-in MCP endpoint answers `whoami` with the full
  session, including the caller's own session token, IP address and user agent, which would put
  the token into the MCP client's conversation. The package points it at `/api/user/me` (id, name,
  email, image, role). The patch is applied at build time and skipped once upstream fixes it.
* **Rate limits** (per client address, at nginx): password, code and link sign-in, sign-up and
  password reset 10/min (burst 20), since Kaneo does not rate-limit them on self-hosted
  instances; MCP client registration 5/min (burst 10).
* **Clean environments.** Supervisor starts with an empty environment, so Cloudron's addon
  credentials and the package's secrets reach only the API (through `app-env.sh`), not nginx.
* **No anonymous access by default**: guest access is off and registration is limited as
  described in [Users and sign-in](#users-and-sign-in).
* The web app's public URLs are filled in by upstream's own renderer on a root-owned copy; the
  read-only image is never modified and the app processes cannot change what is served.
* Outbound webhooks and self-hosted Gitea/GitLab integrations to private addresses are blocked by
  Kaneo unless `KANEO_ALLOW_PRIVATE_WEBHOOK_DESTINATIONS="true"`; leave it off on a shared Cloudron.

## Operations

### Logs

Dashboard → app → Logs, or `cloudron logs -f --app <location>`. A healthy start shows:

```
==> Securing data directories
==> Setting up runtime directories
==> Preparing the web app
==> Waiting for PostgreSQL
==> Starting Kaneo
✅ Database migrated successfully!
⚡ API is running at https://kaneo.example.com/api
```

`Social provider github/google/discord is missing clientId or clientSecret` warnings are expected
when those sign-in options are not configured.

### Updates

New versions are published to `CloudronVersions.json` only after an automated smoke test of the
exact image, including an MCP round trip (see [Development and releasing](#development-and-releasing)).
Cloudron offers the update in the app's **Updates** view and backs up the app first. Kaneo runs
its database migrations on start and does **not** support downgrades: to go back, restore the
pre-update backup from **Backups**.

### Backups and restore

Cloudron backs up `/app/data` (`env.sh`, `.secrets/`) and a dump of the PostgreSQL database;
restore, clone and import work as for any app. **Attachments are not included**: they stay in your
bucket.

## Troubleshooting

| Symptom | Check |
|---|---|
| App does not start, log says `env.sh ... Offending lines` | fix those lines in `/app/data/env.sh`, restart |
| Upload button missing / uploads fail | `S3_*` settings, endpoint reachable from the browser, bucket CORS allows `PUT` from the app's origin |
| No invitation or sign-in emails | app → Email: outbound mail must be enabled; Cloudron's mail logs |
| `account_not_linked` after enabling SSO-only | see [Users and sign-in](#users-and-sign-in) |
| MCP client gets 401 | sign in again from the client; the token is per user and expires |
| "Something went wrong" / "Failed to fetch dynamically imported module" after an update or restart | the browser cached Cloudron's "app is down" page (served with status 200 while the app restarts) under a file URL; clear the site's data in the browser (incognito works meanwhile). See below |
| MCP clients can't connect, registration answers 429 for a long time | the MCP client store is full (Kaneo keeps at most 1000 registered clients for 30 days); remove them with `psql "$CLOUDRON_POSTGRESQL_URL" -c "DELETE FROM mcp_oauth_state WHERE kind='client'"` (web terminal), then reconnect the clients |
| Real-time updates do not arrive | the app must be opened at its Cloudron domain (WebSocket origin check) |

While an app is stopped, restarting or updating, Cloudron's proxy answers every URL with its
"app is down" page with HTTP status 200, no `Cache-Control` and an old `Last-Modified`, which
browsers may keep for hours. A browser that requested a not-yet-loaded part of the app during that
time then fails until its cache entry expires. This is outside the package's control (it never
sees those requests); the package keeps the effect small by letting browsers cache the app's files
for 7 days and revalidate `index.html` on every load.

## Migrating an existing Kaneo installation

1. Install this package at a temporary location and stop it.
2. Dump the old database (`pg_dump --no-owner --no-acl`) and restore it into the app's database
   (`cloudron exec` → `psql "$CLOUDRON_POSTGRESQL_URL"`, or the PostgreSQL addon credentials).
3. Put the old `AUTH_SECRET` and `NOTIFICATION_SECRET_ENCRYPTION_KEY` into
   `/app/data/.secrets/secrets.env` (web terminal; quote values that contain `=`, `+` or `/`,
   e.g. base64) and the old optional settings into `env.sh`.
4. Start the app; Kaneo migrates the schema to its version. Then move the app to the final domain.

The old installation must not be newer than the package's Kaneo version.

## How it works

* The `Dockerfile` copies `/app` (API with production dependencies) and the built web app from
  `ghcr.io/usekaneo/kaneo:<version>@<digest>` onto `cloudron/node-base:24`, and checks at build
  time that the dependencies load on this Node, that the MCP tools are present and that the web
  app still carries its URL placeholders.
* Upstream's startup files (entrypoint, nginx config, URL renderer) are re-implemented in
  `start.sh` and `nginx.conf`. Their checksums are pinned in `upstream.sha256`; when upstream
  changes them the build stops, so the package is reviewed instead of silently drifting.
* `start.sh` (root) secures `/app/data`, generates secrets on first start, validates `env.sh`,
  derives the platform settings, renders the web app into `/run/kaneo/html` and starts supervisor.
* Supervisor runs the API (`node --import loopback.mjs dist/index.js`, migrations on start) and
  nginx (port 8000), both as the `cloudron` user via `app-env.sh`.

## Development and releasing

Build and run a working copy on a test Cloudron (on-server build, no registry needed):

```bash
cloudron install --location kaneo.example.com
cloudron logs -f --app kaneo.example.com
```

`test/smoke.sh <image>` runs an image the way Cloudron does (read-only root filesystem, data and
runtime volumes) next to PostgreSQL and checks start-up, migrations, the web app's rendered URLs,
the MCP discovery documents, sign-up policy, an MCP session (initialize, tools/list, a tool call),
loopback-only API, file ownership and a restart. It needs Docker, curl and jq.

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every PR and push to main | lint, image build with the build-time checks, smoke test |
| `update.yml` (**Update Kaneo**) | by hand | the release button, below |

**Releasing** is one button: Actions → **Update Kaneo** → Run workflow. It

1. looks up Kaneo's latest GitHub release and the digest of `ghcr.io/usekaneo/kaneo:<version>`,
   and stops if that version is already packaged, unless *release package changes* is ticked (then
   add a CHANGELOG line in *notes*);
2. pins the new version and digest, bumps the patch version, sets `upstreamVersion`, writes the
   CHANGELOG entry;
3. builds the image and runs the smoke test;
4. only if everything passes, pushes `ghcr.io/ravolar/cloudron-kaneo:X.Y.Z`, adds it to
   `CloudronVersions.json` as published, commits and tags `vX.Y.Z`.

If the build stops at the `upstream.sha256` check, compare the new upstream files
(`apps/web/nginx.kaneo.conf`, `apps/web/env.awk`, `apps/web/env.sh`, `deploy/kaneo-entrypoint.sh`)
with the previous release, carry relevant changes into `start.sh` / `nginx.conf`, update the
checksums and run the workflow again.

To withdraw a published version, mark it revoked (`cloudron versions revoke --version X.Y.Z`, or
set its `publishState` to `revoked`) and commit `CloudronVersions.json`.

Repository settings needed once: Actions → General → Workflow permissions **Read and write**; the
GHCR package must be public.

## License

Kaneo is © Andrej Acevski and contributors, licensed under the
[MIT License](https://github.com/usekaneo/kaneo/blob/main/LICENSE). This package runs Kaneo's
official image unmodified and is likewise MIT licensed (see `LICENSE`).
