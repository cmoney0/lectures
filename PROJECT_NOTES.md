# Lectures - Project Notes

Durable memory for every Claude session. Newest entries at the bottom of each section.

## Current Status

- 2026-11-05: one-button redesign compiles in CI (run 42090266929, app + LecturesWidgets extension). First TestFlight build **7** uploaded (run 42094571872).
- **Reviewer = the Lectures build session `session_01Xw2SgUJ4SD5jfNotxVqsv8`, subscribed to PR #1** (2026-11-05). Dedicated child sessions were tried and archived: auto mode denies them `add_repo` with push, which `subscribe_pr_activity` needs, so they never woke. A new reviewer session needs Colby to add an allow rule for `add_repo` (or start it himself with the lectures repo attached). **No TestFlight build yet** (needs Colby's approval + the App Store Connect app record for `com.cmoney0.lectures`).

## Architecture

- **App** (`Lectures/`, XcodeGen `project.yml`, iOS 26+, iPhone only, SwiftData).
  - `Audio/AudioPipeline.swift`: mic tap -> fixed 24 kHz mono -> AAC `.m4a` in Documents/Recordings, and -> the transcriber's format. Fixed format means AirPods in/out never breaks the file.
  - `Audio/LectureRecorder.swift`: session, interruptions (calls) and route changes restart the engine; saves the transcript every ~20 s.
  - `Speech/Transcription.swift`: Apple SpeechTranscriber (long-form, on-device), live with volatile results, plus whole-file re-transcription ("Redo from audio").
  - Transcript format: one `[m:ss] sentence` line per finalized result.
  - `Sync/LifeOSClient.swift`: LifeOS passcode -> `/api/unlock` (purpose widget) -> widget key in the Keychain (passcode never stored). Courses = active Canvas courses via `GET /api/lectures?courses=1`. Upload = `POST /api/lectures` (idempotent by lecture id). Edits/re-transcribes clear `uploadedAt` and re-send.
  - A lecture still "recording" at launch = app was killed mid-class -> marked ready/failed; audio is kept for Redo.
