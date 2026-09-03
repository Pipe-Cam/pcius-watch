#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PCIUS off-box uptime watcher — Chunk 1 of planning/SPEC-alerting-2026-07-28.md
#
# Probes the production surfaces from OUTSIDE our infrastructure and sends
# Brian ONE Telegram message when they break, silence while they stay broken,
# and ONE message when they come back.
#
# HOST-AGNOSTIC ON PURPOSE. This script knows nothing about GitHub. It runs
# identically from a GitHub Actions cron, a plain VPS crontab, or your laptop.
# The only host-specific piece is the state store, which is behind a two-call
# interface (store_load / store_save) with two implementations.
#
# Dependencies: bash + curl. Nothing else. (`gh` is needed ONLY if you choose
# the github-issue state backend.) No npm, no jq, no python.
#
# TELEGRAM RULE, NON-NEGOTIABLE: this script calls sendMessage and NOTHING
# else. It must never call getUpdates / setWebhook / deleteWebhook — a second
# poller on that token gets a 409 and breaks Brian's live task intake channel.
#
# Exit codes: 0 = all surfaces healthy. 1 = at least one surface down.
#             2 = configuration/usage error, INCLUDING a NOTIFICATION CHANNEL
#                 THIS RUN NEEDED AND COULD NOT USE. A watcher that cannot
#                 reach its only channel must not exit 0/1 looking healthy — it
#                 cannot announce that failure over the channel that is broken,
#                 so it announces it through the exit code, which
#                 pcius-watch.service surfaces as a failed unit
#                 (SuccessExitStatus=0 1). Three ways to get there:
#                   - the credential is ABSENT (token/chat id unset)
#                   - the credential is PRESENT but REJECTED (401/403/404/400)
#                     — the rotated-token case; permanent, escalates on the
#                     FIRST occurrence
#                   - a TRANSIENT failure (429/5xx/timeout) where NO send has
#                     got out for WATCH_SEND_FAIL_ESCALATE consecutive RUNS
#                     (12 x 5 min = ~1 h), which is no longer distinguishable
#                     from a dead channel. Counted in RUNS, not attempts: one
#                     cycle can send three messages, and counting attempts made
#                     the grace collapse to ~20 min exactly when several alarms
#                     fired together. A run in which ANY send got out resets it.
#                 See send_telegram() / notify() / final_exit().
#
# ⚠ A failed unit does NOT stop the timer. pcius-watch.timer is OnCalendar
# based, so it re-triggers the service on schedule regardless of the previous
# run's exit status; systemd's start rate limiter (DefaultStartLimitBurst=5 per
# DefaultStartLimitIntervalSec=10s, not overridden here) cannot engage at a
# 5-minute cadence. Exit 2 therefore makes the watcher VISIBLY broken without
# making it dead.
# A cron wrapper should NOT treat exit 1 as a script failure — see README.
# ---------------------------------------------------------------------------

set -uo pipefail
# Deliberately NOT `set -e`: probe failures are the normal path, not errors.

# ── Configuration (every value overridable by env) ─────────────────────────
WATCH_API_URL="${WATCH_API_URL:-https://api.pipecam.report/health}"
WATCH_APP_URL="${WATCH_APP_URL:-https://app.pipecam.report/signin}"
# A public, unauthenticated, read-only endpoint that performs a real database
# round-trip (5-table join in resolveToken, platform/apps/api/src/routes/
# public-reports.ts:45-65). A nonexistent token returns 200 {"state":"not_found"}
# and writes nothing. If Postgres is down this 500s while /health still says ok.
WATCH_DB_URL="${WATCH_DB_URL:-https://api.pipecam.report/api/public/reports/pcius-watch-liveness-probe}"

WATCH_TIMEOUT_API="${WATCH_TIMEOUT_API:-10}"
WATCH_TIMEOUT_APP="${WATCH_TIMEOUT_APP:-15}"
WATCH_TIMEOUT_DB="${WATCH_TIMEOUT_DB:-10}"

# In-run retries: absorbs a transient TCP/DNS blip without any stored state.
WATCH_ATTEMPTS="${WATCH_ATTEMPTS:-3}"
WATCH_ATTEMPT_SLEEP="${WATCH_ATTEMPT_SLEEP:-20}"

# Cross-run flap protection: N consecutive FAILED CYCLES before we alarm.
WATCH_FAIL_CYCLES="${WATCH_FAIL_CYCLES:-2}"

# Coming back up: re-probe once more after this many seconds inside the same
# run before declaring recovery. After the 2026-07-28 recovery the box served
# 502s under load ~10 for a while; one premature all-clear is worse than a
# late one.
WATCH_RECOVER_CONFIRM_SLEEP="${WATCH_RECOVER_CONFIRM_SLEEP:-60}"

# State store: "file" (VPS cron, laptop) or "github-issue" (stateless runner).
WATCH_STATE_BACKEND="${WATCH_STATE_BACKEND:-file}"
WATCH_STATE_FILE="${WATCH_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/pcius-watch/state}"
WATCH_STATE_ISSUE_LABEL="${WATCH_STATE_ISSUE_LABEL:-pcius-watch-state}"
WATCH_REPO="${WATCH_REPO:-}"

# Notification
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# DRY-RUN exercises probe -> decide -> format -> build the send call, but does
# not deliver. Set WATCH_DRY_RUN_SEND_URL to POST the identical request at a
# harmless URL of your own if you want the HTTP leg exercised too.
WATCH_DRY_RUN="${WATCH_DRY_RUN:-0}"
WATCH_DRY_RUN_SEND_URL="${WATCH_DRY_RUN_SEND_URL:-}"

WATCH_TZ="${WATCH_TZ:-America/Los_Angeles}"

