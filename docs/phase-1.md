# Phase 1: SceShell user-plugin proof

Phase 1 uses a user-mode taiHEN plugin loaded into SceShell. It does not use a
VPK, a LiveArea bubble, a background-app pair, or a kernel module.

The plugin starts a TCP listener on port `19600` from `module_start` and keeps
the module entry point non-blocking by running the server in its own thread.
It uses SceShell's existing user-mode network environment rather than taking
ownership of global network initialization. If the listener is not ready yet,
it records the error and retries.

## Build

From PowerShell:

```powershell
$env:VITASDK = 'E:\dev\VitaSDK-snapshopt'
cmake -S . -B build-vita-plugin -G Ninja -DCMAKE_TOOLCHAIN_FILE="$env:VITASDK\share\vita.toolchain.cmake"
cmake --build build-vita-plugin
```

The relevant outputs are:

- `build-vita-plugin\vitalab.suprx`: the deployable SceShell plugin.
- `build-vita-plugin\vitalab`: the exact debug ELF retained with a hardware run.
- `build-vita-plugin\VitaLabPluginTest.vpk`: a safe foreground loader used
  before enabling the plugin at boot.

The configure step embeds a build ID and Git commit into the plugin. Reconfigure
before a release build so these values match the intended source revision.

## Safety gate: foreground loader

Do not add the plugin to taiHEN configuration for its first hardware test.

1. Install `VitaLabPluginTest.vpk` normally with VitaShell.
2. Open the `VitaLab Plugin Test` bubble.
3. Record the displayed `Plugin module` and `Start status` values.
4. Leave the loader open for at least five seconds and run the host test.
5. Press X to stop and unload the module before exiting.

If the module fails during this test, only the foreground loader application is
affected; SceShell is not configured to load it during boot.

## Enable in SceShell after the safety gate passes

1. Back up the active taiHEN `config.txt` before editing it.
2. Copy `vitalab.suprx` to `ur0:tai/vitalab.suprx` with VitaShell.
3. Add the following path under the existing `*main` section. Do not create a
   second `*main` section if one already exists:

   ```text
   *main
   ur0:tai/vitalab.suprx
   ```

4. Reboot the Vita TV.
5. Wait several seconds for SceShell and networking to become ready.

If SceShell becomes unstable, hold `L` while powering on to suppress taiHEN
plugin loading, then remove the VitaLab line from `config.txt` before rebooting.

## Hardware proof

On the PC, run:

```powershell
.\host\Test-VitaLabAgent.ps1
```

The client defaults to `192.168.2.222:19600`. A successful run verifies:

```text
HELLO -> VITALAB/1 READY
PING  -> PONG
INFO  -> VITALAB/1 INFO version=... platform=psvita build=... commit=...
```

It then creates `runs\<timestamp>-<build-id>\manifest.json` and preserves the
matching debug ELF beside it. The plugin also appends startup and listener
diagnostics to `ux0:data/vitalab/agent.log`.

## Hardware validation record

On 2026-09-27, build `2723eda75cab-20260927T200210Z` passed both safety gates
on the Vita TV at `192.168.2.222`:

- The foreground loader started and unloaded the SUPRX successfully.
- The same SUPRX loaded at boot from taiHEN's `*main` section.
- LiveArea remained operational after boot.
- `HELLO`, `PING`, and `INFO` passed over TCP port `19600`.
- The archived debug ELF SHA-256 matched the tested build:
  `4033c6648348eb308a6cd560c4dee4434d4f66054d8eaf6ab8be1c18361a07c5`.

The boot-loaded run manifest is under
`runs/20260927T201213996Z-2723eda75cab-20260927T200210Z/`. The `runs` tree is
intentionally ignored by Git and remains local hardware evidence.

This validates boot loading and the initial protocol. Suspend/resume, network
loss/recovery, and repeated-connection stress remain open tests.

## Foreground-application coexistence

The same boot-loaded build remained reachable while two user applications
owned the foreground:

- VitaShell: PASS at `2026-09-27T20:18:02Z`, archived under
  `runs/20260927T201802416Z-2723eda75cab-20260927T200210Z/`.
- A TFoUAD development build: PASS at `2026-09-27T20:20:05Z`, archived under
  `runs/20260927T202005324Z-2723eda75cab-20260927T200210Z/`.

Both runs passed `HELLO`, `PING`, and `INFO` and preserved an ELF with SHA-256
`4033c6648348eb308a6cd560c4dee4434d4f66054d8eaf6ab8be1c18361a07c5`.
This confirms the SceShell user-plugin thread and listener remain responsive
under these foreground workloads. It does not yet validate suspend/resume,
network loss/recovery, or long-duration reliability.

## Repeated-connection stress

`host/Test-VitaLabStress.ps1` opens a fresh TCP connection for every iteration
and requires `HELLO`, `PING`, and `INFO` to pass with an unchanged agent
identity. It writes one summary manifest and archives one matching debug ELF.

On 2026-09-27, the boot-loaded agent passed 100 of 100 connections while the
TFoUAD development build remained foregrounded. End-to-end iteration timing
was 7.949 ms minimum, 9.509 ms average, 11.152 ms at p95, and 48.066 ms maximum.
Evidence is under
`runs/20260927T202450093Z-stress-2723eda75cab-20260927T200210Z/`.

This validates bounded repeated connections, not long-duration soak behavior.

## Ethernet disconnect and recovery

`host/Test-VitaLabNetworkRecovery.ps1` verifies a passing baseline, observes
that the configured endpoint becomes unreachable, and then requires the same
agent identity to return after the operator confirms reconnection. The elapsed
recovery metric begins after that confirmation; it does not measure physical
Ethernet negotiation time.

On 2026-09-27, with Wi-Fi fallback removed to preserve the Ethernet address,
the agent passed this gate at `192.168.2.222`. The outage was observed as a TCP
timeout, and the same build answered the first probe 15 ms after reconnection
was confirmed. Evidence is under
`runs/20260927T203019115Z-network-recovery-2723eda75cab-20260927T200210Z/`.

The archived ELF SHA-256 remained
`4033c6648348eb308a6cd560c4dee4434d4f66054d8eaf6ab8be1c18361a07c5`.
This validates same-address Ethernet link recovery. Automatic interface
failover to a different IP address requires future host discovery support.

## Standby and resume

`host/Test-VitaLabStandbyResume.ps1` verifies the endpoint before standby,
requires it to become unreachable while the Vita TV is suspended, and then
requires the same agent identity after wake. Its detection metric begins only
after the operator confirms that the display has returned; it does not measure
the complete physical wake sequence.

On 2026-09-27, the boot-loaded agent passed standby/resume while a TFoUAD build
was foregrounded. The endpoint timed out during standby and the same build
answered the first probe 11 ms after wake was confirmed. Evidence is under
`runs/20260927T214353619Z-standby-resume-2723eda75cab-20260927T200210Z/`.

The archived ELF SHA-256 remained
`4033c6648348eb308a6cd560c4dee4434d4f66054d8eaf6ab8be1c18361a07c5`.
This validates one standby/resume cycle. Repeated-cycle and long-duration soak
behavior remain untested.

## Application-control gate

The next protocol extension adds two strictly validated commands:

```text
LAUNCH <TITLEID>
STOP <TITLEID>
```

Title IDs must contain exactly nine uppercase ASCII letters or digits. Launch
uses SceShell's AppMgr URI path; stop targets only the explicitly supplied title
ID. The host script requires an explicit title ID so VitaLab does not assume a
project-specific default. `VitaLabControlTarget.vpk` remains available as a
disposable visual target with title ID `VLAB00210`.

`host/Test-VitaLabApplicationControl.ps1` launches the target, confirms that
the agent still answers while it is foregrounded, stops it, confirms that the
agent identity remains unchanged, and archives the exact debug ELF.

On 2026-09-28, build `594db396a2ea-20260928T012818Z` passed this gate against
the installed TFoUAD development build with title ID `WSCG00005`. The launch
returned `OK LAUNCH WSCG00005`, the agent returned `PONG` while TFoUAD was in
the foreground, and stop returned `OK STOP WSCG00005`. The INFO identity was
unchanged after the stop. Evidence is under
`runs/20260928T013957947Z-application-control-594db396a2ea-20260928T012818Z/`.

The archived ELF SHA-256 was
`ec2b3f30189157ea04e724b9c57307771fb015b65ad1e069b540b5a30b55f177`.
All host gates now compare the running agent's version, build ID, and Git commit
with the INFO identity embedded in the selected ELF before accepting a PASS.

## Application-lifecycle gate

The lifecycle extension adds a non-blocking query:

```text
STATUS <TITLEID>
```

It uses AppMgr's title-directed process lookup and returns
`OK STATUS <TITLEID> RUNNING` when that exact title is active, or
`OK STATUS <TITLEID> STOPPED` when AppMgr reports that the application is
absent. Other lookup failures return `ERR STATUS 0x........` so a failed query
cannot be mistaken for a stopped application. Title-ID validation is identical
to `LAUNCH` and `STOP`.

`host/Test-VitaLabApplicationLifecycle.ps1` requires the target to begin
stopped, launches it, polls until it is running, and then polls for a normal
on-device exit. Polling and timeouts stay on the host so the agent continues to
answer other connections. The test archives all status samples and the exact
debug ELF. Hardware validation remains pending for TFoUAD title ID `WSCG00005`.
