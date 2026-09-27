# VitaLab

**Hardware-in-the-loop testing, debugging, and automation for PlayStation Vita.**

VitaLab is an experimental development platform for automating the cycle between a development PC and real PlayStation Vita hardware.

The goal is simple:

```text
code change -> build -> deploy -> run on real hardware -> collect evidence -> analyze -> repeat
```

VitaLab is intended to remove as much manual work as possible from low-level Vita development while keeping the **real Vita hardware as the authority** for whether a build actually works.

> [!NOTE]
> VitaLab is currently in early development. Phase 1 now has a buildable
> SceShell user plugin and a host-side protocol test; real-hardware behavior
> remains authoritative.

## Why?

Debugging hardware-specific problems often involves a slow manual loop:

1. Build the application.
2. Transfer it to the Vita.
3. Launch it.
4. Reproduce the problem.
5. Recover logs and crash dumps.
6. Match the dump to the correct ELF.
7. Symbolize and analyze it.
8. Make another change and repeat.

VitaLab aims to turn that into a reproducible hardware test:

```text
vitalab test <project> <test>
```

with the resulting logs, telemetry, core dump, symbols, build identity, and video evidence collected into a single test run.

## Architecture

VitaLab is designed as a **generic platform**, not as tooling tied to one application.

```text
                       Development PC
                +--------------------------+
                |      VitaLab Host        |
                |                          |
                | build / deploy / run     |
                | artifact collection      |
                | core dump analysis       |
                | capture integration      |
                | structured reports       |
                +------------+-------------+
                             |
                          Ethernet
                             |
                +------------v-------------+
                |       PlayStation TV     |
                |                          |
                |     VitaLab Agent        |
                |          |               |
                |          v               |
                |    Application under     |
                |         test             |
                +------------+-------------+
                             |
                            HDMI
                             |
                    splitter / stripper
                       /           \
                      v             v
                     TV       capture card
```

### VitaLab Agent

A small user-mode taiHEN plugin loaded into SceShell for generic hardware
control and supervision. The current implementation does not include a kernel
module.

Planned responsibilities include:

- Network communication with VitaLab Host
- File upload/download
- Application deployment support
- Launching and terminating applications
- Process/test supervision
- Heartbeat and status reporting
- Log and artifact retrieval
- Core dump discovery/retrieval
- Recovery after application failure

The Agent should know as little as possible about the application being tested.

### VitaLab Host

The PC-side controller and orchestration layer.

Planned responsibilities include:

- Build orchestration
- Deployment
- Test execution
- Agent communication
- Artifact collection
- Matching each run to its exact Git commit and debug ELF
- Vita core dump symbolization
- Structured test reports
- HDMI capture integration
- Eventually visual regression testing

### VitaLab Protocol

A small versioned protocol shared by the Host and Agent.

The initial protocol is expected to cover generic operations such as:

```text
HELLO
STATUS
PUT
GET
LAUNCH
STOP
WAIT
LIST_DUMPS
GET_DUMP
```

Project-specific emulator/game telemetry should remain outside the generic core protocol where practical.

## Project Adapters

Individual Vita projects integrate with VitaLab through thin adapters.

```text
VitaLab
|
+-- Generic adapter
+-- Yabause adapter
+-- TFoUAD adapter
+-- ...
```

An adapter can describe things such as:

- How the project is built
- Its TitleID
- Which executable/artifacts should be deployed
- Which logs should be collected
- Test timeout and success conditions
- Optional project-specific telemetry
- Optional deterministic test commands

This keeps VitaLab itself independent of any particular engine, emulator, or game.

## First Target: Vita Yabause

The first real-world test case will be the PS Vita Yabause port.

The immediate motivation is debugging the Ari64 SH2 dynarec, where failures can involve ARM/Thumb state, generated native code, dynamic dispatch, W^X code publication, ABI transitions, and crashes that only become meaningful when correlated with the exact binary that ran on the Vita.

A future VitaLab Yabause run should be able to automatically:

```text
build Yabause
    |
deploy to Vita
    |
launch on real hardware
    |
run dynarec test
    |
+---+------------------+
|                      |
PASS                  CRASH
|                      |
collect logs      retrieve .psp2dmp
|                      |
+----------+-----------+
           |
symbolize against exact ELF
           |
collect telemetry + HDMI evidence
           |
generate structured report
```

