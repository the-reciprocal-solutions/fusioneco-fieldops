# Daily attendance for payroll (shift based): plan change

Status: **built 2026-10-22: server, web and app (phases D1 to D7; D8 local notification and bulk-assign screen still open). See "Build status" at the end.** · Written 2026-10-22 · **2026-10-22: the per-job site visits this plan was written beside were removed by owner decision; daily attendance is the only attendance now.** Mentions of "site visits" below are history.

## 0. What changed, in one paragraph

Until now the plan recorded **site visits**: "this technician was physically at this job from 10:05 to 11:40". That is evidence for a job. It says nothing about a technician who had no job that day, and it is not a payroll record.

The new requirement is a second layer: **one attendance record per technician per day, based on the technician's shift, that exists even when there is no work order**. That record is what payroll reads: present, late, half day, absent, weekly off (Sunday), holiday, leave, overtime.

The two layers stay separate and talk to each other:

| | Daily attendance (new) | Site visit (built) |
|---|---|---|
| Question it answers | Did the technician work today, and for how long? Is it payable? | Was the technician physically at this job? |
| One per | technician per day | arrival at a job |
| Needs a job? | No | Yes |
| Who reads it | Payroll, HR, supervisors | Supervisors, clients, SLA |
| Rules come from | The technician's **shift** (start, end, grace, weekly off, holidays) | The building's check-in radius |
| Lateness, absence, Sunday | Yes | No |

A technician does **both**: starts the day once (daily attendance), then checks in and out of jobs as they go (site visits).

## 1. Decisions in this plan, and the ones I need from you

### Taken from your message
1. Daily attendance is **per day, shift based**, even with no work orders.
2. **Shifts are a master** (create, edit, deactivate), kept with the other masters.
3. The shift is chosen **on the technician create / edit form itself**.
4. **Sundays** (weekly off) are handled: no check-in expected, no alert, not absent.
5. **Grace time** comes from the shift. Passing it without a check-in sends the technician an **alert notification to check in**.