# ── Backup freshness (S4 / Chunk 4 of the spec) ────────────────────────────
# The nightly backup writes `last-success` ONLY when the WHOLE run succeeded,
# including every configured push to the offsite copy. When an offsite push
# fails the stamp is deliberately NOT touched, so its mtime goes stale. That is
# the signal this check reads: an offsite push can keep failing for days while
# the local backup and the site itself both look perfectly fine, so nothing
# else in the stack would notice. This check is the reader for it.
#
# ⚠ This is a LOCAL FILE check, so it only means anything on a host that can
# see the stamp. It is OFF unless WATCH_BACKUP_STAMP is set, on purpose:
# `srv1550328` deliberately holds no production credential of any kind and must
# not be given one to satisfy this check. On a host where the path is unset the
# check is skipped and nothing is sent, so the GitHub Actions runner and
# srv1550328 keep behaving exactly as before.
#
# ⚠ THE CHECK THAT ACTUALLY RUNS AGAINST THE REAL STAMPS IS THE TWIN OF THIS
# ONE: a backup-freshness checker that runs on the backup host itself, on its
# own daily timer and its own notification channel. Same two stamps (see
# below), same 48 h threshold, same missing/unreadable rules, same alarm-once /
# all-clear-once latch PER STAMP, same wording. The RULE is not duplicated:
# both callers source the shared `lib/backup-probe.sh`, and the test suite
# fails if either one starts re-implementing it. What still differs between the
# two is deliberate and cadence-driven (transport, prose, latch/recovery
# behaviour) — see that library's header for the line between the two.
# probe_backup() below stays here as a thin adapter so the check comes for free
# on any future host that CAN see the stamps.
#
# TWO STAMPS, TWO INDEPENDENT SIGNALS. The nightly backup script writes
# `last-local-success` every run that gets through dump/encrypt/prune, and
# `last-success` only if every configured offsite push ALSO succeeded that
# run — so a fresh local stamp must never suppress a stale offsite alarm, or
# vice versa. This still needs no new credential and no SSH: WATCH_BACKUP_STAMP
# and WATCH_BACKUP_LOCAL_STAMP are both plain local-file checks, gated off by
# default (both empty) for the same reason as before — srv1550328 deliberately
# holds no production credential and never sets these. An earlier design that
# read both stamps over SSH with a broad sudo grant was rejected for that
# reason; this stays a same-box, no-credential file read, exactly like the
# single-stamp version it replaces.
WATCH_BACKUP_STAMP="${WATCH_BACKUP_STAMP:-}"
WATCH_BACKUP_LOCAL_STAMP="${WATCH_BACKUP_LOCAL_STAMP:-}"
# Sibling marker written by the nightly backup script when the backup host
# has NO offsite target configured at all. The offsite STAMP cannot express
# that state: "never attempted" and "attempted and fine" are indistinguishable
# from a mtime, and the dangerous one is silent forever. Defaults to a sibling
# of the offsite stamp; empty WATCH_BACKUP_STAMP leaves it empty too, so a
# host that does not do this check is completely unaffected.
WATCH_BACKUP_NOTCONF_MARKER="${WATCH_BACKUP_NOTCONF_MARKER:-$([ -n "$WATCH_BACKUP_STAMP" ] && printf '%s/offsite-not-configured' "$(dirname "$WATCH_BACKUP_STAMP")")}"
# 48 h = two missed nightly runs. The spec argued 26 h (one missed run plus the
# timer's RandomizedDelaySec=10m and Persistent=true catch-up); 48 h is the
# deliberately quieter default so a single transient offsite blip that fixes
# itself the next night never wakes Brian. Lower it here to get the spec's
# tighter signal. Applies to both stamps.
WATCH_BACKUP_MAX_AGE="${WATCH_BACKUP_MAX_AGE:-172800}"

for arg in "$@"; do
  case "$arg" in
    --dry-run) WATCH_DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

NOW="$(date -u +%s)"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# ── Timestamp helpers ─────────────────────────────────────────────────────
fmt_utc() { date -u -d "@$1" '+%H:%M UTC, %a %d %b'; }
fmt_local() { TZ="$WATCH_TZ" date -d "@$1" '+%H:%M %Z, %a %d %b'; }

# pl <count> <singular> <plural>
pl() { if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi; }

fmt_duration() {
  local s="$1" h m
  [ "$s" -lt 0 ] && s=0
  h=$((s / 3600))
  m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then
    printf '%d hour%s %d minute%s' "$h" "$([ "$h" -eq 1 ] || echo s)" "$m" "$([ "$m" -eq 1 ] || echo s)"
  else
    printf '%d minute%s' "$m" "$([ "$m" -eq 1 ] || echo s)"
  fi
}

# ── Probes ────────────────────────────────────────────────────────────────
# Each probe prints a human reason on failure and returns non-zero.
# Nothing here writes to production. Every request is a GET.

PROBE_REASON=""

# /health is STATIC (platform/apps/api/src/app.ts:155-161) — it returns ok:true
# even with the database on fire. A 200 is necessary but NOT sufficient proof
# of life, so we also assert the response SHAPE and that the deployed commit
# sha is actually present. That catches a proxy/error page answering 200 in the
# API's place, and a process running without its GIT_COMMIT_SHA env.
probe_api() {
  local body code
  body="$(curl -s --max-time "$WATCH_TIMEOUT_API" -w $'\n%{http_code}' "$WATCH_API_URL" 2>/dev/null)"
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$code" != "200" ]; then
    PROBE_REASON="HTTP ${code:-none}"
    return 1
  fi
  # Whitespace after the colon is OPTIONAL in these patterns. Hono's c.json()
  # emits compact JSON today, so a literal '"ok":true' match works — but this
  # is an alerting path, and the cost of being wrong is a false 3am "PCIUS is
  # down" for a perfectly healthy box. A serializer change, a pretty-printing
  # proxy, or anything that reformats the body must not be able to do that.
  # (Found the hard way: a test double using json.dumps() defaults, which emit
  # '"ok": true', failed every probe against a server that was fully up.)
  if ! printf '%s' "$body" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true'; then
    PROBE_REASON="200 but body is not ok:true"
    return 1
  fi
  if ! printf '%s' "$body" | grep -Eq '"version"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]{7,}"'; then
    PROBE_REASON="200 but version sha missing or empty"
    return 1
  fi
  if ! printf '%s' "$body" | grep -Eq '"ts"[[:space:]]*:[[:space:]]*"'; then
    PROBE_REASON="200 but ts missing"
    return 1
  fi
  PROBE_REASON=""
  return 0
}

# The sign-in page is served by a DIFFERENT systemd unit (pcius-app.service)
# than the API (pcius-api.service), so it is a genuinely separate signal.
probe_app() {
  local code
  code="$(curl -s --max-time "$WATCH_TIMEOUT_APP" -o /dev/null -w '%{http_code}' "$WATCH_APP_URL" 2>/dev/null)"
  case "$code" in
    200|304) PROBE_REASON=""; return 0 ;;
    *) PROBE_REASON="HTTP ${code:-none}"; return 1 ;;
  esac
}

