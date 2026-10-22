# Native libkrun vmnet: one-NIC integration slice

This development slice requires macOS 26 or newer, a macOS 26+ SDK, and the
coordinated libkrun patch applied to the managed pinned checkout. It targets the unmodified Apple
Container 1.5.0 CLI. It does not use the old direct-bridge WIP branch.

The runtime still asks Apple's network service for an `allocationOnly` attachment
and keeps its XPC allocation session open. Apple chooses the address, MAC, hostname,
and attachment lifetime. The existing managed `krun` network resolution remains
unchanged. The runtime passes the assigned subnet and MAC to
`krun_add_net_vmnet_shared`, not `krun_add_net_unixgram`.

libkrun starts an isolated shared-mode vmnet interface in each VMM process. The
runtime advertises guest TX checksum and TCPv4 segmentation support; libkrun
completes those operations in software before sending ordinary raw Ethernet to
vmnet. vmnet's own checksum/TSO mode remains disabled. Matching interfaces use the
same Apple-owned allocationOnly subnet without taking an exclusive
`vmnet_network_ref` reservation,
so concurrent VMM processes can coexist on that subnet. The guest remains
statically configured from Apple's attachment and does not run a DHCP client; the
shared-mode vmnet DHCP service is not used by the runtime. Guest-to-host frames
are written to vmnet from the virtio-net worker threads straight out of guest
memory, a whole drain pass per `vmnet_write` (up to 64 frames), with frames vmnet
does not accept un-popped in order for the next pass. Per-call cost is what bounds
this path: one call per frame leaves a single worker wall-saturated at about 11 to
16 microseconds per 64 KiB frame, while batching brings the worker's cost per frame
down and lets one queue carry Apple-runtime throughput. Holding a drain's frames
back to form larger bursts was evaluated and rejected: it makes the host
acknowledge in larger pieces, but a BBR sender's throughput does not rise and its
round-trip time does, so frames are written as soon as a drain pass ends. libkrun
implements packed virtqueues (`VIRTIO_F_RING_PACKED`, the layout Apple's device
negotiates) but offers them only when `KRUN_NET_PACKED_RING=1` is set in its own
process environment: measured against the split layout they were neutral to
slightly slower on this path (eight paced streams 0.77 to 0.82 of Apple's runtime
against 0.83, Reno 1.00 against 1.05, one stream 1.06 against 1.00), so the ring
format is not what separates the two runtimes. It
offers a single RX/TX queue pair by default. It can offer one pair per vCPU (at
most 8, `KRUN_NET_QUEUE_PAIRS`) with a control queue that accepts only the
multiqueue pair-count command and a worker per TX queue, but that is not the
default: Linux pins a TCP flow to the TX queue chosen at its first transmit, so
bulk flows gain nothing from more pairs, and paced senders such as BBR lose
because each worker then sees only a few frames per drain and pays the per-call
cost of `vmnet_write` for them (eight paced streams measured 0.68 of Apple's
runtime with a pair per vCPU and 0.83 with one pair; Reno was unchanged). Other
device-side changes were measured and rejected for the same reason, since every
added per-frame cost lowered both algorithms: copying frames out and completing
them to the guest before the vmnet write, polling the TX ring before sleeping,
indirect descriptors, and 256-entry rings. A larger guest MTU is not available:
Apple's Internet Sharing clamps TCP MSS to 1240 on every vmnet shared bridge
regardless of the interface MTU, which is why guests run at 1280.
Host-to-guest frames are written into pair 0's receive ring by the bridge's vmnet
receive callback; frames that arrive while the ring is empty wait in a bounded list
that the worker drains when the guest posts buffers, and drops beyond that bound are
logged. libkrun's internal anonymous socket pair remains only as the fallback
transport. libkrun honours `KRUN_VMNET_SOCKET_TX`, `KRUN_VMNET_SOCKET_RX`, and
`KRUN_NET_QUEUE_PAIRS` in its own process environment, but the sudoers rule that
launches the VMM helper is `NOSETENV`, so those switches do not reach production
VMs; comparing transports there means rebuilding libkrun with the other default.
There is no external packet helper, named packet socket, or silent fallback. Native
setup failure is a startup failure.

The runtime leaves TCP congestion control to the guest kernel's default (`bbr`;
the Apple guest kernel registers only `reno` and `bbr`) and passes a configured
`net.ipv4.tcp_congestion_control` through unchanged. Reno was evaluated as a
runtime default and rejected: it raises bulk guest-to-host throughput only while
the host has spare capacity, and in every measurement it multiplied round-trip
time on the local link from well under a millisecond to several milliseconds,
which is the wrong trade for a container runtime's default. A container that wants
it opts in per container, since the CLI exposes labels but not sysctls:

