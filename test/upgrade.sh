#!/bin/bash
# Upgrade test: what a Cloudron update does to a running installation. Start the previously
# published image, create real data through the API and MCP (account, workspace, project, task,
# comment), then replace the container with the candidate image on the same /app/data, /run and
# database, and check that the update kept everything: migrations, data, sessions, secrets and
# settings.
#
#   test/upgrade.sh <old image> <new image>
#
# Needs docker, curl and jq. Leaves nothing behind (containers, network, volumes, temp dir).
set -euo pipefail

OLD_IMAGE=${1:?usage: test/upgrade.sh <old image> <new image>}
NEW_IMAGE=${2:?usage: test/upgrade.sh <old image> <new image>}
PG_IMAGE="postgres:17-alpine"
ID="kaneoupgrade$$"
PORT=${UPGRADE_PORT:-18410}
ORIGIN="http://localhost:${PORT}"
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    docker rm -f "${ID}-app" "${ID}-pg" >/dev/null 2>&1 || true
    docker volume rm "${ID}-run" "${ID}-tmp" >/dev/null 2>&1 || true
    docker network rm "${ID}" >/dev/null 2>&1 || true
    # the data dir is root-owned after start.sh ran; remove it from a container
    docker run --rm -v "${WORK}:/w" --entrypoint sh "${PG_IMAGE}" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
    rmdir "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }
app_exec() { docker exec "${ID}-app" "$@"; }

start_app() {
    docker run -d --name "${ID}-app" --network "${ID}" --read-only \
        -p "127.0.0.1:${PORT}:8000" \
        -v "${WORK}/data:/app/data" -v "${ID}-run:/run" -v "${ID}-tmp:/tmp" \
        -e CLOUDRON_APP_ORIGIN="${ORIGIN}" \
        -e CLOUDRON_POSTGRESQL_URL="postgres://kaneouser:p%2Bw%2Fd%3D1@${ID}-pg:5432/kaneodb" \
        -e CLOUDRON_POSTGRESQL_HOST="${ID}-pg" -e CLOUDRON_POSTGRESQL_PORT=5432 \
        -e CLOUDRON_POSTGRESQL_USERNAME=kaneouser -e CLOUDRON_POSTGRESQL_PASSWORD='p+w/d=1' \
        -e CLOUDRON_POSTGRESQL_DATABASE=kaneodb \
        "$1" >/dev/null
}

wait_ready() {
    for _ in $(seq 1 90); do
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' "${ORIGIN}/api/health")" == 200 ]]; then
            return 0
        fi
        if docker logs "${ID}-app" 2>&1 | grep -qE "migration failed|Refusing to start|==> ERROR"; then
            return 1
        fi
        sleep 2
    done
    return 1
}

api() {
    local method=$1 path=$2 body=${3:-}
    curl -s -X "${method}" "${ORIGIN}${path}" -H "Authorization: Bearer ${token}" -H "Origin: ${ORIGIN}" \
        -H 'Content-Type: application/json' ${body:+-d "${body}"}
}

# Calls an MCP tool and prints the text of its result (the tool's JSON output).
tool() {
    local name=$1 args=$2
    curl -s -X POST "${ORIGIN}/api/mcp" -H "Authorization: Bearer ${token}" \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -H 'MCP-Protocol-Version: 2025-06-18' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${name}\",\"arguments\":${args}}}" |
        sed -n 's/^data: //p; t; /^{/p' | jq -r '.result.content[0].text // empty'
}

secrets_sum() { app_exec sha256sum /app/data/.secrets/secrets.env /app/data/env.sh; }

echo "==> Old version: ${OLD_IMAGE}"
docker network create "${ID}" >/dev/null
docker run -d --name "${ID}-pg" --network "${ID}" \
    -e POSTGRES_USER=kaneouser -e POSTGRES_PASSWORD='p+w/d=1' -e POSTGRES_DB=kaneodb \
    "${PG_IMAGE}" >/dev/null
