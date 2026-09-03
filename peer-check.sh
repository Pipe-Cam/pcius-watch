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
# Exit codes: 0 = peer is fresh. 1 = a real finding (the peer is stale, or it
#             is alive but reports that its own notification channel is dead).
#             2 = this script could not have told anyone either way —
#             configuration/usage error, or OUR OWN Telegram channel is broken.
#             See send_telegram() / notify() / final_exit(), which mirror
#             check.sh's taxonomy deliberately: two alerting scripts that
#             disagree about what "I could not notify" means is how one of
#             them ends up silently mute.
# ---------------------------------------------------------------------------

set -uo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
PEER_NAME="${PEER_NAME:-the other watcher}"
PEER_KIND="${PEER_KIND:-gha-workflow}"     # gha-workflow | git-ref
PEER_REPO="${PEER_REPO:-Pipe-Cam/pcius-watch}"
PEER_WORKFLOW="${PEER_WORKFLOW:-watch.yml}"
PEER_REF="${PEER_REF:-heartbeat}"
PEER_STALE_AFTER="${PEER_STALE_AFTER:-21600}"   # seconds; 6 h default

# The one sentence that explains WHAT THIS SILENCE MEANS, which differs per
# peer. The default describes the original watcher-watching-watcher pair. The
# second instance watches the backup host's own freshness checker, where
# "the pair is down to one watcher" would be simply false and would send the
# responder to the wrong box. An alarm that misdescribes what broke costs more
# than it saves.
PEER_CONTEXT="${PEER_CONTEXT:-Production itself is being watched normally from the other side, so this is not an outage — but the pair is down to one watcher, and a single watcher that dies is silent.}"

# A GitHub API read can fail for reasons that say nothing about the peer
# (rate limit, DNS, GitHub itself being down). Those must never be reported as
# "the peer is dead" — that is exactly the crying-wolf failure this whole
# design is trying to avoid. They get their own streak and their own message.
PEER_API_FAIL_CYCLES="${PEER_API_FAIL_CYCLES:-8}"

# Consecutive RUNS in which nothing got out over Telegram. A transient failure
# that never clears is not meaningfully different from a revoked credential: a
# 500 on every run for a day silences this alarm exactly as completely as a 401
# does. Crossing this threshold escalates to the same exit 2 a permanent
# rejection gets, so the unit goes red instead of retrying silently forever.
# 4 runs = ~1 h on the 15-minute peer leg and ~4 h on the hourly backup leg;
# both are far inside the staleness thresholds those legs are judging (6 h and
# 48 h), so the channel is surfaced before the finding it would have to carry.
PEER_SEND_FAIL_ESCALATE="${PEER_SEND_FAIL_ESCALATE:-4}"

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
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
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

# PRINTS TWO LINES: the epoch, then the producer's own last exit status
# (`exit_code=` in the heartbeat body) or empty when it published none.
#
# WHY THE SECOND LINE EXISTS. A fresh commit date proves the producer RAN. It
# does not prove the producer could SPEAK. A checker whose Telegram or email
# credential was revoked exits 2, keeps running, keeps publishing a perfectly
# fresh heartbeat — and every reader downstream calls it healthy while it is
# incapable of reporting the failure it exists to report. That is the same
# false-green this whole leg was built to kill, moved one hop upstream.
#
# It costs NOTHING to read: GitHub's commits API already returns the file's
# patch in the response we were fetching anyway, so this is zero extra
# requests against the 60/hour unauthenticated budget.
#
# ⚠ STRICTLY OPTIONAL, AND THAT IS THE CONTRACT. A producer that publishes
# nothing but a timestamp must still read as ALIVE — see heartbeat-push.sh's
# header. Absence is "cannot judge", never "broken".
peer_last_seen() {
  local body iso epoch hb_exit=""
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
      # Patch lines carry a leading '+' on an orphan branch's only commit.
      hb_exit="$(printf '%s' "$body" | jq -r '.files[0].patch // ""' \
        | sed -n 's/^[+ ]*exit_code=//p' | tail -n1 | tr -d '[:space:]')"
      # Anything that is not a plain integer is not a status; treat it as
      # "none published" rather than guessing.
      case "$hb_exit" in ''|*[!0-9]*) hb_exit="" ;; esac
      ;;
    *)
      log "FATAL unknown PEER_KIND=$PEER_KIND"; exit 2 ;;
  esac
  [ -n "$iso" ] || return 1
  epoch="$(date -u -d "$iso" +%s 2>/dev/null)" || return 1
  [ -n "$epoch" ] || return 1
  printf '%s\n%s\n' "$epoch" "$hb_exit"
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
# The peer is running but told us its own notification channel is dead.
mute_alarmed="$(state_get mute_alarmed 0)"
# Consecutive runs in which OUR channel got nothing out. Reset by the first
# send that lands. See notify() / finalize_send_streak().
send_fail_streak="$(state_get send_fail_streak 0)"

