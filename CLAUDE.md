# Claude Code Instructions For Lectures

Colby's class-recording iPhone app (SwiftUI, iOS 26+). It records a lecture, transcribes it live **on-device** (Apple SpeechAnalyzer), keeps the audio on the phone, and sends the transcript to **LifeOS** (`cmoney0/lifeos`), where his School Claude project reads it.

Read `PROJECT_NOTES.md` before meaningful work and add a dated entry after every change (what / why / files / verification + commit).

## Rules

- **Same response style as LifeOS:** start with a `---` line, short bold `##` sections, concise, plain-language outcomes, no pasted code unless asked, a crisp recommendation.
- **TestFlight needs Colby's explicit approval, every time.** Never start the workflow's manual run with `testflight: true` on your own. End every reply with a **Next build** list of changes since the last TestFlight build (kept in `PROJECT_NOTES.md` > Next Build Queue). List **only Lectures changes** there - never LifeOS native changes, even in a session that also has LifeOS open (Colby, 2026-11-05).
- Land finished work on `main` (standing permission; on a pinned web-session branch push it, open a PR to `main`, merge it).
- There is no Mac, and **no automatic CI** (Colby, 2026-11-14: macOS runner minutes cost credits). The iOS workflow is manual-only: never start a run (compile or TestFlight) unless Colby asks. Swift changes are checked at the next build he approves - review them carefully before pushing.
- Target Colby's iPhone 18 Pro Max (440 x 956 pt). Style = LifeOS Claude theme: warm gray surfaces, Claude-orange accent `#C96442`, Manrope (`Lectures/Views/Theme.swift`).
- Server side lives in LifeOS: `api/_lectures.js` (upload + review request + doorbell, `/api/lectures`, widget key) and `api/canvas-proxy.js` routes `lectures` + `lecture/:id` (School project, `CLAUDE_READ_KEY`). Supabase table `public.lectures`.
- **PR #1 "Lectures inbox" is a doorbell: NEVER merge or close it.** LifeOS comments on it per review request; the "Lectures - Reviewer" session (subscribed) follows `REVIEWER.md`.
- No class picker or calendar in the app (Colby): Claude names the class from the transcript.
- Signing: `ci/signing.py` is a copy of LifeOS's. Profiles are named `Lectures CI <target>` - never `LifeOS CI ...` (LifeOS's signing deletes unknown `LifeOS CI` profiles).