```bash
container run --runtime container-runtime-krun \
  --label com.github.robertderose.container-runtime-krun.sysctl.net.ipv4.tcp_congestion_control=reno \
  ...
```

Labels under that prefix set guest `net.*` sysctls only; other keys and values with
whitespace or `/` are ignored, and an explicitly configured sysctl takes precedence.
The paired benchmark's `--tcp-congestion` option selects per socket for comparisons.

## Privilege boundary

The plugin itself continues running as the Apple Container user. For a networked
VM it invokes only this executable through noninteractive sudo:

```
/Library/PrivilegedHelperTools/com.github.robertderose.container-runtime-krun/bin/container-krun-vmm-helper
```

The installer explicitly authorizes the installing user to run that protected
helper without another password prompt. The helper and its libkrun copy are
root-owned, have no group/other write access, and are protected from ACL write
grants. The installer rejects non-system dynamic-library dependencies, rewrites
system Swift library references to absolute system locations, removes rpaths,
and signs the final images. It does not install a setuid development executable.

The privileged helper accepts only a bounded caller-owned regular `krun-vmm.json`
file, checks its fixed executable/library locations and their ancestors, and uses
`krun_create_ctx2(KRUN_CTX_NO_DEFAULT_FIRMWARE)`. Ordinary `krun_create_ctx` can
search for libkrunfw; the new context flag prevents that implicit library load
while privileged. Logging does not read environment-based configuration.

After the native interface is created, the helper clears supplementary groups,
sets real/effective GID and UID to the sudo caller, and checks that regaining
UID/GID zero is denied. Only then does it configure guest disks, kernel, virtiofs,
console paths, and vCPUs. It logs its real PID and identity, rather than treating
the sudo monitor's PID/identity as the VMM's. `--network none` uses the ordinary
unprivileged packaged helper; it still requires the coordinated libkrun ABI.

`LIBKRUN_DYLIB` cannot select a user-writable library for native setup. Install the
selected fork into the protected location instead. Networkless development may
still use the existing override.

## Build and install the managed patched dependency

Apply the libkrun patch directly to `.build-deps/libkrun`; `git am` records the
patch as a commit, so provenance can identify the exact source revision. Apply the
runtime patch on top of the PTY diagnostic and compatibility patches. Do not apply
it to the old `wip/direct-vmnet-runtime` branch.

From the runtime checkout:

```bash
git -C .build-deps/libkrun am --3way ~/Downloads/libkrun-native-vmnet-owned-network.patch
mise install
mise run check
container system stop
mise run native:install
container system start
```

`mise run native:install` requests sudo for the protected installation. Inspect
the changes before approving it. The system stop interrupts running containers;
finish other container work first. No kernel/initfs or Apple CLI patch is needed.

The libkrun task uses `.build-deps/libkrun`, requires intentional source changes
to be committed, and records its actual HEAD and build hash. The repository-owned
`.checkout-*` mise stamp is ignored when determining whether libkrun source is clean.
The installer records
the final signed/normalized dylib and helper hashes separately from the original
build hash. LLVM, lld, and xz remain build dependencies; `vmnet-helper` is not a
native-backend dependency. The old `libkrun:checkout` task has been removed.

A failed install does not restart Apple Container automatically. Correct the
reported error and repeat installation before starting the service. Runtime,
helper, and library changes must be installed together.

## Run the native gate

```bash
scripts/validate_native_vmnet.sh
```

The script does not build, install, change sudo authorization, or restart services.
It creates one uniquely named container, collects evidence, attempts bounded
stop/delete cleanup, and writes a `validation-results/krun-native-*.tar.gz` archive
even if a check fails. All CLI invocations have deadlines with termination and
kill escalation. Cleanup failures remain failures rather than overwriting the
original result. Run without concurrently starting unrelated vmnet workloads:
new external helpers/socket directories are treated as contamination.

The gate requires:

- Matching installed/protected library and helper provenance, native exported ABI
  symbols, signatures, and a trusted dynamic-loader dependency list.
- Exactly one `krun_add_net_vmnet_shared` success event backed by
  `vmnet_start_interface`, no default-firmware load, and an irreversible UID/GID
  drop before guest configuration/start. The live
  VMM PID must also have the caller's UID/GID.
- The exact Apple-assigned IPv4 address, MAC, MTU (when provided), and default route
  inside the guest; a gateway response; outbound IP traffic; DNS and HTTP.
- Host-to-guest and guest-to-host TCP round trips with unpredictable exact tokens,
  plus increasing native receive/transmit counters. The temporary host HTTP
  server binds only the allocated gateway and serves no host files.
- No new external `vmnet-helper` or packet-socket directory in sampled process
  observations, no native lifecycle timeout warning, and no remaining VMM after
  stop/delete. Sampling is evidence, not a claim of exhaustive process tracing.

