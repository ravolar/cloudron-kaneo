#!/bin/bash
# Starts a Kaneo process with its environment. Runs as the `cloudron` user (supervisor's user=),
# never as root: operator settings from /app/data/env.sh can contain anything the validator
# accepts, including NODE_OPTIONS, LD_PRELOAD or PATH, so they must only ever reach processes
# that already run with the app's own privileges.
#
# Order: operator settings first, then the secrets and platform-derived values written by
# start.sh, which take precedence.
set -eu

set +u
set -o allexport
# shellcheck disable=SC1091
source /app/data/env.sh
# shellcheck disable=SC1091
source /run/kaneo/kaneo.env
set +o allexport
set -u

# Sign-up defaults, unless env.sh sets them: no anonymous guests; with Cloudron user management new
# users come in through their Cloudron account (or an invitation), otherwise by invitation only.
export DISABLE_GUEST_ACCESS="${DISABLE_GUEST_ACCESS:-true}"
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
    export DISABLE_PASSWORD_REGISTRATION="${DISABLE_PASSWORD_REGISTRATION:-true}"
else
    export DISABLE_REGISTRATION="${DISABLE_REGISTRATION:-true}"
fi

exec "$@"
