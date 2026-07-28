# pcius-watch

**An uptime checker that Pipe Cam, Inc. runs against its own website.**

Every five minutes a GitHub Actions job requests three public URLs belonging to us. If they stop
answering, it sends one Telegram message to the person who fixes them. When they start answering
again, it sends one more. Silence in between.

That is the whole repository. **It contains no application code, no business logic, no customer
data, and no credentials.** The only things it knows about our systems are two hostnames that are
already public — `api.pipecam.report` and `app.pipecam.report` — which anyone can visit right now.

### Why is this public?

Because GitHub gives public repositories unlimited Actions minutes, and a check that runs every
five minutes is about 8,640 billable minutes a month. Our private repository's allowance would be
gone in days, and the same budget pays for our deployments. Making the checker its own public
repository is the cheap, boring answer. Since the thing it does is send ourselves a message when
our own public website is down, there is nothing here worth hiding.

### Why not just run it on the server?

Because on 2026-07-28 our production host was unreachable for roughly six hours and every alarm we
had was running *on that host*. When the box is gone, so is everything that would tell you the box
is gone. This checker is the one that does not live on the thing it is checking.

---

## What is in this repository

| File | What it is |
|---|---|
| `check.sh` | The entire watcher. Bash + curl, no other dependencies. One run = one check cycle. |
| `.github/workflows/watch.yml` | The schedule that runs it. |
| `README.md` | This file. |

`check.sh` is host-agnostic on purpose — it contains no GitHub-specific logic and runs identically
from a cron entry on any Linux box or from a laptop. The only host-specific part is where it keeps
its state, which sits behind two functions (`store_load` / `store_save`) with two implementations:
a plain file, or a GitHub issue. This workflow uses the issue backend, because Actions runners keep
nothing between runs.

**Source of truth.** `check.sh` is maintained inside Pipe Cam's private `pcius` repository at
`operations/watch/`. This repository is the deployed copy. Comments referencing internal file
paths, service names and hosting details were removed on the way over; **every executable line is
byte-identical to the original** (verified by diffing all non-comment lines).

---

## What it checks

1. **`https://api.pipecam.report/health`** — must return 200, *and* the body must actually contain
   `"ok":true`, a non-empty hex `version` commit sha, and a `ts`. The shape assertions matter: our
   `/health` is a static handler that happily returns `ok:true` with the database on fire, so a
   bare 200 proves very little. Checking the shape also catches a proxy or error page answering 200
   in the API's place.
2. **`https://app.pipecam.report/signin`** — must return 200 or 304. This is a separate process
   from the API and can be dead while the API is perfectly healthy. Staff use the app, not the API.
3. **`https://api.pipecam.report/api/public/reports/pcius-watch-liveness-probe`** — a public,
   unauthenticated, read-only endpoint whose handler performs a real multi-table database join. The
   token does not exist, so it returns `200 {"state":"not_found"}` and writes nothing. If the
   database is down this returns a 5xx while `/health` still says `ok:true`. It is the closest
   thing to a database check available from outside with no credential and no change to production
   code.

Alarms **name which surface is down**, because "all three" means the whole box while "app only"
means one service — different first move at 2 a.m.

### How it decides to alarm

- Each run probes up to **3 times**, 20 seconds apart, so a single TCP or DNS blip is absorbed
  with no stored state.
- It alarms only after **2 consecutive failed cycles**. One bad moment never sends a message.
- Once alarmed it goes **quiet** until things recover — no repeat messages during an outage.
- On the way back up it waits **60 seconds and re-probes** before declaring recovery, because a
  host coming back under load serves errors for a while, and a premature all-clear is worse than a
  late one.
- Recovery sends exactly **one** message, naming how long the outage lasted.

State lives in a single long-lived GitHub issue in this repository labelled `pcius-watch-state`.
Its title shows current status (🔴 / 🟢) and it gets a comment on every transition, which gives us
a timestamped incident log for free — useful when claiming a hosting SLA credit, since those are
never automatic.

---

## The schedule, honestly

```
cron: "3-58/5 * * * *"
```

Every 5 minutes, deliberately offset off the hour rather than `*/5` — scheduled runs at :00 land in
GitHub's busiest queue and are the most likely to be delayed.

**GitHub's scheduler is best-effort.** Runs are routinely several minutes late, and under load a
run can be **dropped entirely**. Treat 5 minutes as a floor, not a promise. Combined with the
2-cycle alarm threshold, realistic time-to-first-alert is **5–20 minutes**, occasionally worse.

### ⚠️ Scheduled workflows are auto-disabled after 60 days of repository inactivity

This is the watcher's own silent-death mode, and it is the most important thing to know about it.
GitHub disables `schedule:` triggers in any repository with no commits for 60 days — and a
repository whose entire job is to sit still and run a cron is *exactly* the repository that goes 60
days without a commit. When that happens the watcher stops, and **a stopped watcher looks exactly
like a healthy system.** You will get no message, ever, and you will believe everything is fine.

There is currently **no compensating control**. The weekly heartbeat that would make "no news"
actually mean something is designed but **not built yet**. Until it exists:

- **Check the Actions tab periodically.** If the newest run is older than a few hours, the
  schedule is off.
- GitHub emails the repository admins before disabling a schedule for inactivity. Do not ignore
  that email.
