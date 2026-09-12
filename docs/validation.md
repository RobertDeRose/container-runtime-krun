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

## Gate 3: allocation-only networking

Create a dedicated non-overlapping Apple network using the `allocationOnly` variant once:

```bash
container network create \
  --subnet 192.168.200.0/24 \
  --option variant=allocationOnly \
  krun
```

Choose another private subnet if that range overlaps an existing network. Then run the repository validation collector:

```bash
scripts/validate_networking.sh --install
```

`--install` builds and installs the current checkout, restarts Apple Container, and runs `make doctor`, `make check`, and `make test`. The guest probe validates the interface, route, gateway, outbound IPv4 connectivity, resolver configuration, and DNS resolution. After that run is cleaned up, the collector performs one `--network none` baseline boot so network-specific startup cost can be separated from libkrun/vminitd startup cost.

The script preserves each stopped container long enough to collect the guest boot and libkrun logs before explicitly deleting it. It also samples helper processes and Unix sockets while the networked container is alive and records cleanup state. Results are written under `validation-results/` and packaged as a single `container-runtime-krun-networking-*.tar.gz` archive.

The important diagnostics are:

- `network-run.txt`: complete guest packet-flow probe;
- `baseline-run.txt`: no-network startup comparison;
- `boot.log` and `baseline-boot.log`: guest kernel/vminitd boot logs;
- `lifecycle.txt`: monotonic lifecycle events for both runs and `elapsed_ms` values;
- `runtime-plugin.log`: complete runtime service log;
- `krun-vmnet-0.log`: `vmnet-helper` startup/backend output;
- `krun-vmm.log`: libkrun/VMM helper output;
- `system-logs-container.txt`: Apple Container control-plane events for the test container;
- `system-network-lifecycle.txt`: Apple network allocation/release events around the run;
- `runtime-state-live.txt`: runtime/helper/socket samples during the run;
- `runtime-state-after-delete.txt`: networked-run cleanup state;
- `runtime-state-final.txt`: final cleanup state after the no-network baseline;
- `make_check.txt` and `make_test.txt`: repository validation output.

Do not reduce readiness timeouts based only on total command duration. Use `lifecycle.txt` to identify the adjacent lifecycle events containing the delay. In particular, a long `vmnet-helper launched` -> `vmnet-helper socket ready` gap means the delay is before the packet socket becomes usable; a long `libkrun helper launched` -> `first successful vminitd RPC` gap is guest transport/readiness; and a long network-configuration gap is in the vminitd configuration RPCs.

The observed startup race was an early libkrun host socket connection arriving shortly before vminitd began serving gRPC in the guest. A single doomed gRPC readiness call previously held the retry loop for roughly five seconds. Readiness now retains the 30-second overall deadline and still requires a successful real vminitd RPC, while each probe has a 250 ms RPC deadline so an early stale connection can be discarded and retried. The validated networked bootstrap returned to the low-single-second range without weakening readiness.

The script does not create, modify, or replace Apple network allocations. It expects the named network to already exist and leaves Apple `container-network-vmnet` authoritative for IPAM and allocation lifetime.

## Gate 4: networked lifecycle regression

After Gate 3 has established a working packet path, run the lifecycle regression collector:

```bash
scripts/validate_runtime_regression.sh --install
```

The collector exercises the validated v0.1 behavior through the real Apple Container CLI while every VM uses the `krun` allocation-only network:

- normal and nonzero init exit propagation;
- attached stdout/stderr and interactive stdin;
- attached and detached `container exec`;
- nonzero exec exit propagation;
- repeated execs to verify stdio ports are returned to the pool;
- interactive PTY allocation and a real terminal resize;
- `container stats`, including Rx/Tx growth after network traffic;
- graceful `container stop` and SIGKILL;
- repeated create/delete cycles and helper/socket cleanup;
- the established 2 GiB VM / 1 GiB incompressible tmpfs memory-reclamation workload.

The default memory observation window after releasing the guest allocation is 120 seconds. The script verifies guest `Shmem` rises and falls and that a subsequent exec still succeeds. Host reclamation is intentionally recorded rather than reduced to a fixed RSS threshold: `memory-host.txt` samples `vm_stat`, swap usage, helper RSS/virtual size, and `top` every five seconds.

Results are packaged as `validation-results/container-runtime-krun-regression-*.tar.gz`.

## Gate 5: statistics

The networked lifecycle collector runs `container stats --no-stream --format json` before and after explicit guest network traffic. Process, CPU, memory, and network fields must be populated, and both Rx and Tx counters must increase. Preserve the raw snapshots in the regression archive for review.

## Gate 6: memory behavior

The networked lifecycle collector repeats the established feasibility workload through the real runtime plugin:

