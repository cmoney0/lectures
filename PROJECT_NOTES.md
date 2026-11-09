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

Last TestFlight build: **13** (d2ab26a, 2026-11-05, approved by Colby: "okay build it"). Shipped since build 7: multi-select review types, delete (swipe / menu / long-press, whole lecture or audio only), recording time on Home rows, iPad app + LifeOS sync + in-depth study guides (slide figures, fill-ins, problems + Pencil scratchpad, PDF).

Changes since then:
- Live Activity: just a red recording dot (no timer) on the Lock Screen and Dynamic Island; gray when paused; "Recording stopped" with a hollow dot if the app dies.
- Crash alert: if the app dies while recording, a "Lectures stopped recording" notification arrives within ~75 s; tapping it reopens the app and continues the same lecture.
- Home layout fix: Record button, in-progress cards and class groups share one width and 16 pt gutter; tighter section spacing.

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