for _ in $(seq 1 60); do
    docker exec "${ID}-pg" pg_isready -q -U kaneouser -d kaneodb >/dev/null 2>&1 && break
    sleep 1
done
sleep 2
mkdir -p "${WORK}/data"
docker pull -q "${OLD_IMAGE}" >/dev/null
start_app "${OLD_IMAGE}"
if wait_ready; then pass "old version started"; else fail "old version started"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi

echo "==> Creating data on the old version"
token=$(curl -s -X POST "${ORIGIN}/api/auth/sign-up/email" -H "Origin: ${ORIGIN}" -H 'Content-Type: application/json' \
    -d '{"email":"admin@example.com","password":"Upgrade-test-pass-123","name":"Upgrade"}' | jq -r '.token // empty')
check "admin account created" test -n "${token}"
workspace_id=$(api POST /api/auth/organization/create '{"name":"Upgrade test","slug":"upgrade-test"}' | jq -r '.id // empty')
check "workspace created" test -n "${workspace_id}"
project_id=$(tool create_project "{\"name\":\"Upgrade project\",\"workspaceId\":\"${workspace_id}\",\"icon\":\"Layout\",\"slug\":\"UPG\"}" | jq -r '.id // empty')
check "project created (MCP)" test -n "${project_id}"
task_id=$(tool create_task "{\"projectId\":\"${project_id}\",\"title\":\"Survives the update\",\"description\":\"Created before the update\",\"priority\":\"high\",\"status\":\"to-do\"}" | jq -r '.id // empty')
check "task created (MCP)" test -n "${task_id}"
comment_id=$(tool create_task_comment "{\"taskId\":\"${task_id}\",\"content\":\"Comment from before the update\"}" | jq -r '.id // empty')
check "comment created (MCP)" test -n "${comment_id}"
before_secrets=$(secrets_sum)
if [[ ${FAILED} -ne 0 ]]; then
    echo "==> UPGRADE TEST FAILED (could not create data on the old version)"
    docker logs "${ID}-app" 2>&1 | tail -40
    exit 1
fi

echo "==> Updating to: ${NEW_IMAGE}"
# Like a Cloudron update: the container is replaced; /app/data, /run, /tmp and the database stay.
docker rm -f "${ID}-app" >/dev/null
start_app "${NEW_IMAGE}"
if wait_ready; then pass "new version started on the old data"; else fail "new version started on the old data"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi

logs=$(docker logs "${ID}-app" 2>&1)
check "database migrated" grep -q "Database migrated successfully" <<<"${logs}"
check "secrets and settings unchanged" test "$(secrets_sum)" = "${before_secrets}"
check "session from before the update still valid" bash -c "grep -q admin@example.com <<<\"\$1\"" _ "$(tool whoami '{}')"
check "workspace kept" bash -c "jq -e --arg id \"\$2\" 'map(.id) | index(\$id)' <<<\"\$1\"" _ "$(tool list_workspaces '{}')" "${workspace_id}"
check "task kept" test "$(tool get_task "{\"taskId\":\"${task_id}\"}" | jq -r '.title // empty')" = "Survives the update"
check "task listed in its project" bash -c "grep -q '${task_id}' <<<\"\$1\"" _ "$(tool list_tasks "{\"projectId\":\"${project_id}\"}")"
check "comment kept" bash -c "grep -q 'Comment from before the update' <<<\"\$1\"" _ "$(tool list_task_comments "{\"taskId\":\"${task_id}\"}")"
check "new data can be written" test -n "$(tool create_task "{\"projectId\":\"${project_id}\",\"title\":\"Created after the update\",\"description\":\"\",\"priority\":\"low\",\"status\":\"to-do\"}" | jq -r '.id // empty')"

echo "==> Restart after the update"
docker restart "${ID}-app" >/dev/null
if wait_ready; then pass "restarts cleanly after the update"; else fail "restarts cleanly after the update"; fi

if [[ ${FAILED} -ne 0 ]]; then
    echo "==> UPGRADE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -60
    exit 1
fi
echo "==> Upgrade test passed"