# The closest thing to a database check available from outside without any
# credential and without a code change. See WATCH_DB_URL above.
probe_db() {
  local body code
  body="$(curl -s --max-time "$WATCH_TIMEOUT_DB" -w $'\n%{http_code}' "$WATCH_DB_URL" 2>/dev/null)"
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$code" != "200" ]; then
    PROBE_REASON="HTTP ${code:-none} (a 5xx here usually means the database)"
    return 1
  fi
  if ! printf '%s' "$body" | grep -Eq '"state"[[:space:]]*:[[:space:]]*"[a-z_]+"'; then
    PROBE_REASON="200 but no query result in the body"
    return 1
  fi
  PROBE_REASON=""
  return 0
}

# Backup freshness. Deliberately NOT part of run_cycle: a stale backup is not
# "PCIUS is down", it must not flip the up/down status, and it must not be
# retried three times with 20 s gaps — a file mtime does not flap. It gets its
# own reason variable so it cannot clobber the uptime probes' PROBE_REASON.
#
# THE RULE ITSELF LIVES IN THE SHARED `lib/backup-probe.sh`.
# It used to be written out in full here AND in full in the backup host's own
# freshness checker, kept together by a "CHANGE ONE, CHANGE THE OTHER" comment.
# They agreed by luck. A comment is not a gate: one edit to either file could
# silently fork the two hosts' behaviour, so that one alarms and the other
# reads green over the same stamp — the "instrument reads green over a broken
# backup" failure, relocated one level up. Now there is one copy, and the test
# suite fails if either caller re-implements it.
#
# ⚠ SOURCED LAZILY, ON PURPOSE. This library is only needed when this host can
# actually see the stamps, which srv1550328 deliberately cannot (it holds no
# production credential of any kind). Sourcing it unconditionally would give
# the UPTIME watcher — the part that must never stop — a hard dependency on a
# file it does not use, so a human who reinstalled check.sh and forgot the lib
# would kill the watcher silently. Instead: no stamps configured, no
# dependency; stamps configured and the lib missing, exit 2 loudly, because
# running a DIFFERENT rule quietly is the one outcome worth refusing.
WATCH_LIB_DIR="${WATCH_LIB_DIR:-${PCIUS_OPS_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)}}"
backup_probe_lib() {
  [ "${BP_LIB_API:-0}" = "1" ] && return 0
  if [ ! -r "${WATCH_LIB_DIR}/backup-probe.sh" ]; then
    log "FATAL: WATCH_BACKUP_STAMP is set but the shared rule '${WATCH_LIB_DIR}/backup-probe.sh' is missing. Install the lib/ directory alongside check.sh, or unset the stamp paths to turn this check off."
    exit 2
  fi
  # shellcheck source=/dev/null
  . "${WATCH_LIB_DIR}/backup-probe.sh"
  if [ "${BP_LIB_API:-0}" != "1" ]; then
    log "FATAL: lib/backup-probe.sh reports API ${BP_LIB_API:-none}, this script needs 1. check.sh and the library were installed from different revisions."
    exit 2
  fi
}

# probe_backup <path> — thin adapter over the shared rule, called once per
# stamp so the two signals (local, offsite) can never drift apart. Returns 0
# fresh, 1 stale/missing/unreadable. BACKUP_AGE is set when known.
BACKUP_REASON=""
BACKUP_AGE=0
probe_backup() {
  local rc=0
  backup_probe_lib
  bp_probe_stamp "$1" "$WATCH_BACKUP_MAX_AGE" "$NOW" || rc=$?
  BACKUP_REASON="$BP_REASON"
  BACKUP_AGE="$BP_AGE"
  return "$rc"
}

# probe_backup_offsite — the offsite stamp PLUS the one state a stamp cannot
# express: no offsite target is configured on the backup host at all, so no
# offsite copy was ever attempted.
BACKUP_OFFSITE_NOT_CONFIGURED=0
probe_backup_offsite() {
  local rc=0
  backup_probe_lib
  bp_probe_offsite "$WATCH_BACKUP_STAMP" "$WATCH_BACKUP_MAX_AGE" "$NOW" \
    "$WATCH_BACKUP_NOTCONF_MARKER" || rc=$?
  BACKUP_REASON="$BP_REASON"
  BACKUP_AGE="$BP_AGE"
  BACKUP_OFFSITE_NOT_CONFIGURED="$BP_NOT_CONFIGURED"
  return "$rc"
}

# run_cycle <attempts> <sleep_between>
# Sets CYCLE_DOWN (space separated surface names) and CYCLE_DETAIL.
CYCLE_DOWN=""
CYCLE_DETAIL=""
run_cycle() {
  local attempts="$1" gap="$2" attempt ok_api=0 ok_app=0 ok_db=0
  local reason_api="" reason_app="" reason_db=""
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if [ "$ok_api" -eq 0 ]; then
      if probe_api; then ok_api=1; else reason_api="$PROBE_REASON"; fi
    fi
    if [ "$ok_app" -eq 0 ]; then
      if probe_app; then ok_app=1; else reason_app="$PROBE_REASON"; fi
    fi
    if [ "$ok_db" -eq 0 ]; then
      if probe_db; then ok_db=1; else reason_db="$PROBE_REASON"; fi
    fi
    log "attempt $attempt/$attempts: api=$ok_api app=$ok_app db=$ok_db"
    [ "$ok_api" -eq 1 ] && [ "$ok_app" -eq 1 ] && [ "$ok_db" -eq 1 ] && break
    [ "$attempt" -lt "$attempts" ] && [ "$gap" -gt 0 ] && sleep "$gap"
  done
  CYCLE_DOWN=""
  CYCLE_DETAIL=""
  if [ "$ok_api" -eq 0 ]; then
    CYCLE_DOWN="$CYCLE_DOWN api"
    CYCLE_DETAIL="${CYCLE_DETAIL}api.pipecam.report/health — ${reason_api}"$'\n'
  fi
  if [ "$ok_app" -eq 0 ]; then
    CYCLE_DOWN="$CYCLE_DOWN app"
    CYCLE_DETAIL="${CYCLE_DETAIL}app.pipecam.report/signin — ${reason_app}"$'\n'
  fi
  if [ "$ok_db" -eq 0 ]; then
    CYCLE_DOWN="$CYCLE_DOWN db"
    CYCLE_DETAIL="${CYCLE_DETAIL}database-backed request — ${reason_db}"$'\n'
  fi
  CYCLE_DOWN="${CYCLE_DOWN# }"
  [ -z "$CYCLE_DOWN" ]
}

