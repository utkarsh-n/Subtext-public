import Foundation

// Standalone entry for the WP1 SampleRing checks (the checks themselves live in
// Tools/synctest/ScenariosAudio.swift, which is also compiled into the harness as the `audio`
// suite). This file lives one level below the harness glob so its top-level statements do not
// collide with Tools/synctest/main.swift. Run via Tools/synctest/audio/run.sh.

exit(SampleRingChecks.run() == 0 ? 0 : 1)
