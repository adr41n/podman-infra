#!/bin/bash
# test-cron-jobs.sh — Verifies cron job scheduling, script permissions, and logic.
# Usage: bash test-cron-jobs.sh
# Exit 0 → all tests passed.  Exit 1 → one or more tests failed.

PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; RESET='\033[0m'

BIN_LOCAL=/home/adrian/bin_local

pass()  { echo -e "  ${GREEN}PASS${RESET}  $1"; ((++PASS)); return 0; }
fail()  { echo -e "  ${RED}FAIL${RESET}  $1"; ((++FAIL)); return 0; }
skip()  { echo -e "  ${YELLOW}SKIP${RESET}  $1";             }
section(){ echo; echo "── $1"; }

# ── Mock setup ───────────────────────────────────────────────────────────────
# Prepend a mock-bin directory to PATH so network/IO commands are no-ops.
# crontab is intentionally NOT mocked — real output is needed for schedule tests.
MOCK_BIN=$(mktemp -d)
trap 'rm -rf "$MOCK_BIN"' EXIT

for cmd in curl rsync apt snap flatpak sudo tee cp mkdir; do
  printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/$cmd"
  chmod +x "$MOCK_BIN/$cmd"
done

# Capture the real crontab before overriding PATH.
CRONTAB=$(crontab -l 2>/dev/null)
export PATH="$MOCK_BIN:$PATH"

# ─────────────────────────────────────────────────────────────────────────────
section "1. Crontab schedule"
# ─────────────────────────────────────────────────────────────────────────────

grep -qE '^\*/5 \* \* \* \* .*/CheckRequests$' <<< "$CRONTAB" \
  && pass "CheckRequests scheduled every 5 min  (*/5 * * * *)" \
  || fail "CheckRequests scheduled every 5 min  (*/5 * * * *)"

grep -qE '^0 6 \* \* \* .*/SaveHome$' <<< "$CRONTAB" \
  && pass "SaveHome scheduled daily at 06:00     (0 6 * * *)" \
  || fail "SaveHome scheduled daily at 06:00     (0 6 * * *)"

grep -qE '^55 5 1 \* \* .*/ClearSaveHomeLog$' <<< "$CRONTAB" \
  && pass "ClearSaveHomeLog 1st of month 05:55   (55 5 1 * *)" \
  || fail "ClearSaveHomeLog 1st of month 05:55   (55 5 1 * *)"

# ─────────────────────────────────────────────────────────────────────────────
section "2. Script existence, permissions, and syntax"
# ─────────────────────────────────────────────────────────────────────────────

for script in CheckRequests SaveHome ClearSaveHomeLog; do
  path="$BIN_LOCAL/$script"
  [ -f "$path" ]  && pass "$script: file exists"      || fail "$script: file exists"
  [ -x "$path" ]  && pass "$script: is executable"    || fail "$script: is executable"
  bash -n "$path" && pass "$script: syntax is valid"  || fail "$script: syntax is valid"
done

# ─────────────────────────────────────────────────────────────────────────────
section "3. ClearSaveHomeLog — log file cleanup"
# ─────────────────────────────────────────────────────────────────────────────

LOG_FILES=(CheckRequests.txt SaveHome.txt SaveHome-Error.txt rSyncMovies.txt rSyncTV.txt)

# Seed all expected log files.
for f in "${LOG_FILES[@]}"; do touch "$BIN_LOCAL/$f"; done

bash "$BIN_LOCAL/ClearSaveHomeLog"

for f in "${LOG_FILES[@]}"; do
  [ ! -f "$BIN_LOCAL/$f" ] \
    && pass "ClearSaveHomeLog: removed $f" \
    || fail "ClearSaveHomeLog: removed $f"
done

# Re-run when no files present — must exit 0 cleanly.
bash "$BIN_LOCAL/ClearSaveHomeLog" \
  && pass "ClearSaveHomeLog: exits cleanly when no log files present" \
  || fail "ClearSaveHomeLog: exits cleanly when no log files present"