# ── State store ───────────────────────────────────────────────────────────
# Two calls, two implementations. The blob is plain `key=value` lines so it
# needs no parser and reads fine to a human in a GitHub issue body.
#
#   store_load          -> prints the blob (empty string if there is none)
#   store_save          <- reads the blob on stdin
#   store_note "<text>" -> optional durable incident-log entry
#
# Add a third backend (S3, Cloudflare KV, a gist) by implementing these three.

store_load() {
  case "$WATCH_STATE_BACKEND" in
    file) [ -f "$WATCH_STATE_FILE" ] && cat "$WATCH_STATE_FILE"; return 0 ;;
    github-issue) gh_issue_load ;;
    *) log "FATAL unknown WATCH_STATE_BACKEND=$WATCH_STATE_BACKEND"; exit 2 ;;
  esac
}

store_save() {
  case "$WATCH_STATE_BACKEND" in
    file)
      mkdir -p "$(dirname "$WATCH_STATE_FILE")"
      cat >"$WATCH_STATE_FILE"
      ;;
    github-issue) gh_issue_save ;;
    *) log "FATAL unknown WATCH_STATE_BACKEND=$WATCH_STATE_BACKEND"; exit 2 ;;
  esac
}

store_note() {
  case "$WATCH_STATE_BACKEND" in
    file)
      mkdir -p "$(dirname "$WATCH_STATE_FILE")"
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"${WATCH_STATE_FILE}.log"
      ;;
    github-issue)
      [ -n "${GH_ISSUE_NUMBER:-}" ] || return 0
      gh issue comment "$GH_ISSUE_NUMBER" --repo "$WATCH_REPO" \
        --body "$(date -u +%Y-%m-%dT%H:%M:%SZ) — $1" >/dev/null 2>&1 || true
      ;;
  esac
}

# --- github-issue backend --------------------------------------------------
# One long-lived issue whose BODY is the state blob and whose TITLE reflects
# current status, so a human scrolling the repo sees "down" at a glance and
# the transition comments form a timestamped incident log (which is what you
# need to claim a Hostinger SLA credit — those are not automatic).
GH_ISSUE_NUMBER=""
gh_issue_find() {
  [ -n "$WATCH_REPO" ] || { log "FATAL github-issue backend needs WATCH_REPO=owner/name"; exit 2; }
  GH_ISSUE_NUMBER="$(gh issue list --repo "$WATCH_REPO" --label "$WATCH_STATE_ISSUE_LABEL" \
    --state open --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)"
}

gh_issue_load() {
  gh_issue_find
  [ -n "$GH_ISSUE_NUMBER" ] || return 0
  gh issue view "$GH_ISSUE_NUMBER" --repo "$WATCH_REPO" --json body --jq '.body' 2>/dev/null
}

gh_issue_save() {
  local blob title
  blob="$(cat)"
  if [ "$(printf '%s' "$blob" | sed -n 's/^status=//p' | tail -n1)" = "down" ]; then
    title="🔴 PCIUS watcher — DOWN"
  else
    title="🟢 PCIUS watcher — up"
  fi
  [ -n "$GH_ISSUE_NUMBER" ] || gh_issue_find
  if [ -z "$GH_ISSUE_NUMBER" ]; then
    gh label create "$WATCH_STATE_ISSUE_LABEL" --repo "$WATCH_REPO" \
      --description "pcius-watch state record" --color ededed >/dev/null 2>&1 || true
    GH_ISSUE_NUMBER="$(gh issue create --repo "$WATCH_REPO" --label "$WATCH_STATE_ISSUE_LABEL" \
      --title "$title" --body "$blob" 2>/dev/null | grep -Eo '[0-9]+$')"
  else
    gh issue edit "$GH_ISSUE_NUMBER" --repo "$WATCH_REPO" --title "$title" --body "$blob" >/dev/null
  fi
}

# ── State record ──────────────────────────────────────────────────────────
STATE_BLOB="$(store_load)"
# store_load ran in a command substitution, so any issue number it discovered
# died with that subshell. Re-find it in THIS shell so store_note can comment.
[ "$WATCH_STATE_BACKEND" = "github-issue" ] && gh_issue_find

state_get() {
  local v
  v="$(printf '%s\n' "$STATE_BLOB" | sed -n "s/^$1=//p" | tail -n1)"
  printf '%s' "${v:-$2}"
}

status="$(state_get status up)"
fail_streak="$(state_get fail_streak 0)"
ok_streak="$(state_get ok_streak 0)"
first_fail_at="$(state_get first_fail_at 0)"
alarmed="$(state_get alarmed 0)"
# Own alarm latches, independent of the uptime one AND of each other: the
# backup can be stale while production is perfectly up, and a fresh local
# stamp must never silence a stale offsite alarm (or the reverse). Migration:
# the earlier single-signal state only ever tracked the offsite stamp
# (it never read the local one), so if this run is the first under the new
# code and `backup_alarmed` is present but `backup_offsite_alarmed` is not,
# its value seeds backup_offsite_alarmed and backup_local_alarmed starts at 0
# — there is no local-signal history to inherit, which is simply true.
backup_offsite_alarmed="$(state_get backup_offsite_alarmed "$(state_get backup_alarmed 0)")"
backup_local_alarmed="$(state_get backup_local_alarmed 0)"
# Consecutive failed sends across ALL call sites (see notify()). Persisted so a
# channel that fails every cycle eventually escalates instead of retrying
# silently forever. Reset to 0 by the first send that gets out.
send_fail_streak="$(state_get send_fail_streak 0)"