state_write() {
  # Fold this run's send outcomes into send_fail_streak BEFORE persisting, so
  # the counter written here always means "consecutive runs with no send out".
  # Defined further down; bash resolves it at call time.
  finalize_send_streak
  {
    printf '# pcius-watch PEER state — do not hand-edit while the timer is running\n'
    printf '# last run: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'peer_status=%s\n' "$peer_status"
    printf 'peer_alarmed=%s\n' "$peer_alarmed"
    printf 'mute_alarmed=%s\n' "$mute_alarmed"
    printf 'api_fail_streak=%s\n' "$api_fail_streak"
    printf 'api_alarmed=%s\n' "$api_alarmed"
    printf 'send_fail_streak=%s\n' "$send_fail_streak"
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
  # Return 2, not 1: a missing token is a broken CHANNEL, not one failed
  # message. Retrying it every cycle forever will never help, so notify()
  # escalates this through the exit code instead.
  if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
    log "ERROR TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID not set — message NOT sent"
    return 2
  fi
  # Run logs may be public. Never echo the URL, the token, or the response
  # body — Telegram error bodies can echo request context back.
  set +x
  code="$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text=%s"\n' \
    "$TELEGRAM_BOT_TOKEN" "$TELEGRAM_CHAT_ID" "$text" \
    | curl -sS --max-time 20 -o /dev/null -w '%{http_code}' --config - 2>/dev/null)"
  if [ "$code" = "200" ]; then log "telegram sendMessage ok"; return 0; fi
  # PERMANENT vs TRANSIENT, same split as check.sh. A credential that is
  # PRESENT but REJECTED — a rotated token — is a dead channel; retrying it
  # every cycle forever will never help and must escalate exactly like an
  # empty credential. 400 bad chat_id · 401 revoked token · 403 bot blocked or
  # kicked · 404 malformed token in the path. Everything else (429, 5xx, and
  # an empty code from a timeout or DNS failure) is genuinely transient and
  # must not burn the escalation on its first occurrence.
  case "$code" in
    400 | 401 | 403 | 404)
      log "ERROR telegram sendMessage returned HTTP $code — the bot token or chat id is REJECTED (PERMANENT); retrying will not help"
      return 2
      ;;
  esac
  log "ERROR telegram sendMessage returned HTTP ${code:-none} (transient — will retry next cycle)"
  return 1
}

# EVERY alarm and every recovery goes through notify(), never send_telegram()
# directly.
#
# THE DEFECT THIS EXISTS TO PREVENT. Before this, both alarm paths did
#
#     send_telegram "..."
#     peer_status="stale"; peer_alarmed=1
#
# — setting the latch UNCONDITIONALLY, discarding send_telegram's return. So a
# send that never left the box latched the alarm as if it had been delivered:
# the operator was never told, and the state file said they were. Every
# subsequent run then read "already alarmed — staying quiet" and the finding
# was lost permanently. `peer_status` tracks REALITY; `peer_alarmed` tracks
# whether A HUMAN WAS ACTUALLY TOLD. They are not the same fact and must never
# be set together.
SEND_MISCONFIGURED=0
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
# from state_write, so the exit paths cannot drift apart on it.
SEND_STREAK_FINALIZED=0
finalize_send_streak() {
  [ "$SEND_STREAK_FINALIZED" = "1" ] && return 0
  SEND_STREAK_FINALIZED=1

  if [ "$RUN_SEND_OK" = "1" ]; then
    # PARTIAL SUCCESS COUNTS AS SUCCESS, DELIBERATELY. This counter exists to
    # detect a DEAD CHANNEL, and a channel that delivered something this run is
    # demonstrably not dead. The send that DID fail is not forgiven: its own
    # latch stayed clear, so that specific alarm is retried on its own merits
    # next run. This counter is about the channel; the latches are about each
    # message.
    if [ "$send_fail_streak" != "0" ]; then
      log "a send got out this run — resetting send_fail_streak (was $send_fail_streak)"
    fi
    send_fail_streak=0
    return 0
  fi

  if [ "$RUN_SEND_FAILED" = "1" ]; then
    send_fail_streak=$((send_fail_streak + 1))
    if [ "$send_fail_streak" -ge "$PEER_SEND_FAIL_ESCALATE" ]; then
      SEND_MISCONFIGURED=1
      log "COULD NOT NOTIFY — no send has got out for $send_fail_streak consecutive runs (threshold $PEER_SEND_FAIL_ESCALATE). A transient failure this persistent is indistinguishable from a dead channel — escalating to exit 2."
    else
      log "no send got out this run (run $send_fail_streak/$PEER_SEND_FAIL_ESCALATE in a row) — retrying next run"
    fi
    return 0
  fi

  # Nothing was attempted this run, so it says nothing about the channel
  # either way. Leave the streak exactly as it was.
  return 0
}

