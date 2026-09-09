#!/usr/bin/env bash
#
# Start the built image and assert the HTTP behaviour a Proxmox installer
# depends on, in two scenarios:
#
#   1. pre-provisioned  - certificate, token and answer files already on disk
#   2. first run        - an empty directory, everything generated on start
#
# Usage:
#
#   tests/smoke.sh [image-tag]      (default: pve-answer:smoke)
#
# Build it first, e.g.:
#
#   docker build -t pve-answer:smoke .

set -euo pipefail

IMAGE="${1:-pve-answer:smoke}"
# 0 lets Docker pick a free port, so the test cannot collide with whatever
# else is listening. Override with PORT=... to pin it.
PUBLISH_PORT="${PORT:-0}"
CONTAINER="pve-answer-smoke-$$"
WORKDIR="$(mktemp -d)"
FAILURES=0

# The entrypoint creates files as root, which the host user may not be able to
# remove; delete them from inside a container instead.
cleanup() {
    docker rm -f "$CONTAINER" "${CONTAINER}-nohost" "${CONTAINER}-root" \
        "${CONTAINER}-user" >/dev/null 2>&1 || true
    docker volume rm "pve-answer-smoke-root-$$" >/dev/null 2>&1 || true
    docker run --rm --platform "$IMAGE_PLATFORM" --entrypoint sh \
        -v "$WORKDIR:/w" "$IMAGE" \
        -c 'rm -rf /w/public /w/private' >/dev/null 2>&1 || true
    rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

check() {
    local name="$1" expected="$2" actual="$3"

    if [ "$expected" = "$actual" ]; then
        printf 'ok   %-42s %s\n' "$name" "$actual"
    else
        printf 'FAIL %-42s expected %s, got %s\n' "$name" "$expected" "$actual"
        FAILURES=$((FAILURES + 1))
    fi
}

# The image's own architecture, so a cross-architecture image starts under
# emulation without a platform-mismatch warning.
IMAGE_PLATFORM="$(docker image inspect "$IMAGE" --format '{{.Os}}/{{.Architecture}}')"

# Wait for a container to answer on its published port, and echo that base URL.
# Never use a fixed sleep here: under QEMU emulation the first start has to
# generate a 4096-bit RSA key, which takes far longer than on native hardware.
wait_ready() {
    local container="$1" port base

    # The port mapping is not always registered by the time `docker run -d`
    # returns, so poll for it rather than reading it once.
    for _ in $(seq 1 60); do
        port="$(docker port "$container" 8443/tcp 2>/dev/null | head -1 | sed 's/.*://')"

        [ -n "$port" ] && break

        sleep 0.5
    done

    if [ -z "$port" ]; then
        echo "no published port for $container" >&2
        docker logs "$container" >&2
        return 1
    fi

    base="https://127.0.0.1:$port"

    for _ in $(seq 1 240); do
        if curl -sk -o /dev/null "$base/health"; then
            echo "$base"
            return 0
        fi
        sleep 0.5
    done

    echo "$container never became ready. Container log:" >&2
    docker logs "$container" >&2
    return 1
}

# Start the image against $WORKDIR and wait for it to serve. Extra arguments
# are passed to docker run.
start_container() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

    docker run -d --name "$CONTAINER" --platform "$IMAGE_PLATFORM" \
        -p "$PUBLISH_PORT:8443" \
        -e PVE_ANSWER_TOKEN_FILE=/app/private/token \
        -v "$WORKDIR/public:/app/public" \
        -v "$WORKDIR/private:/app/private" \
        "$@" "$IMAGE" >/dev/null

    PORT="$(docker port "$CONTAINER" 8443/tcp | head -1 | sed 's/.*://')"

    if [ -z "$PORT" ]; then
        echo "FAIL could not determine the published port" >&2
        docker logs "$CONTAINER" >&2
        exit 1
    fi

    BASE="$(wait_ready "$CONTAINER")" || exit 1
}

status() { curl -sk -o /dev/null -w '%{http_code}' "$@"; }

# `docker logs | grep -q` is unsafe here: grep exits on the first match, docker
# logs dies of SIGPIPE, and `set -o pipefail` reports the pipeline as failed.
# Match against a captured string instead.
logs_contain() {
    local container="$1" needle="$2" logs
    logs="$(docker logs "$container" 2>&1)"

    case "$logs" in
        *"$needle"*) echo yes ;;
        *)           echo no ;;
    esac
}
header() {
    curl -sk -D - -o /dev/null "$@" | tr -d '\r' \
        | awk -F': ' 'tolower($1)=="x-answer-match" {print $2}'
}