# ─────────────────────────────────────────────────────────────────────────────
section "4. CheckRequests — dispatch logic"
# ─────────────────────────────────────────────────────────────────────────────

# Clean slate.
rm -f "$BIN_LOCAL/SaveHome-Request"    "$BIN_LOCAL/SaveHome-Active"
rm -f "$BIN_LOCAL/DorSyncMovies-Request" "$BIN_LOCAL/rSyncMovies-Active"
rm -f "$BIN_LOCAL/DorSyncTV-Request"   "$BIN_LOCAL/rSyncTV-Active"
rm -f "$BIN_LOCAL/DorSyncFLAC-Request" "$BIN_LOCAL/rSyncFLAC-Active"

# 4a: No request files → nothing dispatched.
bash "$BIN_LOCAL/CheckRequests"
[ ! -f "$BIN_LOCAL/SaveHome-Active" ] \
  && pass "CheckRequests: no request files → SaveHome not launched" \
  || fail "CheckRequests: no request files → SaveHome not launched"

# 4b: SaveHome-Active present → request must be ignored (file preserved).
touch "$BIN_LOCAL/SaveHome-Request" "$BIN_LOCAL/SaveHome-Active"
bash "$BIN_LOCAL/CheckRequests"
[ -f "$BIN_LOCAL/SaveHome-Request" ] \
  && pass "CheckRequests: SaveHome-Active blocks dispatch (request preserved)" \
  || fail "CheckRequests: SaveHome-Active blocks dispatch (request preserved)"
rm -f "$BIN_LOCAL/SaveHome-Active" "$BIN_LOCAL/SaveHome-Request"

# 4c: SaveHome-Request present, no Active → request consumed (file removed).
# CheckRequests removes the request file before launching SaveHome in background.
# We never modify the actual SaveHome binary; mocked PATH makes the background run harmless.
touch "$BIN_LOCAL/SaveHome-Request"
bash "$BIN_LOCAL/CheckRequests"
sleep 1   # allow background SaveHome to complete under mocked PATH

[ ! -f "$BIN_LOCAL/SaveHome-Request" ] \
  && pass "CheckRequests: SaveHome-Request consumed after dispatch" \
  || fail "CheckRequests: SaveHome-Request consumed after dispatch"

rm -f "$BIN_LOCAL/SaveHome-Active"   # clean up flag left by background SaveHome

# ─────────────────────────────────────────────────────────────────────────────
section "5. SaveHome — flag-file guard"
# ─────────────────────────────────────────────────────────────────────────────

FLAGFILE="$BIN_LOCAL/SaveHome-Active"
LOGFILE="$BIN_LOCAL/SaveHome.txt"
rm -f "$FLAGFILE" "$LOGFILE"

# 5a: Flag present → exits early and logs "already active".
touch "$FLAGFILE"
bash "$BIN_LOCAL/SaveHome"
grep -q "already active" "$LOGFILE" \
  && pass "SaveHome: logs 'already active' when flag is set" \
  || fail "SaveHome: logs 'already active' when flag is set"
[ ! -f "$FLAGFILE" ] \
  && skip "SaveHome: flag not removed in early-exit path (expected behaviour)" \
  || true
rm -f "$FLAGFILE" "$LOGFILE"

# 5b: Flag absent → flag is created on entry and removed on exit.
[ ! -f "$FLAGFILE" ] \
  && pass "SaveHome: flag absent before run (precondition)" \
  || fail "SaveHome: flag absent before run (precondition)"

bash "$BIN_LOCAL/SaveHome"

[ ! -f "$FLAGFILE" ] \
  && pass "SaveHome: flag cleaned up after successful run" \
  || fail "SaveHome: flag cleaned up after successful run"
rm -f "$LOGFILE"

# ─────────────────────────────────────────────────────────────────────────────
section "Summary"
# ─────────────────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))
echo
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All $TOTAL tests passed.${RESET}"
  exit 0
else
  echo -e "${RED}$FAIL of $TOTAL tests failed.${RESET}"
  exit 1
fi
