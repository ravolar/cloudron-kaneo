#!/bin/bash
set -eu

# Kaneo on Cloudron. Runs as root for setup, then hands the API and nginx to supervisor (both drop
# to the `cloudron` user).
#
#   /app/data/env.sh     operator settings (sign-up policy, object storage, integrations); edit + restart
#   /app/data/.secrets   generated once; never regenerated, or sessions and stored secrets break

SECRETS=/app/data/.secrets/secrets.env

# Root must never act on paths the app user (cloudron) can rename or replace, or a compromised app
# could plant symlinks and steer the root steps below. So /app/data is root-owned, env.sh is
# root-owned and only readable by the app, and /run/kaneo is recreated, root-owned, on every start.
echo "==> Securing data directories"
chown root:root /app/data
chmod 755 /app/data
for path in /app/data/env.sh /app/data/.secrets "${SECRETS}"; do
    if [[ -L "${path}" ]]; then
        echo "==> ERROR: ${path} is a symbolic link, which this package never creates. Refusing to start."
        echo "    Inspect it from the web terminal, remove the link and restart."
        sleep 30
        exit 1
    fi
done
if [[ -e /app/data/env.sh && ! -f /app/data/env.sh ]]; then
    echo "==> ERROR: /app/data/env.sh should be a regular file. Refusing to start."
    sleep 30
    exit 1
fi
if [[ -e /app/data/.secrets && ! -d /app/data/.secrets ]]; then
    echo "==> ERROR: /app/data/.secrets should be a directory. Refusing to start."
    sleep 30
    exit 1
fi
mkdir -p /app/data/.secrets
chown root:root /app/data/.secrets
chmod 700 /app/data/.secrets
# Check the secrets file again now that the app user can no longer write into its directory.
if [[ -L "${SECRETS}" ]] || [[ -e "${SECRETS}" && ! -f "${SECRETS}" ]]; then
    echo "==> ERROR: ${SECRETS} is not a regular file. Refusing to start."
    sleep 30
    exit 1
fi

echo "==> Setting up runtime directories"
rm -rf /run/kaneo
mkdir -p /run/kaneo/home /run/kaneo/tmp /run/kaneo/nginx
chmod 755 /run/kaneo
chown cloudron:cloudron /run/kaneo/home /run/kaneo/tmp /run/kaneo/nginx

if [[ ! -f /app/data/env.sh ]]; then
    echo "==> First run: writing /app/data/env.sh template"
    cat > /app/data/env.sh <<'EOF'
# Kaneo settings. Restart the app after editing (Cloudron dashboard -> Restart).
# Reference: https://kaneo.app/docs/core/installation/environment-variables
#
# Set by the package on every start (values here are ignored): the database, the public URLs,
# outgoing email (Cloudron's mail server) and, when the app uses Cloudron user management,
# the "Continue with OIDC" sign-in via Cloudron.

# --- Sign-up ------------------------------------------------------------------------------
# The first account becomes the instance administrator. Package defaults:
#   with Cloudron user management:  DISABLE_PASSWORD_REGISTRATION="true" (new users sign in
#                                   with their Cloudron account; invited users can still sign up)
#   without it:                     DISABLE_REGISTRATION="true" (new users by invitation only)
#   always:                         DISABLE_GUEST_ACCESS="true"
# DISABLE_REGISTRATION="true"
# DISABLE_PASSWORD_REGISTRATION="true"
# DISABLE_GUEST_ACCESS="true"
# DISABLE_WORKSPACE_CREATION="false"   # "true": only instance admins create workspaces
# DISABLE_EMAIL_OTP_SIGN_IN="false"    # "true": email + password instead of emailed codes
# DISABLE_LOGIN_FORM="false"           # "true": Cloudron sign-in only (see the README first)
# CUSTOM_OAUTH_AUTO_LOGIN="false"      # "true": skip the sign-in page, go straight to Cloudron

# --- Attachments (object storage) ---------------------------------------------------------
# Files in task descriptions and comments need S3-compatible storage (AWS S3, Cloudflare R2,
# MinIO, ...). Browsers upload directly to S3_ENDPOINT, so it must be reachable from them and
# allow this app's origin in its CORS rules. Without it, attachments are disabled.
# S3_ENDPOINT="https://s3.example.com"
# S3_BUCKET=""
# S3_ACCESS_KEY_ID=""
# S3_SECRET_ACCESS_KEY=""
# S3_REGION="us-east-1"
# S3_FORCE_PATH_STYLE="true"
# S3_MAX_IMAGE_UPLOAD_BYTES="10485760"