- **Server** (in `cmoney0/lifeos`): `api/_lectures.js`, routed by `widget-data.js` (`/api/lectures`); Supabase `public.lectures` (RLS on, service role only). School Claude project reads `GET /api/canvas/lectures?days=&course=&q=` and `GET /api/canvas/lecture/:id` with the existing `CLAUDE_READ_KEY`.
- **CI** `.github/workflows/ios.yml`: push to main = simulator compile; manual run with TestFlight = sign + upload (ONLY with Colby's approval). `ci/signing.py` + `ci/dist-cert.enc` copied from LifeOS (same ASC key -> same certificate).

## Flow (2026-11-05 redesign)

1. **Record** - Home button, the "Record lecture" Control Center / Lock Screen control, Action Button or Siri (`StartLectureIntent`, opens the app). No class picker and no calendar (Colby): Claude names the class from the transcript.
2. **While recording** - live transcript with Copy; Live Activity (Lock Screen + Dynamic Island) with Pause/Resume and Stop & send. Audio in 60 s chunks; transcript saved every ~15 s.
3. **Stop** - in the app: review-options sheet (length quick/standard/deep, type notes/exam/flashcards/summary, focus), auto-sends after 10 s with the last choices; from the Live Activity: sends at once with the saved defaults.
4. **Send** - `POST /api/lectures` with `requestReview` -> LifeOS rings the doorbell (comment on PR #1) -> the Reviewer session writes `review` JSON into `public.lectures` (REVIEWER.md) -> the app polls `GET /api/lectures?ids=` every 15 s while open.
5. **Home** - In progress cards with the 4 steps (Recorded / Transcribed / Sent / Review); finished lectures grouped by class. Detail: Review (summary, exam flags with tap-to-hear timestamps, sections, key terms), Cards (flip), Quiz (score + explanations), Transcript; menu: Export PDF, share to Claude app, redo review, continue recording, redo transcript.
6. **Crash** - a lecture still `recording` at launch becomes `interrupted`: Continue recording (appends, timestamps offset) or Finish & send. Orphaned Live Activities are ended at launch.

## Roadmap (Colby, 2026-11-05)

1. **External transcription option**: a per-lecture "Transcribe with cloud" choice for hard-to-hear classes, from the saved audio. The `engine` field already exists on both sides.
2. **Automatic review guides**: when a lecture lands in LifeOS, generate a review guide with Claude (needs the Claude API - a claude.ai project can't be triggered from outside), store it on the lecture (`reviewGuide` already in the app model; add a `review_guide` column) and show it in the app and on the class in LifeOS School.

## Next Build Queue

Last TestFlight build: **34** (cd9aa24, 2026-11-11, approved by Colby: "Okay build"). Shipped since build 24: review versions dropdown, AssemblyAI by default (Deepgram removed), Live Activity says "Recording stopped" only when LifeOS hears nothing for 75 s (push-driven, first Lectures build with Push Notifications), Settings > Last recording diagnostics, first unit tests.

Changes since then:
- Live Activity buttons react instantly: Pause / Play pulse (bloom, then a ring draws round and away, like the LifeOS habit logger); Stop pulses, the label turns "Saving lecture...", then "Saved - sending to Claude" with a check for ~2 s before it goes away (Colby via School HQ, 2026-11-14).

## 2026-11-05 - v1 app

### What Changed
- New repo + first version of the app, CI and signing (see Architecture).
### Why
- Colby wants a dedicated app to record classes and get them into his School Claude project.
### Design/Workflow Notes
- On-device chosen over sending audio to Claude: the Claude API takes no audio input, on-device is free/offline/private, and the audio is kept so a cloud pass can be added later.
- Profiles are `Lectures CI <target>`, never `LifeOS CI ...` (LifeOS signing deletes unknown `LifeOS CI` profiles).
### Tests/Verification
- 3fb089c: iOS workflow run 1 (42074963431) generated the project and compiled for the simulator - BUILD SUCCEEDED. Server routes live: `/api/lectures` answers 401 without a key (LifeOS PR #636, dc4fc98).
- Not yet run on a real phone (needs the first TestFlight build).

## 2026-11-05 - One-button redesign + Claude review pipeline

### What Changed
- Removed the class picker; added the Live Activity extension (`LecturesWidgets`: Live Activity + Record control), shared intents (`Lectures/Shared/LectureActivity.swift`), review options sheet, progress home, interactive review screens + PDF export, chunked audio + resume, polling for reviews. `REVIEWER.md` + PR #1 doorbell.
### Why
- Colby: one button, no class selection, choose review length/type, Claude (on his subscription, no API) reviews and sends it back sorted by class, see each step's progress, resume after a crash.
### Design/Workflow Notes
- Intents compile into both targets; bodies only under `LECTURES_APP` (Live Activity buttons and open-app intents run in the app process).
- `ci/signing.py` now signs `Lectures` + `LecturesWidgets` (bundle registered by the API if missing).
- The Reviewer must run in the lifeos environment (its setup script `cd`s into lifeos); it attaches lectures with add_repo.
### Tests/Verification
- 6eb14dc: iOS run 42090266929 BUILD SUCCEEDED (app + extension). Server: LifeOS PR #642. Reviewer reached Supabase (0 lectures). End-to-end doorbell test pending the Reviewer's push access.

## 2026-11-05 - First TestFlight build (7)

### What Changed
- `ci/signing.py`: the p12 password must stay `lifeos-ci` - the shared `dist-cert.enc` .p12 was made by LifeOS CI with it (run 3 failed at `security import`).
- `project.yml`: `UIRequiresFullScreen: true` - App Store validation rejects a portrait-only app otherwise (run 5: "include all orientations to support iPad multitasking").
### Tests/Verification
- Run 42094571872 (build 7): signed with the shared certificate, ARCHIVE SUCCEEDED, uploaded to TestFlight. Not yet opened on a phone.

## 2026-11-05 - Multi-select review types + upload RLS fix

### What Changed
- `ReviewOptions.type` -> `types: [String]` (at least one; order follows the list). Decoder accepts build 7's single `type`. Sheet and Settings toggle types. Upload sends `types` (+ `type` = first for old servers). `REVIEWER.md`: combine all picked types into one review.
- Server fix (no app change): uploads failed with "new row violates row-level security policy for table lectures" - the table had RLS on but no server policy. Added `lectures_server` (`lifeos_is_server()`, same as `iron_*`). The LifeOS server has no service-role key; it passes RLS with the `x-lifeos-server` header.
### Tests/Verification
- Server `cleanOptions` node test (dedupe, invalid dropped, legacy `type`). iOS compile: see the push run.

## 2026-11-05 - Delete lectures

### What Changed
- `Pipeline.delete` (audio, chunks, local record, LifeOS row) and `Pipeline.deleteAudio`; Delete in the lecture menu with a confirmation; Home long-press offers the same two choices. Deleting from the detail screen waits until it has closed (SwiftData must not render a deleted model).
### Tests/Verification
- iOS compile on push (see run).

## 2026-11-05 - iPad + in-depth study guides with slide figures

### What Changed
- Universal app (`TARGETED_DEVICE_FAMILY 1,2`; iPad all orientations; `UIRequiresFullScreen` removed again - iPad orientations satisfy validation).
- `Pipeline.syncFromLifeOS` (launch, foreground, pull-to-refresh): `GET /api/lectures?full=1` creates local copies of lectures from other devices (no audio) and updates reviews; removes audio-less copies that disappeared from LifeOS (deleted elsewhere). Never touches a lecture still recording/sending.
- New review type `guide`. `LectureReview.guide` (intro, sections{read, figures{fileId,page,caption}, fillIns with {{blanks}}}, problems{prompt, steps, answer}, sources). `GuideView`: readable width, `SlideFigure` renders the Canvas PDF page on device (PDFKit; deck downloaded once via `GET /api/lectures?file=<id>` -> 302 to Canvas, cached in Caches/Slides), `FillInBlock` (FlowLayout words + inline TextFields, Check / Show answers / score), `ProblemView` (PencilKit scratchpad, reveal steps one at a time, answer). iPad opens the Guide tab first.
- `REVIEWER.md`: guide job - reads slides through the LifeOS Canvas proxy with an `x-api-key` network credential (request_credential, Colby pastes the School project key once), picks real diagram pages by rendering and looking at them, PDFs only.
### Tests/Verification
- iOS compile on push (see run). Not yet on a device.

## 2026-11-05 - Swipe to delete on Home

### What Changed
- Home is now a `List` (inset grouped, Claude-theme backgrounds) instead of a ScrollView so rows get native `swipeActions`: swipe left -> Delete -> the same confirm (whole lecture or audio only). Rows use a hidden NavigationLink so the card keeps its own look; long-press still works; a lecture that is recording can't be deleted.

## 2026-11-05 - TestFlight build 13

### Tests/Verification
- Run 42112162040 (build 13, d2ab26a): archived, signed, uploaded. First build with the iPad target - Colby needs to install it on the iPad from TestFlight too.

## 2026-11-05 - Reviewer moved into the build session

### What Changed
- The 2:05 PM test lecture sat at "Waiting for Claude": Colby had asked the old reviewer for a sample review ("Advancements in AI (sample review)"), then tapped Redo review so the app would refetch it, but that reviewer was never subscribed (auto mode denied it push access), so nothing woke. Restored it to `ready` (the sample review was still stored).
- This build session subscribed to lectures PR #1 and is now the reviewer (REVIEWER.md updated); the blocked child reviewer was archived.

## 2026-11-05 - Home layout fix (build 13 List)

### What Changed
- Build 13's List Home put the Record button, in-progress cards and class rows at three different widths (16 pt row insets inside the inset-grouped margin vs zero) with big section gaps. Now every row has zero horizontal insets, the list has one 16 pt horizontal content margin, section spacing 14, headers aligned to the cards.
- The "Advancements in AI (sample review)" card stuck at Waiting was timing: the server flipped it to ready at 21:34:31, the minute of the screenshot; the app's 15 s poll / pull-to-refresh picks it up.

## 2026-11-09 - Crash alert + red-dot Live Activity

### What Changed
- Colby lost ~15 min of a lecture: the app crashed and the Live Activity kept looking like it was recording. An app can't notify at the moment it dies, so `LectureRecorder.armWatchdog` re-schedules a local notification (`CrashWatchdog`, id `recording-watchdog`) 75 s out every 20 s while recording; it is cancelled on Stop/Pause and at launch. If the process dies the re-scheduling stops and the notification fires. Tapping it -> `AppDelegate` -> `Pipeline.resumeLatestInterrupted()` (marks the lecture interrupted and Continue-records it; audio is chunked so <=60 s is lost before the crash).
- Live Activity content now carries `staleDate` = last heartbeat + 90 s (none while paused); the widget shows "Recording stopped" when `context.isStale`.
- Live Activity shows only a red dot - no timer anywhere (compact trailing is empty).
- Notification permission is asked once, at the first recording.
### Design/Workflow Notes
- A phone call pauses recording and can suspend the app, so a call longer than ~75 s may also trigger the alert - acceptable (recording really did pause).
- The crash itself is not diagnosed yet: TestFlight crash reports (App Store Connect > TestFlight > Crashes, or the TestFlight app's feedback) would show where.

## 2026-11-09 - Save-only fix, delete before sending, simpler Lock Screen

### What Changed
- Bug: "Just save, no review" still sent the lecture to Claude. Dismissing the options sheet cancels its `.task`; the countdown's `try? await Task.sleep` swallowed the cancellation, so the loop ran down instantly and called `send()`. Now the loop returns on cancellation and every action sets `decided` first (send/save/delete are one-shot).
- Options sheet: "Save only - no review" and "Delete recording" (confirm; deletes after the sheet closes).
- Live Activity: Lock Screen is one row (dot, state, icon-only circular pause/play + stop), no transcript; Dynamic Island expanded shows the dot/state and the same icon buttons.

## 2026-11-09 - Short titles + collapsible class sections

### What Changed
- `Lecture.courseShort` (synced from LifeOS `courseShort`, set by the server from the calendar title). `displayTitle`: review title ("Fluids 11/9 · Couette Flow", written by the Reviewer) else "Fluids 11/9" else the old title. `sectionName` groups Home by the short name.
- Home class sections collapse: `ClassHeader` (chevron, name, count) toggles; expanded set in `@AppStorage("expandedClasses")`; all start collapsed.

## 2026-11-09 - TestFlight build 18 shipped (approved)

### What Changed
- Uploaded **build 18** from main 717e7cf (Colby approved: "can you push changes for my voice recording app and this app aswell?"). Shipped:
- Home: finished lectures in collapsible class sections named by the short calendar class (Fluids, Controls, Materials) with a count; open sections are remembered. Titles read "Fluids 11/9 · Couette Flow" ("Fluids 11/9" while the review is on its way).
- Lock Screen Live Activity: no transcript line; one row with the dot, state and icon-only round buttons (pause/play, stop).
- After Stop: "Delete recording" (confirm) next to "Save only - no review". Fixed: "Save only" sometimes still sent to Claude.
- Live Activity: just a red recording dot (no timer) on the Lock Screen and Dynamic Island; gray when paused; "Recording stopped" with a hollow dot if the app dies.
- Crash alert: if the app dies while recording, a "Lectures stopped recording" notification arrives within ~75 s; tapping it reopens the app and continues the same lecture.
- Home layout fix: Record button, in-progress cards and class groups share one width and 16 pt gutter; tighter section spacing.

### Tests/Verification
- iOS workflow run 42689377749 (testflight: true) green: archive succeeded, "Uploaded build 18".

### Files Touched
- `PROJECT_NOTES.md` (Next Build Queue cleared).

## 2026-11-09 - Action items -> LOS

### What Changed
- Colby: lectures should surface things to add to LifeOS (homework, exams, quizzes...) and LOS should ping him to approve them, e.g. make the class calendar event red with EXAM/QUIZ first.
- REVIEWER.md step 7 + `actionItems` schema (kind task/exam/quiz/reading/deadline/info, date/time America/Chicago, `proposal` = exact LifeOS task or calendar edit). When there are items the Reviewer posts ONE `Claude → LOS:` comment on lifeos PR #634 and adds a dated line to LOS-NOTES.md "Claude → LOS" (lifeos main via PR). LOS reviews with Colby; tasks go in through its agent link, calendar edits come back as a LOS note for Claude (Google Calendar connector). Calendar convention: exam/quiz = class event retitled `EXAM · <Short>` / `QUIZ · <Short>`, colored red.
- App: `LectureReview.actionItems` + `ActionRow` card at the top of Review (exams/quizzes red), PDF lists them.

## 2026-11-09 - Cloud transcription in the app

### What Changed
- `TranscriptionEngine` (Settings picker, saved in UserDefaults). `Lecture.transcriptEngine` / `cloudError`.
- Stop: merge audio first, then (cloud engine) `Pipeline.cloudTranscribe(forReview: true)` = upsert lecture, upload audio to the signed URL (PUT, x-upsert), start the job - then the review request. On failure the lecture falls back to on-device and the review is re-requested (server rings then).
- Lecture menu "Transcribe with..." (any engine, any lecture with audio); Transcript tab: segmented On-device / engines with status (words / transcribing / failed).
- Recording bitrate 48 -> 32 kbps; merge uses passthrough export (fallback AppleM4A re-encode) - smaller files, faster, under OpenAI's 25 MB.

## 2026-11-10 - OpenAI dropped from the app

- Colby has no OpenAI billing, so the engine picker and "Transcribe with..." offer only AssemblyAI and Deepgram (`TranscriptionEngine` has no `.openai`). LifeOS's server still accepts `openai` if it's ever wanted again.

## 2026-11-10 - TestFlight build 24 (cloud transcription)

- Before building: Vercel had both keys but they postdated the last deploy; redeployed (LifeOS PR #714) and `GET /api/lectures?engines=1` returned AssemblyAI ok (200) and Deepgram ok (200).
- Run 42847585618: archived + uploaded. LifeOS build 151 shipped in the same go.

## 2026-11-10 - Review versions (v1, v2... tagged by transcript)

### What Changed
- Every finished transcript (on-device or cloud) now gets its own review, saved as the next version by a Supabase trigger (`lecture_reviews`, migration `lecture_review_versions`). LifeOS returns them as `reviews` in the `?ids` and `?full` sync (lifeos PR #717).
- App: `ReviewVersion` + `Lecture.reviewVersionsJSON`, stored in `Pipeline.apply`; `LectureDetailView` shows a "v2 · AssemblyAI ▾" menu above the tabs when there are 2+ versions, and every tab (and Export PDF) follows the picked version.
- REVIEWER.md: write from `review_engine`'s transcript; never edit `lecture_reviews`.
- LifeOS skips the automatic review when a cloud transcript has under 40% of the on-device words (Deepgram returned 0-550 words on 4 of 5 lectures).

### Files Touched
`Lectures/Model/Lecture.swift`, `Lectures/Sync/LifeOSClient.swift`, `Lectures/App/LecturesApp.swift`, `Lectures/Views/LectureDetailView.swift`, `REVIEWER.md`.

### Design/Workflow Notes
- The trigger only fires on a status change INTO `ready`, so a re-review must go `working` first (REVIEWER.md already claims rows that way).

### Tests/Verification
- iOS compile on push (f4546d5).

## 2026-11-10 - Review A/B: on-device vs AssemblyAI transcript (5 lectures)

### What Changed
- Wrote a fresh v2 review from the AssemblyAI transcript for all 5 lectures (blind, same REVIEWER.md prompt and options) and compared each to v1 (on-device). Controls 11/9 got both v1 and v2 today. Comparison files were scratch only.

### Findings
- Concepts, equations and course terms: the same in both. Claude repairs garbled on-device text well ("native situations" -> Navier-Stokes, "sharpie / happy test" -> Charpy, "KRC man's life" -> K(r - y)).
- What it cannot repair is information the on-device transcript lost outright: Fluids 11/9 HW 4 announcement (v1 missed it entirely), Fluids exam scope, Controls 11/9 "Fourier transforms are in the homework", Controls 11/6 pole -1/2 heard as -5 (v1 built a wrong quiz question on it), Materials "practice for the quiz" and "grades Friday".
- Verdicts: 1 material (Fluids 11/9), 3 minor, 1 none-minor. Cloud lost a few small details on-device kept (closing transform list, "memorize these assumptions").
- 3 of 5 AssemblyAI rows were still giant speaker turns in the table (no usable timestamps) -> lifeos PR #719 re-splits them on the next `?full` sync.
- Deepgram: 0-550 words on 4 of 5 lectures even with the words-based parser (Materials 3,700 OK) - not usable; lifeos PR #718 skips auto-reviews for such transcripts.

### Recommendation
- AssemblyAI as the default engine (about $0.15-0.45/hr, roughly $15-45 a semester, mostly inside the free credit); on-device stays the live view and fallback. Drop Deepgram.

## 2026-11-10 - AssemblyAI for every lecture + no Canvas doubles

### What Changed
- `TranscriptionEngine` is now AssemblyAI (default) or "On-device only"; the setting moved to `transcriptionEngine.v2` so everyone starts on AssemblyAI. Deepgram is gone from the app (LifeOS still serves it); `TranscriptionEngine.name()` labels old deepgram/openai rows.
- REVIEWER.md step 7: Canvas owns homework. The doorbell lists "Already tracked" (Canvas assignments + open LifeOS tasks for the class, lifeos PR #721); matches are marked "Already in LifeOS (Canvas)" and never sent to LOS, a different spoken date becomes a Q:, not-yet-posted homework is "Watch", never "Add task".

### Files Touched
`Lectures/Model/Lecture.swift`, `Lectures/Views/LectureDetailView.swift`, `Lectures/Views/SettingsView.swift`, `REVIEWER.md`.

### Tests/Verification
- iOS compile on push (e2af8eb).

## 2026-11-10 - iPad: no more left-half launches

### What Changed
- New `Lectures/App/WindowFit.swift`, attached behind the root view in `LecturesApp.swift`: an invisible view that keeps the window (and the root view inside it) the size of its window scene - checked at launch, on every `effectiveGeometry` change (KVO), every layout pass, and on becoming active (plus re-checks at 0.15 / 0.5 / 1.2 s while the launch settles).
### Why
- Colby: on iPad, about half the launches drew the app in only the left half of the screen until he relaunched.
### Design/Workflow Notes
- Cause not proven (no iPad to reproduce on). iPadOS 26 can open an app in a partial window during the launch and then resize it; the app sometimes stayed laid out at that first size. The fix is a no-op whenever the sizes already match (always on iPhone).
- If it still happens on the next build: check whether the right half shows the wallpaper/another app (a real half-size window from Windowed Apps / Stage Manager tiling - a Multitasking setting, not the app) or the app's own background (a layout bug - next step would be enabling multiple scenes).
### Tests/Verification
- 1819e7a: branch compile run 42882731661.

## 2026-11-11 - Live Activity said "Recording stopped" while still recording

### What Changed
- New `Lectures/Shared/LiveActivityPolicy.swift` (app + widget + tests): heartbeat 20 s, crash notification 75 s, Live Activity stale only after **15 min** (was 90 s); `LiveActivityMode` recording / paused / noSignal ("No signal - open Lectures to check", never "stopped"); `HeartbeatLog` of gaps.
- `LectureRecorder`: uses the policy, logs every heartbeat (`RecordingDiagnostics`, shown in Settings > Last recording: heartbeats, longest gap, Live Activity state), refreshes the Live Activity the moment the app becomes active.
- Widget uses `LiveActivityMode`. Info.plist `NSSupportsLiveActivitiesFrequentUpdates`.
- First test target `LecturesTests` (XCTest, no host) + CI step "Unit tests (simulator)" on every push; CI paths now include LecturesWidgets/** and LecturesTests/**.

### Why
- Reported by Colby via School HQ: the Lock Screen said "Recording stopped" but the app was still recording. The Live Activity went stale 90 s after the last refresh that landed; with the phone locked iOS does not promise a backgrounded app's Live Activity refreshes land on time, so one late refresh looked like a crash. The local crash notification (not throttled) is the real crash alarm and did not fire, so the app really was alive.

### Manual test on the phone (next build)
1. Record, lock the phone 10+ min: Lock Screen keeps the red dot; then open Settings > Last recording - note the longest gap.
2. Record, switch to another app 5 min, come back: still recording, no "no signal".
3. Pause from the Lock Screen 5 min, resume: gray dot while paused, red again after.
4. Phone call or Siri mid-recording, then back: recording continues, transcript keeps growing.
5. Swap AirPods in/out mid-recording: keeps recording.
6. Force-quit while recording: "Lectures stopped recording" notification within ~75 s; Lock Screen shows "No signal" by 15 min; reopening clears it and offers resume.

### Tests/Verification
- CI compile + unit tests (see commit).

## 2026-11-11 (later) - Live Activity: LifeOS decides "stopped" (replaces the 15-min window)

### What Changed
- Colby: the 15-min window was a patch ("there's a way for this to work perfectly"); he got NO crash notification when the Lock Screen said stopped, so the app was alive and only its local Live Activity refreshes weren't landing.
- App never sets a stale date and only updates the Live Activity on start / pause / resume / stop. `ContentState.lost` (set only by LifeOS) is the one thing that shows "Recording stopped - tap to resume".
- App heartbeats LifeOS (`POST /api/lectures?live=1`: id, state recording/paused/ended, the activity's APNs push token, startedAt) every 20 s, on pause/resume/stop, and the moment the network comes back (NWPathMonitor). Leftover activities from a crash are ended on launch and reported "ended".
- LifeOS (lifeos repo `api/_lectures.js`): `lecture_live` table; `?live=tick` (server key) from pg_cron every 10 s marks a recording lost after 75 s of silence and pushes the Live Activity with `lost: true` (apns-expiration 0, re-sent every 30 s up to 2 h, so a phone that was only offline never gets a late "stopped"); the next heartbeat pushes it back to recording.
- `aps-environment: production` entitlement; `ci/signing.py` turns on Push Notifications for com.cmoney0.lectures through the ASC API and rebuilds the profile until it carries aps-environment. Without push the activity still starts (fallback), just without the server backstop.
- Local "Lectures stopped recording" notification unchanged (offline backup).
- Tests rewritten: 18 cases (regression of the old 90 s rule, no stale date ever, server lost timing, decoding LifeOS's stopped / heal pushes in Apple-epoch dates, heartbeat log).

### Server status
- Supabase migration `lecture_live_heartbeat` applied 2026-11-11 with Colby's OK and verified end to end (cron -> LifeOS -> APNs within 10 s). Rows whose token Apple rejects are ended (lifeos #746).

### Tests/Verification
- CI compile + unit tests (see commit).

## 2026-11-14 - Live Activity tap animations

### What Changed
- New `Lectures/Shared/LiveActivityTap.swift` (app + widget + tests): `LectureTap` / `LectureTapAnim` / `LectureTapRing`, copied from LifeOS's LOSTap / LOSTapAnim / LOSTapRing (lifeos PR #768) - the apps don't share code.
- `ContentState` gains `tap`, `stopping`, `saved` (all optional, old states still decode).
- `LectureRecorder.pulse(_:)`: the intent puts step 0 (bloom) into the activity at once, then rings on / away / idle (260 / 800 / 760 ms). Pause and Stop pulse; Stop shows "Saving lecture..." while it finishes, holds until the pulse has played, then ends with "Saved - sending to Claude" (check icon) and dismisses after 2 s.
- Widget buttons: ring drawn behind each button, `.invalidatableContent()` on the icons, symbol replace on pause/play.
- `LiveActivityMode` gains `.saving` / `.saved`. 5 new unit tests (23 total).

### Why
- Colby: "there needs to be some animations right away as you click the buttons ... pulsing and loading ... exactly how the habit logger animations are." LOS - Real App flagged the Lectures buttons as having no feedback.

### Tests/Verification
- CI compile + unit tests (see commit).