# state_write <exit-code>
# Called only from final_exit(), which is the one place the run's exit code is
# finally known.
state_write() {
  local run_exit="$1"
  # Fold this run's send outcomes into send_fail_streak BEFORE persisting, so
  # the counter written here always means "consecutive runs with no send out".
  # Defined further down; bash resolves it at call time.
  finalize_send_streak
  {
    printf '# pcius-watch state — do not hand-edit while the cron is running\n'
    printf '# last run: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'status=%s\n' "$status"
    printf 'fail_streak=%s\n' "$fail_streak"
    printf 'ok_streak=%s\n' "$ok_streak"
    printf 'first_fail_at=%s\n' "$first_fail_at"
    printf 'alarmed=%s\n' "$alarmed"
    # Two-key format. Legacy `backup_alarmed` (single signal,
    # offsite only) is deliberately no longer written — the migration where
    # these are read already folded its value into backup_offsite_alarmed, so
    # from this write onward the file is fully in the new format.
    printf 'backup_local_alarmed=%s\n' "$backup_local_alarmed"
    printf 'backup_offsite_alarmed=%s\n' "$backup_offsite_alarmed"
    printf 'send_fail_streak=%s\n' "$send_fail_streak"
    printf 'down_surfaces=%s\n' "${CYCLE_DOWN// /,}"
    # THIS RUN'S EXIT CODE, AND WHEN. It is written here so something OUTSIDE
    # this box can learn it: heartbeat-push.sh reads these two keys and
    # publishes `status=` beside the heartbeat timestamp, which is the only
    # way a reader can tell a healthy watcher from one that is running but
    # MUTE (exit 2 — its Telegram credential is gone). Without this the
    # heartbeat says "alive" and means nothing more.
    #
    # last_exit_at is not decoration: without it a watcher that stopped a week
    # ago would keep publishing its final `last_exit=0` as current health.
    printf 'last_exit=%s\n' "$run_exit"
    printf 'last_exit_at=%s\n' "$NOW"
  } | store_save
}

# ── Telegram ──────────────────────────────────────────────────────────────
# sendMessage ONLY. Never getUpdates.
send_telegram() {
  local text="$1" url code
  url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

  if [ "$WATCH_DRY_RUN" = "1" ]; then
    printf -- '---- DRY-RUN: would send ----\n'
    printf 'POST https://api.telegram.org/bot<REDACTED>/sendMessage\n'
    printf '  chat_id=%s\n' "${TELEGRAM_CHAT_ID:-<TELEGRAM_CHAT_ID unset>}"
    printf '  token=%s\n' "$([ -n "$TELEGRAM_BOT_TOKEN" ] && echo '<set, redacted>' || echo '<TELEGRAM_BOT_TOKEN unset>')"
    printf -- '---- message body ----\n%s\n----------------------------\n' "$text"
    if [ -n "$WATCH_DRY_RUN_SEND_URL" ]; then
      code="$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "$WATCH_DRY_RUN_SEND_URL" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${text}" 2>/dev/null)"
      printf 'dry-run POST to WATCH_DRY_RUN_SEND_URL -> HTTP %s\n' "${code:-none}"
    fi
    return 0
  fi

  # Return 2, not 1: a missing token is a broken CHANNEL, not one failed
  # message. Retrying it every 5 minutes forever will never help, so notify()
  # escalates this through the exit code instead. See notify() below.
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "ERROR TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set — message NOT sent"
    return 2
  fi

  # Run logs may be public (public watch repo). Never echo the URL, the token,
  # or Telegram's response body — error responses can echo request context.
  set +x
  code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$url" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" 2>/dev/null)"
  if [ "$code" = "200" ]; then
    log "telegram sendMessage ok"
    return 0
  fi
  # PERMANENT vs TRANSIENT. A credential that is PRESENT but REJECTED is the
  # headline scenario this whole alarm exists for — a ROTATED TOKEN — and
  # retrying it every 5 minutes forever will never help. It must escalate
  # exactly like an empty credential, or it escapes the escalation path and the
  # watcher runs alive-but-mute while systemd reads exit 1 as a success
  # (SuccessExitStatus=0 1). Telegram's rejections:
  #   401 invalid/revoked bot token
  #   403 bot blocked, kicked from the chat, or chat deactivated
  #   404 malformed token in the /bot<token>/ path
  #   400 chat_id not found / bad request — will not fix itself on retry
  # Everything else (429 rate limit, 5xx, and an empty code from a timeout or
  # DNS failure) is genuinely transient and must NOT burn the escalation on the
  # first occurrence.
  case "$code" in
    400 | 401 | 403 | 404)
      log "ERROR telegram sendMessage returned HTTP $code — the bot token or chat id is REJECTED (PERMANENT); retrying will not help"
      return 2
      ;;
  esac
  log "ERROR telegram sendMessage returned HTTP ${code:-none} (transient — will retry next cycle)"
  return 1
}

# ── Notification outcome ──────────────────────────────────────────────────
# EVERY alarm/recovery goes through notify(), never send_telegram() directly.
#
# THE DEFECT THIS EXISTS TO PREVENT: send_telegram()'s return value used to be
# discarded at all six call sites, which set their latch on the next line
# regardless. One 429, or a rotated token, and the state file
# recorded that a human was told while no human was told — and every later run
# took the "already alarmed — staying quiet" branch. There was no retry, ever.
# The alarm state was DOWN and permanently silent — the very outage-goes-
# unnoticed failure this instrument exists to prevent, reproduced inside the
# instrument.
#
#   notify "<text>"  -> 0 delivered (or dry-run)
#                       1 the send failed — retry on the next cycle
#                       2 the channel itself is not configured on this host
#
# CADENCE — this matters, do not copy it blindly. check.sh runs on a FIVE
# MINUTE loop, so "leave the latch clear, the next cycle retries" costs at most
# one cycle. Its twin on the backup host runs DAILY, where the identical shape
# would swallow a notification for ~24 h — which is why that script makes the
# opposite call on its recovery path and says so in its own comment. An earlier
# rejected change imported the daily reasoning into a 5-minute script and
# produced a ~50-hour notification delay. Match the cadence, not the code.
#
# A broken channel cannot report itself over that channel, so it is escalated
# through the EXIT CODE (2), which pcius-watch.service surfaces as a failed
# unit (SuccessExitStatus=0 1). Silence is the one outcome not permitted.
# A TRANSIENT FAILURE THAT NEVER CLEARS IS NOT MEANINGFULLY DIFFERENT FROM A
# REVOKED CREDENTIAL. A 500 on every cycle for an hour silences this alarm just
# as completely as a 401 does, so "transient" must not mean "retry silently
# forever". send_fail_streak counts CONSECUTIVE RUNS IN WHICH NO SEND GOT OUT,
# is persisted in the state file, and crossing the threshold escalates to the
# same exit 2 a permanent rejection gets.
#
# ⚠ RUNS, NOT ATTEMPTS — this distinction is the whole correctness of the
# counter. This script can send up to three messages in ONE cycle (backup-local
# alarm, backup-offsite alarm, main uptime alarm). Counting failed ATTEMPTS
# made the documented ~1 h grace compress to ~20 minutes whenever several
# alarms fired together — i.e. precisely during a real incident, which is the
# worst possible moment to start crying wolf about the notification channel.
# So the streak is folded ONCE PER RUN, in finalize_send_streak() below, from
# two per-run flags rather than incremented at each call site.
#
# 12 consecutive RUNS x the 5-minute cadence = ~1 hour, and now genuinely so
# regardless of how many alarms fire per cycle. Chosen because Telegram 429s
# and brief 5xx blips resolve in minutes, so an hour of unbroken failure is no
# longer a blip — while an hour is still short enough that a genuinely dead
# channel is surfaced the same morning rather than never. Its daily twin uses 2
# (~48 h) for the same reason expressed in its own cadence.
WATCH_SEND_FAIL_ESCALATE="${WATCH_SEND_FAIL_ESCALATE:-12}"