KNOWN='{"network_interfaces":[{"mac":"bc:24:11:7b:51:aa"}]}'
UNKNOWN='{"network_interfaces":[{"mac":"00:11:22:33:44:55"}]}'

# ===========================================================================
# Scenario 1: everything already provisioned
# ===========================================================================

echo "== pre-provisioned =="

mkdir -p "$WORKDIR/public/answers" "$WORKDIR/private/tls"

cat > "$WORKDIR/public/answers/bc-24-11-7b-51-aa.toml" <<'TOML'
[global]
keyboard = "se"
country = "sv"
fqdn = "smoke-test.example.com"
mailto = "admin@example.com"
timezone = "Europe/Stockholm"
root-password-hashed = "$y$j9T$smoke$test"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["sda"]
TOML

echo '# no settings, so an unregistered machine is not installed' \
    > "$WORKDIR/public/default.toml"

printf 'smoke:%s' "$(openssl rand -hex 16)" > "$WORKDIR/private/token"
TOKEN="$(cat "$WORKDIR/private/token")"

openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
    -keyout "$WORKDIR/private/tls/server.key" \
    -out "$WORKDIR/private/tls/server.crt" \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null

chmod 644 "$WORKDIR/private/tls/server.key" "$WORKDIR/private/token"

start_container
echo "Testing '$IMAGE' on port $PORT"

check "GET /health" 200 "$(status "$BASE/health")"
check "GET /answer (POST expected)" 405 "$(status "$BASE/answer")"
check "GET / (debug off)" 404 "$(status "$BASE/")"

check "POST /answer without a token" 401 \
    "$(status -X POST "$BASE/answer" -d "$KNOWN")"
check "POST /answer with a wrong token" 401 \
    "$(status -X POST -H "Authorization: Bearer smoke:wrong" "$BASE/answer" -d "$KNOWN")"
check "POST /answer with a wrong scheme" 401 \
    "$(status -X POST -H "Authorization: Basic $TOKEN" "$BASE/answer" -d "$KNOWN")"

AUTH=(-H "Authorization: Bearer $TOKEN")

check "POST /answer, known MAC" 200 \
    "$(status -X POST "${AUTH[@]}" "$BASE/answer" -d "$KNOWN")"
check "POST /answer, unknown MAC" 200 \
    "$(status -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN")"

check "X-Answer-Match, known MAC" "bc-24-11-7b-51-aa" \
    "$(header -X POST "${AUTH[@]}" "$BASE/answer" -d "$KNOWN")"
check "X-Answer-Match, unknown MAC" "none" \
    "$(header -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN")"

check "known MAC serves its answer file" "yes" \
    "$(curl -sk -X POST "${AUTH[@]}" "$BASE/answer" -d "$KNOWN" \
        | grep -q 'smoke-test.example.com' && echo yes || echo no)"
check "unknown MAC serves no install settings" "yes" \
    "$(curl -sk -X POST "${AUTH[@]}" "$BASE/answer" -d "$UNKNOWN" \
        | grep -q '^\[' && echo no || echo yes)"

check "TLS is enforced (plain HTTP is refused)" "yes" \
    "$(curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && echo no || echo yes)"

check "existing certificate is not replaced" "no" \
    "$(logs_contain "$CONTAINER" 'generating a self-signed')"
check "existing token is not replaced" "no" \
    "$(logs_contain "$CONTAINER" 'generated a new auth token')"
RUNTIME_UID="$(docker exec "$CONTAINER" awk '/^Uid:/ {print $2}' /proc/1/status)"

check "server does not run as root" "yes" \
    "$([ "$RUNTIME_UID" != "0" ] && echo yes || echo no)"
DIR_OWNER="$(docker exec "$CONTAINER" stat -c '%u' /app/private)"

check "runs as the private dir owner, or falls back when it is root" "yes" \
    "$([ "$RUNTIME_UID" = "$DIR_OWNER" ] \
        || { [ "$DIR_OWNER" = "0" ] && [ "$RUNTIME_UID" = "10001" ]; } \
        && echo yes || echo no)"

# ===========================================================================
# Scenario 2: first run against an empty directory
# ===========================================================================

