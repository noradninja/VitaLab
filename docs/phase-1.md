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
Network disconnect/recovery remains the next gate.
