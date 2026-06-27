#!/usr/bin/env bash
#
# plex-healthcheck.sh — Verify the Plex (Podman) container is healthy and
# restart it if necessary.
#
# Health is defined as BOTH:
#   1. The container is running.
#   2. Plex Media Server answers HTTP 200 on its local /identity endpoint
#      (no auth required, returns the server's machine identifier XML).
#
# If either check fails, the container is restarted and the script waits for
# Plex to come back up before reporting the result.
#
# Exit codes:
#   0  Plex healthy (either already, or recovered after a restart)
#   1  Plex unhealthy and could NOT be recovered
#   2  Environment error (e.g. podman not found)
#
# Run as the same user that owns the container (rootless Podman). Override any
# setting via environment variables, e.g.:
#   PLEX_CONTAINER=plex PLEX_PORT=32400 ./plex-healthcheck.sh

set -o pipefail

# ---- Configuration (override via environment) ----------------------------
CONTAINER_NAME="${PLEX_CONTAINER:-plex}"
PLEX_HOST="${PLEX_HOST:-127.0.0.1}"
PLEX_PORT="${PLEX_PORT:-32400}"
HEALTH_PATH="/identity"                                # 200 + XML, no auth
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"                     # seconds per request
POST_RESTART_RETRIES="${POST_RESTART_RETRIES:-12}"     # attempts after restart
POST_RESTART_DELAY="${POST_RESTART_DELAY:-5}"          # seconds between attempts
LOG_FILE="${PLEX_HEALTH_LOG:-}"                        # optional; empty = stdout
# Report file: a line is appended ONLY when Plex has to be reset (restarted).
REPORT_FILE="${PLEX_HEALTH_REPORT:-$HOME/Podman/plex-healthcheck-report.log}"
# How to restart Plex. The container is managed by a systemd/Quadlet unit and
# runs with auto-remove, so 'podman restart' fails after a stop/crash — it must
# be (re)started via systemd. Mode: auto (systemd if unit exists) | systemd | podman.
RESTART_MODE="${PLEX_RESTART_MODE:-auto}"
SYSTEMD_UNIT="${PLEX_SYSTEMD_UNIT:-plex.service}"
SYSTEMCTL_SCOPE="${PLEX_SYSTEMCTL_SCOPE:---user}"      # "--user" (rootless) or "" (system)
# Parse the scope string into an array: "--user" yields one arg; an empty value
# (system scope) yields zero args. The array expansion used below is correct in
# both cases without relying on unquoted word-splitting (avoids SC2086).
read -ra SYSTEMCTL_SCOPE_ARR <<< "$SYSTEMCTL_SCOPE"

PLEX_URL="http://${PLEX_HOST}:${PLEX_PORT}${HEALTH_PATH}"

# ---- Logging -------------------------------------------------------------
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [ -n "$LOG_FILE" ]; then
        echo "$msg" | tee -a "$LOG_FILE"
    else
        echo "$msg"
    fi
}

report() {
    # Append one key=value record describing a Plex reset (restart) event.
    local result="$1" reason="$2" attempts="$3" duration="$4"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
    mkdir -p "$(dirname "$REPORT_FILE")" 2>/dev/null
    if [ ! -f "$REPORT_FILE" ]; then
        echo "# Plex reset report — one line per restart performed by plex-healthcheck.sh" \
            >> "$REPORT_FILE" 2>/dev/null
    fi
    if printf '%s  RESET  result=%s  reason="%s"  attempts=%s  duration=%ss  host=%s\n' \
        "$ts" "$result" "$reason" "$attempts" "$duration" "${HOSTNAME:-unknown}" \
        >> "$REPORT_FILE" 2>/dev/null; then
        log "Report entry written to ${REPORT_FILE} (result=${result})."
    else
        log "ERROR: failed to write report entry to ${REPORT_FILE}."
    fi
}

# ---- Checks --------------------------------------------------------------
require_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        log "ERROR: 'podman' not found in PATH."
        exit 2
    fi
}

container_running() {
    podman ps --filter "name=^${CONTAINER_NAME}$" --filter "status=running" \
        --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

plex_responding() {
    curl -sf -o /dev/null --max-time "$CURL_TIMEOUT" "$PLEX_URL"
}

# True if the configured systemd unit is known to the (user) manager.
unit_exists() {
    [ "$(systemctl "${SYSTEMCTL_SCOPE_ARR[@]}" show "$SYSTEMD_UNIT" --property=LoadState --value 2>/dev/null)" = "loaded" ]
}

restart_plex() {
    # Quadlet/systemd-managed containers run with auto-remove, so a plain
    # 'podman restart' fails once the container is gone; restart via systemd.
    if [ "$RESTART_MODE" = "systemd" ] || { [ "$RESTART_MODE" = "auto" ] && unit_exists; }; then
        log "Restarting via systemd unit '${SYSTEMD_UNIT}' (systemctl ${SYSTEMCTL_SCOPE})..."
        if systemctl "${SYSTEMCTL_SCOPE_ARR[@]}" restart "$SYSTEMD_UNIT"; then
            log "systemctl restart issued for '${SYSTEMD_UNIT}'."
            return 0
        fi
        log "ERROR: 'systemctl ${SYSTEMCTL_SCOPE} restart ${SYSTEMD_UNIT}' failed."
        return 1
    fi

    log "Restarting container '${CONTAINER_NAME}' via podman..."
    if podman restart "$CONTAINER_NAME" >/dev/null 2>&1; then
        log "Restart command issued."
        return 0
    fi
    log "ERROR: 'podman restart ${CONTAINER_NAME}' failed (does the container exist?)."
    return 1
}

# Set by wait_for_recovery so the report can record how many attempts it took.
RECOVERY_ATTEMPTS=0

wait_for_recovery() {
    local i
    for (( i = 1; i <= POST_RESTART_RETRIES; i++ )); do
        if plex_responding; then
            RECOVERY_ATTEMPTS=$i
            log "Plex is responding again (attempt ${i}/${POST_RESTART_RETRIES})."
            return 0
        fi
        log "Waiting for Plex to come up (attempt ${i}/${POST_RESTART_RETRIES})..."
        sleep "$POST_RESTART_DELAY"
    done
    RECOVERY_ATTEMPTS=$POST_RESTART_RETRIES
    return 1
}

# ---- Main ----------------------------------------------------------------
main() {
    require_podman

    if container_running && plex_responding; then
        log "OK: '${CONTAINER_NAME}' running and Plex responding at ${PLEX_URL}."
        exit 0
    fi

    local reason
    if container_running; then
        reason="container running but Plex not responding at ${PLEX_URL}"
    else
        reason="container '${CONTAINER_NAME}' not running"
    fi
    log "WARN: ${reason}. Resetting Plex..."

    local start=$SECONDS
    if ! restart_plex; then
        report "FAILED-RESTART" "$reason" "0" "$(( SECONDS - start ))"
        exit 1
    fi

    if wait_for_recovery; then
        log "OK: Plex recovered after restart."
        report "RECOVERED" "$reason" "$RECOVERY_ATTEMPTS" "$(( SECONDS - start ))"
        exit 0
    fi

    log "ERROR: Plex still not responding after restart."
    report "FAILED-RECOVERY" "$reason" "$RECOVERY_ATTEMPTS" "$(( SECONDS - start ))"
    exit 1
}

main "$@"
