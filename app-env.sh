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

# Sign-up defaults, unless env.sh sets them: no anonymous guests; with Cloudron user management
# everyone signs in with a Cloudron account, otherwise new users come by invitation only.
export DISABLE_GUEST_ACCESS="${DISABLE_GUEST_ACCESS:-true}"
if [[ "${KANEO_CLOUDRON_SSO:-false}" == true ]]; then
    export DISABLE_LOGIN_FORM="${DISABLE_LOGIN_FORM:-true}"
    export DISABLE_PASSWORD_REGISTRATION="${DISABLE_PASSWORD_REGISTRATION:-true}"
else
    export DISABLE_REGISTRATION="${DISABLE_REGISTRATION:-true}"
fi

exec "$@"