SEND_MISCONFIGURED=0
# Per-RUN send outcomes, folded into send_fail_streak exactly once at the end.
RUN_SEND_OK=0
RUN_SEND_FAILED=0

notify() {
  local rc=0
  send_telegram "$1" || rc=$?
  case "$rc" in
    0)
      RUN_SEND_OK=1
      return 0
      ;;
    2)
      # PERMANENT — escalates immediately, independently of the run counter.
      SEND_MISCONFIGURED=1
      log "COULD NOT NOTIFY — the Telegram channel is broken (PERMANENT: missing or rejected credential). Escalating to exit 2 so the unit goes red; a mute watcher must not read as a healthy one."
      return 2
      ;;
    *)
      RUN_SEND_FAILED=1
      log "COULD NOT NOTIFY — the send failed (transient) — retrying next cycle"
      return 1
      ;;
  esac
}

# Fold this run's send outcomes into the persisted streak. Called exactly once,
# from state_write, so the two exit paths cannot drift apart on it.
SEND_STREAK_FINALIZED=0
finalize_send_streak() {
  [ "$SEND_STREAK_FINALIZED" = "1" ] && return 0
  SEND_STREAK_FINALIZED=1

  if [ "$RUN_SEND_OK" = "1" ]; then
    # PARTIAL SUCCESS COUNTS AS SUCCESS, DELIBERATELY. The streak exists to
    # detect a DEAD CHANNEL, and a channel that delivered a message this run is
    # demonstrably not dead — escalating it would be a false alarm, and crying
    # wolf on the alerting stack is how people learn to ignore it. The send
    # that DID fail is not forgotten or forgiven: its own latch stayed clear,
    # so that specific alarm is retried on its own merits next cycle. This
    # counter is about the channel; the latches are about each message.
    if [ "$send_fail_streak" != "0" ]; then
      log "a send got out this run — resetting send_fail_streak (was $send_fail_streak)"
    fi
    send_fail_streak=0
    return 0
  fi

  if [ "$RUN_SEND_FAILED" = "1" ]; then
    send_fail_streak=$((send_fail_streak + 1))
    if [ "$send_fail_streak" -ge "$WATCH_SEND_FAIL_ESCALATE" ]; then
      SEND_MISCONFIGURED=1
      log "COULD NOT NOTIFY — no send has got out for $send_fail_streak consecutive runs (threshold $WATCH_SEND_FAIL_ESCALATE). A transient failure this persistent is indistinguishable from a dead channel — escalating to exit 2."
    else
      log "no send got out this run (run $send_fail_streak/$WATCH_SEND_FAIL_ESCALATE in a row) — retrying next cycle"
    fi
    return 0
  fi

  # No send was attempted at all this run, so this run says nothing about the
  # channel either way. Leave the streak exactly as it was.
  return 0
}

# Exit wrapper. A notification channel we could not reach outranks the up/down
# result: exit 2 is the only way this script can say "I could not have told you
# either way". Without this, a watcher with a dead channel exits 0 and looks
# perfectly healthy — the exact false-green shape being fixed.
#
# It is also the ONLY caller of state_write, because the exit code is part of
# the state now (see `last_exit` there) and it is not known until here. Two
# call sites persisting state, one of them without the code, is how the file
# would come to hold a code from the wrong run.
final_exit() {
  local code="$1"
  # May itself set SEND_MISCONFIGURED, when the run streak crosses its
  # threshold — so it has to run BEFORE the check below. Idempotent; the
  # state_write call after this one will not double-count it.
  finalize_send_streak
  if [ "$SEND_MISCONFIGURED" = "1" ]; then
    log "EXIT 2 — the notification channel is misconfigured; the up/down result this run was $code"
    code=2
  fi
  state_write "$code"
  exit "$code"
}

# ── Message bodies (§8 of the spec; wording is Brian's to change) ──────────
compose_alarm() {
  local when="$1" what
  # CYCLE_DOWN is always built in the order api, app, db.
  case "$CYCLE_DOWN" in
    "api app db") what="Nothing on the box is answering. This looks like the whole server, not one service." ;;
    "api app") what="Both api.pipecam.report and app.pipecam.report stopped answering." ;;
    "api db") what="The API is down. The app is still serving pages." ;;
    "app db") what="The app is down and database-backed requests are failing, but the API process is alive." ;;
    "api") what="The API is down. The app is still serving pages, so this is the API service, not the box." ;;
    "app") what="The app is down. The API is still answering, so this is the web app service, not the box." ;;
    "db") what="The API and the app are both up, but a database-backed request is failing. This looks like the database, not the box." ;;
    *) what="These stopped answering: $CYCLE_DOWN." ;;
  esac
  printf '%s\n' "🔴 PCIUS is down"
  printf '%s\n' "$what"
  printf 'First seen %s (%s).\n' "$(fmt_utc "$when")" "$(fmt_local "$when")"
  printf 'Confirmed over %s in a row, %s each.\n' \
    "$(pl "$WATCH_FAIL_CYCLES" check checks)" "$(pl "$WATCH_ATTEMPTS" try tries)"
  printf '\n%s' "$CYCLE_DETAIL"
  printf '\nI will message again when it is back.\n'
}

# compose_backup_local_alarm / _recovery, compose_backup_offsite_alarm /
# _recovery — one pair per signal, worded like the backup host's own freshness
# checker's equivalents (keep them in sync — see the header comment).
compose_backup_local_alarm() {
  printf '%s\n' "🔴 PCIUS backup pipeline is not running"
  printf 'The nightly backup has not even completed its LOCAL step (dump, encrypt,\n'
  printf 'tier-copy, prune) — %s.\n' "$BACKUP_REASON"
  printf '\n'
  printf 'This is more serious than an offsite-only failure: NEITHER copy is\n'
  printf 'confirmed current. If we lost the server today, the newest backup we can\n'
  printf 'point to is however old this stamp is.\n'
  printf '\nI will message again when a local backup completes.\n'
}

