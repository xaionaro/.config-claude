---
name: android-device
description: Use when working with Android phones or tablets — fastboot, adb, flashing, kernel updates, device debugging, on-device experiments, benchmarks, perf measurement.
---

# Android Device Operations

Routine health checks/fixes happen in-place in the current session — no separate agent needed.

**User data is sacred.** `fastboot erase userdata`, `fastboot erase metadata`, `fastboot -w`, and factory reset require explicit user request. Erasing user data is never a side effect of another operation.

**Avoid `adb forward` / `adb reverse` unless necessary.** Device usually reaches the host directly over LAN — use the host IP. Tunnels add hidden state, mask real connectivity issues, and break when adbd restarts. Justify every `forward`/`reverse` (e.g. USB-only device, no routable network).

## Experiment Hygiene

**Hard gate: never start an experiment until every health check in section 1 passes.** No exceptions for "probably fine" or "just a quick run." A single FAIL contaminates results.

Pipeline: **health-check → remediate → re-check → baseline snapshot → run → verify → cleanup**. Skip health → contaminated results. Skip cleanup → device left dirty.

### 1. Health check + remediate (gate)

Check each row. If FAIL: apply fix, re-check, repeat until PASS. Only when **every** row passes may the run start.

| Check | Command | Pass | Fix on FAIL |
|-------|---------|------|-------------|
| CPU load | `adb shell uptime` | 1-min load < ~0.5/core | Find culprit via `top -n1 -b -m5`; kill (`am force-stop <pkg>` or `kill <pid>`); wait |
| Hot procs | `adb shell top -n1 -b -m5` | No non-test app > 5% | `am force-stop <pkg>`; disable sync/updates |
| Thermal | `adb shell dumpsys thermalservice \| grep -i status` | `THROTTLING_NONE` | Cool down: screen off, idle ≥60s, re-poll until clear |
| Battery temp | `adb shell dumpsys battery \| grep temp` | < 35°C | Wait; unplug if charging |
| Battery level | same | ≥ 50% | Charge to ≥50%, then unplug before run (charging skews power numbers) |
| Memory | `adb shell cat /proc/meminfo` | MemAvailable healthy | `am kill-all`; drop caches if root |
| Doze / idle | `adb shell dumpsys deviceidle get deep` | `ACTIVE` (unless testing doze) | `dumpsys deviceidle unforce` |
| Screen state | `adb shell dumpsys power \| grep mWakefulness` | Matches intended | `input keyevent KEYCODE_WAKEUP` / `KEYCODE_SLEEP` |
| Crash handlers | `adb shell pgrep -a crash_dump64` (fallback: `adb shell ps -A \| grep '[c]rash_dump64'` if pgrep unavailable) | no output | Investigate crashes before flashing/benchmarking; never report success while crash_dump64 is running. |

Snapshot the passing values to a file → diff against post-run.

### 2. Stabilize for run

| Goal | Action (record original, restore after) |
|------|-----------------------------------------|
| No bg sync / radios | airplane mode or `svc data disable` |
| Logcat clean | save existing buffer if needed, then `adb logcat -c` |
| Governor | `cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`; pin only if required |
| Wait between runs | poll thermal until `THROTTLING_NONE` + battery temp ≤ baseline+1°C |

### 3. Post-experiment verify

Re-run section 1. Compare to snapshot.

| Delta | Meaning → action |
|-------|------------------|
| CPU still elevated | Leaked process → kill |
| Thermal throttling | Cool-down before next run |
| MemAvailable dropped | Leak → heap dump before cleanup |
| Battery temp ↑↑ | Cool-down required |

### 4. Cleanup (mandatory)

Track every mutation; reverse each.

| Mutation | Reversal |
|----------|----------|
| Files in `/data/local/tmp/...` | `rm -rf <exact paths>` (never glob `/data/local/tmp/*`) |
| Installed test apps | `adb uninstall <pkg>` |
| Spawned procs | `pkill -f <pattern>`; confirm via `ps -A` |
| `settings put` / `setprop` | Restore recorded value |
| Pinned governor | Restore recorded governor |
| Airplane mode / data | Restore recorded state |
| Logcat buffer size | Restore default |
| `deviceidle force-idle` | `deviceidle unforce` |
| Wakelocks | Release; check `dumpsys power` |

Re-run section 1; must match pre-experiment snapshot within tolerance. Mismatch → investigate, never hand device back dirty.