echo
echo "== first run, empty directory =="

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run --rm --platform "$IMAGE_PLATFORM" --entrypoint sh \
    -v "$WORKDIR:/w" "$IMAGE" \
    -c 'rm -rf /w/public /w/private' >/dev/null 2>&1 || true
mkdir -p "$WORKDIR/public" "$WORKDIR/private"

# Without an address for the certificate's SAN it must refuse to start.
docker run --name "${CONTAINER}-nohost" --platform "$IMAGE_PLATFORM" \
    -e PVE_ANSWER_TOKEN_FILE=/app/private/token \
    -v "$WORKDIR/public:/app/public" -v "$WORKDIR/private:/app/private" \
    "$IMAGE" >/dev/null 2>&1 || true
check "refuses to start without PVE_ANSWER_HOSTNAMES" "1" \
    "$(docker inspect "${CONTAINER}-nohost" --format '{{.State.ExitCode}}')"
check "and says why" "yes" \
    "$(logs_contain "${CONTAINER}-nohost" 'PVE_ANSWER_HOSTNAMES')"
check "and leaves no partial state behind" "yes" \
    "$([ -e "$WORKDIR/private/token" ] && echo no || echo yes)"
docker rm -f "${CONTAINER}-nohost" >/dev/null 2>&1 || true

start_container -e PVE_ANSWER_HOSTNAMES=127.0.0.1,localhost

check "generated a certificate" "yes" \
    "$(docker exec "$CONTAINER" test -f /app/private/tls/server.crt \
        && echo yes || echo no)"
check "generated a private key" "yes" \
    "$(docker exec "$CONTAINER" test -f /app/private/tls/server.key \
        && echo yes || echo no)"
check "generated a token" "yes" \
    "$(docker exec "$CONTAINER" test -f /app/private/token && echo yes || echo no)"
check "generated a default answer file" "yes" \
    "$(docker exec "$CONTAINER" test -f /app/public/default.toml \
        && echo yes || echo no)"
check "created the answers directory" "yes" \
    "$(docker exec "$CONTAINER" test -d /app/public/answers && echo yes || echo no)"

check "logged the token for prepare-iso" "yes" \
    "$(logs_contain "$CONTAINER" '--answer-auth-token')"
# grep -c reads all input, so it is safe under pipefail.
check "logged the certificate fingerprint" "yes" \
    "$([ "$(docker logs "$CONTAINER" 2>&1 \
        | grep -cE '^entrypoint:   ([0-9A-F]{2}:){31}' || true)" != "0" ] \
        && echo yes || echo no)"

GENERATED_TOKEN="$(docker exec "$CONTAINER" cat /app/private/token)"
RUNTIME_UID="$(docker exec "$CONTAINER" awk '/^Uid:/ {print $2}' /proc/1/status)"

check "generated token owned by the runtime uid" "$RUNTIME_UID" \
    "$(docker exec "$CONTAINER" stat -c '%u' /app/private/token)"
check "generated key owned by the runtime uid" "$RUNTIME_UID" \
    "$(docker exec "$CONTAINER" stat -c '%u' /app/private/tls/server.key)"
check "generated default.toml owned by the runtime uid" "$RUNTIME_UID" \
    "$(docker exec "$CONTAINER" stat -c '%u' /app/public/default.toml)"
check "generated files are not root-owned" "yes" \
    "$([ "$(docker exec "$CONTAINER" stat -c '%u' /app/private/token)" != "0" ] \
        && echo yes || echo no)"

check "generated certificate carries the right SAN" "yes" \
    "$(echo | openssl s_client -connect "127.0.0.1:$PORT" 2>/dev/null \
        | openssl x509 -noout -text 2>/dev/null \
        | grep -q 'IP Address:127.0.0.1' && echo yes || echo no)"

check "serves with the generated token" 200 \
    "$(status -X POST -H "Authorization: Bearer $GENERATED_TOKEN" \
        "$BASE/answer" -d "$UNKNOWN")"
check "still rejects a request without it" 401 \
    "$(status -X POST "$BASE/answer" -d "$UNKNOWN")"
check "generated default installs nothing" "yes" \
    "$(curl -sk -X POST -H "Authorization: Bearer $GENERATED_TOKEN" \
        "$BASE/answer" -d "$UNKNOWN" | grep -q '^\[' && echo no || echo yes)"

# A restart must not invalidate what the first run generated.
LOG_LINES_BEFORE_RESTART="$(docker logs "$CONTAINER" 2>&1 | wc -l | tr -d ' ')"
docker restart "$CONTAINER" >/dev/null

