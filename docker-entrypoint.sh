#!/bin/sh
#
# Creates whatever is missing, then runs the server unprivileged.
# Existing files are never overwritten.

set -eu

# Used only if the private directory's owner cannot be used.
FALLBACK_UID=10001
FALLBACK_GID=10001

PUBLIC_DIR="${PVE_ANSWER_PUBLIC_DIR:-/app/public}"
PRIVATE_DIR="${PVE_ANSWER_PRIVATE_DIR:-/app/private}"

ANSWERS_DIR="$PUBLIC_DIR/answers"
DEFAULT_ANSWER="$PUBLIC_DIR/default.toml"
TOKEN_FILE="$PRIVATE_DIR/token"
TLS_DIR="$PRIVATE_DIR/tls"
CERT_FILE="$TLS_DIR/server.crt"
KEY_FILE="$TLS_DIR/server.key"

log() { echo "entrypoint: $*"; }

# Checked first, so a doomed run leaves nothing behind.
if [ ! -e "$CERT_FILE" ] || [ ! -e "$KEY_FILE" ]; then
    if [ -z "${PVE_ANSWER_HOSTNAMES:-}" ]; then
        log "ERROR: no certificate at $CERT_FILE and PVE_ANSWER_HOSTNAMES is"
        log "unset, so one cannot be generated."
        log ""
        log "The Proxmox installer validates the certificate's SAN entries, so"
        log "every address it may use to reach this server has to be named."
        log "Set it to a comma-separated list, for example:"
        log "  PVE_ANSWER_HOSTNAMES=10.100.9.50,pve-answer.example.com"
        exit 1
    fi
fi

mkdir -p "$ANSWERS_DIR" "$TLS_DIR"

# --- runtime identity ------------------------------------------------------
# Run as the owner of the private directory, so generated files are usable on
# the host without sudo.

DIR_UID="$(stat -c '%u' "$PRIVATE_DIR" 2>/dev/null || true)"
DIR_GID="$(stat -c '%g' "$PRIVATE_DIR" 2>/dev/null || true)"

if [ -n "$DIR_UID" ] && [ "$DIR_UID" != "0" ]; then
    APP_UID="$DIR_UID"
    APP_GID="${DIR_GID:-$DIR_UID}"
else
    APP_UID="$FALLBACK_UID"
    APP_GID="$FALLBACK_GID"

    if [ "$DIR_UID" = "0" ]; then
        log "WARNING: $PRIVATE_DIR is owned by root, so the server will run as"
        log "$APP_UID instead and generated files will need sudo to remove."
        log "To avoid that: chown -R \$(id -u):\$(id -g) on the host directory."
    else
        log "WARNING: could not determine the owner of $PRIVATE_DIR; running as"
        log "$APP_UID."
    fi
fi

log "running as uid $APP_UID, gid $APP_GID"

# --- default answer file ---------------------------------------------------

if [ ! -e "$DEFAULT_ANSWER" ]; then
    log "creating $DEFAULT_ANSWER"

    cat > "$DEFAULT_ANSWER" <<'TOML'
# No answer file matched this machine's MAC address.
#
# This file is intentionally empty of settings, so the installer receives an
# answer file with no [global], [network] or [disk-setup] section, fails
# validation, and stops. Nothing is installed automatically on a machine that
# has not been registered.
#
# To provision this machine, add an answer file named after its MAC address:
#
#   public/answers/<mac>.toml       e.g. public/answers/bc-24-11-7b-51-aa.toml
#
# Separators do not matter: bc-24-11-7b-51-aa, bc:24:11:7b:51:aa and
# BC24117B51AA all match the same NIC.
#
# Field reference:
# https://pve.proxmox.com/wiki/Automated_Installation#Answer_File_Format
#
# To turn this into a real catch-all install later, replace these comments
# with a complete answer file.
TOML
fi

# --- auth token ------------------------------------------------------------

if [ ! -e "$TOKEN_FILE" ]; then
    printf 'provisioning:%s' "$(openssl rand -hex 32)" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"

    log "generated a new auth token. Prepare ISOs with:"
    log "  --answer-auth-token '$(cat "$TOKEN_FILE")'"
fi

# --- TLS certificate -------------------------------------------------------

if [ ! -e "$CERT_FILE" ] || [ ! -e "$KEY_FILE" ]; then
    san=""
    IFS=','
    for host in $PVE_ANSWER_HOSTNAMES; do
        host="$(echo "$host" | tr -d ' ')"

        [ -n "$host" ] || continue

        case "$host" in
            *[!0-9.]*) entry="DNS:$host" ;;
            *)         entry="IP:$host" ;;
        esac

        if [ -z "$san" ]; then
            san="$entry"
        else
            san="$san,$entry"
        fi
    done
    unset IFS

    if [ -z "$san" ]; then
        log "ERROR: PVE_ANSWER_HOSTNAMES contains no usable entries"
        exit 1
    fi

    log "generating a self-signed certificate for $san"

    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -subj "/CN=$(echo "$PVE_ANSWER_HOSTNAMES" | cut -d ',' -f 1)" \
        -addext "subjectAltName=$san" 2>/dev/null

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"
fi

# Printed every start, so it is always in the log.
log "certificate SHA-256 fingerprint (pass to prepare-iso --cert-fingerprint):"
log "  $(openssl x509 -in "$CERT_FILE" -noout -fingerprint -sha256 \
    | cut -d '=' -f 2)"

# --- hand over -------------------------------------------------------------

# Only files this script created; answer files keep their own ownership.
chown "$APP_UID:$APP_GID" "$TOKEN_FILE" "$CERT_FILE" "$KEY_FILE" 2>/dev/null || true
[ -e "$DEFAULT_ANSWER" ] && chown "$APP_UID:$APP_GID" "$DEFAULT_ANSWER" 2>/dev/null || true

exec setpriv --reuid="$APP_UID" --regid="$APP_GID" --clear-groups \
    python3 /app/server.py "$@"
