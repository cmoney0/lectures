# Lectures - Project Notes

Durable memory for every Claude session. Newest entries at the bottom of each section.

## Current Status

- v1 app built 2026-11-05; compiles in CI. **No TestFlight build yet** (needs Colby's approval + the App Store Connect app record for `com.cmoney0.lectures`).

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

## Roadmap (Colby, 2026-11-05)

1. **External transcription option**: a per-lecture "Transcribe with cloud" choice for hard-to-hear classes, from the saved audio. The `engine` field already exists on both sides.
2. **Automatic review guides**: when a lecture lands in LifeOS, generate a review guide with Claude (needs the Claude API - a claude.ai project can't be triggered from outside), store it on the lecture (`reviewGuide` already in the app model; add a `review_guide` column) and show it in the app and on the class in LifeOS School.

## Next Build Queue

Changes since the last TestFlight build (none yet):
- v1: record + live on-device transcript, lock-screen recording, course picker from Canvas, playback with tap-to-seek timestamps, Redo from audio, share/copy to Claude, auto-send to LifeOS.

## 2026-11-05 - v1 app

### What Changed
- New repo + first version of the app, CI and signing (see Architecture).
### Why
- Colby wants a dedicated app to record classes and get them into his School Claude project.
### Design/Workflow Notes
- On-device chosen over sending audio to Claude: the Claude API takes no audio input, on-device is free/offline/private, and the audio is kept so a cloud pass can be added later.
- Profiles are `Lectures CI <target>`, never `LifeOS CI ...` (LifeOS signing deletes unknown `LifeOS CI` profiles).
### Tests/Verification
- See commit history / iOS workflow runs.
