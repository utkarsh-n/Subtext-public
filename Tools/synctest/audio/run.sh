#!/bin/zsh
# WP1 SampleRing checks, standalone (macOS, swiftc only; no other harness file needed).
# The same checks run inside the harness with: SCENARIOS=audio Tools/synctest.sh
set -e
cd "$(dirname "$0")/../../.."
mkdir -p Tools/synctest/out
swiftc -O -o Tools/synctest/out/sampleringtest \
  Subtext/Sync/Logic/SampleRing.swift \
  Tools/synctest/ScenariosAudio.swift \
  Tools/synctest/audio/main.swift
Tools/synctest/out/sampleringtest
