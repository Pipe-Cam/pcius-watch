#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# PCIUS watcher MUTUAL HEARTBEAT — "who watches the watcher"
#
# A watcher that dies looks exactly like a healthy system: silence. This script
# is the compensating control. It runs on BOTH sides of the pair and each side
# checks that its PEER has been seen recently. If the peer goes quiet, this
# side says so — once — over Telegram.
#
# The two sides deliberately use INDEPENDENT SCHEDULERS, because a peer
# scheduled by the same mechanism inherits the same blind spot and goes quiet
# in exactly the scenario it exists to detect:
#
#   side A  srv1550328 systemd timer   -> watches GitHub Actions  (PEER_KIND=gha-workflow)
#   side B  GitHub Actions cron        -> watches srv1550328      (PEER_KIND=git-ref)
#
# Side A reads GitHub's public API with no credential at all. Side B reads a
# git ref that side A force-pushes with a repo-scoped deploy key. Neither side
# needs to reach the other's host, and neither touches production.
#
# Dependencies: bash, curl, jq. jq is required (unlike check.sh, which is
# bash+curl only) because this script parses GitHub API JSON, and a fragile
# hand-rolled parser in an alerting path is a worse bet than a dependency that
# ships in both Ubuntu's base image and GitHub's runner image.
#
# TELEGRAM RULE, NON-NEGOTIABLE: sendMessage and NOTHING else. Never
# getUpdates / setWebhook / deleteWebhook — a second poller on that token gets
# a 409 and breaks Brian's live task-intake channel.
#
# Exit codes: 0 = peer is fresh. 1 = peer is stale (a real finding, not a
#             script failure). 2 = configuration/usage error.
# ---------------------------------------------------------------------------

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
PEER_NAME="${PEER_NAME:-the other watcher}"
PEER_KIND="${PEER_KIND:-gha-workflow}"     # gha-workflow | git-ref
PEER_REPO="${PEER_REPO:-Pipe-Cam/pcius-watch}"
PEER_WORKFLOW="${PEER_WORKFLOW:-watch.yml}"
PEER_REF="${PEER_REF:-heartbeat}"
PEER_STALE_AFTER="${PEER_STALE_AFTER:-21600}"   # seconds; 6 h default

# A GitHub API read can fail for reasons that say nothing about the peer
# (rate limit, DNS, GitHub itself being down). Those must never be reported as
# "the peer is dead" — that is exactly the crying-wolf failure this whole
# design is trying to avoid. They get their own streak and their own message.
PEER_API_FAIL_CYCLES="${PEER_API_FAIL_CYCLES:-8}"

# State backend. `file` on a box with a disk; `github-issue` on a stateless
# runner, where a file would vanish between runs and every single run during an
# outage would send another message.
PEER_STATE_BACKEND="${PEER_STATE_BACKEND:-file}"
PEER_STATE_FILE="${PEER_STATE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/pcius-watch/peer-state}"
PEER_STATE_REPO="${PEER_STATE_REPO:-$PEER_REPO}"
PEER_STATE_ISSUE_LABEL="${PEER_STATE_ISSUE_LABEL:-pcius-watch-peer-state}"
PEER_TIMEOUT="${PEER_TIMEOUT:-20}"

# Optional. Unset on srv1550328 (public repos allow unauthenticated reads at
# 60/hour per IP; this runs 4 times an hour). Set to GITHUB_TOKEN on a runner.
PEER_GH_TOKEN="${PEER_GH_TOKEN:-${GH_TOKEN:-}}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

PEER_DRY_RUN="${PEER_DRY_RUN:-0}"
WATCH_TZ="${WATCH_TZ:-America/Los_Angeles}"

for arg in "$@"; do
  case "$arg" in
    --dry-run) PEER_DRY_RUN=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

command -v jq >/dev/null 2>&1 || { log "FATAL jq is required but not installed"; exit 2; }

