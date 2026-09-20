# v0.2 validation plan

v0.1 validated the standalone runtime lifecycle and memory reclamation. v0.2 keeps those gates and adds a focused network validation layer.

## Gate 1: installation and discovery

```bash
mise install
mise run doctor
mise run release
mise run install
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

Run the repository validation collector without pre-creating a network:

```bash
scripts/validate_networking.sh --install
```

The networked probe intentionally omits `--network`. Apple Container therefore requests its built-in `default` network. The runtime must use that resource directly when it is already compatible; on macOS 26, where the built-in default is `reserved`, it must create or reuse its managed `krun` allocation-only network through Apple Container's network API before allocation.

`--install` builds and installs the current checkout, restarts Apple Container, and runs `mise run doctor`, `mise run check`, and `mise run test`. The guest probe validates the interface, route, gateway, outbound IPv4 connectivity, resolver configuration, and DNS resolution. After that run is cleaned up, the collector performs one `--network none` baseline boot so network-specific startup cost can be separated from libkrun/vminitd startup cost.

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
- `mise_check.txt` and `mise_test.txt`: repository validation output.

Do not reduce readiness timeouts based only on total command duration. Use `lifecycle.txt` to identify the adjacent lifecycle events containing the delay. In particular, a long `vmnet-helper launched` -> `vmnet-helper socket ready` gap means the delay is before the packet socket becomes usable; a long `libkrun helper launched` -> `first successful vminitd RPC` gap is guest transport/readiness; and a long network-configuration gap is in the vminitd configuration RPCs.

The observed startup race was an early libkrun host socket connection arriving shortly before vminitd began serving gRPC in the guest. A single doomed gRPC readiness call previously held the retry loop for roughly five seconds. Readiness now retains the 30-second overall deadline and still requires a successful real vminitd RPC, while each probe has a 250 ms RPC deadline so an early stale connection can be discarded and retried. The validated networked bootstrap returned to the low-single-second range without weakening readiness.

The script records both the built-in `default` resource and the managed `krun` resource before the run. On macOS 26 it verifies that `krun` is available afterward; on older systems the compatible built-in default remains the effective resource. Apple `container-network-vmnet` remains authoritative for the actual network service, IPAM, and attachment lifetime. Passing `--network NAME` switches the primary probe to an existing explicit network.

With the normal default-network invocation on macOS 26 or newer, the collector also exercises explicit CLI selection end to end. It reruns a container with `--network krun` and verifies the persisted container configuration contains exactly that requested network. It then creates an ephemeral `reserved` vmnet network and verifies `container run --network <name>` fails with the runtime's actionable compatibility error naming the network and the required `container-network-vmnet`/NAT/`allocationOnly` contract. The temporary incompatible network is deleted before the collector exits.

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

### PTY resize compatibility and startup diagnostics

The collector runs two independent `container exec -it` probes. Only established-
session compatibility gates the runtime by default; the separate startup diagnostic
remains visible without requiring a patched Apple Container CLI.

**Required compatibility check (`pty-resize.txt`).** The host PTY starts at 24 rows
and 80 columns. The guest must report that valid initial geometry with its WINCH
trap installed. Setup requests a distinct 30-row, 90-column size and waits up to
ten seconds for a guest WINCH observation plus an independent PTY-size sample.
During setup only, the host may resend SIGWINCH every 500 ms without changing
geometry. This proves a resize round trip, rather than assuming a guest readiness
message or a fixed sleep means the host listener is ready.

After setup, the probe checks 40x100, 32x72, and 24x80 in sequence (rows x columns).
Each step makes one host size change and sends one explicit SIGWINCH to the CLI;
it does not retry. The size change may itself also generate SIGWINCH. Each step
has a ten-second deadline and needs a guest WINCH at the requested size and an
independent matching sample. Returning to 24x80 also checks that the smaller
geometry is applied. Setup and all three steps, followed by a clean CLI exit,
are required to pass. Missing setup confirmation is a failure, not a skip.

**Separate startup diagnostic (`pty-resize-startup.txt`).** A fresh exec runs the
original immediate-after-readiness test. Guest readiness here intentionally means
only that its trap is installed, not that the CLI has subscribed to SIGWINCH.
It requests 40x100 and observes for ten seconds. After a failed first window it
may send one more SIGWINCH without changing geometry. `retry=RECOVERED` still
returns failure for this diagnostic; it never becomes a startup pass. The default
collector records a failed diagnostic as `WARN`, records `pty_startup=FAIL` in
`run.env` and `SUMMARY.txt`, and continues. This warning alone does not prove the
known startup race caused it: inspect the trace and any errors.

Use `--require-pty-startup` to make that diagnostic a required gate, for example
when testing the host CLI fix. It is a separate exec even when the compatibility
check fails. A startup warning never overrides a compatibility failure.

Both traces record UTC/monotonic timestamps, host read-back geometry, guest size
samples and signal observations. Cleanup waits up to five seconds for normal CLI
exit, one second after SIGTERM, and two seconds after SIGKILL. Child waits remain
bounded and drain output; cleanup errors preserve the original failure. Forced
cleanup cannot pass either probe. Guest loops have iteration limits. The collector
owns deletion of its test container; standalone probes do not delete a supplied
container.

The runtime logs `resize received`, `resize RPC start`, `resize RPC complete`, and
`resize failed` through the existing lifecycle logger. `resize_id` correlates a
request across actor suspension; metadata includes width/height, the runtime
process ID once decoded, the container ID, elapsed lifecycle time, and request
duration on completion/failure. `pty-resize-runtime.txt` extracts these events from
`runtime-lifecycle.txt`. A completed RPC is not itself proof of guest trap delivery.

Compare the target request (`width=100`, `height=40`) against the guest observations.
No matching receipt points upstream of the runtime. A start without completion
points to the agent call. Completion with stale guest geometry points to guest
PTY selection or a later overwriting request. Correct geometry without a target
WINCH points to guest signal handling or foreground-process-group behavior. Retain
the full logs as well: an empty filtered trace alone does not prove no request was
sent if log collection failed or the instrumented runtime was not installed.

The collector also captures the installed libkrun hash/linkage and separately
records the local dependency checkout HEAD, dirty state, and built dylib hashes.
The checkout observation and configured provenance commit are not proof of the
source used for a manually replaced installed library.

For an already running test container, the probe can be invoked independently:

```bash
# Required compatibility behavior (also the default mode).
python3 scripts/pty_resize_probe.py CONTAINER_ID --mode compatibility