# Exit wrapper. A notification channel WE could not reach outranks the peer
# result: exit 2 is the only way this script can say "I could not have told you
# either way". Without it, a peer checker with a dead channel exits 0 and looks
# perfectly healthy — the same false-green shape this leg exists to kill, one
# level down. The units carry SuccessExitStatus=0 1, so only 2 turns the unit
# red.
final_exit() {
  local code="$1"
  if [ "$SEND_MISCONFIGURED" = "1" ]; then
    log "EXIT 2 — MY OWN notification channel is misconfigured; the peer result this run was $code"
    code=2
  fi
  exit "$code"
}

# ── Decide ────────────────────────────────────────────────────────────────
log "peer=$PEER_NAME kind=$PEER_KIND repo=$PEER_REPO stale_after=${PEER_STALE_AFTER}s"
log "state in: peer_status=$peer_status peer_alarmed=$peer_alarmed mute_alarmed=$mute_alarmed api_fail_streak=$api_fail_streak send_fail_streak=$send_fail_streak"

peer_read="$(peer_last_seen)"; rc=$?
last_seen="$(printf '%s' "$peer_read" | sed -n 1p)"
peer_exit="$(printf '%s' "$peer_read" | sed -n 2p)"

if [ "$rc" -eq 2 ]; then
  # Could not ask GitHub. Says nothing about the peer. Do not touch peer state.
  last_seen="$(state_get peer_last_seen 0)"
  api_fail_streak=$((api_fail_streak + 1))
  log "could not reach the GitHub API (streak $api_fail_streak/$PEER_API_FAIL_CYCLES) — NOT treating this as a dead peer"
  if [ "$api_alarmed" = "0" ] && [ "$api_fail_streak" -ge "$PEER_API_FAIL_CYCLES" ]; then
    if notify "$(printf '%s\n%s\n%s\n' \
      "⚠️ PCIUS watcher — cannot check on ${PEER_NAME}" \
      "The GitHub API has been unreachable from this box for $api_fail_streak checks in a row, so I cannot tell whether ${PEER_NAME} is still running." \
      "Production monitoring itself is unaffected — this is only the watcher-watching-the-watcher leg.")"; then
      note "API-UNREACHABLE streak=$api_fail_streak"
      api_alarmed=1
    else
      log "the GitHub API is unreachable and that did NOT go out — leaving api_alarmed=0 so the next run retries it"
      note "API-UNREACHABLE (alarm NOT delivered) streak=$api_fail_streak"
    fi
  fi
  state_write
  final_exit 1
fi

if [ "$api_alarmed" = "1" ]; then
  if notify "$(printf '%s\n%s\n' "🟢 PCIUS watcher — GitHub API reachable again" \
    "I can check on ${PEER_NAME} once more.")"; then
    note "API-RECOVERED"
    api_alarmed=0
  else
    # The all-clear did not go out. Clearing the latch here would leave the
    # operator holding an alarm that is over and will never be retracted, and
    # nothing would ever say so again. Keep it set and retry next run.
    log "the all-clear did NOT go out — keeping api_alarmed=1 so the next run retries it"
  fi
else
  api_alarmed=0
fi
api_fail_streak=0

if [ "$rc" -eq 1 ] || [ -z "${last_seen:-}" ] || [ "${last_seen:-0}" -eq 0 ] 2>/dev/null; then
  # Never seen. On a fresh install this is expected exactly once, and it is
  # not an incident — say nothing, record nothing, let the next run judge.
  log "peer has no recorded activity yet — nothing to judge, staying quiet"
  last_seen=0
  state_write
  final_exit 0
fi

age=$((NOW - last_seen))
log "peer last seen $(fmt_utc "$last_seen") — ${age}s ago (threshold ${PEER_STALE_AFTER}s)"

