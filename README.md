# mac-core-temp-watch

A lightweight native macOS menubar app that monitors CPU temperature, battery temperature, real-time CPU clock frequency, and thermal pressure on Apple Silicon Macs — with a one-click **Boost Mode** that squeezes up to 13% more performance out of your CPU.

![Swift](https://img.shields.io/badge/Swift-5.9+-orange) ![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green)

## What it shows

```
CPU: 48°C 2.1GHz | Bat: 31°C
```

When Boost Mode is active:

```
⚡ CPU: 62°C 3.8GHz | Bat: 35°C
```

Click the menubar item for a detailed dropdown:

```
CPU Temperature:      48°C
P-Cluster Frequency:  2.1 GHz
E-Cluster Frequency:  0.8 GHz
Battery Temperature:  31°C
Thermal: Nominal
───────────────────────
Status: Normal
───────────────────────
⚡ Enable Boost          ⌘B
───────────────────────
Quit TempMonitor
```

## Boost Mode

One-click performance boost for CPU-intensive work. Verified **13% throughput improvement** on sustained workloads via A/B benchmarking.

**What it does:**

| Action | Why |
|---|---|
| Purge disk cache | Reduce memory pressure and CPU overhead from memory compression |
| Pause Spotlight indexing | Stop background CPU and I/O competition |
| Pause Time Machine | Free disk I/O bandwidth |
| Power assertion | Prevent idle throttling during intensive work |

**How it works:** On fanless Macs (MacBook Air), the CPU has a limited thermal budget — it can only sustain peak frequency for so long before throttling. Every background process eating CPU shortens that window. Boost Mode silences background consumers so your thermal budget goes entirely to your work.

- Requires admin password (one prompt per toggle)
- Fully reversible — un-boost restores everything
- Spotlight and Time Machine resume automatically if the app quits
- Cmd+B keyboard shortcut

## Features

- **Boost Mode** — 13% more CPU throughput with one click
- **Thermal monitoring** — real-time pressure level (Nominal/Moderate/Heavy/Critical)
- **Truly lightweight** — 168K binary, ~12MB RAM, 0.0% CPU
- **Zero dependencies** — no Xcode project, no Swift packages, no third-party libs
- **Single file** — entire app is one Swift file compiled with `swiftc`
- **Battery-friendly** — sampling runs on E-cores via utility QoS
- **Zero memory leaks** — verified with `leaks` tool
- **Max-of-all-cores temp** — reads all 13 CPU sensors, reports the hottest
- **No network, no file writes, no data collection**
- **Apple Silicon native** — arm64, tested on M3

## Requirements

- macOS 14+
- Apple Silicon (M1/M2/M3/M4)

## Install

Download the DMG from [Releases](../../releases), open it, and drag `TempMonitor.app` to your Applications folder.

Or build from source:

```bash
git clone https://github.com/adiKhan12/mac-core-temp-watch.git
cd mac-core-temp-watch
./build.sh
open build/TempMonitor.app
```

## Build from source

```bash
./build.sh
```

```
=== TempMonitor Build ===
[1/4] Compiling...        168K binary
[2/4] Creating app bundle...
[3/4] Code signing...     valid on disk
[4/4] Creating DMG...     72K
```

Output: `build/TempMonitor.dmg`

## How it works

| Component | Method |
|---|---|
| CPU temp | SMC via IOKit — reads all detected cores, reports max |
| Battery temp | SMC via IOKit (TB1T/TB2T/TB0T keys) |
| CPU frequency | IOReport DVFS residency sampling (no root needed) |
| Thermal pressure | Darwin notify API (`com.apple.system.thermalpressurelevel`) |
| Boost Mode | Memory purge + Spotlight/TM pause + power assertion (admin prompt) |

The app probes for available sensor keys at startup since they vary across Mac models. Temperature values are bounds-checked (-20 to 150°C) and the byte order is handled for both Apple Silicon (little-endian) and Intel (big-endian).

## Architecture

```
TempMonitor.swift (single file, ~750 lines)
├── SMC Types & Byte Conversion
├── SMCClient (IOKit connection)
├── TemperatureReader (multi-core sensor probing)
├── FrequencyReader (IOReport DVFS sampling)
├── ThermalMonitor (Darwin notify API)
├── BoostManager (privileged commands via osascript)
├── MenuBarController (NSStatusItem + NSMenu)
└── AppDelegate (timer, wiring, boost toggle)
```

## License

MIT