compose_backup_local_recovery() {
  printf '%s\n' "🟢 PCIUS backup pipeline is running again"
  printf 'The local backup step (dump/encrypt/prune) completed successfully %s ago.\n' "$(fmt_duration "$BACKUP_AGE")"
}

compose_backup_offsite_alarm() {
  # NOT CONFIGURED is its own message. The generic body below blames the
  # offsite push, which would send the responder hunting a failure that never
  # happened — nothing was ever attempted. Twin of the backup host's own
  # compose_offsite_alarm() — keep them in sync.
  if [ "$BACKUP_OFFSITE_NOT_CONFIGURED" = "1" ]; then
    printf '%s\n' "🔴 PCIUS has NO offsite backup configured"
    printf 'The backup host is not configured to send a copy anywhere off the box.\n'
    printf 'Neither an rsync target nor an offsite bucket is set, so no offsite\n'
    printf 'copy is being attempted at all — %s.\n' "$BACKUP_REASON"
    printf '\n'
    printf 'The local encrypted backup on disk may be perfectly fine. It is the copy\n'
    printf 'that survives losing the SERVER that does not exist.\n'
    printf '\n'
    printf 'Most likely cause: an offsite setting was commented out of the backup\n'
    printf 'env file and never put back.\n'
    printf '\nI will message again when an offsite push completes.\n'
    return 0
  fi
  printf '%s\n' "🔴 PCIUS backup is not landing offsite"
  # LOCAL_STALE_NOW is captured from THIS run's local probe, before the
  # offsite probe overwrites BACKUP_REASON/BACKUP_AGE (see the Decide
  # section below) — so this sentence is accurate about the local signal's
  # actual state, or (unknown, WATCH_BACKUP_LOCAL_STAMP unset on this host)
  # silent about it, never a stale assumption. Twin fix to
  # the backup host's compose_offsite_alarm() — keep them in sync.
  case "$LOCAL_STALE_NOW" in
    1)
      printf 'The nightly backup'"'"'s LOCAL step has ALSO not run — %s. The OFFSITE\n' "$LOCAL_REASON_NOW"
      printf 'copy has not landed either — %s.\n' "$BACKUP_REASON"
      printf '\n'
      printf 'This means backups have stopped entirely, not just the offsite leg — see\n'
      printf 'the separate "backup pipeline is not running" alert, which is the more\n'
      printf 'serious half of this.\n'
      ;;
    0)
      printf 'The nightly backup'"'"'s local step is fine, but the OFFSITE copy has not\n'
      printf 'landed — %s.\n' "$BACKUP_REASON"
      printf '\n'
      printf 'This does NOT mean the site is down, and the local encrypted backup on\n'
      printf 'disk is fine. It means that if we lost the SERVER ITSELF today, we would\n'
      printf 'be restoring from an old offsite copy.\n'
      printf '\n'
      printf 'The most likely cause is the push to the offsite copy failing — the\n'
      printf 'offsite stamp only updates when every configured offsite push succeeds.\n'
      printf 'Check the backup host'"'"'s own logs for the failing push.\n'
      ;;
    *)
      printf 'The OFFSITE copy has not landed — %s.\n' "$BACKUP_REASON"
      printf '\n'
      printf '(This host does not check the local step, so this alert cannot say\n'
      printf 'whether the local backup is also affected.)\n'
      ;;
  esac
  printf '\nI will message again when an offsite push completes.\n'
}

compose_backup_offsite_recovery() {
  printf '%s\n' "🟢 PCIUS backup is landing offsite again"
  printf 'An offsite push completed successfully %s ago.\n' "$(fmt_duration "$BACKUP_AGE")"
}

compose_recovery() {
  local down_at="$1" up_at="$2"
  printf '%s\n' "🟢 PCIUS is back"
  printf 'Everything answering normally again as of %s (%s).\n' "$(fmt_utc "$up_at")" "$(fmt_local "$up_at")"
  printf 'It was down for %s.\n' "$(fmt_duration "$((up_at - down_at))")"
  printf 'Went down at %s (%s).\n' "$(fmt_utc "$down_at")" "$(fmt_local "$down_at")"
}

# ── Decide ────────────────────────────────────────────────────────────────
log "checking api=$WATCH_API_URL app=$WATCH_APP_URL db=$WATCH_DB_URL"
log "state in: status=$status fail_streak=$fail_streak alarmed=$alarmed backup_local_alarmed=$backup_local_alarmed backup_offsite_alarmed=$backup_offsite_alarmed backend=$WATCH_STATE_BACKEND dry_run=$WATCH_DRY_RUN"

# ── Backup freshness decision — two independent signals ───────────────────
# Runs BEFORE the uptime cycle so it still happens on every path — both exits
# below go through state_write, which persists both latches. Alarm-once /
# all-clear-once PER SIGNAL, exactly like the uptime signal, which is why this
# can sit on the 5-minute timer without ever becoming a 5-minute nag. A fresh
# local stamp must never clear (or suppress) a stale offsite latch, or the
# reverse — that independence is the entire point of tracking two.
#
# This never changes the process exit code. Exit 0/1 keep meaning "production
# up / down" and 2 stays reserved for a misconfigured watcher, because
# pcius-watch.service pins SuccessExitStatus=0 1 against those meanings.
# LOCAL_STALE_NOW ("" unknown / "0" fresh / "1" stale) + LOCAL_REASON_NOW:
# captured from the local probe below, BEFORE the offsite probe overwrites
# BACKUP_REASON/BACKUP_AGE, so compose_backup_offsite_alarm() can describe
# the local signal's actual state from this same run — see that function.
LOCAL_STALE_NOW=""
LOCAL_REASON_NOW=""

if [ -z "$WATCH_BACKUP_STAMP" ] && [ -z "$WATCH_BACKUP_LOCAL_STAMP" ]; then
  log "backup freshness: skipped (WATCH_BACKUP_STAMP and WATCH_BACKUP_LOCAL_STAMP both unset — this host cannot see the stamps)"
