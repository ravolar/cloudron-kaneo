#!/bin/bash
# Smoke test: run the package image the way Cloudron does (read-only root filesystem, /app/data,
# /run and /tmp as writable volumes) next to PostgreSQL, and check that Kaneo comes up healthy,
# that the MCP server works end to end and that the package's safety measures are in place. Then
# restart and check again.
#
#   test/smoke.sh <image>
#
# Needs docker, curl and jq. Leaves nothing behind (containers, network, volumes, temp dir).
set -euo pipefail

IMAGE=${1:?usage: test/smoke.sh <image>}
PG_IMAGE="postgres:17-alpine"
ID="kaneosmoke$$"
PORT=${SMOKE_PORT:-18400}
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
no_match() { ! grep -qE "$1" <<<"$2"; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "==> Starting PostgreSQL"
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

start_app() {
    docker run -d --name "${ID}-app" --network "${ID}" --read-only \
        -p "127.0.0.1:${PORT}:8000" \
        -v "${WORK}/data:/app/data" -v "${ID}-run:/run" -v "${ID}-tmp:/tmp" \
        -e CLOUDRON_APP_ORIGIN="${ORIGIN}" \
        -e CLOUDRON_POSTGRESQL_URL="postgres://kaneouser:p%2Bw%2Fd%3D1@${ID}-pg:5432/kaneodb" \
        -e CLOUDRON_POSTGRESQL_HOST="${ID}-pg" -e CLOUDRON_POSTGRESQL_PORT=5432 \
        -e CLOUDRON_POSTGRESQL_USERNAME=kaneouser -e CLOUDRON_POSTGRESQL_PASSWORD='p+w/d=1' \
        -e CLOUDRON_POSTGRESQL_DATABASE=kaneodb \
        "${IMAGE}" >/dev/null
}

wait_ready() {
    for _ in $(seq 1 90); do
        if [[ "$(status "${ORIGIN}/api/health")" == 200 ]]; then
            return 0
        fi
        if docker logs "${ID}-app" 2>&1 | grep -qE "migration failed|Refusing to start|==> ERROR"; then
            return 1
        fi
        sleep 2
    done
    return 1
}

# JSON-RPC to the MCP endpoint with a bearer token; prints the JSON result (plain or SSE framed).
mcp() {
    curl -s -X POST "${ORIGIN}/api/mcp" -H "Authorization: Bearer $1" \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -H 'MCP-Protocol-Version: 2025-06-18' -d "$2" | sed -n 's/^data: //p; /^{/p'
}

run_checks() {
    local logs html_js
    logs=$(docker logs "${ID}-app" 2>&1)
    check "API healthy through nginx" test "$(status "${ORIGIN}/api/health")" = 200
    check "web app renders" bash -c "curl -fs '${ORIGIN}/' | grep -q '<div id=\"root\"'"
    check "client-side routes fall back to the app" test "$(status "${ORIGIN}/auth/sign-in")" = 200
    check "database migrated" grep -q "Database migrated successfully" <<<"${logs}"
    html_js=$(app_exec sh -c 'cat /run/kaneo/html/assets/*.js')
    check "public URL filled into the web app" grep -qF "\"${ORIGIN}/api\"" <<<"${html_js}"
    check "no URL placeholders left" no_match '[`"'"'"']KANEO_(API_URL|CLIENT_URL)' "${html_js}"
    check "MCP resource metadata" test "$(curl -fs "${ORIGIN}/.well-known/oauth-protected-resource/api/mcp" | jq -r .resource)" = "${ORIGIN}/api/mcp"
    check "MCP authorization server metadata" test "$(curl -fs "${ORIGIN}/.well-known/oauth-authorization-server/api" | jq -r .token_endpoint)" = "${ORIGIN}/api/mcp/token"
    check "MCP metadata also under /api" test "$(curl -fs "${ORIGIN}/api/.well-known/oauth-protected-resource/api/mcp" | jq -r .resource)" = "${ORIGIN}/api/mcp"
    check "MCP without a token asks for OAuth" bash -c "curl -s -D - -o /dev/null -X POST -H 'content-type: application/json' -d '{}' '${ORIGIN}/api/mcp' | grep -qi '^www-authenticate: Bearer resource_metadata=\"${ORIGIN}/api/'"
    check "other /.well-known paths are not served" test "$(status "${ORIGIN}/.well-known/foo")" = 404
    check "index.html is revalidated (no stale chunk names after updates)" bash -c "curl -sI '${ORIGIN}/' | grep -qi '^cache-control: no-cache'"
    check "client-side routes are revalidated too" bash -c "curl -sI '${ORIGIN}/dashboard' | grep -qi '^cache-control: no-cache'"
    local asset
    asset=$(app_exec ls /run/kaneo/html/assets | grep -m1 '\.js$')
    check "hashed assets are cacheable" bash -c "curl -sI '${ORIGIN}/assets/${asset}' | grep -qi '^cache-control: public, max-age=604800'"
    check "API responses keep their own caching headers" bash -c "! curl -sI '${ORIGIN}/api/health' | grep -qi '^cache-control: no-cache\$'"
    check "source maps not served" test "$(status "${ORIGIN}/assets/x.js.map")" = 404
    check "only port 8000 listens on all interfaces" app_exec bash -c \
        'test "$(cat /proc/net/tcp /proc/net/tcp6 | awk "\$4==\"0A\"{print \$2}" | grep -E "^0+:" | sed "s/.*://" | sort -u | tr "\n" " ")" = "1F40 "'
    check "API listens on loopback" app_exec bash -c 'grep -q "0100007F:0539 00000000:0000 0A" /proc/net/tcp'
    check "/app/data is root-owned" test "$(app_exec stat -c %U:%a /app/data)" = "root:755"
    check "env.sh readable by the app only via group" test "$(app_exec stat -c %U:%G:%a /app/data/env.sh)" = "root:cloudron:640"
    check "secrets are root-only" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"
    check "app user cannot read the secrets" bash -c "! docker exec -u cloudron ${ID}-app cat /app/data/.secrets/secrets.env"
    check "app user cannot write env.sh" bash -c "! docker exec -u cloudron ${ID}-app sh -c 'echo x >> /app/data/env.sh'"
    check "app user cannot change the web app" bash -c "! docker exec -u cloudron ${ID}-app sh -c 'echo x >> /run/kaneo/html/index.html'"
    check "Kaneo processes run as the app user (uid 1000)" test "$(app_exec bash -c 'for p in /proc/[0-9]*; do case "$(cat "$p/comm" 2>/dev/null)" in node|nginx) awk "/^Uid:/{print \$2}" "$p/status";; esac; done | sort -u | tr -d "\n"')" = "1000"
}

echo "==> First start"
start_app
if wait_ready; then pass "app started"; else fail "app started"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi
run_checks

echo "==> Accounts and MCP"
signup() {
    curl -s -D "${WORK}/headers" -X POST "${ORIGIN}/api/auth/sign-up/email" -H "Origin: ${ORIGIN}" \
        -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"Smoke-test-pass-123\",\"name\":\"Smoke\"}"
}
token=$(signup admin@example.com | jq -r '.token // empty')
check "first account can sign up" test -n "${token}"
check "first account is the instance admin" test "$(docker exec "${ID}-pg" psql -U kaneouser -d kaneodb -tAc "select role from \"user\" where email='admin@example.com'")" = admin
    check "further sign-ups are closed (invitation only)" no_match '"token"' "$(signup other@example.com)"
