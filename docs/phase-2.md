# Phase 2: Reproducible hardware runs

Phase 2 binds every hardware result to the exact host revision, resident agent,
target package, and debug ELF used for that run. The host archives structured
manifests, matching binaries, retrieved artifacts, and deterministic local
symbolization output. No AI service is required to decode a Vita core dump.

## Yabause crash-symbolization proof

On 2026-09-28, VitaLab launched Yabause `YABA00001` with its Vita Ari64 dynarec
enabled. The title progressed from `STOPPED` to `RUNNING` and then crashed as
expected. The dump list contained 23 entries before launch and 24 afterward;
the host selected only the new dump:

`psp2core-1790597035-0x0000323b7d-eboot.bin.psp2dmp`

The dump was 126,944 bytes with SHA-256
`d9ecd291e12b90283ba2a2ba4e913dd983d367610d3219c0b5a9c11245f2742a`.
Local symbolization identified the crashed thread as `YABA00001`, the stop
reason as data abort `0x00030004`, PC `0x810a1214` as `ScspExec`, and the fault
address as `0x18`. Seven additional target-code addresses were identified on
the crashed thread stack; they are explicitly recorded as heuristic candidates,
not as a proven unwind.

The target application was built from Yabause Git commit
`56bf607c18aead9f5227340d6ddd738c418989ad`. The matching archived files were:

- `target.elf`: SHA-256
  `86368dcff7ce0efc269658fe6ea212315e116f6ad66f08a516560c79d13cb0eb`
- `target.vpk`: SHA-256
  `7c47b572d17db6be8b4d8dec8453925b7c778e4ee42d19056b3a36c1ce47d19c`

The resident VitaLab agent remained reachable before, during, and after the
crash. Its build ID was `6e85d3f7360e-20260928T112757Z`, and its archived ELF
SHA-256 was
`af94227e05db4af608c498e88061b147fbe973661af6eab90b18bbe118c4c094`.

The complete evidence is under
`runs/20260928T120337696Z-crash-symbolization-YABA00001`.

## Local symbolization boundaries

The current decoder relocates runtime addresses to the matching target ELF,
resolves functions and available source locations with VitaSDK `addr2line`, and
records crash registers plus heuristic target-code addresses found on the
stack. It does not yet interpret `.ARM.exidx`, `.ARM.extab`, or DWARF call-frame
information to produce a proven frame-by-frame backtrace. That is a future
quality improvement rather than a dependency for deterministic address
symbolization.