else
  if [ -z "$WATCH_BACKUP_LOCAL_STAMP" ]; then
    log "backup local freshness: skipped (WATCH_BACKUP_LOCAL_STAMP unset)"
  elif probe_backup "$WATCH_BACKUP_LOCAL_STAMP"; then
    log "backup local freshness: ok (last success $(fmt_duration "$BACKUP_AGE") ago)"
    LOCAL_STALE_NOW=0
    if [ "$backup_local_alarmed" = "1" ]; then
      # Clear the latch only if the all-clear actually went out. On this
      # 5-minute cadence a lost all-clear is retried in five minutes, so
      # holding the latch is cheap and the message is not lost. (The DAILY
      # twin makes the opposite call for its own good reason — see notify().)
      if notify "$(compose_backup_local_recovery)"; then
        store_note "BACKUP LOCAL RECOVERED — last success $(fmt_duration "$BACKUP_AGE") ago"
        backup_local_alarmed=0
      else
        log "backup local recovered but the all-clear did NOT go out — keeping the latch set so the next cycle retries it"
      fi
    fi
  else
    log "backup local freshness: STALE — $BACKUP_REASON"
    LOCAL_STALE_NOW=1
    LOCAL_REASON_NOW="$BACKUP_REASON"
    if [ "$backup_local_alarmed" = "1" ]; then
      log "already alarmed about the local backup — staying quiet"
    else
      if notify "$(compose_backup_local_alarm)"; then
        store_note "BACKUP LOCAL STALE — $BACKUP_REASON"
        backup_local_alarmed=1
      else
        log "backup local is STALE and the alarm did NOT go out — leaving the latch CLEAR so the next cycle retries"
        store_note "BACKUP LOCAL STALE (alarm NOT delivered) — $BACKUP_REASON"
      fi
    fi
  fi

  if [ -z "$WATCH_BACKUP_STAMP" ]; then
    log "backup offsite freshness: skipped (WATCH_BACKUP_STAMP unset)"
  elif probe_backup_offsite; then
    log "backup offsite freshness: ok (last success $(fmt_duration "$BACKUP_AGE") ago)"
    if [ "$backup_offsite_alarmed" = "1" ]; then
      if notify "$(compose_backup_offsite_recovery)"; then
        store_note "BACKUP OFFSITE RECOVERED — last success $(fmt_duration "$BACKUP_AGE") ago"
        backup_offsite_alarmed=0
      else
        log "backup offsite recovered but the all-clear did NOT go out — keeping the latch set so the next cycle retries it"
      fi
    fi
  else
    log "backup offsite freshness: STALE — $BACKUP_REASON"
    if [ "$backup_offsite_alarmed" = "1" ]; then
      log "already alarmed about the offsite backup — staying quiet"
    else
      if notify "$(compose_backup_offsite_alarm)"; then
        store_note "BACKUP OFFSITE STALE — $BACKUP_REASON"
        backup_offsite_alarmed=1
      else
        log "backup offsite is STALE and the alarm did NOT go out — leaving the latch CLEAR so the next cycle retries"
        store_note "BACKUP OFFSITE STALE (alarm NOT delivered) — $BACKUP_REASON"
      fi
    fi
  fi
fi

if run_cycle "$WATCH_ATTEMPTS" "$WATCH_ATTEMPT_SLEEP"; then
  cycle_healthy=1
else
  cycle_healthy=0
fi

if [ "$cycle_healthy" -eq 1 ]; then
  fail_streak=0
  ok_streak=$((ok_streak + 1))

  if [ "$status" = "down" ]; then
    # Do not call it back on one good probe. Confirm again inside this run.
    log "surfaces healthy while marked down — confirming again in ${WATCH_RECOVER_CONFIRM_SLEEP}s"
    [ "$WATCH_RECOVER_CONFIRM_SLEEP" -gt 0 ] && sleep "$WATCH_RECOVER_CONFIRM_SLEEP"
    if run_cycle 1 0; then
      up_at="$(date -u +%s)"
      log "recovery confirmed"
      if [ "$alarmed" = "1" ]; then
        if notify "$(compose_recovery "$first_fail_at" "$up_at")"; then
          store_note "RECOVERED after $(fmt_duration "$((up_at - first_fail_at))")"
          status="up"; alarmed=0; first_fail_at=0
        else
          # Deliberately stay marked `down`. status=down is precisely what
          # makes the NEXT cycle re-enter this recovery branch and retry the
          # all-clear. Flipping to up here while the message never arrived
          # would strand alarmed=1 with no path back — Brian would be left
          # holding a "PCIUS is down" message that is never followed by
          # anything, which is the worst of both states.
          log "recovery confirmed but the all-clear did NOT go out — staying marked down so the next cycle retries it"
          store_note "RECOVERED but the all-clear was NOT delivered — will retry"
        fi
      else
        log "was down but never alarmed — no all-clear needed"
        status="up"; alarmed=0; first_fail_at=0
      fi
    else
      log "recovery NOT confirmed (still flapping) — staying down, saying nothing"
      ok_streak=0
    fi
  fi
  log "state out: status=$status fail_streak=$fail_streak alarmed=$alarmed"
  [ "$status" = "up" ] && final_exit 0
  final_exit 1
fi

# --- cycle failed ---
ok_streak=0
fail_streak=$((fail_streak + 1))
[ "$first_fail_at" = "0" ] && first_fail_at="$NOW"

log "cycle FAILED (streak $fail_streak/$WATCH_FAIL_CYCLES) down: $CYCLE_DOWN"

if [ "$alarmed" = "1" ]; then
  log "already alarmed — staying quiet"
elif [ "$fail_streak" -ge "$WATCH_FAIL_CYCLES" ]; then
  # status tracks REALITY (the surfaces are down); alarmed tracks whether a
  # human was actually told. They are not the same fact and must not be set
  # together — conflating them is what made one failed send silence this alarm
  # permanently. status=down is true either way; alarmed=1 only if it got out.
  status="down"
  if notify "$(compose_alarm "$first_fail_at")"; then
    store_note "DOWN — surfaces: ${CYCLE_DOWN// /,}"
    alarmed=1
  else
    log "PCIUS is DOWN and the alarm did NOT go out — leaving alarmed=0 so the next cycle retries the alarm"
    store_note "DOWN (alarm NOT delivered) — surfaces: ${CYCLE_DOWN// /,}"
  fi
else
  log "below the ${WATCH_FAIL_CYCLES}-cycle threshold — not alarming yet (this is the flap guard)"
fi

log "state out: status=$status fail_streak=$fail_streak alarmed=$alarmed"
final_exit 1