# Independent, strict startup diagnostic: a retry recovery still exits nonzero.
python3 scripts/pty_resize_probe.py CONTAINER_ID --mode startup
```

Host-side probe tests require no VM and also run as part of `mise run check`:

```bash
python3 -m unittest discover -s scripts/tests -v
```

#### Preserve an experimental libkrun installation

When testing with a CLI from a different checkout, set `INSTALL_ROOT` to the
actual runtime installation root as well as selecting the CLI on `PATH`.
Otherwise provenance collection derives a root from the selected CLI and may
look for the plugin in that checkout. For a stock-CLI comparison, select the
installed CLI explicitly, not the previously patched checkout. These script-only
validation changes need no runtime rebuild or daemon restart.

Do not use the collector's `--install` option when retaining a manually installed
native-vmnet libkrun build: the normal install path manages the pinned dependency.
Build/sign and replace only the runtime executable instead. The following leaves
the installed VMM helper, dylib, and provenance unchanged, replaces the executable
with a fresh inode, and restarts Apple Container before collecting evidence:

```bash
(
  set -eu
  mise run sign
  install_root="${INSTALL_ROOT:-$(python3 scripts/install_root.py)}"
  bin_dir="$install_root/libexec/container-plugins/container-runtime-krun/bin"
  staged="$(mktemp "$bin_dir/.pty-resize-runtime.XXXXXX")"
  trap 'rm -f "$staged"' EXIT
  install -m 755 .build/arm64-apple-macosx/release/container-runtime-krun "$staged"
  mv -f "$staged" "$bin_dir/container-runtime-krun"
  container system stop
  container system start
  scripts/validate_runtime_regression.sh
)
```

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

- request Rosetta;
- request nested virtualization.

The remaining runtime-only `dial` route must remain fail-closed rather than silently succeeding. Container 1.4.1 has no public CLI surface for `dial`. Rosetta must additionally direct users to Apple's official runtime for x86_64 emulation. Copy, host bind/virtio-fs mounts, `--init`, published Unix sockets, SSH forwarding, snapshot/export, logs/clean, and multiple networks are covered by dedicated gates instead.

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

SSH forwarding is validated with a host-side fake agent socket: both the initial process and `container exec` must receive `SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock`, relay bidirectional bytes to the host socket, and preserve the source socket permissions on the guest staging socket. A run with no host `SSH_AUTH_SOCK` verifies Apple's permissive behavior: the guest environment variable remains present, but no socket is mounted. Finally, a deliberate published-TCP bind collision forces bootstrap rollback after libkrun and the Unix relay are live and proves that the owned published host socket and helper process are cleaned up.

## Gate 13: v0.5 running-container snapshot/export

Validate live rootfs export with:

```bash
scripts/validate_snapshot.sh --install
```

The validator starts a running container, writes data into the root filesystem, exports through Apple Container's public `container export` command, and verifies the resulting tar archive contains the pre-export data. It then writes additional data without an explicit workload-side `sync` and performs a second export; that second archive must contain the new write, proving the runtime freezes the mounted rootfs and captures a fresh image while the workload remains writable after thaw. A caller-side output failure is followed by another exec health check. Attached volumes are intentionally outside this rootfs export contract.

## Gate 14: v0.5 multiple allocation-only networks

Validate two attachments with:

```bash
scripts/validate_multiple_networks.sh --install
```

The validator creates two temporary Apple `allocationOnly` networks, attaches one container to both in request order, and verifies `eth0`/`eth1` address placement, one default route through `eth0`, a connected route on `eth1`, outbound connectivity, published TCP forwarding through the primary attachment, Apple allocation release, and helper cleanup. Override the temporary CIDRs if they overlap local networks.

## Gate 15: v0.5 runtime comparison benchmark

Collect non-gating comparison data with:

```bash
scripts/benchmark_runtimes.sh --install-krun --iterations 5
```

The harness compares `container-runtime-linux` and `container-runtime-krun` with a warmed image and networking disabled for the repeated microbenchmarks. Repeated samples use deterministic paired AB/BA ordering so host drift is shared between the two runtimes instead of accumulating in separate runtime-wide blocks. Startup measures detached container start only; teardown is outside that timed sample. Volume writes run through `container exec` in one already-running volume-backed container per runtime, so VM boot and volume attachment are not part of every write sample.

Raw TSV samples and a summary table cover startup, exec, deterministic CPU work, copy in/out, persistent-container volume writes, stop/delete latency, and host process footprint. The harness also captures live krun lifecycle events and preserves each krun startup sample's `krun-vmm.log` before deleting the container, allowing runtime and helper sub-phases to be correlated with the timing samples. It repeats the established 1 GiB guest-memory release workload and records host memory/process observations without imposing a fixed RSS-reclamation threshold.


## Gate 16: persistent logs and filesystem trim

Validate the two remaining Container 1.4.1 runtime-parity surfaces with:

```bash
scripts/validate_logs_clean.sh --install
```

The validator starts a detached container whose init process writes distinct stdout and stderr markers, verifies `container logs` returns both while the container is running, then verifies the same persisted output remains readable after stop. It then starts a container with a writable Apple volume, creates and deletes data on both rootfs and the volume, and requires `container clean` to complete successfully. This exercises vminitd TRIM against every writable block-backed target. The container must remain usable afterward, while a stopped container must reject `container clean` in the same way as Apple's native runtime.

## Gate 17: host bind / virtiofs mounts

Validate host directory sharing with:

```bash
scripts/validate_virtiofs.sh --install
```

The validator starts a container with a read-write `--volume` host path, a read-only
`--mount type=bind` host path, and an explicit read-write `--mount type=virtiofs` host path. It
verifies host-to-guest visibility, guest-to-host writes, live host updates, read-only enforcement at
the guest and host, multiple independent virtio-fs devices, and cleanup. It also copies files into and out
of the read-write share through Apple Container's public `container copy` surface, proving vminitd
path translation resolves the VM-global virtio-fs staging mount rather than the hidden rootfs path.
A host symlink pointing outside the exposed directory is exercised as a normal guest-path smoke test.

libkrun's macOS virtio-fs backend does not provide a hard confinement boundary against a malicious
or compromised guest kernel. This gate validates normal container/VFS behavior with the stock Apple
Container guest kernel; it does not claim to validate a hostile-kernel security boundary.


## Native libkrun vmnet integration

Use `scripts/validate_native_vmnet.sh` after the coordinated native installation.
This is a separate one-NIC integration gate, not the old direct-vmnet feasibility
probe. It verifies provenance, native ABI use, privilege drop, assigned guest
configuration, bidirectional packet flow, and cleanup without installing or
rebuilding anything. See [native setup and evidence](native-vmnet.md).
