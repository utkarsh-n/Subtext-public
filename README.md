# Subtext

Live subtitles in the Dynamic Island, Lock Screen and Apple Watch for whatever is playing on
the TV. The phone listens to the room, works out where you are in the subtitle track, and keeps
the current line in step. No connection to the player is needed.

## How sync works

1. **Voice activity** – `Sync/VoiceActivityDetector.swift` marks each 10 ms of microphone audio as
   speech or silence (rolling-percentile noise floor, recent-peak reference, hangover).
2. **Envelope + onsets** – `Sync/SpeechEnvelope.swift` turns both the subtitle track and the heard
   audio into two signals: an on/off speech envelope and a train of speech onsets (someone starts
   talking after a pause ↔ a cue appears after a gap).
3. **Correlation** – `Sync/Correlator.swift` slides the heard window along the track with vDSP and
   scores both signals. Acceptance uses an onset z-statistic that scales with evidence, so a wrong
   film never passes (measured in `Tools/synctest`).
4. **Tracking** – `Sync/SyncTracker.swift` runs the state machine: searching → candidate → locked →
   drifting. Once locked it only searches ±3 s, and a least-squares fit of media time against wall
   time learns the playback rate (PAL 25/23.976 transfers, 1.5× speed-watching).
5. **Speech hints** – `Sync/LiveTranscriber.swift` streams the mic through the on-device iOS 26
   `SpeechAnalyzer`; `Sync/TranscriptMatcher.swift` matches a few recognised words to cue text to
   narrow the search. Cuts first lock from ~30 s to ~15 s when audio and subtitle language agree.

Manual controls always win: ±0.1/±0.5/±1 s steppers and Re-sync in the island, a haptic scrub
wheel, "Tap the line you hear", and "Set position" in the app.

## Build

```bash
xcodegen generate
xcodebuild -project Subtext.xcodeproj -scheme Subtext -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Device: `xcodebuild -destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM_ID build`
then `xcrun devicectl device install app --device <udid> build/Build/Products/Debug-iphoneos/Subtext.app`.

Debug launch arguments: `-importSubtitles /path/file.srt` loads a track at launch;
`-recordMic` saves the first 40 s of microphone audio to Documents/mic.caf.

## Sync test harness

`Tools/synctest.sh` compiles the sync engine as a macOS CLI, synthesises a six-minute film from
made-up dialogue with the system voice, writes the matching `film.srt`, then plays "the room"
into the tracker from random points, with noise, PAL speed-up, 1.5× playback, long gaps and
speech hints. It also checks that a different film with the same statistics never locks.
Set `DEBUG=1` for per-analysis output, `WINDOW=30` to change the analysis window.

## OpenSubtitles

Searching needs an API key (register a consumer at opensubtitles.com/consumers); downloading needs
a login. Both are entered in Settings and stored in the keychain. Subtitle text is not public
domain; the app goes through the licensed API and never bundles subtitle content.

## Real-room test

Play a film with a known subtitle file, start the session on the phone within earshot, and watch
the status pill: Listening → Searching → Locked. First lock takes 15–45 s depending on how
distinctive the dialogue rhythm is. If the audio language differs from the subtitle language, turn
off "Use speech to find the scene"; the rhythm match still works.


## Public snapshot

See [PUBLICATION.md](PUBLICATION.md) for publication exclusions and setup requirements.