### My defaults (change any of them, none is hard to change)
| # | Question | Default I used |
|---|---|---|
| D1 | Is a check-in inside the grace window "on time"? | **Yes.** Inside grace = on time, 0 late minutes. |
| D2 | After grace, how are late minutes counted? | **From shift start** (09:00 shift, in at 09:40 = 40 min late), not from the end of grace. Switchable per shift. |
| D3 | When does "late" become "half day" / "absent"? | Per shift: half day when in after `halfDayAfterMin` (default 120 min), absent when no check-in by `absentAfterMin` (default 240 min). |
| D4 | Present needs how many hours? | Per shift `minWorkMinutes` (default 8 h minus breaks, with a "half day" floor of 4 h). Under the floor = half day or absent. |
| D5 | Overtime | After shift end, only when the supervisor approves it. Never auto-paid. |
| D6 | Working on Sunday / holiday | Recorded as **off-day work**, goes to the supervisor for approval, then payroll pays it at the off-day rate (the rate itself is payroll's, not ours). |
| D7 | What fence does a day check-in use? | The technician's **home site** if one is set (optional, on the technician form); otherwise no fence, position is recorded and flagged only if missing. Warn-only, like site visits. |
| D8 | Photo | Selfie at day start and day end, same sheet as site visits. |
| D9 | Month close | A manager **locks the month**; after that, changes need an unlock with a note. |

### Needs your answer (these change the build)
- **Q1. Where does payroll attendance live today?** I saw a separate **FusionHRM** app on the phone with its own "Check in", leave and overtime. If HRM already owns payroll attendance, the FieldOps day check-in should **feed HRM** instead of becoming a second source of truth. If FieldOps is the only source for technicians, we build it all here as written. *I assumed FieldOps is the source; this must be confirmed before building.* -Answer: FieldOps is the once source of truth.
- **Q2. Rotating weekly offs?** One fixed weekly off per shift (Sunday, or Friday) is in this plan. A rotating roster (off on different days each week) is a bigger feature and is not included. - Answer: Fixed weekly off is enough.
- **Q3. Public holidays:** reuse the holiday list already stored in the SLA business calendars, or a new holiday master? I recommend a **new, small holiday list** on the shift's calendar so payroll holidays and SLA holidays can differ. -Answer: Public holiday list is enough.

## 2. Shift master

New master tab **Masters ▸ Shifts** (next to SLA calendars, same table + side sheet pattern).

### 2.1 What a shift holds
| Field | Meaning | Example |
|---|---|---|
| Name, code | | "General day", GEN |
| Start time, end time | Local time | 09:00 – 18:00 |
| Crosses midnight | Derived when end ≤ start | Night 22:00 – 06:00 |
| Timezone | Where the times are read | Asia/Kolkata |
| **Grace in (minutes)** | Check-in window after start that still counts as on time | 15 |
| Grace out (minutes) | Leaving this early before end is not "early leave" | 10 |
| Count late from | `shift start` (default) or `end of grace` | start |
| Half day after (min late) | Check-in later than this = half day | 120 |
| Absent after (min late) | No check-in by this = absent | 240 |
| Break minutes, paid or not | Subtracted from worked time when unpaid | 60, unpaid |
| Minimum work minutes for "present" | | 480 |
| Half-day minimum minutes | | 240 |
| Weekly off days | One or more weekdays | Sun |
| Holiday list | Dates + names | 2026-10-20 Diwali |
| Overtime allowed after (min past end) | Only counts beyond this | 30 |
| Early check-in opens (min before start) | When "Start my day" becomes available | 120 |
| Reminder before start (min), optional | "Your shift starts at 09:00" nudge, 0 = off | 10 |
| Active | Inactive shifts cannot be newly assigned | |

A shift can be **deactivated, never deleted, once anyone has used it** (history must stay readable).

### 2.2 Assigning a shift to a technician
- The **technician create form and edit form** get: **Shift** (required for field technicians), **Effective from** (default today), optional **Home site**, optional **Employee / payroll code**.
- Saved as a row in `technician_shift_assignments` (technician, shift, effective from, effective to). Changing a shift on the 15th creates a new row from that date; **days already recorded keep the shift they had** (each daily record stores a snapshot of the shift's rules).
- Bulk: from the Shifts master, "Assign technicians" lets a manager move many people at once with an effective date.
- A technician with **no shift** has no daily attendance expected: no alerts, not counted absent. The Attendance page shows them under "No shift set" so nobody is silently skipped.

## 3. Daily attendance record

One row per technician per **shift date** (the date the shift *starts*, so a night shift 22:00 to 06:00 belongs to the day it began).

| Field | Notes |
|---|---|
| technician, date, shift snapshot | Shift id + the rules as they were that day |
| `dayType` | `working`, `weekly_off`, `holiday`, `leave` |
| `status` | `present`, `late`, `half_day`, `absent`, `weekly_off`, `holiday`, `leave`, `off_day_work` |
| first in / last out | Tap times (phone clock, with receive time kept beside it, same clock rules as site visits) |
| in/out selfie, position, accuracy, distance from home site | Same capture as site visits |
| lateMinutes, earlyLeaveMinutes, workedMinutes, overtimeMinutes | Computed by the server only |
| flags | Late, grace exceeded, no photo, no location, missed check-out, off-day work, clock off, outside home site |
| reviewStatus + note + reviewer | Same approve / reject / correct as visits |
| source | `app`, `admin_entry` (a manager entered it for someone), `system` (absent / auto-close) |
| lockedAt | Set when the month is locked |

**A row exists for every expected day**, written by a nightly job (section 6), so "absent" is a real record, not the lack of one. This is what makes payroll complete.

## 4. How a day is judged (the rules, in order)

Given a technician, a date and their shift:

1. **What kind of day is it?** Holiday list first, then weekly off, then approved leave, else working.
2. **Working day, check-in time `t` versus shift start `S`, grace `G`:**
   - `t ≤ S + G` → **present**, 0 late minutes.
   - `S + G < t ≤ S + halfDayAfter` → **late**, late minutes = `t − S` (or `t − (S+G)` if the shift says so).
   - `S + halfDayAfter < t ≤ S + absentAfter` → **half day (late)**.
   - no check-in by `S + absentAfter` → **absent** (system writes it, supervisor can correct).
3. **Check-out `o` versus shift end `E`:** worked = `o − t − unpaid break`. `o < E − graceOut` → early leave minutes. `o > E + overtimeAfter` → overtime minutes (pending approval).
4. **Worked time floor:** under half-day minimum → absent; between half-day and present minimum → half day.
5. **Non-working day with a check-in** (Sunday, holiday): status **off_day_work**, always pending review, never silently paid.
6. **Weekly off / holiday / leave without a check-in:** status is that day type, nothing is expected, nothing alerts.

All of this runs on the server from the tap time, never from the time the request arrived, so a technician in a basement who taps at 08:58 and syncs at 11:00 is **on time**.

## 5. Alerts (grace and the rest)

Timeline for a 09:00 shift with 15 min grace. All pushes come from the server (reaches a closed app), all are skipped on weekly off, holiday and approved leave, and all stop the moment the technician checks in.

| When | Who | Message | Why |
|---|---|---|---|
| 08:50 (optional, shift setting) | Technician | "Your shift starts at 09:00. Start your day when you arrive." | Nudge |
| **09:15 (grace ends, no check-in)** | **Technician** | **"You haven't checked in. Your grace time ended at 09:15. Check in now."** | **The alert you asked for** |
| 09:45 (30 min after grace) | Technician | Second, louder reminder | Still missing |
| 10:00 | Technician's supervisors / building admins | "Balaji has not checked in (shift 09:00)." | Someone can phone him |
| 11:00 (`halfDayAfter`) | Technician | "Checking in now will count as a half day." | Last warning before the status changes |
| 13:00 (`absentAfter`) | Technician + supervisors | "Marked absent for today unless corrected." and the system writes `absent` | Closes the day |
| End of shift, still checked in | Technician | "Your shift has ended. Check out." | Forgotten check-out |
| End + buffer (default 2 h) | System | Auto-close, flag "missed check-out", pending review | Day never stays open |

Rules for the alerts:
- Each alert is **sent once per day per technician** (a stored marker, like the existing "Still checked in?" reminder).
- A technician with **no signal** gets the push when signal returns. Because that can be late, the **app also shows a banner on open** ("Grace time ended at 09:15 · Check in") and, in a later phase, schedules a **local notification** on the phone at grace end so it fires even offline.
- Late or not is always decided from the tap time, so a late-delivered alert never changes the result.

## 6. Background jobs (server)

| Job | Every | Does |
|---|---|---|
| Day builder | night, per timezone | Creates the next day's expected rows: working / weekly_off / holiday / leave per technician |
| Grace and absence watcher | 5 min | Sends the alerts above, marks `absent` at the cutoff |
| Day closer | 15 min | Auto-closes a day still open past shift end + buffer |
| Month report | on demand | Builds the payroll summary (section 8) |

These sit beside the existing 15-minute visit sweep and reuse its push path.

## 7. How it meets site visits

- Day check-in and a job check-in are **different taps**, different records.
- **Soft prompt:** if a technician starts a job check-in and has **not started the day**, the app offers "Start your day with this check-in too?" Yes = one selfie and position serve both, so no double work. No = they continue; the day stays open for them to start.
- A **job visit never creates or changes the day record by itself**; only the technician's day check-in (or a manager's correction) does.
- Day check-out with a job visit still open → "You are still checked in at WO-760. Check out of it first?" (same gate idea as today).
- Supervisors see both on one technician row: day status, and under it the jobs visited that day.

## 8. Payroll output

- **Daily board** (web): per day, every technician with status, in, out, worked, late, flags.
- **Monthly sheet**: per technician: working days expected, present, late (count and minutes), half days, absent, weekly offs, holidays, leave, off-day work days, overtime hours, total payable hours. CSV export for payroll.
- **Month lock:** manager reviews flagged rows, then locks. Locked rows are read-only; an unlock needs a note and is logged.
- Corrections on any day: manager edits in / out or status **with a required note**; the original tap is kept beside the correction.

## 9. User scenarios (the correct flow)

Shift used in the examples: **General, 09:00–18:00, grace 15 min, half day after 120 min late, absent after 240, weekly off Sunday.**

### A. Normal day
1. 08:55: Balaji reaches the site gate, opens FieldOps. Dashboard card: "General shift 09:00–18:00 · **Start my day**".
2. Taps it, takes the selfie, position found (inside his home site), confirms. Card turns green: "On duty since 08:55 · on time".
3. 09:30: opens WO-760, **Check in** (job visit, separate). Works. Checks out of the job at 11:10.
4. Afternoon: two more jobs.
5. 18:05: card says "Shift ends 18:00 · **End my day**". Taps, selfie, done.
6. Server: **present**, in 08:55, out 18:05, worked 8 h 10 min, 0 late, 5 min over (inside the 30 min overtime threshold, so none).
7. Payroll sees one **Present** day with 8 h 10 min.

### B. Late but inside grace
Taps at 09:12 → on time, 0 late minutes. Nothing alerts.

### C. Late beyond grace (the alert case)
1. 09:15 passes, no check-in. **Push: "You haven't checked in. Your grace time ended at 09:15. Check in now."**
2. Balaji is stuck in traffic. 09:45 second reminder. 10:00 his supervisor gets "Balaji has not checked in".
3. 10:20 he arrives and taps **Start my day**. The sheet shows "You are 1 h 20 min late" before he confirms.
4. Server: **late, 80 minutes** (counted from 09:00). Flag "grace exceeded", pending the supervisor's OK (policy: late beyond grace needs an acknowledgement; approving does not change the minutes).
5. If he taps at 11:30 instead: **half day (late)**.

### D. Never checks in
1. Alerts at 09:15, 09:45, 10:00 (supervisor), 11:00 ("will count as half day"), 13:00.
2. 13:00: system writes **absent**, notifies technician and supervisors.
3. Later it turns out his phone broke. Supervisor opens the day, **Correct**: enters in 09:10 / out 18:00 with the note "phone broken, confirmed by site gate". Status becomes present (corrected), original absent kept in the history.

### E. A day with no work orders
Balaji starts and ends his day, no job visits. Status **present**, 9 h. Nothing about work orders is needed. This is the case the change exists for.

### F. Sunday (weekly off)
1. Sunday morning: **no** reminder, **no** alert, no absent. The card reads "Sunday · Weekly off".
2. Payroll shows **Weekly off** (not absent, not worked).
3. **If he is called in for an emergency:** he opens the app, the card says "Weekly off today. **Start off-day work**" (a clear extra step so it is never an accident). Takes selfie, works, checks in and out of the emergency job normally (site visit), ends the day.
4. Server: status **off_day_work**, worked hours recorded, **pending supervisor approval**. Supervisor approves (or rejects with a note). Only then does payroll count it, tagged "worked on weekly off".
5. If nobody approves, payroll sees it as "pending", never as paid.

### G. Public holiday
Same as Sunday, using the shift's holiday list. A holiday that falls on a Sunday is one day, labelled holiday.

### H. Night shift (22:00–06:00)
1. Check-in opens at 20:00 (early window 2 h). He taps at 21:55 on Monday.
2. The day belongs to **Monday** (the date the shift started) even though it ends Tuesday 06:00.
3. Grace ends 22:15; alerts follow the same pattern on Monday night.
4. Checks out Tuesday 06:05 → one Monday record, 8 h.

### I. No network at the gate
1. He taps **Start my day** at 08:58 in a basement car park, no signal. The selfie and position are saved on the phone, the screen says "Saved · waiting to send".
2. He drives out, signal returns at 09:40, it uploads. Server judges by the **tap time 08:58**: **on time**. (A push at 09:15 may have been missed; that does not change the result.)
3. If he is still offline at 09:15 he sees the in-app banner when he opens the app; with local notifications (phase 2) the phone itself nudges him.

### J. Forgot to end the day
1. 18:00 push "Your shift has ended. Check out." He ignores it.
2. 20:00 (end + 2 h) the system closes the day at **18:00** (shift end), flag **missed check-out**, pending the supervisor. Worked time is the shift length, not an open-ended number; the supervisor can correct.

### K. Shift changed in the middle of a month
Manager edits Balaji on the 15th: new shift Night, effective 16 Oct. Days 1–15 keep General (each stored with its own rules); from the 16th the Night rules apply. Payroll for the month shows both.

### L. Approved leave
A leave day (entered by the supervisor, or later fed from HRM) is written as **leave**. No alerts, not absent. If he comes in anyway, it is off-day work needing approval.

### M. Month end
Manager opens **Attendance ▸ Monthly**, filters flagged rows, approves / corrects, then **Lock month**. Payroll exports the CSV. A later change needs "Unlock" with a note.

## 10. Where each piece lives

### Server (`fusion-eco-server`)
New tables (all additive, created by the boot schema guard like `job_visits`):
- `attendance_shifts`: the master.
- `attendance_shift_holidays` (or a JSON list on the shift): holiday dates.
- `technician_shift_assignments`: technician, shift, effective from / to.
- `daily_attendance`: section 3.
- `attendance_month_locks`: org, month, lockedBy, lockedAt, unlock history.
- Technician gets nullable `homeBuildingId`, `payrollCode`.

New code: `services/attendance/` with a **pure rules file** (like `visitPolicy.ts`): `dayType`, `judgeCheckIn`, `judgeCheckOut`, `grace` helpers, covered by unit tests for every scenario above.

Endpoints: shift CRUD under masters; technician create/update accept `shiftId`, `shiftEffectiveFrom`, `homeBuildingId`; `POST /api/fm/technicians/me/day/check-in` and `.../check-out` (idempotent by phone-made id, exempt from the 428 location gate like visits); `GET /api/fm/technicians/me/day/today`; admin `GET /api/fm/attendance/daily`, `GET /monthly`, `PATCH /daily/:id/review`, `POST /daily/:id/correct`, `POST /months/:month/lock`.

### Web (`fusion-eco-client`)
- **Masters ▸ Shifts** tab (Orbit design system).
- **Technician create/edit form**: Shift, Effective from, Home site, Payroll code.
- **Attendance** gets two tabs: **Daily** (today's board and any date) and **Monthly** (payroll sheet, lock, export). Existing Visits and Timesheet stay.

### App (`technician_portal`)
- Dashboard **day card** (Start my day / End my day / Weekly off / Holiday / On leave), a day banner, the grace countdown, the soft prompt on job check-in.
- Same photo + position sheet, same offline outbox pattern (`DayIn`, `DayOut` entity types), same reconcile after the background engine.
- en + ar strings.

## 11. Build phases

1. **D1 Shifts master and assignment** (server tables, CRUD, rules for "what kind of day"; web masters tab; technician form fields). Testable on its own.
2. **D2 Day rules engine** (pure functions + tests for scenarios A–M).
3. **D3 Day check-in/out API + app day card + offline** (phone test: normal, offline, forgotten check-out).
4. **D4 Daily builder and alerts** (grace alert, supervisor alert, absent marker, closer) and phone check of the push.
5. **D5 Off-day work, holidays, approval.**
6. **D6 Web Daily board, review/correct.**
7. **D7 Monthly sheet, lock, CSV.**
8. **D8 Local (offline) grace notification, HRM link if Q1 says so.**

## 12. Tests

- Unit: every row of section 4 and 5, shift crossing midnight, grace edges (09:15:00 is on time, 09:15:01 is late), clock skew, DST-free timezone, weekly off + holiday overlap, shift change mid-month, lock.
- Phone: scenarios A, C, F, I, J on a real phone with the dev server and a short test shift (e.g. start 5 minutes from now, grace 2 minutes) so the alerts can actually be seen.
- Web: shifts CRUD, technician form saves the shift, daily board, correction with note, month lock refuses edits.
- Payroll check: a fixture month with every status; the monthly totals must equal the sum of the days.

## 13. Risks

| Risk | Handling |
|---|---|
| Two sources of attendance (FieldOps and HRM) | Decide Q1 before building |
| Wrong shift on a technician → wrong payroll | Shift required on the form; "No shift set" list; shift snapshot stored on every day |
| Alert fatigue | Each alert once per day; none on off days; stops at check-in |
| Offline phones miss the push | Tap-time judging; in-app banner; local notification in D8 |
| Edits after payroll ran | Month lock + audited unlock |
| Technician at a different site than home site | Fence is warn-only; flagged, never blocks |


## Build status (2026-10-22)

Owner answers used: FieldOps is the single source of truth (no FusionHRM link); one fixed weekly off per shift; one public holiday list for all shifts (a master of its own, not the SLA calendars).

| Phase | State |
|---|---|
| D1 Shifts master, public holidays, shift on the technician form | Built (web Masters ▸ Shifts and Public Holidays; server CRUD; technician form has Shift, Shift applies from, Home site, Payroll code). |
| D2 Day rules engine | Built and unit-tested (`services/attendance/attendanceRules.ts`, every scenario A to M in the tests). |
| D3 Day check-in / out API, app day card, offline | Built. App: "My day" card on the dashboard, shell banner, same selfie + position sheet, offline outbox (`DayIn` / `DayOut`). |
| D4 Daily builder and alerts | Built (cron every 5 minutes). Verified live on the dev server: grace alert, second reminder, supervisor alert, half-day warning (and a real bug found: stale alerts after a newer one; fixed and tested). |
| D5 Off-day work, holidays, approval | Built (off-day work always pending approval). |
| D6 Web Daily board, review, correct, leave | Built. |
| D7 Monthly sheet, lock, CSV | Built. |
| D8 Local offline grace notification; bulk "assign technicians" screen | Local reminders built 2026-10-22 (`lib/core/push/day_reminders.dart`: "You haven't checked in" at the end of grace, "Your shift has ended" at the shift end; scheduled by the phone, tested in airplane mode; a server push with the same `day:<date>:<kind>` tag replaces it). Bulk "assign technicians" screen not built (the API exists). |

Phone test 2026-10-22 (Balaji, real phone, dev server): late start online (half day, 283 min late, selfie saved), end of day taken offline then synced (card "Waiting to send" then "Sent"), off-day work on a public holiday (asks first, "needs approval", then "approved" once a supervisor approves; label fixed in the app), late banner and "counts as a half day" wording. Bugs found on the phone and fixed: a technician with no organisation never saw the holidays (also hit the monthly sheet and the month lock); holidays added after the day was built did not change recorded days (now re-judged); the server did not send the holiday name. Web: Holidays moved into a clean list (year picker, counts, yearly, copy to next year), Attendance has one Add holiday button and no leave screens.

Phone test 2026-10-22, second round: on-time start (present, 0 late, no flags); forgotten end of day with a custom shift that ended 2 h before (banner "Your shift ended at 13:16 · End your day", server end reminder + auto-close at the next 5-minute tick, both pushes arrived); month lock (current month: "Attendance for 2026-10 is locked for payroll" on the phone, card "Not sent · closed for payroll"; previous month: leave and a check-out with its start refused, today's check-in not blocked); holiday name on the card; local grace reminder in airplane mode. Found and fixed: the card never learned the server had auto-closed the day (new "closed for you" state, no end-of-day nudge). Web: building-limited admin sees only their site's technicians on Daily and Monthly (the shift-assignment table is organisation-only, so names were blank and the board built no rows; read now unscoped, visibility still scoped), Lock month and Add holiday hidden from them; CSV checked (BOM, Arabic names, formula-looking cells neutralised); Copy to next year, delete, and the technician form's shift saved for real.

Deviations from this plan, on purpose:
- The full-day minimum is relaxed by grace in + grace out, so an on-time start with a leave inside grace out is not turned into a half day.
- The minimum work default follows the shift length less the unpaid break (a night shift 22:00 to 06:00 is 7 h, not 8).
- A check-out after the system auto-closed the day replaces the auto-close (a genuine tap beats the system guess).
- A rejected working day becomes absent; a rejected off-day day goes back to weekly off / holiday.
