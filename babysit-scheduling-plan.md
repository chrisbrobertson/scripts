# Plan — Babysit lock recovery + scheduled runs with bounded concurrency

> **Status:** drafted, not yet implemented. Execute when ready.

## Context

Two gaps in `babysit-with-review.sh`'s startup logic block both crash recovery and scheduling:

1. **Cannot tell live lock from stale lock.** The per-project lock at `~/sisyphus-logs/<project>.stop` is created by `touch` (empty file). On startup, *any* existing file means error — even if the previous run was killed by SIGKILL / OOM / power loss / dropped SSH and no babysit is actually running. The error message asks the operator to `pgrep -af babysit` and `rm` the file. Bad UX for a human; fatal for cron/launchd.

2. **Hard error on held lock breaks scheduling.** Even when correctly detecting "another instance is live," `exit 1` causes a launchd job to be marked failed. A scheduled babysit needs to *silently skip* a tick when the project is already busy — that's not a failure, it's intended back-pressure.

Today's startup block is at lines 57–86 of `~/repos/scripts/babysit-with-review.sh`. Lock claim is at line 82 (`touch "$LOG" "$STOP_FILE"`). EXIT trap at line 83 clears it on graceful exit and most signals.

## Decisions captured during planning

1. **Concurrency applies per-project AND globally.** Per-project (1 max) is already free from the stop-file lock. Global cap is configurable via `MAX_CONCURRENT_BABYSITS` (default 1).
2. **Schedule via macOS launchd LaunchAgent**, one plist per project. Native macOS, runs as the user, OAuth token already in place.

## Fix

### 1. Lock with PID; detect stale vs live

Replace the existing block at lines 63–83 of `~/repos/scripts/babysit-with-review.sh` with:

```bash
NONINTERACTIVE="${BABYSIT_NONINTERACTIVE:-}"
MAX_CONCURRENT_BABYSITS="${MAX_CONCURRENT_BABYSITS:-1}"

# Exit cleanly when scheduled (launchd/cron); error visibly when interactive.
soft_exit() {
  local code="$1"; shift
  if [ -n "$NONINTERACTIVE" ]; then
    echo "[skip] $*" >&2
    exit 0
  fi
  echo "$*" >&2
  exit "$code"
}

# --- per-project lock: stale-vs-live ---
if [ -f "$STOP_FILE" ]; then
  OLD_PID="$(cat "$STOP_FILE" 2>/dev/null)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    soft_exit 1 "babysit lock $STOP_FILE held by live PID $OLD_PID for '$PROJECT'"
  else
    echo "[lock] clearing stale lock $STOP_FILE (previous PID ${OLD_PID:-empty} no longer running)" >&2
    rm -f "$STOP_FILE"
  fi
fi

# --- global concurrency cap ---
# pgrep -cf matches argv, so it includes our own bash invocation. Subtract 1.
RUNNING="$(pgrep -cf 'babysit-with-review\.sh' 2>/dev/null || echo 1)"
OTHERS=$(( RUNNING > 0 ? RUNNING - 1 : 0 ))
if [ "$OTHERS" -ge "$MAX_CONCURRENT_BABYSITS" ]; then
  soft_exit 0 "$OTHERS babysit(s) running; MAX_CONCURRENT_BABYSITS=$MAX_CONCURRENT_BABYSITS — skipping"
fi

# --- claim the lock atomically ---
TMP_RESULT=$(mktemp)
TMP_REVIEW=$(mktemp)
TMP_REVIEW_RESULT=$(mktemp)
touch "$LOG"

# set -C (no-clobber) closes the small TOCTOU window between stale-check and lock-claim.
if ! ( set -C; echo "$$" > "$STOP_FILE" ) 2>/dev/null; then
  soft_exit 1 "another babysit grabbed $STOP_FILE for '$PROJECT' between checks"
fi
trap 'rm -f "$STOP_FILE" "$TMP_RESULT" "$TMP_REVIEW" "$TMP_REVIEW_RESULT"' EXIT
```

This replaces lines 63–83 (the existing `if [ -f "$STOP_FILE" ]` block + the tmp-file creates + the `touch "$LOG" "$STOP_FILE"` + the `trap`).

### 2. Document the new env vars

Lines 15–19 of `babysit-with-review.sh` list the env vars; add two:

```
#   BABYSIT_NONINTERACTIVE   set non-empty to silence interactive errors and exit 0
#                            on held/stale-lock paths. For launchd/cron use.
#   MAX_CONCURRENT_BABYSITS  default 1   global cap on simultaneous babysit-with-review
#                            processes. Counted via pgrep across all projects.
```

Mirror in `usage()` at lines 32–43.

### 3. launchd LaunchAgent template

New file: `~/repos/scripts/launchd/com.chrisrobertson.babysit.PROJECT.plist.template`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Replace __PROJECT__ with the project basename. -->
  <key>Label</key>
  <string>com.chrisrobertson.babysit.__PROJECT__</string>

  <key>ProgramArguments</key>
  <array>
    <string>/Users/chrisrobertson/repos/scripts/babysit-with-review.sh</string>
  </array>

  <!-- Replace __PROJECT_PATH__ with absolute path to the repo to babysit. -->
  <key>WorkingDirectory</key>
  <string>__PROJECT_PATH__</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>BABYSIT_NONINTERACTIVE</key>
    <string>1</string>
    <key>MAX_CONCURRENT_BABYSITS</key>
    <string>1</string>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>HOME</key>
    <string>/Users/chrisrobertson</string>
  </dict>

  <!-- Edit the schedule. Example: 09:00 and 17:00 daily. -->
  <key>StartCalendarInterval</key>
  <array>
    <dict>
      <key>Hour</key>    <integer>9</integer>
      <key>Minute</key>  <integer>0</integer>
    </dict>
    <dict>
      <key>Hour</key>    <integer>17</integer>
      <key>Minute</key>  <integer>0</integer>
    </dict>
  </array>

  <key>RunAtLoad</key>
  <false/>

  <key>StandardOutPath</key>
  <string>/Users/chrisrobertson/sisyphus-logs/launchd-__PROJECT__.out</string>
  <key>StandardErrorPath</key>
  <string>/Users/chrisrobertson/sisyphus-logs/launchd-__PROJECT__.err</string>
</dict>
</plist>
```

**Intentional choices (write into the template's leading comment):**

- **No `KeepAlive`.** Avoids the crash-loop pattern that bit Mac Mini's colima daemon. `StartCalendarInterval` fires at the wall-clock moment and that's it.
- **No `ThrottleInterval`.** Only matters for KeepAlive-driven respawns.
- **`RunAtLoad = false`.** Loading the plist with `launchctl load` shouldn't immediately fire a babysit run.

### 4. Install helper (optional, small)

New file: `~/repos/scripts/launchd/install-babysit-agent.sh`

A 30–40 line bash script that takes `<project_basename> <project_absolute_path>` and:
1. Reads the template, substitutes `__PROJECT__` and `__PROJECT_PATH__`.
2. Writes to `~/Library/LaunchAgents/com.chrisrobertson.babysit.<project>.plist`.
3. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/...` (with `launchctl load` as fallback for older macOS).
4. Prints a `launchctl print` summary so the operator can verify.

Optional QoL — the plist alone is sufficient.

### 5. CLAUDE.md update

Add a short subsection after the **Files** table:

> **Locking & scheduled runs.** `babysit-with-review.sh` claims a per-project lock at `~/sisyphus-logs/<project>.stop` containing the PID. On startup it detects stale (orphaned) locks via `kill -0` and clears them automatically. Set `BABYSIT_NONINTERACTIVE=1` to make held-lock and at-cap conditions exit 0 instead of erroring (used by launchd jobs). Set `MAX_CONCURRENT_BABYSITS` (default 1) to cap total simultaneous runs across all projects. See `launchd/com.chrisrobertson.babysit.PROJECT.plist.template` for a LaunchAgent example.

## Files modified / added

| Path | Change |
| --- | --- |
| `~/repos/scripts/babysit-with-review.sh` | Replace existing lock block (lines 63–83). Document `BABYSIT_NONINTERACTIVE` and `MAX_CONCURRENT_BABYSITS` in the file header (lines 15–19) and `usage()` (lines 32–43). |
| `~/repos/scripts/launchd/com.chrisrobertson.babysit.PROJECT.plist.template` | NEW — LaunchAgent template with `__PROJECT__` / `__PROJECT_PATH__` placeholders. |
| `~/repos/scripts/launchd/install-babysit-agent.sh` | NEW — optional helper that fills the template and bootstraps it via `launchctl`. |
| `~/repos/scripts/CLAUDE.md` | Add **Locking & scheduled runs** subsection. |

