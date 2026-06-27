#!/usr/bin/env bash
#
# plex-report-clear.sh — Clear (truncate) the Plex reset report log.
#
# Intended to run monthly via the plex-report-clear systemd user timer, but it
# is safe to run by hand. Uses the same default path / override as the
# health-check script so the two stay in sync.
#
#   PLEX_HEALTH_REPORT=/path/to/report.log ./plex-report-clear.sh

set -o pipefail

REPORT_FILE="${PLEX_HEALTH_REPORT:-$HOME/Podman/plex-healthcheck-report.log}"
ts="$(date '+%Y-%m-%d %H:%M:%S %z')"

mkdir -p "$(dirname "$REPORT_FILE")" 2>/dev/null

# Truncate to empty and write a fresh header recording when it was cleared.
{
    echo "# Plex reset report — one line per restart performed by plex-healthcheck.sh"
    echo "# Cleared: ${ts}"
} > "$REPORT_FILE"

echo "[${ts}] Cleared report log: ${REPORT_FILE}"