check "guest access disabled" test "$(status -X POST -H "Origin: ${ORIGIN}" -H 'Content-Type: application/json' -d '{}' "${ORIGIN}/api/auth/sign-in/anonymous")" != 200
init=$(mcp "${token}" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}')
check "MCP initialize" test "$(jq -r '.result.serverInfo.name // empty' <<<"${init}")" != ""
tools=$(mcp "${token}" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
check "MCP lists the Kaneo tools" bash -c "jq -e '.result.tools | map(.name) | index(\"create_task\") and index(\"list_workspaces\")' <<<\"\$1\"" _ "${tools}"
whoami=$(mcp "${token}" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"whoami","arguments":{}}}')
check "MCP tool call runs as the user" grep -q "admin@example.com" <<<"${whoami}"
check "MCP whoami does not reveal the session token" no_match "${token}" "${whoami}"

echo "==> Restart"
docker restart "${ID}-app" >/dev/null
if wait_ready; then pass "app restarted"; else fail "app restarted"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi
check "still healthy after restart" test "$(status "${ORIGIN}/api/health")" = 200
check "secrets kept across restart" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"
whoami=$(mcp "${token}" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"whoami","arguments":{}}}')
check "sessions survive a restart (stable AUTH_SECRET)" grep -q "admin@example.com" <<<"${whoami}"

if [[ ${FAILED} -ne 0 ]]; then
    echo "==> SMOKE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -60
    exit 1
fi
echo "==> Smoke test passed"