# An ephemeral published port is reassigned on restart, so the old $BASE is
# dead and polling it just burns the whole timeout.
PORT="$(docker port "$CONTAINER" 8443/tcp | head -1 | sed 's/.*://')"
BASE="https://127.0.0.1:$PORT"

for _ in $(seq 1 180); do
    curl -sk -o /dev/null "$BASE/health" && break
    sleep 0.5
done

check "serves again after restart" 200 "$(status "$BASE/health")"

check "restart keeps the same token" "$GENERATED_TOKEN" \
    "$(docker exec "$CONTAINER" cat /app/private/token)"
check "restart regenerates nothing" "0" \
    "$(docker logs "$CONTAINER" 2>&1 \
        | tail -n "+$((LOG_LINES_BEFORE_RESTART + 1))" \
        | grep -cE 'generating a self-signed|generated a new auth token' || true)"

# ===========================================================================
# Scenario 3: root-owned private directory falls back to the image user
# ===========================================================================

echo
echo "== root-owned private directory =="

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

# A fresh named volume is owned by root, which is exactly the case that has to
# fall back rather than run the server as root.
ROOT_VOLUME="pve-answer-smoke-root-$$"
docker volume create "$ROOT_VOLUME" >/dev/null

docker run -d --name "${CONTAINER}-root" --platform "$IMAGE_PLATFORM" -p 0:8443 \
    -e PVE_ANSWER_HOSTNAMES=127.0.0.1 \
    -e PVE_ANSWER_TOKEN_FILE=/app/private/token \
    -v "$WORKDIR/public:/app/public" \
    -v "$ROOT_VOLUME:/app/private" \
    "$IMAGE" >/dev/null

ROOT_BASE="$(wait_ready "${CONTAINER}-root")" || exit 1

check "warns about the root-owned directory" "yes" \
    "$(logs_contain "${CONTAINER}-root" 'owned by root')"
check "falls back to the image user, not root" "10001" \
    "$(docker exec "${CONTAINER}-root" awk '/^Uid:/ {print $2}' /proc/1/status 2>/dev/null \
        || echo unavailable)"
check "and serves" 200 "$(status "$ROOT_BASE/health")"

docker rm -f "${CONTAINER}-root" >/dev/null 2>&1 || true

# ===========================================================================
# Scenario 4: private directory owned by a real user
# ===========================================================================
#
# Docker Desktop presents bind mounts as root-owned whatever the host says, so
# the derivation is exercised through a volume chowned to a known uid instead.
# This is the case that matters on a Linux host.

echo
echo "== private directory owned by uid 4242 =="

docker run --rm --platform "$IMAGE_PLATFORM" --entrypoint sh \
    -v "$ROOT_VOLUME:/app/private" "$IMAGE" \
    -c 'chown 4242:4242 /app/private' >/dev/null

docker run -d --name "${CONTAINER}-user" --platform "$IMAGE_PLATFORM" -p 0:8443 \
    -e PVE_ANSWER_HOSTNAMES=127.0.0.1 \
    -e PVE_ANSWER_TOKEN_FILE=/app/private/token \
    -v "$WORKDIR/public:/app/public" \
    -v "$ROOT_VOLUME:/app/private" \
    "$IMAGE" >/dev/null

USER_BASE="$(wait_ready "${CONTAINER}-user")" || exit 1

check "runs as the directory owner" "4242" \
    "$(docker exec "${CONTAINER}-user" awk '/^Uid:/ {print $2}' /proc/1/status \
        2>/dev/null || echo unavailable)"
check "no root-owned warning" "no" \
    "$(logs_contain "${CONTAINER}-user" 'owned by root')"
check "generated token owned by that uid" "4242" \
    "$(docker exec "${CONTAINER}-user" stat -c '%u' /app/private/token \
        2>/dev/null || echo unavailable)"
check "generated key owned by that uid" "4242" \
    "$(docker exec "${CONTAINER}-user" stat -c '%u' /app/private/tls/server.key \
        2>/dev/null || echo unavailable)"

check "and still serves" 200 "$(status "$USER_BASE/health")"

docker rm -f "${CONTAINER}-user" >/dev/null 2>&1 || true
docker volume rm "$ROOT_VOLUME" >/dev/null 2>&1 || true

# ===========================================================================

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed. Container log:" >&2
    docker logs "$CONTAINER" >&2
    exit 1
fi

echo "All smoke checks passed against '$IMAGE'."