# --- Optional integrations ------------------------------------------------------------------
# GITHUB_OAUTH_CLIENT_ID=""         # "Sign in with GitHub"
# GITHUB_OAUTH_CLIENT_SECRET=""
# GOOGLE_CLIENT_ID=""               # "Sign in with Google"
# GOOGLE_CLIENT_SECRET=""
# GITHUB_APP_ID=""                  # GitHub repository integration (GitHub App)
# GITHUB_APP_NAME=""
# GITHUB_WEBHOOK_SECRET=""
# GITHUB_PRIVATE_KEY_BASE64=""
# KANEO_TURNSTILE_SITE_KEY=""       # Cloudflare Turnstile CAPTCHA on sign-in/sign-up
# TURNSTILE_SECRET_KEY=""
# SENTRY_DSN=""                     # API error reports (off unless set)
EOF
fi

# Secrets are generated on first run only. When migrating an existing Kaneo, replace them with the
# old installation's values (AUTH_SECRET, NOTIFICATION_SECRET_ENCRYPTION_KEY) before the first start
# against the imported database.
if [[ ! -f "${SECRETS}" ]]; then
    echo "==> First run: generating secrets"
    ( umask 077; cat > "${SECRETS}" <<EOF
AUTH_SECRET=$(openssl rand -hex 32)
NOTIFICATION_SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)
EOF
    )
fi
chown root:root "${SECRETS}"
chmod 600 "${SECRETS}"

# Both files may only contain plain assignments: NAME="value" or NAME='value', no $, backticks or
# backslashes inside double quotes, no "export", no leading spaces. env.sh is later sourced by the
# app user; anything that could run a command is refused.
check_env_file() {
    local file=$1 bad
    # Only space and tab count as blanks: grep's [[:space:]] would also accept vertical tab and
    # form feed, which bash does not treat as blanks, so "x"<VT>#$(cmd) would run cmd.
    local sp=$' \t'
    if grep -q $'\r' "${file}"; then
        echo "==> ERROR: ${file} has Windows (CRLF) line endings, which would corrupt the values."
        echo "    Re-save it with Unix (LF) line endings and restart."
        return 1
    fi
    if LC_ALL=C grep -q $'[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]' "${file}"; then
        echo "==> ERROR: ${file} contains control characters. Remove them and restart."
        return 1
    fi
    if ! bash -n "${file}"; then
        echo "==> ERROR: ${file} has a syntax error (see above). Fix it and restart."
        return 1
    fi
    if bad=$(grep -nvE "^[${sp}]*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=(\"[^\"\$\`\\]*\"|'[^']*'|[A-Za-z0-9_./:@,+-]*)([${sp}]+#.*)?[${sp}]*$" "${file}"); then
        echo "==> ERROR: ${file} may only contain NAME=\"value\" lines (quote every value; use single"
        echo "    quotes if it contains \$, \` or a backslash; no 'export', no leading spaces). Offending lines:"
        echo "${bad}" | cut -d: -f1 | sed 's/^/    line /'
        return 1
    fi
}

chown root:cloudron /app/data/env.sh
chmod 640 /app/data/env.sh
if ! check_env_file /app/data/env.sh || ! check_env_file "${SECRETS}"; then
    sleep 30
    exit 1
fi

