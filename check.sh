#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PCIUS off-box uptime watcher.
#
# Probes the production surfaces from OUTSIDE our infrastructure and sends
# ONE Telegram message when they break, silence while they stay broken,
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
# poller on that token gets a 409 and breaks the live chat that shares it.
#
# Exit codes: 0 = all surfaces healthy. 1 = at least one surface down.
#             2 = configuration/usage error.
# A cron wrapper should NOT treat exit 1 as a script failure — see README.
# ---------------------------------------------------------------------------

set -uo pipefail
# Deliberately NOT `set -e`: probe failures are the normal path, not errors.

# ── Configuration (every value overridable by env) ─────────────────────────
WATCH_API_URL="${WATCH_API_URL:-https://api.pipecam.report/health}"
WATCH_APP_URL="${WATCH_APP_URL:-https://app.pipecam.report/signin}"
# A public, unauthenticated, read-only endpoint that performs a real database
# round-trip (a multi-table join in the report-token resolver on the API
# side). A nonexistent token returns 200 {"state":"not_found"}
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
# run before declaring recovery. A box coming back from an outage can serve
# 502s under load for a while; one premature all-clear is worse than a late
# one.
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

# /health is STATIC on our API — it returns ok:true
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
  case "$body" in
    *'"ok":true'*) : ;;
    *) PROBE_REASON="200 but body is not ok:true"; return 1 ;;
  esac
  if ! printf '%s' "$body" | grep -Eq '"version":"[0-9a-fA-F]{7,}"'; then
    PROBE_REASON="200 but version sha missing or empty"
    return 1
  fi
  if ! printf '%s' "$body" | grep -q '"ts":"'; then
    PROBE_REASON="200 but ts missing"
    return 1
  fi
  PROBE_REASON=""
  return 0
}

# The sign-in page is served by a DIFFERENT service process than the API,
# so it is a genuinely separate signal.
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
  if ! printf '%s' "$body" | grep -Eq '"state":"[a-z_]+"'; then
    PROBE_REASON="200 but no query result in the body"
    return 1
  fi
  PROBE_REASON=""
  return 0
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
# need to claim a hosting SLA credit — those are not automatic).
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

state_write() {
  {
    printf '# pcius-watch state — do not hand-edit while the cron is running\n'
    printf '# last run: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'status=%s\n' "$status"
    printf 'fail_streak=%s\n' "$fail_streak"
    printf 'ok_streak=%s\n' "$ok_streak"
    printf 'first_fail_at=%s\n' "$first_fail_at"
    printf 'alarmed=%s\n' "$alarmed"
    printf 'down_surfaces=%s\n' "${CYCLE_DOWN// /,}"
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

  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "ERROR TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set — message NOT sent"
    return 1
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
  log "ERROR telegram sendMessage returned HTTP ${code:-none}"
  return 1
}

# ── Message bodies ────────────────────────────────────────────────────────
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

compose_recovery() {
  local down_at="$1" up_at="$2"
  printf '%s\n' "🟢 PCIUS is back"
  printf 'Everything answering normally again as of %s (%s).\n' "$(fmt_utc "$up_at")" "$(fmt_local "$up_at")"
  printf 'It was down for %s.\n' "$(fmt_duration "$((up_at - down_at))")"
  printf 'Went down at %s (%s).\n' "$(fmt_utc "$down_at")" "$(fmt_local "$down_at")"
}

# ── Decide ────────────────────────────────────────────────────────────────
log "checking api=$WATCH_API_URL app=$WATCH_APP_URL db=$WATCH_DB_URL"
log "state in: status=$status fail_streak=$fail_streak alarmed=$alarmed backend=$WATCH_STATE_BACKEND dry_run=$WATCH_DRY_RUN"

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
        send_telegram "$(compose_recovery "$first_fail_at" "$up_at")"
        store_note "RECOVERED after $(fmt_duration "$((up_at - first_fail_at))")"
      else
        log "was down but never alarmed — no all-clear needed"
      fi
      status="up"; alarmed=0; first_fail_at=0
    else
      log "recovery NOT confirmed (still flapping) — staying down, saying nothing"
      ok_streak=0
    fi
  fi
  state_write
  log "state out: status=$status fail_streak=$fail_streak alarmed=$alarmed"
  [ "$status" = "up" ] && exit 0
  exit 1
fi

# --- cycle failed ---
ok_streak=0
fail_streak=$((fail_streak + 1))
[ "$first_fail_at" = "0" ] && first_fail_at="$NOW"

log "cycle FAILED (streak $fail_streak/$WATCH_FAIL_CYCLES) down: $CYCLE_DOWN"

if [ "$alarmed" = "1" ]; then
  log "already alarmed — staying quiet"
elif [ "$fail_streak" -ge "$WATCH_FAIL_CYCLES" ]; then
  send_telegram "$(compose_alarm "$first_fail_at")"
  store_note "DOWN — surfaces: ${CYCLE_DOWN// /,}"
  status="down"
  alarmed=1
else
  log "below the ${WATCH_FAIL_CYCLES}-cycle threshold — not alarming yet (this is the flap guard)"
fi

state_write
log "state out: status=$status fail_streak=$fail_streak alarmed=$alarmed"
exit 1