if [ "$age" -gt "$PEER_STALE_AFTER" ]; then
  # peer_status tracks REALITY — the peer IS stale whether or not we got the
  # word out. peer_alarmed tracks whether A HUMAN WAS TOLD. Setting them
  # together is the bug this block used to have.
  peer_status="stale"
  if [ "$peer_alarmed" = "1" ]; then
    log "already alarmed about $PEER_NAME — staying quiet"
  elif notify "$(printf '%s\n%s\n%s\n%s\n' \
      "⚠️ PCIUS watcher — ${PEER_NAME} has gone quiet" \
      "It has not checked in for $(fmt_duration "$age"). Last seen $(fmt_utc "$last_seen") ($(fmt_local "$last_seen"))." \
      "$PEER_CONTEXT" \
      "I will message again when it comes back.")"; then
    note "PEER-STALE ${PEER_NAME} age=${age}s"
    peer_alarmed=1
  else
    log "${PEER_NAME} has gone quiet and the alarm did NOT go out — leaving peer_alarmed=0 so the next run retries the alarm"
    note "PEER-STALE (alarm NOT delivered) ${PEER_NAME} age=${age}s"
  fi
  state_write
  final_exit 1
fi

if [ "$peer_alarmed" = "1" ]; then
  if notify "$(printf '%s\n%s\n' \
    "🟢 PCIUS watcher — ${PEER_NAME} is back" \
    "It checked in at $(fmt_utc "$last_seen") ($(fmt_local "$last_seen")). Both watchers are running again.")"; then
    note "PEER-RECOVERED ${PEER_NAME}"
    peer_alarmed=0
  else
    # Same reasoning as the API all-clear: an undelivered recovery must not
    # clear the latch, or the operator is left holding a stale alarm forever.
    log "the all-clear for ${PEER_NAME} did NOT go out — keeping peer_alarmed=1 so the next run retries it"
  fi
fi
peer_status="fresh"

# ── Alive, but can it SPEAK? ──────────────────────────────────────────────
# A fresh heartbeat proves the peer RAN. `exit_code=2` in its body is the peer
# telling us it ran and COULD NOT HAVE REPORTED ANYTHING — its own credential
# is missing or rejected. Treating that as healthy is exactly the false green
# this leg exists to kill, so it gets its own alarm and its own latch.
#
# A peer that publishes no exit_code at all is NOT judged here. Absence is
# "cannot tell", never "broken": the contract is that a bare timestamp still
# reads as alive.
if [ -z "$peer_exit" ]; then
  log "peer published no exit_code — freshness only, not judging its channel"
elif [ "$peer_exit" = "2" ]; then
  if [ "$mute_alarmed" = "1" ]; then
    log "already alarmed that $PEER_NAME is mute — staying quiet"
  elif notify "$(printf '%s\n%s\n%s\n%s\n' \
      "⚠️ PCIUS watcher — ${PEER_NAME} is running but cannot raise an alarm" \
      "It checked in normally at $(fmt_utc "$last_seen") ($(fmt_local "$last_seen")), and reported that its OWN notification channel is broken — a missing or rejected credential." \
      "So it is alive, but its silence no longer means everything is fine: a real failure would now go unreported." \
      "Fix its credential, then this will clear itself.")"; then
    note "PEER-MUTE ${PEER_NAME} exit_code=$peer_exit"
    mute_alarmed=1
  else
    log "${PEER_NAME} is mute and that alarm did NOT go out — leaving mute_alarmed=0 so the next run retries it"
    note "PEER-MUTE (alarm NOT delivered) ${PEER_NAME} exit_code=$peer_exit"
  fi
  state_write
  log "state out: peer_status=$peer_status peer_alarmed=$peer_alarmed mute_alarmed=$mute_alarmed"
  final_exit 1
else
  log "peer reported exit_code=$peer_exit — its channel is working"
  if [ "$mute_alarmed" = "1" ]; then
    if notify "$(printf '%s\n%s\n' \
      "🟢 PCIUS watcher — ${PEER_NAME} can raise alarms again" \
      "Its notification channel is working: it reported exit_code=${peer_exit} at $(fmt_utc "$last_seen").")"; then
      note "PEER-MUTE-RECOVERED ${PEER_NAME}"
      mute_alarmed=0
    else
      log "the mute all-clear did NOT go out — keeping mute_alarmed=1 so the next run retries it"
    fi
  fi
fi

state_write
log "state out: peer_status=$peer_status peer_alarmed=$peer_alarmed mute_alarmed=$mute_alarmed"
final_exit 0