Defaults use `alpine:3.20`, `1.1.1.1`, and `example.com`. Override `--image`,
`--outbound-ip`, `--dns-name`, and `--outbound-url` for a controlled network.
ICMP filtering, host firewall policy, unavailable registries, and unavailable
external test endpoints can fail these checks; the archive preserves the exact
command/output. Do not reinterpret those failures automatically as native success.

Important archive files are `SUMMARY.json`, `results.txt`, `run.json`,
`libkrun.provenance`, `krun-vmm.json`, `krun-vmm.log`, `container-inspect.txt`,
`processes-live.txt`, `backend-observations.json`, and the per-traffic-check outputs.

Endpoint-security software can fail the acceptance collector from the host side.
A transparent proxy network extension (Sophos is one) may reject the collector's
own Python `connect()` to guests on private ranges such as `10.0.0.0/8` with
`No route to host` while `curl` and `nc` reach the same guest and ICMP and ARP are
normal. Stale networking state in the Apple Container service presents the same
way: every third-party process gets `No route to host` toward guests on newly
created networks while `curl` and `nc` succeed and no SYN reaches the bridge.
When the two-NIC HTTP probe is the only failing check, confirm with
`curl http://<guest>:8080/` from the host, then restart the service
(`container system stop && container system start`) and rerun before treating
it as a runtime fault.

After this gate passes twice consecutively, run the native acceptance collector:

```bash
scripts/validate_native_vmnet_acceptance.sh
```

It is the completion gate for the remaining native-network work. It validates two
concurrent VMs on the same Apple network, a two-NIC container plus partial network
allocation rollback, published TCP and UDP ports plus partial forwarder rollback,
and recovery after an abrupt VMM `SIGKILL`. It also rejects production-source
references to the old `vmnet-helper`, `krun_add_net_unixgram`, and named packet
socket path outside the benchmark control mode: `KrunVMNetBackend.swift` and the
two files that select it may reference the legacy backend only while they carry
the `vmnetHelperControl` gate, and the installed plugin must not carry the
one-shot `.vmnet-helper-control` marker that enables that mode.

By default the acceptance collector then runs the non-superseded regression
collectors for lifecycle/memory, init, copy, volumes, Unix sockets, virtiofs, logs,
snapshots, and fail-closed behavior. The native acceptance scenarios replace the
old helper-specific networking, multiple-network, and port-forwarding collectors.
Use `--skip-regression` only while iterating on an acceptance failure; a completion
run must omit it. Every subcollector remains independently archived by its existing
script, while the acceptance archive records their command output/status.

The stock Container startup-only PTY diagnostic (observed with 1.4.1) may warn during the runtime
regression; established-session resize remains mandatory. Native validation does
not weaken or replace that test.

Published TCP/UDP ports require the unprivileged runtime process to connect back
to the guest's vmnet address. On macOS, those backend connections are subject to
Local Network Privacy. Before creating a `SocketForwarder`, the runtime uses
Apple's TN3179 link-local UDP technique to proactively trigger the one-time
permission alert and logs `local network privacy trigger attempted` with the
number of probe addresses.

If macOS presents a Local Network prompt for `container-runtime-krun`, allow it.
A denied permission presents as direct host-to-guest traffic succeeding while
the published localhost socket resets and the runtime logs `backend - connect
failed` with `No route to host` / errno 65. Replacing the runtime executable can
require that permission to be granted again.

## Failure behavior and remaining validation

Native interface start, TX shutdown, stop acknowledgement, and queued-callback
cleanup waits are bounded. If vmnet fails to acknowledge a lifecycle operation,
the bridge retains resources rather than freeing storage that a callback may
still use. It emits `native resources retained until process exit`; the gate
fails on that message. A caller must terminate the per-VM process after a setup
failure. Synchronous framework calls are not converted into cancellable calls.

The one-NIC gate intentionally remains narrow. The acceptance collector described
above is what establishes concurrent same-network VMMs, multiple attachments,
published TCP/UDP ports, partial-startup rollback, abrupt process-death recovery,
and the final legacy-backend removal/regression gate. Do not infer those guarantees
from a one-container pass; require a clean acceptance archive before treating the
native backend as the complete replacement.

To remove the privileged authorization without uninstalling other Apple software:

```bash
sudo rm -f /etc/sudoers.d/container-runtime-krun-native-vmnet
sudo rm -rf /Library/PrivilegedHelperTools/com.github.robertderose.container-runtime-krun
```

After removing it, the native runtime fails closed for networked VMs. Restore a
previous complete runtime/helper/libkrun installation before returning to the old
backend; this branch does not select it automatically.
