# Native libkrun vmnet: one-NIC integration slice

This development slice requires macOS 26 or newer, a macOS 26+ SDK, and the
coordinated libkrun patch applied to the managed pinned checkout. It targets the unmodified Apple
Container 1.4.1 CLI. It does not use the old direct-bridge WIP branch.

The runtime still asks Apple's network service for an `allocationOnly` attachment
and keeps its XPC allocation session open. Apple chooses the address, MAC, hostname,
and attachment lifetime. The existing managed `krun` network resolution remains
unchanged. The runtime passes the assigned subnet and MAC to
`krun_add_net_vmnet_shared`, not `krun_add_net_unixgram`.

libkrun creates the vmnet network and its interface in the VMM process, disables
DHCP, requests interface isolation, and requires zero offload features. It checks
that the network's returned IPv4 gateway/mask match the requested values. Its
internal anonymous socket pair carries raw Ethernet to the existing virtio-net
implementation; there is no external packet helper, named packet socket, or
silent fallback. Native setup failure is a startup failure.

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
- Exactly one `krun_add_net_vmnet_shared` success event, no default-firmware load,
  and an irreversible UID/GID drop before guest configuration/start. The live
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

After this gate passes, run the broader compatibility collector with the same
stock CLI and installation root:

```bash
scripts/validate_runtime_regression.sh --memory-observe-seconds 0
```

Its startup-only PTY diagnostic may warn on stock 1.4.1; established-session resize
remains mandatory. Native validation does not weaken or replace that test.

## Failure behavior and remaining validation

Native interface start, TX shutdown, stop acknowledgement, and queued-callback
cleanup waits are bounded. If vmnet fails to acknowledge a lifecycle operation,
the bridge retains resources rather than freeing storage that a callback may
still use. It emits `native resources retained until process exit`; the gate
fails on that message. A caller must terminate the per-VM process after a setup
failure. Synchronous framework calls are not converted into cancellable calls.

The implementation keeps the existing multiple-attachment control-plane code,
but this gate validates only one NIC in one VM. It does not establish that
separately owned reserved networks can share the same Apple allocation subnet
across multiple live VMMs, or that cross-container communication/isolation matches
the old shared-interface backend. Concurrent VMMs/subnet reservation behavior,
multiple attachments, published TCP/UDP ports, abrupt process death, and repeated
lifecycle stress are the next acceptance work. Do not infer those guarantees from
a one-container pass or deploy this as a fully validated backend replacement.

To remove the privileged authorization without uninstalling other Apple software:

```bash
sudo rm -f /etc/sudoers.d/container-runtime-krun-native-vmnet
sudo rm -rf /Library/PrivilegedHelperTools/com.github.robertderose.container-runtime-krun
```

After removing it, the native runtime fails closed for networked VMs. Restore a
previous complete runtime/helper/libkrun installation before returning to the old
backend; this branch does not select it automatically.
