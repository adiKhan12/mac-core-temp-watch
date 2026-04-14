# mac-core-temp-watch

A lightweight native macOS menubar app that monitors CPU temperature, battery temperature, and real-time CPU clock frequency on Apple Silicon Macs.

![Swift](https://img.shields.io/badge/Swift-5.9+-orange) ![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green)

## What it shows

```
CPU: 48°C 2.1GHz | Bat: 31°C
```

- **CPU Temperature** — read directly from the SMC (System Management Controller)
- **CPU Frequency** — real-time P-cluster speed via IOReport DVFS sampling
- **Battery Temperature** — from SMC battery sensors
- **Color-coded** — green (normal), orange (warm), red (hot)

Click the menubar item for a detailed dropdown:

```
CPU Temperature:      48°C
P-Cluster Frequency:  2.1 GHz
E-Cluster Frequency:  0.8 GHz
Battery Temperature:  31°C
───────────────────────
Status: Normal
───────────────────────
Quit TempMonitor
```

## Features

- **Truly lightweight** — 144K binary, ~12MB RAM, 0.0% CPU
- **Zero dependencies** — no Xcode project, no Swift packages, no third-party libs
- **Single file** — entire app is one Swift file compiled with `swiftc`
- **Battery-friendly** — sampling runs on E-cores via utility QoS
- **Zero memory leaks** — verified with `leaks` tool
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

This compiles the app, creates the `.app` bundle, code-signs it (ad-hoc), and packages a `.dmg`:

```
=== TempMonitor Build ===
[1/4] Compiling...        144K binary
[2/4] Creating app bundle...
[3/4] Code signing...     valid on disk
[4/4] Creating DMG...     64K
```

Output: `build/TempMonitor.dmg`

## How it works

| Component | Method |
|---|---|
| CPU temp | SMC via IOKit (`AppleSMC` service, sensor key probing) |
| Battery temp | SMC via IOKit (TB1T/TB2T/TB0T keys) |
| CPU frequency | IOReport DVFS residency sampling (private framework, no root needed) |

The app probes for available sensor keys at startup since they vary across Mac models. Temperature values are bounds-checked (-20 to 150°C) and the byte order is handled for both Apple Silicon (little-endian) and Intel (big-endian).

## Architecture

```
TempMonitor.swift (single file)
├── SMC Types & Byte Conversion
├── SMCClient (IOKit connection)
├── TemperatureReader (sensor key probing)
├── FrequencyReader (IOReport DVFS sampling)
├── MenuBarController (NSStatusItem + NSMenu)
└── AppDelegate (timer, wiring)
```

## License

MIT