# Validate the state backend HERE, in the main shell, not lazily inside
# store_load. store_load is called as `STATE_BLOB="$(store_load)"`, and an
# `exit` inside a command substitution only kills the subshell — the script
# would sail on with empty state, which means NO DEDUP, which means a message
# every single run. Crying wolf is the one failure this whole design exists to
# avoid, so a misconfigured store has to be fatal for real.
case "$PEER_STATE_BACKEND" in
  file) : ;;
  github-issue)
    command -v gh >/dev/null 2>&1 || { log "FATAL PEER_STATE_BACKEND=github-issue needs the gh CLI"; exit 2; }
    [ -n "$PEER_STATE_REPO" ] || { log "FATAL PEER_STATE_BACKEND=github-issue needs PEER_STATE_REPO"; exit 2; }
    ;;
  *) log "FATAL unknown PEER_STATE_BACKEND=$PEER_STATE_BACKEND"; exit 2 ;;
esac

NOW="$(date -u +%s)"
fmt_utc() { date -u -d "@$1" '+%H:%M UTC, %a %d %b'; }
fmt_local() { TZ="$WATCH_TZ" date -d "@$1" '+%H:%M %Z, %a %d %b'; }

fmt_duration() {
  local s="$1" h m
  [ "$s" -lt 0 ] && s=0
  h=$((s / 3600)); m=$(((s % 3600) / 60))
  if [ "$h" -gt 0 ]; then
    printf '%d hour%s %d minute%s' "$h" "$([ "$h" -eq 1 ] || echo s)" "$m" "$([ "$m" -eq 1 ] || echo s)"
  else
    printf '%d minute%s' "$m" "$([ "$m" -eq 1 ] || echo s)"
  fi
}

# ── Read the peer's last-seen timestamp ───────────────────────────────────
# Prints a unix epoch on stdout and returns 0. Returns 1 if the peer has never
# been seen at all, 2 if the API call itself failed (which is NOT the peer's
# fault and must be reported differently).
gh_api() {
  local path="$1" out code
  set -- -sS --max-time "$PEER_TIMEOUT" -H 'Accept: application/vnd.github+json' \
         -H 'X-GitHub-Api-Version: 2022-11-28' -w $'\n%{http_code}'
  [ -n "$PEER_GH_TOKEN" ] && set -- "$@" -H "Authorization: Bearer ${PEER_GH_TOKEN}"
  out="$(curl "$@" "https://api.github.com/${path}" 2>/dev/null)"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [ "$code" != "200" ]; then
    log "github api ${path%%\?*} -> HTTP ${code:-none}"
    return 1
  fi
  printf '%s' "$out"
}

peer_last_seen() {
  local body iso
  case "$PEER_KIND" in
    gha-workflow)
      # Only event=schedule counts. A manual workflow_dispatch proves a human
      # was there, not that the scheduler is alive — and the scheduler is the
      # thing whose reliability is in question.
      body="$(gh_api "repos/${PEER_REPO}/actions/workflows/${PEER_WORKFLOW}/runs?event=schedule&per_page=1")" || return 2
      iso="$(printf '%s' "$body" | jq -r '.workflow_runs[0].run_started_at // .workflow_runs[0].created_at // empty')"
      ;;
    git-ref)
      body="$(gh_api "repos/${PEER_REPO}/commits/${PEER_REF}")" || return 2
      iso="$(printf '%s' "$body" | jq -r '.commit.committer.date // empty')"
      ;;
    *)
      log "FATAL unknown PEER_KIND=$PEER_KIND"; exit 2 ;;
  esac
  [ -n "$iso" ] || return 1
  date -u -d "$iso" +%s 2>/dev/null || return 1
}

# ── State ─────────────────────────────────────────────────────────────────
# Two backends behind three calls, exactly as check.sh does it. The blob is
# plain key=value lines so it needs no parser and still reads fine to a human
# looking at a GitHub issue body.
PEER_ISSUE_NUMBER=""

issue_find() {
  [ -n "$PEER_STATE_REPO" ] || { log "FATAL github-issue backend needs PEER_STATE_REPO"; exit 2; }
  PEER_ISSUE_NUMBER="$(gh issue list --repo "$PEER_STATE_REPO" --label "$PEER_STATE_ISSUE_LABEL" \
    --state open --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)"
}

