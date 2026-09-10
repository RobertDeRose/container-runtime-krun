# v0.1 validation plan

The standalone plugin adds one integration layer beyond the already completed libkrun feasibility experiment. Validation should therefore be staged rather than repeating low-level boot debugging for every feature.

## Gate 1: installation and discovery

```bash
make doctor
make release
make install
container system stop
container system start
```

Confirm the plugin is discoverable with the Apple Container plugin listing/help surfaces before starting a VM.

## Gate 2: minimal run

```bash
container run --rm --runtime container-runtime-krun --network none alpine:3.20 /bin/true
container run --rm --runtime container-runtime-krun --network none alpine:3.20 echo hello
```

This validates plugin launch, runtime XPC bootstrap, libkrun boot, vminitd, rootfs mount, the bootstrap/start lifecycle boundary, initial-process creation, stdout, wait, cleanup, and runtime shutdown.

## Gate 3: process lifecycle

Use a long-running container and exercise:

- stdin/stdout/stderr;
- `container exec` with and without a TTY;
- terminal resize;
- SIGTERM and SIGKILL;
- normal process exit and explicit stop;
- repeated execs to verify stdio ports are returned to the pool.

## Gate 4: statistics

Run a memory/CPU workload and verify `container stats` reports process, CPU, memory and block-I/O values. Network fields are intentionally absent in v0.1.

## Gate 5: memory behavior

Repeat the feasibility workload through the real runtime plugin:

1. hold roughly 1 GiB of incompressible anonymous/tmpfs memory;
2. record helper RSS/footprint and host VM statistics;
3. release the guest allocation while keeping the container alive;
4. observe for 120 seconds;
5. verify another `container exec` still succeeds;
6. compare against `container-runtime-linux` under the same host pressure.

The acceptance criterion is not an immediate one-for-one RSS drop. libkrun uses `MADV_FREE`; the important property is that released guest backing becomes reclaimable under host pressure while the guest remains usable.

## Gate 6: fail-closed v0.1 boundaries

Verify each unsupported feature produces an explicit error before VM startup where possible:

- omit `--network none`;
- publish a port;
- add a host/volume mount;
- request Rosetta;
- request nested virtualization;
- request SSH forwarding;
- request `--init`.

Runtime-only unsupported routes (`dial`, copy, snapshot, clean) must also return `unsupported` rather than hanging or silently succeeding.
