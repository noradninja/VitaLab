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

- [x] Define Host/Agent protocol
- [x] Establish reliable Ethernet connection to PlayStation TV
- [x] Upload/download files
- [x] Launch and terminate a test application
- [x] Detect application termination
- [x] Retrieve logs and core dumps

### Phase 2 - Reproducible hardware runs

- [x] Build/run manifests
- [x] Git commit/build identity tracking
- [x] Preserve matching debug ELF
- [x] Automatic core dump symbolization
- [x] Structured result format
- [x] Run artifact archive

### Phase 3 - Capture

- [x] Capture-card discovery/control
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

The current milestone is a SceShell user plugin providing versioned `HELLO`,
`PING`, `INFO`, `LAUNCH`, `STOP`, application `STATUS`, and bounded `PUT`/`GET`
commands over TCP. A foreground loader VPK is used as a safety
gate before enabling the plugin under taiHEN's `*main` section. Build
`2723eda75cab-20260927T200210Z` has passed both the foreground-loader and
boot-loaded SceShell tests on a real PlayStation TV. The same resident plugin
also remained reachable while VitaShell and a TFoUAD development build were
running in the foreground, including a 100-connection protocol stress pass and
same-address Ethernet disconnect/recovery. One standby/resume cycle also passed
with the same agent identity and matching archived ELF.

Build `594db396a2ea-20260928T012818Z` also passed the application-control gate
against TFoUAD title ID `WSCG00005`: the agent launched it, remained reachable
while it was foregrounded, and stopped it while retaining the same identity.
Host tests now reject a run when the resident agent identity does not match the
identity embedded in the ELF selected for archival.

Build `9f65e6e8d0bf-20260928T021159Z` passed title lifecycle observation against
TFoUAD: stopped before launch, running after launch, and stopped after a normal
on-device exit. Waiting and timeouts remain host-side so the agent listener
never blocks on application termination.

Build `4a8feadb464c-20260928T021934Z` passed the safe file-transfer gate under
`ux0:data/vitalab/files/`: traversal, absolute paths, and oversized uploads were
rejected, and a 64 KiB upload/download round trip preserved its SHA-256 hash.

Build `6e85d3f7360e-20260928T112757Z` passed restricted artifact retrieval: the
agent log was archived, 23 eligible core dumps were discovered, and one dump
was downloaded and hashed while arbitrary artifact paths were rejected.

`host/Invoke-VitaLabRun.ps1` combines the agent identity check, application
lifecycle gate, and artifact collection into one top-level hardware run. It
attempts artifact collection even when an earlier component fails and records
component evidence in one manifest.

Build `6e85d3f7360e-20260928T112757Z` passed the combined hardware workflow for
TFoUAD `WSCG00005`: the title progressed from stopped to running, a natural
exit was detected, the agent stayed reachable, and restricted log/core-dump
collection completed. The top-level run preserved the matching ELF with SHA-256
`af94227e05db4af608c498e88061b147fbe973661af6eab90b18bbe118c4c094`.

`host/Invoke-VitaLabCoreSymbolization.ps1` performs deterministic local
symbolization with the .NET SDK and VitaSDK `addr2line`, `objdump`, and
`readelf`; it does not require an AI service. It records highlighted crash-site
disassembly, performs ARM EHABI unwinding when the applicable `.ARM.exidx`
entry permits it, and retains clearly labeled heuristic stack candidates as a
fallback. `host/Test-VitaLabCrashSymbolization.ps1` snapshots the dump list,
launches an expected-to-crash title, retrieves only newly created dumps, and
archives the exact target ELF and installable package before symbolizing the
crash PC. The target package supplied to the test must be the package installed
on the Vita for that run.

The Vita Yabause title ID is `YABA00001`. A dynarec crash gate therefore uses
the matching `.elf` and `.vpk` from one build:

```powershell
.\host\Test-VitaLabCrashSymbolization.ps1 `
    -TitleId YABA00001 `
    -TargetElfPath E:\vita-yabause\build-vita\Yabause_Dynarec_Symbolization.elf `
    -TargetPackagePath E:\vita-yabause\build-vita\Yabause_Dynarec_Symbolization.vpk
```

Launch gates remind the operator to approve the Vita's close-current-application
dialog when it appears. After a new crash dump has been retrieved and archived,
the crash gate pauses on the host until the operator clears the Vita crash
dialog and confirms that LiveArea is visible. This waiting remains host-side;
the SceShell agent listener stays available. For explicitly unattended runs,
`-SkipCrashDialogConfirmation` bypasses only the final manual confirmation.

The first fresh Yabause hardware crash gate passed on 2026-09-28. VitaLab
detected exactly one new dump, archived the installed-package pair, and resolved
PC `0x810a1214` to `ScspExec`. The dump recorded a data abort with fault address
`0x18`. The target was built from Yabause commit
`56bf607c18aead9f5227340d6ddd738c418989ad`; the ELF SHA-256 was
`86368dcff7ce0efc269658fe6ea212315e116f6ad66f08a516560c79d13cb0eb` and
the VPK SHA-256 was
`7c47b572d17db6be8b4d8dec8453925b7c778e4ee42d19056b3a36c1ce47d19c`.
Evidence is under
`runs/20260928T120337696Z-crash-symbolization-YABA00001`.

The initial Host-to-Agent proof is documented in [docs/phase-1.md](docs/phase-1.md).
The reproducible-run and local-symbolization proof is documented in
[docs/phase-2.md](docs/phase-2.md).

---

VitaLab is an independent homebrew development project and is not affiliated with or endorsed by Sony Interactive Entertainment.