1. boot a 2 GiB VM (1920 MiB container limit plus the runtime's 128 MiB overhead);
2. hold 1 GiB of incompressible `/dev/urandom` data in `/dev/shm`;
3. record helper RSS/footprint and host VM statistics;
4. release the guest allocation while keeping the container alive;
5. observe for 120 seconds by default;
6. verify guest `Shmem` falls and another `container exec` still succeeds.

The acceptance criterion is not an immediate one-for-one RSS drop. libkrun uses `MADV_FREE`; the important property is that released guest backing becomes reclaimable under host pressure while the guest remains usable. The archived host samples should be compared with the previously validated memory-reclamation behavior and, where useful, with `container-runtime-linux` under equivalent host pressure.

## Gate 7: published TCP/UDP ports

After the packet path and lifecycle regression pass, validate host-to-guest forwarding with:

```bash
scripts/validate_port_forwarding.sh --install
```

The validator starts one networked container with both a loopback TCP publication and a loopback UDP publication. It verifies TCP request/response traffic, UDP echo traffic, container cleanup, Apple allocation release, and that both host ports can be rebound after the container is deleted. It then exercises a partial-bind failure: one host TCP port is published successfully before a second requested port collides with an already-bound listener. The first port must be released when bootstrap fails, and the failed container must leave no runtime, VMM, vmnet helper, Unix socket, or Apple network allocation behind.

The runtime uses Apple Container's public `SocketForwarder` implementation and the Apple-assigned attachment address; the validator does not create a second forwarding or IPAM mechanism. Results are packaged as `validation-results/container-runtime-krun-ports-*.tar.gz`.

## Gate 8: remaining fail-closed boundaries

Verify each remaining unsupported feature produces an explicit error before VM startup where possible:

- request more than one network attachment;
- add a host bind/virtio-fs mount;
- request Rosetta;
- request nested virtualization.

Runtime-only unsupported routes (`dial`, snapshot, clean) must also return `unsupported` rather than hanging or silently succeeding. Rosetta must additionally direct users to Apple's official runtime for x86_64 emulation. Copy, `--init`, published Unix sockets, and SSH forwarding are covered by dedicated gates instead.

## Gate 9: v0.3 copy operations

Validate the first v0.3 host-integration slice with:

```bash
scripts/validate_copy.sh --install
```

The validator runs the krun runtime with networking disabled and exercises regular-file and directory copies in both directions through the real Apple Container `container copy` command. It also verifies existing-directory and trailing-slash destination behavior, repeated binary round trips, several concurrent transfers, recovery after a missing-source failure, continued container usability, and final VMM/socket cleanup.

Copy traffic must use the dedicated predeclared transfer pool and must not consume the v0.1 stdio capacity. Results are packaged as `validation-results/container-runtime-krun-copy-*.tar.gz`.

## Gate 10: v0.3 Apple volumes

Validate block-backed named and anonymous volumes with:

```bash
scripts/validate_volumes.sh --install
```

The validator uses Apple Container's own volume service and `-v` parsing. It verifies named-volume persistence across VM recreation, read-only exposure, multiple independent volumes, repeated destinations for one backing volume, anonymous volume allocation, copy/statistics compatibility, Apple-owned volume deletion, and final VMM/socket cleanup. The runtime must not create a second volume registry or persistent metadata store.

## Gate 11: v0.4 minimal init

Validate `--init` with:

```bash
scripts/validate_init.sh --install
```

The validator proves that the requested workload is no longer PID 1, preserves workload exit status, forwards stdin/stdout and terminal I/O, leaves `container exec` usable, reaps an orphaned grandchild without leaving a PID-1 zombie, forwards `SIGTERM` to the workload while preserving its trapped exit status, and leaves no VMM helper or private socket-directory leak after cleanup.

## Gate 12: v0.4 Unix sockets and SSH agent forwarding

Validate the two directions of fixed-vsock Unix socket relaying with:

```bash
scripts/validate_unix_sockets.sh --install
```

The validator publishes a workload-owned Unix socket to the host, exercises repeated and concurrent host clients, and verifies that the host listener is removed during normal cleanup. It repeats publication for a socket stored on an Apple block-backed volume so container-path resolution is checked against mount shadowing.

SSH forwarding is validated with a host-side fake agent socket: both the initial process and `container exec` must receive `SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock`, relay bidirectional bytes to the host socket, and preserve the source socket permissions on the guest staging socket. A run with no host `SSH_AUTH_SOCK` verifies Apple's permissive behavior: the guest environment variable remains present, but no socket is mounted. Finally, an intentionally invalid sysctl forces bootstrap rollback after libkrun starts and proves that the owned published host socket and helper process are cleaned up.
