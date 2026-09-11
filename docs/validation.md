# v0.2 validation plan

v0.1 validated the standalone runtime lifecycle and memory reclamation. v0.2 keeps those gates and adds a focused network validation layer.

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

## Gate 4: allocation-only networking

Create a dedicated non-overlapping Apple network using the `allocationOnly` variant:

```bash
container network create \
  --subnet 192.168.200.0/24 \
  --option variant=allocationOnly \
  krun
```

Choose another private subnet if that range overlaps an existing network. Then verify the libkrun runtime explicitly uses it:

```bash
container run --rm --runtime container-runtime-krun --network krun alpine:3.20 ip addr show eth0
container run --rm --runtime container-runtime-krun --network krun alpine:3.20 ip route
container run --rm --runtime container-runtime-krun --network krun alpine:3.20 cat /etc/resolv.conf
container run --rm --runtime container-runtime-krun --network krun alpine:3.20 ping -c 1 1.1.1.1
container run --rm --runtime container-runtime-krun --network krun alpine:3.20 nslookup example.com
```

Confirm `container list`/`container inspect` expose the Apple-allocated attachment, repeated runs release their allocations, and each container's `vmnet-helper` process is terminated during cleanup.

Also verify that omitting `--network krun` on macOS 26 fails closed with an actionable error for the default `reserved` network rather than attempting `vmnet_interface_start_with_network`.

## Gate 5: statistics

Run a memory/CPU/network workload and verify `container stats --no-stream` reports process, CPU, memory, block-I/O, and network Rx/Tx values.

## Gate 6: memory behavior

Repeat the feasibility workload through the real runtime plugin:

1. hold roughly 1 GiB of incompressible anonymous/tmpfs memory;
2. record helper RSS/footprint and host VM statistics;
3. release the guest allocation while keeping the container alive;
4. observe for 120 seconds;
5. verify another `container exec` still succeeds;
6. compare against `container-runtime-linux` under the same host pressure.

The acceptance criterion is not an immediate one-for-one RSS drop. libkrun uses `MADV_FREE`; the important property is that released guest backing becomes reclaimable under host pressure while the guest remains usable.

## Gate 7: fail-closed v0.2 boundaries

Verify each unsupported feature produces an explicit error before VM startup where possible:

- request more than one network attachment;
- publish a port;
- add a host/volume mount;
- request Rosetta;
- request nested virtualization;
- request SSH forwarding;
- request `--init`.

Runtime-only unsupported routes (`dial`, copy, snapshot, clean) must also return `unsupported` rather than hanging or silently succeeding.
