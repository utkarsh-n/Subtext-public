import Foundation

// Entry point. Run via Tools/synctest.sh.
//
//   SCENARIOS=v1 (default)   the V1 table, wrong-film check, cost line, matcher probes
//   SCENARIOS=checkin        a package suite: `synctest_suite_<name>` looked up by name
//   SCENARIOS=v1,presence    several, in order
//   SCENARIOS=all            v1 then every known suite that is compiled in
//   DEBUG=1 per-analysis output · WINDOW=30 analysis window · KILL=300 kill clock override
//
// Only this file may contain top-level statements.

let requested = (ProcessInfo.processInfo.environment["SCENARIOS"] ?? "v1")
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    .filter { !$0.isEmpty }

// Synthesise the film first so its line prints before any table.
_ = film

for suite in requested {
    switch suite {
    case "v1":
        runV1Scenarios()
    case "all":
        runV1Scenarios()
        for name in knownSuites where runSuite(name) {}
    default:
        if !runSuite(suite) {
            print("Unknown scenario suite '\(suite)'. Known: v1, all, \(knownSuites.joined(separator: ", ")) (when compiled in).")
        }
    }
}