## HDMI Capture

VitaLab is also intended to support an independent video observation path.

The initial development setup uses a PlayStation TV whose HDMI signal is split between a display and a dedicated PCIe capture card.

This allows a test run to preserve:

- Full test video
- Failure frames
- Screenshots at telemetry checkpoints
- Visual evidence even if the application/debug connection crashes
- Eventually reference-frame and visual regression results

The capture path is intentionally independent of the VitaLab Agent.

## Test Runs

Every hardware run should be reproducible and retain enough information to identify exactly what produced the result.

A run may eventually look like:

```text
runs/
  0042-573a535/
    manifest.json
    eboot.bin
    application.elf
    logs/
    telemetry/
    crash/
      psp2core-....psp2dmp
      symbolized.txt
    video/
      test.mp4
      failure-frame.png
    analysis/
      result.json
      report.txt
```

The exact debug ELF used for a run must be preserved with that run. A core dump should never be symbolized against an assumed or unrelated build.

## AI-Assisted Development

VitaLab itself is not an AI project, but its structured interface is intentionally suitable for automated development tools.

Instead of handing an AI model an arbitrary collection of logs, VitaLab should be able to provide a bounded result containing:

- Exact source revision
- Exact binary/ELF
- Test configuration
- Hardware telemetry
- Crash registers
- Symbolized stack/core information
- Project-specific diagnostic data
- HDMI screenshots/video
- Comparison with previous runs

This makes possible a future loop such as:

```text
analyze -> patch -> build -> VitaLab test -> hardware evidence -> analyze
```

The same interface could later be consumed by local systems such as Continuity or external coding/reasoning tools without coupling VitaLab to a particular model.

## Initial Roadmap

### Phase 1 - Communication and deployment

- [ ] Define Host/Agent protocol
- [ ] Establish reliable Ethernet connection to PlayStation TV
- [ ] Upload/download files
- [ ] Launch and terminate a test application
- [ ] Detect application termination
- [ ] Retrieve logs and core dumps

### Phase 2 - Reproducible hardware runs

- [ ] Build/run manifests
- [ ] Git commit/build identity tracking
- [ ] Preserve matching debug ELF
- [ ] Automatic core dump symbolization
- [ ] Structured result format
- [ ] Run artifact archive

### Phase 3 - Capture

- [ ] Capture-card discovery/control
- [ ] Automated recording
- [ ] Failure-frame extraction
- [ ] Timestamp correlation with test telemetry

### Phase 4 - Project adapters

- [ ] Generic adapter
- [ ] Yabause adapter
- [ ] Yabause dynarec telemetry
- [ ] TFoUAD adapter

### Phase 5 - Advanced testing

- [ ] Deterministic application test commands
- [ ] Performance regression testing
- [ ] Visual regression testing
- [ ] Automated hardware test pipelines
- [ ] Optional AI/Continuity integration

## Design Principles

**Real hardware is authoritative.** VitaLab exists specifically to observe what code actually does on Vita hardware.

**Keep the Agent small.** Building, symbolization, video processing, source analysis, and other expensive work belong on the host.

**Separate supervision from the application under test.** A crashing test application should not take the VitaLab control path down with it.

**Preserve evidence.** Every result should remain associated with the exact build, configuration, and artifacts that produced it.

**Stay project-agnostic.** Yabause is the first use case, not a dependency.

## Status

The current milestone is a minimal SceShell user plugin providing versioned
`HELLO`, `PING`, and `INFO` commands over TCP. File transfer and application
control remain future work. A foreground loader VPK is used as a safety gate
before enabling the plugin under taiHEN's `*main` section. Build
`2723eda75cab-20260927T200210Z` has passed both the foreground-loader and
boot-loaded SceShell tests on a real PlayStation TV. The same resident plugin
also remained reachable while VitaShell and a TFoUAD development build were
running in the foreground, including a 100-connection protocol stress pass and
same-address Ethernet disconnect/recovery. One standby/resume cycle also passed
with the same agent identity and matching archived ELF.

The initial Host-to-Agent proof is documented in [docs/phase-1.md](docs/phase-1.md).

---

VitaLab is an independent homebrew development project and is not affiliated with or endorsed by Sony Interactive Entertainment.
