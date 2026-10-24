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
# Reads the API's environment as its own user (root in the container may not read other users'
# /proc/<pid>/environ without CAP_SYS_PTRACE).
api_has_auth_secret() {
    local env
    env=$(docker exec -u cloudron "${ID}-app" bash -c 'tr "\0" "\n" < "/proc/$(pgrep -f dist/index.js | head -1)/environ"')
    grep -q '^AUTH_SECRET=' <<<"${env}"
}
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

# 401 with WWW-Authenticate: Bearer resource_metadata="<url>", and that URL serves this app's MCP metadata. Upstream
# moved the URL from /api/.well-known/… to the RFC 9728 /.well-known/oauth-protected-resource/api/mcp in 2.47.0; both
# are served here, so check what the header says rather than one fixed form.
mcp_asks_for_oauth() {
    local headers url
    headers=$(curl -s -D - -o /dev/null -X POST -H 'content-type: application/json' -d '{}' "${ORIGIN}/api/mcp")
    grep -q '^HTTP/[0-9.]* 401' <<<"${headers}" || return 1
    url=$(grep -i '^www-authenticate: Bearer ' <<<"${headers}" | sed -nE 's/.*resource_metadata="([^"]+)".*/\1/p' | tr -d '\r')
    [[ "${url}" == "${ORIGIN}/"* ]] || return 1
    [[ "$(curl -fs "${url}" | jq -r .resource)" == "${ORIGIN}/api/mcp" ]]
}

start_app() {
    docker run -d --name "${ID}-app" --network "${ID}" --read-only \
        -p "127.0.0.1:${PORT}:8000" \
        -v "${WORK}/data:/app/data" -v "${ID}-run:/run" -v "${ID}-tmp:/tmp" \
        -e CLOUDRON_APP_ORIGIN="${ORIGIN}" \
        -e CLOUDRON_POSTGRESQL_URL="postgres://kaneouser:p%2Bw%2Fd%3D1@${ID}-pg:5432/kaneodb" \
        -e CLOUDRON_POSTGRESQL_HOST="${ID}-pg" -e CLOUDRON_POSTGRESQL_PORT=5432 \
        -e CLOUDRON_POSTGRESQL_USERNAME=kaneouser -e CLOUDRON_POSTGRESQL_PASSWORD='p+w/d=1' \
        -e CLOUDRON_POSTGRESQL_DATABASE=kaneodb \
        "$@" "${IMAGE}" >/dev/null
}

wait_ready() {
    for _ in $(seq 1 90); do
        if [[ "$(status "${ORIGIN}/api/health")" == 200 ]]; then
            return 0
        fi
        logs=$(docker logs "${ID}-app" 2>&1)  # captured first: `docker logs | grep -q` under pipefail can SIGPIPE
        if grep -qE "migration failed|Refusing to start|==> ERROR" <<<"${logs}"; then
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
        -H 'MCP-Protocol-Version: 2025-06-18' -d "$2" | sed -n 's/^data: //p; t; /^{/p'
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
    check "MCP without a token asks for OAuth" mcp_asks_for_oauth
    check "other /.well-known paths are not served" test "$(status "${ORIGIN}/.well-known/foo")" = 404
    check "index.html is revalidated (no stale chunk names after updates)" bash -c "curl -sI '${ORIGIN}/' | grep -qi '^cache-control: no-cache'"
    check "client-side routes are revalidated too" bash -c "curl -sI '${ORIGIN}/dashboard' | grep -qi '^cache-control: no-cache'"
    local asset
    asset=$(app_exec ls /run/kaneo/html/assets | grep '\.js$' | tail -n 1)
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
    check "supervisor does not carry addon credentials" bash -c "! docker exec ${ID}-app cat /proc/1/environ | tr '\\0' '\\n' | grep -qE '^(CLOUDRON_POSTGRESQL_PASSWORD|AUTH_SECRET|DATABASE_URL)='"
    # nginx inherits supervisor's environment (checked above; its own /proc environ is overwritten
    # by its process title). The API must still get its secrets through app-env.sh.
    check "API gets its secrets through app-env.sh" api_has_auth_secret
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

codes=$(for _ in $(seq 1 40); do status -X POST -H "Origin: ${ORIGIN}" -H 'Content-Type: application/json' \
    -d '{"email":"nobody@example.com","password":"wrong-password-123"}' "${ORIGIN}/api/auth/sign-in/email"; echo; done)
check "password sign-in is rate-limited" grep -q 429 <<<"${codes}"

asset_url="${ORIGIN}/assets/$(app_exec bash -c 'ls /run/kaneo/html/assets | grep "^get-api-url-.*\.js$" | tail -n 1')"
etag_before=$(curl -sI "${asset_url}" | tr -d '\r' | awk 'tolower($1)=="etag:"{print $2}')

echo "==> Restart"
docker restart "${ID}-app" >/dev/null
if wait_ready; then pass "app restarted"; else fail "app restarted"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi
check "still healthy after restart" test "$(status "${ORIGIN}/api/health")" = 200
check "rendered assets keep their ETag across restarts" test "$(curl -sI "${asset_url}" | tr -d '\r' | awk 'tolower($1)=="etag:"{print $2}')" = "${etag_before}"
check "secrets kept across restart" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"
whoami=$(mcp "${token}" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"whoami","arguments":{}}}')
check "sessions survive a restart (stable AUTH_SECRET)" grep -q "admin@example.com" <<<"${whoami}"

echo "==> With Cloudron user management (OIDC addon)"
docker rm -f "${ID}-app" >/dev/null
start_app -e CLOUDRON_OIDC_CLIENT_ID=smoke-oidc -e CLOUDRON_OIDC_CLIENT_SECRET=smoke-secret \
    -e CLOUDRON_OIDC_DISCOVERY_URL=https://oidc.invalid/openid/.well-known/openid-configuration \
    -e CLOUDRON_OIDC_ISSUER=https://oidc.invalid/openid -e CLOUDRON_PROXY_IP=172.18.0.1
if wait_ready; then pass "app started with SSO"; else fail "app started with SSO"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi
config=$(curl -fs "${ORIGIN}/api/config")
check "Cloudron sign-in offered" test "$(jq -r .hasCustomOAuth <<<"${config}")" = true
check "local sign-in form disabled" test "$(jq -r .disableLoginForm <<<"${config}")" = true
check "local password registration disabled" test "$(jq -r .disablePasswordRegistration <<<"${config}")" = true
check "password sign-up closed at the proxy" test "$(status -X POST -H "Origin: ${ORIGIN}" -H 'Content-Type: application/json' \
    -d '{"email":"late@example.com","password":"Smoke-test-pass-123","name":"Late"}' "${ORIGIN}/api/auth/sign-up/email")" = 403
check "local password sign-in refused" no_match '"token"' "$(curl -s -X POST -H "Origin: ${ORIGIN}" -H 'Content-Type: application/json' \
    -d '{"email":"admin@example.com","password":"Smoke-test-pass-123"}' "${ORIGIN}/api/auth/sign-in/email")"
check "client addresses trusted from Cloudron's proxy only" app_exec grep -qx 'set_real_ip_from 172.18.0.1;' /run/kaneo/nginx-http.conf
whoami=$(mcp "${token}" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"whoami","arguments":{}}}')
check "existing MCP sessions keep working" grep -q "admin@example.com" <<<"${whoami}"

if [[ ${FAILED} -ne 0 ]]; then
    echo "==> SMOKE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -60
    exit 1
fi
echo "==> Smoke test passed"