No new runtime dependencies. `pgrep`, `kill -0`, `set -C`, `launchctl` are all macOS built-ins.

## Verification

1. **Shell syntax.**
   ```
   bash -n ~/repos/scripts/babysit-with-review.sh
   bash -n ~/repos/scripts/launchd/install-babysit-agent.sh
   # plutil rejects placeholders; lint after substitution:
   plutil -lint ~/Library/LaunchAgents/com.chrisrobertson.babysit.scripts.plist
   ```

2. **Stale-lock recovery — synthetic.**
   ```
   echo 99999 > ~/sisyphus-logs/scripts.stop      # PID 99999 should not be running
   cd ~/repos/scripts && ./babysit-with-review.sh # should log "[lock] clearing stale lock ..." and proceed
   # Ctrl-C immediately after it boots; verify the stop file was cleared.
   ```

3. **Live-lock respect — interactive.** With one babysit running, in another terminal:
   ```
   cd ~/repos/scripts && ./babysit-with-review.sh
   echo "exit: $?"   # expect a "lock held by live PID X" message and exit 1
   ```

4. **Live-lock respect — non-interactive.**
   ```
   BABYSIT_NONINTERACTIVE=1 ./babysit-with-review.sh
   echo "exit: $?"   # expect [skip] and exit 0
   ```

5. **Global cap — non-interactive.** With one babysit running and the cap at default (1):
   ```
   BABYSIT_NONINTERACTIVE=1 MAX_CONCURRENT_BABYSITS=1 ./babysit-with-review.sh
   ```
   Expect `[skip] 1 babysit(s) running; MAX_CONCURRENT_BABYSITS=1 — skipping`, exit 0. Bumping `MAX_CONCURRENT_BABYSITS=2` should let a second start (it'll then hit the per-project lock if same project — expected).

6. **TOCTOU is benign.** Two simultaneous starts for the same project: at most one wins the `set -C` lock-claim; the other gets the "another babysit grabbed lock between checks" path. Neither corrupts state.

7. **launchd plist materialisation.**
   ```
   ~/repos/scripts/launchd/install-babysit-agent.sh scripts ~/repos/scripts
   plutil -lint ~/Library/LaunchAgents/com.chrisrobertson.babysit.scripts.plist
   launchctl print gui/$(id -u)/com.chrisrobertson.babysit.scripts | head -40
   # Then unload to keep it off until you actually want it scheduled:
   launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chrisrobertson.babysit.scripts.plist
   ```

8. **End-to-end (lower confidence — costs model spend).** Reduce the schedule in the test plist to a near-future minute, load it, watch `~/sisyphus-logs/launchd-scripts.{out,err}` for the babysit log header, then unload.

## Delivery

Single PR against `main` of `chrisbrobertson/scripts`. Two commits:

1. **`Detect stale locks; honour BABYSIT_NONINTERACTIVE; cap with MAX_CONCURRENT_BABYSITS`** — the script changes (lock block + header doc + usage doc).
2. **`Add launchd LaunchAgent template + install helper`** — the new `launchd/` directory.

PR title: *Babysit: stale-lock recovery + launchd-friendly mode*

PR body: short summary, point at the two gaps in the existing lock setup (lines 63–83), note that this builds on the in-flight `fix-review-cycle-bail-paths` work without modifying it.

## Critical files referenced

| Path | Why |
| --- | --- |
| `~/repos/scripts/babysit-with-review.sh` lines 15–19 | Env-var docblock — extend with the two new vars. |
| `~/repos/scripts/babysit-with-review.sh` lines 32–43 (`usage()`) | Mirror the env-var doc here. |
| `~/repos/scripts/babysit-with-review.sh` lines 57–86 | The lock setup — single edit site replacing lines 63–83. |
| `~/repos/scripts/babysit-with-review.sh` line 83 (the existing `trap`) | Already removes the stop file on graceful exit; relocate after the lock-claim. |
| `~/repos/scripts/CLAUDE.md` Files table | Add **Locking & scheduled runs** subsection beneath it. |