store_load() {
  case "$PEER_STATE_BACKEND" in
    file) [ -f "$PEER_STATE_FILE" ] && cat "$PEER_STATE_FILE"; return 0 ;;
    github-issue)
      command -v gh >/dev/null 2>&1 || { log "FATAL github-issue backend needs gh"; exit 2; }
      issue_find
      [ -n "$PEER_ISSUE_NUMBER" ] || return 0
      gh issue view "$PEER_ISSUE_NUMBER" --repo "$PEER_STATE_REPO" --json body --jq '.body' 2>/dev/null
      ;;
    *) log "FATAL unknown PEER_STATE_BACKEND=$PEER_STATE_BACKEND"; exit 2 ;;
  esac
}

store_save() {
  local blob title
  case "$PEER_STATE_BACKEND" in
    file)
      mkdir -p "$(dirname "$PEER_STATE_FILE")"
      cat >"$PEER_STATE_FILE"
      ;;
    github-issue)
      blob="$(cat)"
      if [ "$(printf '%s' "$blob" | sed -n 's/^peer_status=//p' | tail -n1)" = "stale" ]; then
        title="🔴 pcius-watch peer — ${PEER_NAME} is QUIET"
      else
        title="🟢 pcius-watch peer — ${PEER_NAME} is alive"
      fi
      [ -n "$PEER_ISSUE_NUMBER" ] || issue_find
      if [ -z "$PEER_ISSUE_NUMBER" ]; then
        gh label create "$PEER_STATE_ISSUE_LABEL" --repo "$PEER_STATE_REPO" \
          --description "pcius-watch peer heartbeat state" --color ededed >/dev/null 2>&1 || true
        PEER_ISSUE_NUMBER="$(gh issue create --repo "$PEER_STATE_REPO" --label "$PEER_STATE_ISSUE_LABEL" \
          --title "$title" --body "$blob" 2>/dev/null | grep -Eo '[0-9]+$')"
      else
        gh issue edit "$PEER_ISSUE_NUMBER" --repo "$PEER_STATE_REPO" --title "$title" --body "$blob" >/dev/null
      fi
      ;;
  esac
}

STATE_BLOB="$(store_load)"
# store_load ran in a command substitution, so an issue number it discovered
# died with that subshell. Re-find it here so store_save/note can use it.
[ "$PEER_STATE_BACKEND" = "github-issue" ] && issue_find

state_get() {
  local v; v="$(printf '%s\n' "$STATE_BLOB" | sed -n "s/^$1=//p" | tail -n1)"
  printf '%s' "${v:-$2}"
}
peer_status="$(state_get peer_status fresh)"
peer_alarmed="$(state_get peer_alarmed 0)"
api_fail_streak="$(state_get api_fail_streak 0)"
api_alarmed="$(state_get api_alarmed 0)"

state_write() {
  {
    printf '# pcius-watch PEER state — do not hand-edit while the timer is running\n'
    printf '# last run: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'peer_status=%s\n' "$peer_status"
    printf 'peer_alarmed=%s\n' "$peer_alarmed"
    printf 'api_fail_streak=%s\n' "$api_fail_streak"
    printf 'api_alarmed=%s\n' "$api_alarmed"
    printf 'peer_last_seen=%s\n' "${last_seen:-0}"
  } | store_save
}

note() {
  case "$PEER_STATE_BACKEND" in
    file)
      mkdir -p "$(dirname "$PEER_STATE_FILE")"
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"${PEER_STATE_FILE}.log"
      ;;
    github-issue)
      [ -n "$PEER_ISSUE_NUMBER" ] || return 0
      gh issue comment "$PEER_ISSUE_NUMBER" --repo "$PEER_STATE_REPO" \
        --body "$(date -u +%Y-%m-%dT%H:%M:%SZ) — $1" >/dev/null 2>&1 || true
      ;;
  esac
}

# ── Telegram — sendMessage ONLY ───────────────────────────────────────────
send_telegram() {
  local text="$1" code
  if [ "$PEER_DRY_RUN" = "1" ]; then
    printf -- '---- DRY-RUN: would send ----\n%s\n----------------------------\n' "$text"
    return 0
  fi
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "ERROR TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set — message NOT sent"
    return 1
  fi
  # Run logs may be public. Never echo the URL, the token, or the response
  # body — Telegram error bodies can echo request context back.
  set +x
  code="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' \
    "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "$text" \
    | curl -sS --max-time 20 -o /dev/null -w '%{http_code}' --config - 2>/dev/null)"
  if [ "$code" = "200" ]; then log "telegram sendMessage ok"; return 0; fi
  log "ERROR telegram sendMessage returned HTTP ${code:-none}"
  return 1
}