- Any commit to the default branch resets the 60-day clock.

---

## What this does NOT catch

Being straight about the gaps is what keeps an alert worth trusting.

1. **Anything shorter than the cadence.** 5-minute checks × 2 consecutive failures means an outage
   under roughly **11 minutes is invisible**. Deliberate — the events we actually suffer run
   much longer, and a tighter threshold would cry wolf.
2. **Schedule jitter**, as above. "5 minutes" is aspirational.
3. **Slowness is not measured.** A page taking 40 seconds returns 200 and reports healthy. A human
   would call that broken; the watcher calls it fine.
4. **Correctness is not measured.** `/signin` returning 200 does not mean anyone can log in.
5. **Partial failures pass completely.** One route returning 500 while everything else works leaves
   all three probes green.
6. **A dead database is only inferred.** Probe 3 is a strong hint, not a diagnosis. It cannot tell
   "the database is down" from "that one query path is broken", and it cannot see a database that
   is up but degraded, out of connections, or 30 seconds slow.
7. **Migration drift, queue stalls, backup failures and TLS expiry are all invisible.**
8. **The watcher can die silently** — see the 60-day note above. One watcher, no second opinion.
9. **If the runner's own network path is degraded**, it may report a false outage. The 3-attempt
   and 2-cycle guards make this unlikely, not impossible.
10. **Our email alert channel is unmonitored.** If that provider fails, the alarms that do live on
    the server vanish and nothing says so.

---

## Configuration

Two repository secrets are required (Settings → Secrets and variables → Actions):

| Secret | What it is |
|---|---|
| `TELEGRAM_BOT_TOKEN` | The bot that sends the message. |
| `TELEGRAM_CHAT_ID` | Where the message goes. |

**No secret value appears anywhere in this repository, and none ever should.** They are encrypted
Actions secrets, injected as environment variables at run time. Because run logs on a public
repository are public, `check.sh` never echoes the token, never prints the Telegram URL, discards
the response body (`-o /dev/null`), and never prints an error body from `api.telegram.org`.

### The one rule for anyone editing `check.sh`

> **Call Telegram's `sendMessage` and nothing else. Never `getUpdates`, `setWebhook` or
> `deleteWebhook`.**

Telegram permits exactly one poller per bot token. A second `getUpdates` caller gets a `409` and
breaks the live chat that shares this token. Sending is not exclusive — `sendMessage` is a
stateless HTTPS POST and any number of callers may use it at once. That is precisely why this
watcher can reuse an existing bot instead of needing its own.

Everything else is tunable by environment variable; the defaults are listed at the top of
`check.sh`. The ones worth knowing:

| Variable | Default | What it does |
|---|---|---|
| `WATCH_FAIL_CYCLES` | `2` | Consecutive failed cycles before alarming — the flap guard |
| `WATCH_ATTEMPTS` | `3` | Probe attempts within one cycle |
| `WATCH_ATTEMPT_SLEEP` | `20` | Seconds between attempts |
| `WATCH_RECOVER_CONFIRM_SLEEP` | `60` | Re-probe delay before declaring recovery |
| `WATCH_DRY_RUN` | `0` | `1` = probe, decide and format, deliver nothing |
| `WATCH_TZ` | `America/Los_Angeles` | Second timezone shown in messages |

---

## Running it by hand

Use the **Run workflow** button on the Actions tab. It takes two inputs:

- **`dry_run`** — probe production and format the message, but deliver nothing. A safe rehearsal.
- **`test_message`** — send exactly one "watcher is alive" Telegram message and do nothing else.
  This is how you prove the alert path still works (stored secrets, runner egress, Telegram)
  *without* faking an outage. It never touches the state issue, so it cannot confuse a real
  incident. Worth running occasionally — it doubles as a manual stand-in for the heartbeat that
  does not exist yet, and it resets nothing else.

Locally:

```sh
# Dry run against real production. Delivers nothing.
WATCH_STATE_FILE=/tmp/w/state ./check.sh --dry-run

# Simulate an outage: point it at a dead port and run twice.
# First run = below threshold, silent. Second run = exactly one alarm.
for i in 1 2; do
  WATCH_STATE_FILE=/tmp/w/state WATCH_DRY_RUN=1 \
  WATCH_API_URL=http://127.0.0.1:9/health \
  WATCH_APP_URL=http://127.0.0.1:9/signin \
  WATCH_DB_URL=http://127.0.0.1:9/x \
  WATCH_ATTEMPTS=2 WATCH_ATTEMPT_SLEEP=0 WATCH_TIMEOUT_API=2 \
  WATCH_TIMEOUT_APP=2 WATCH_TIMEOUT_DB=2 ./check.sh
done

# Simulate recovery: run again with the real URLs. Exactly one all-clear.
WATCH_STATE_FILE=/tmp/w/state WATCH_DRY_RUN=1 \
WATCH_RECOVER_CONFIRM_SLEEP=0 ./check.sh
```

**Exit codes:** `0` = healthy · `1` = something is down (a normal outcome, *not* a script failure)
· `2` = the watcher is misconfigured. A cron wrapper must not treat exit 1 as an error, or it will
mail you on every failed cycle and reintroduce exactly the noise this design avoids.