# This script runs as root and never sources a file: values like NODE_OPTIONS, LD_PRELOAD or PATH
# would affect the root-run commands below. Values it needs are read as text, by name; env.sh is
# loaded by app-env.sh, as the cloudron user, right before each process starts.
file_value() {
    # Quoted value: take what is inside the quotes (a "#" there is part of the value); unquoted:
    # drop a trailing " # comment". The validator has already restricted the line shapes.
    grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2- |
        sed -E "s/^\"([^\"]*)\".*/\1/; t; s/^'([^']*)'.*/\1/; t; s/[[:blank:]]+#.*$//"
}
for name in AUTH_SECRET NOTIFICATION_SECRET_ENCRYPTION_KEY; do
    value=$(file_value "${SECRETS}" "${name}")
    if [[ ${#value} -lt 32 ]]; then
        echo "==> ERROR: ${name} is missing or shorter than 32 characters in ${SECRETS}. Refusing to start."
        sleep 30
        exit 1
    fi
    export "${name}=${value}"
done

# Platform-derived settings: recomputed on every start because addon credentials and the app's
# domain can change.
export DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}"
export KANEO_CLIENT_URL="${CLOUDRON_APP_ORIGIN}"
export KANEO_API_URL="${CLOUDRON_APP_ORIGIN}/api"
export KANEO_INTERNAL_API_URL="http://127.0.0.1:1337"
export CORS_ORIGINS="${CLOUDRON_APP_ORIGIN}"
# Requests reach the API only through the local nginx, which sets X-Forwarded-For to the client.
export TRUSTED_PROXIES="127.0.0.1/32,::1/128"
export HOME=/run/kaneo/home
export TMPDIR=/run/kaneo/tmp
derived=(AUTH_SECRET NOTIFICATION_SECRET_ENCRYPTION_KEY DATABASE_URL KANEO_CLIENT_URL KANEO_API_URL
    KANEO_INTERNAL_API_URL CORS_ORIGINS TRUSTED_PROXIES HOME TMPDIR)

# Outgoing email through Cloudron's mail server (sendmail addon; absent if outbound mail is
# disabled for the app). Plain SMTP on the internal Docker network, like every Cloudron app.
if [[ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]]; then
    export SMTP_HOST="${CLOUDRON_MAIL_SMTP_SERVER}"
    export SMTP_PORT="${CLOUDRON_MAIL_SMTP_PORT}"
    export SMTP_SECURE="false"
    export SMTP_REQUIRE_TLS="false"
    export SMTP_USER="${CLOUDRON_MAIL_SMTP_USERNAME}"
    export SMTP_PASSWORD="${CLOUDRON_MAIL_SMTP_PASSWORD}"
    export SMTP_FROM="${CLOUDRON_MAIL_FROM_DISPLAY_NAME:-Kaneo} <${CLOUDRON_MAIL_FROM}>"
    derived+=(SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_REQUIRE_TLS SMTP_USER SMTP_PASSWORD SMTP_FROM)
fi

# Sign-in with Cloudron accounts (oidc addon; only present when the app uses Cloudron user
# management). Without it, CUSTOM_OAUTH_* from env.sh (another identity provider) are kept.
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
    export CUSTOM_OAUTH_CLIENT_ID="${CLOUDRON_OIDC_CLIENT_ID}"
    export CUSTOM_OAUTH_CLIENT_SECRET="${CLOUDRON_OIDC_CLIENT_SECRET}"
    export CUSTOM_OAUTH_DISCOVERY_URL="${CLOUDRON_OIDC_DISCOVERY_URL}"
    export CUSTOM_OAUTH_SCOPES="openid,profile,email"
    export CUSTOM_AUTH_PKCE="true"
    derived+=(CUSTOM_OAUTH_CLIENT_ID CUSTOM_OAUTH_CLIENT_SECRET CUSTOM_OAUTH_DISCOVERY_URL
        CUSTOM_OAUTH_SCOPES CUSTOM_AUTH_PKCE)
fi

# Hand secrets and derived values to app-env.sh, which applies them after env.sh so they win.
# The app processes get these values in their environment anyway, so the file is readable by them.
kaneo_env=$(mktemp /run/kaneo/.kaneo.env.XXXXXX)
for name in "${derived[@]}"; do
    printf '%s=%q\n' "${name}" "${!name}"
done > "${kaneo_env}"
chown root:cloudron "${kaneo_env}"
chmod 640 "${kaneo_env}"
mv -f "${kaneo_env}" /run/kaneo/kaneo.env

# The web app is built with placeholders for its public URLs; fill them in on a copy (the image is
# read-only), with upstream's own renderer. Values reach awk through its environment only.
echo "==> Preparing the web app"
cp -a /app/code/web /run/kaneo/html
find /run/kaneo/html -type f -name '*.js' -print0 |
    while IFS= read -r -d '' asset; do
        env -i LC_ALL=C KANEO_API_URL="${KANEO_API_URL}" KANEO_CLIENT_URL="${KANEO_CLIENT_URL}" \
            KANEO_TURNSTILE_SITE_KEY="$(file_value /app/data/env.sh KANEO_TURNSTILE_SITE_KEY)" \
            awk -v mode=bundle -f /app/code/env.awk "${asset}" > "${asset}.tmp"
        mv -f "${asset}.tmp" "${asset}"
    done
chown -R root:root /run/kaneo/html
chmod -R a+rX,go-w /run/kaneo/html

# Warnings only: read the values as text, without evaluating env.sh.
env_value() { file_value /app/data/env.sh "$1"; }
if [[ -z "$(env_value S3_ENDPOINT)" || -z "$(env_value S3_BUCKET)" ]]; then
    echo "==> NOTE: object storage is not configured, so attachments are disabled (see /app/data/env.sh)."
fi
if [[ -z "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]]; then
    echo "==> WARNING: outbound email is disabled: no invitations, sign-in codes or password resets."
fi

echo "==> Waiting for PostgreSQL"
for attempt in $(seq 1 60); do
    if pg_isready -q -h "${CLOUDRON_POSTGRESQL_HOST}" -p "${CLOUDRON_POSTGRESQL_PORT}" \
        -U "${CLOUDRON_POSTGRESQL_USERNAME}" -d "${CLOUDRON_POSTGRESQL_DATABASE}"; then
        break
    fi
    if [[ ${attempt} == 60 ]]; then
        echo "==> ERROR: PostgreSQL did not become ready in 2 minutes; exiting so Cloudron restarts the app."
        exit 1
    fi
    echo "==> PostgreSQL not ready yet (${attempt}/60)"
    sleep 2
done

# The API runs its database migrations itself on start, before it begins listening.
echo "==> Starting Kaneo"
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon
