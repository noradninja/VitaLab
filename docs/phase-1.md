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

Until the host test succeeds against the Vita TV, this build is toolchain
validated only. Suspend/resume, network reconnection, SceShell restart, and
coexistence with foreground applications require separate hardware checks.
