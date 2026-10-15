#!/bin/zsh
# Builds the sync engine as a macOS CLI with a synthetic film and runs the scenarios.
#
# The compile list is globs, so packages add files without editing this script:
#   Subtext/Sync/Logic/**      pure sync logic (scheduler, presence, memory extensions)
#   Shared/Presentation/**     Foundation-only presenter / layout logic (no SwiftUI/WidgetKit)
#   Tools/synctest/*.swift     Film, Room, Runner, ScenariosV1 and one Scenarios<Package>.swift each
# Usage: Tools/synctest.sh            (SCENARIOS=v1 by default; see Tools/synctest/main.swift)
set -e
setopt NULL_GLOB
cd "$(dirname "$0")/.."
mkdir -p Tools/synctest/out
swiftc -O -o Tools/synctest/out/synctest \
  Shared/SyncPhase.swift \
  Shared/IslandState.swift \
  Shared/Presentation/**/*.swift \
  Subtext/Models/SubtitleTrack.swift \
  Subtext/Playback/PlaybackClock.swift \
  Subtext/Sync/SpeechEnvelope.swift \
  Subtext/Sync/VoiceActivityDetector.swift \
  Subtext/Sync/Correlator.swift \
  Subtext/Sync/TranscriptMatcher.swift \
  Subtext/Sync/SyncTracker.swift \
  Subtext/Sync/MicRing.swift \
  Subtext/Sync/Logic/**/*.swift \
  Tools/synctest/*.swift
Tools/synctest/out/synctest