# ── Decide ────────────────────────────────────────────────────────────────
log "peer=$PEER_NAME kind=$PEER_KIND repo=$PEER_REPO stale_after=${PEER_STALE_AFTER}s"
log "state in: peer_status=$peer_status peer_alarmed=$peer_alarmed api_fail_streak=$api_fail_streak"

last_seen="$(peer_last_seen)"; rc=$?

if [ "$rc" -eq 2 ]; then
  # Could not ask GitHub. Says nothing about the peer. Do not touch peer state.
  last_seen="$(state_get peer_last_seen 0)"
  api_fail_streak=$((api_fail_streak + 1))
  log "could not reach the GitHub API (streak $api_fail_streak/$PEER_API_FAIL_CYCLES) — NOT treating this as a dead peer"
  if [ "$api_alarmed" = "0" ] && [ "$api_fail_streak" -ge "$PEER_API_FAIL_CYCLES" ]; then
    send_telegram "$(printf '%s\n%s\n%s\n' \
      "⚠️ PCIUS watcher — cannot check on ${PEER_NAME}" \
      "The GitHub API has been unreachable from this box for $api_fail_streak checks in a row, so I cannot tell whether ${PEER_NAME} is still running." \
      "Production monitoring itself is unaffected — this is only the watcher-watching-the-watcher leg.")"
    note "API-UNREACHABLE streak=$api_fail_streak"
    api_alarmed=1
  fi
  state_write
  exit 1
fi

if [ "$api_alarmed" = "1" ]; then
  send_telegram "$(printf '%s\n%s\n' "🟢 PCIUS watcher — GitHub API reachable again" \
    "I can check on ${PEER_NAME} once more.")"
  note "API-RECOVERED"
fi
api_fail_streak=0; api_alarmed=0

if [ "$rc" -eq 1 ] || [ -z "${last_seen:-}" ] || [ "${last_seen:-0}" -eq 0 ] 2>/dev/null; then
  # Never seen. On a fresh install this is expected exactly once, and it is
  # not an incident — say nothing, record nothing, let the next run judge.
  log "peer has no recorded activity yet — nothing to judge, staying quiet"
  last_seen=0
  state_write
  exit 0
fi

age=$((NOW - last_seen))
log "peer last seen $(fmt_utc "$last_seen") — ${age}s ago (threshold ${PEER_STALE_AFTER}s)"

if [ "$age" -gt "$PEER_STALE_AFTER" ]; then
  if [ "$peer_alarmed" = "1" ]; then
    log "already alarmed about $PEER_NAME — staying quiet"
  else
    send_telegram "$(printf '%s\n%s\n%s\n%s\n' \
      "⚠️ PCIUS watcher — ${PEER_NAME} has gone quiet" \
      "It has not checked in for $(fmt_duration "$age"). Last seen $(fmt_utc "$last_seen") ($(fmt_local "$last_seen"))." \
      "Production itself is being watched normally from the other side, so this is not an outage — but the pair is down to one watcher, and a single watcher that dies is silent." \
      "I will message again when it comes back.")"
    note "PEER-STALE ${PEER_NAME} age=${age}s"
    peer_status="stale"; peer_alarmed=1
  fi
  state_write
  exit 1
fi

if [ "$peer_alarmed" = "1" ]; then
  send_telegram "$(printf '%s\n%s\n' \
    "🟢 PCIUS watcher — ${PEER_NAME} is back" \
    "It checked in at $(fmt_utc "$last_seen") ($(fmt_local "$last_seen")). Both watchers are running again.")"
  note "PEER-RECOVERED ${PEER_NAME}"
fi
peer_status="fresh"; peer_alarmed=0
state_write
log "state out: peer_status=$peer_status peer_alarmed=$peer_alarmed"
exit 0
