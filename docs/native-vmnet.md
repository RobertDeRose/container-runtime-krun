# Native libkrun vmnet: one-NIC integration slice

This development slice requires macOS 26 or newer, a macOS 26+ SDK, and the
coordinated libkrun patch applied to the managed pinned checkout. It targets the unmodified Apple
Container 1.4.1 CLI. It does not use the old direct-bridge WIP branch.

The runtime still asks Apple's network service for an `allocationOnly` attachment
and keeps its XPC allocation session open. Apple chooses the address, MAC, hostname,
and attachment lifetime. The existing managed `krun` network resolution remains
unchanged. The runtime passes the assigned subnet and MAC to
`krun_add_net_vmnet_shared`, not `krun_add_net_unixgram`.

libkrun starts an isolated shared-mode vmnet interface in each VMM process and
requires zero offload features. Matching interfaces use the same Apple-owned
allocationOnly subnet without taking an exclusive `vmnet_network_ref` reservation,
so concurrent VMM processes can coexist on that subnet. The guest remains
statically configured from Apple's attachment and does not run a DHCP client; the
shared-mode vmnet DHCP service is not used by the runtime. libkrun's internal
anonymous socket pair carries raw Ethernet to the existing virtio-net implementation;
there is no external packet helper, named packet socket, or silent fallback. Native
setup failure is a startup failure.

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

After this gate passes twice consecutively, run the native acceptance collector:

```bash
scripts/validate_native_vmnet_acceptance.sh
```

It is the completion gate for the remaining native-network work. It validates two
concurrent VMs on the same Apple network, a two-NIC container plus partial network
allocation rollback, published TCP and UDP ports plus partial forwarder rollback,
and recovery after an abrupt VMM `SIGKILL`. It also rejects production-source
references to the old `vmnet-helper`, `krun_add_net_unixgram`, and named packet
socket path.

By default the acceptance collector then runs the non-superseded regression
collectors for lifecycle/memory, init, copy, volumes, Unix sockets, virtiofs, logs,
snapshots, and fail-closed behavior. The native acceptance scenarios replace the
old helper-specific networking, multiple-network, and port-forwarding collectors.
Use `--skip-regression` only while iterating on an acceptance failure; a completion
run must omit it. Every subcollector remains independently archived by its existing
script, while the acceptance archive records their command output/status.

The stock Container 1.4.1 startup-only PTY diagnostic may warn during the runtime
regression; established-session resize remains mandatory. Native validation does
not weaken or replace that test.

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
