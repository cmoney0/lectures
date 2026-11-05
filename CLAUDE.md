# Claude Code Instructions For Lectures

Colby's class-recording iPhone app (SwiftUI, iOS 26+). It records a lecture, transcribes it live **on-device** (Apple SpeechAnalyzer), keeps the audio on the phone, and sends the transcript to **LifeOS** (`cmoney0/lifeos`), where his School Claude project reads it.

Read `PROJECT_NOTES.md` before meaningful work and add a dated entry after every change (what / why / files / verification + commit).

## Rules

- **Same response style as LifeOS:** start with a `---` line, short bold `##` sections, concise, plain-language outcomes, no pasted code unless asked, a crisp recommendation.
- **TestFlight needs Colby's explicit approval, every time.** Never start the workflow's manual run with `testflight: true` on your own. End every reply with a **Next build** list of changes since the last TestFlight build (kept in `PROJECT_NOTES.md` > Next Build Queue).
- Land finished work on `main` (standing permission; on a pinned web-session branch push it, open a PR to `main`, merge it).
- There is no Mac: the iOS workflow compiles on every push to `main`. Check its result after pushing Swift changes.
- Target Colby's iPhone 18 Pro Max (440 x 956 pt). Style = LifeOS Claude theme: warm gray surfaces, Claude-orange accent `#C96442`, Manrope (`Lectures/Views/Theme.swift`).
- Server side lives in LifeOS: `api/_lectures.js` (upload, `/api/lectures`, widget key) and `api/canvas-proxy.js` routes `lectures` + `lecture/:id` (School project, `CLAUDE_READ_KEY`). Supabase table `public.lectures`.
- Signing: `ci/signing.py` is a copy of LifeOS's. Profiles are named `Lectures CI <target>` - never `LifeOS CI ...` (LifeOS's signing deletes unknown `LifeOS CI` profiles).
