# v0.2 design

## Objective

Provide a standalone Apple Container runtime handler that uses libkrun without requiring modifications to either `apple/container` or `apple/containerization`.

The design continues to optimize for narrow, testable increments rather than immediate feature parity. v0.1 established lifecycle and memory reclamation; v0.2 adds explicit NAT networking through Apple's `allocationOnly` network variant without changing the runtime plugin boundary.

## Extension boundary

Apple Container already treats runtimes as plugins. The API server selects a runtime from `ContainerConfiguration.runtimeHandler`, starts one plugin instance per container, and communicates with it through the `ContainerRuntimeClient` XPC routes.

`container-runtime-krun` implements that boundary directly. It does not implement `VirtualMachineManager` or `VirtualMachineInstance`, so it does not depend on package-scoped `VsockListener` construction APIs in Containerization.

```text
container CLI
    |
    v
Container API server
    |
    | existing RuntimeClient/XPC contract
    v
container-runtime-krun        one per container
    |
    +-- vminitd client
    +-- process/stdio lifecycle
    |
    `-- container-krun-vmm-helper
            |
            v
          libkrun
            |
            v
      Hypervisor.framework
            |
            v
      Apple kernel + vminitd
```

## Process separation

The runtime plugin owns Apple Container semantics. The VMM helper owns only libkrun configuration and VM execution.

This split is deliberate:

- `krun_start_enter()` blocks for the lifetime of the VM;
- only the helper needs the Hypervisor.framework entitlement;
- a libkrun failure does not load the VMM into the runtime XPC server itself;
- the helper can remain a small dynamic loader with no Apple Container dependencies other than a shared Codable configuration schema.

## Boot lifecycle

On `bootstrap`:

1. Materialize the normal Apple runtime bundle from `runtime-configuration.json` if needed.
2. Reject unsupported configuration before starting a VM.
3. If a network is requested, allocate it through Apple's network plugin and attach libkrun to the resulting vmnet network.
4. Create a short private directory under `/tmp` for Unix sockets.
5. Predeclare the vminitd/stdin/stdout/copy mappings, network devices, and resolved Apple volume disks in the helper configuration.
6. Start `container-krun-vmm-helper`.
7. Connect to guest port 1024 through libkrun's Unix proxy.
8. Require a successful read-only vminitd RPC before considering the guest ready.
9. Run `Vminitd.standardSetup()` and the stock runtime sysctls.
10. Mount `/dev/vdb` at `/run/container/<id>/rootfs`.
11. Mount any volume disks beginning at `/dev/vdc` under `/run/container/<id>/volumes/<n>`.
12. Configure `eth0`, routes, DNS, and `/etc/hosts` from the Apple network allocation.
13. Record the init-process configuration and XPC-provided stdio handles without creating the guest process.
14. Transition the runtime to `booted` and return from `bootstrap`.

The helper attaches the initfs as `/dev/vda`, rootfs as `/dev/vdb`, and unique Apple volumes from `/dev/vdc` onward. The kernel command line retains Apple's vminitd contract:

```text
console=hvc0 ... init=/sbin/vminitd ro rootfstype=ext4 root=/dev/vda
```

The helper disables libkrun's implicit vsock because its macOS default enables TSI when no virtio-net device exists. It then creates a plain virtio-vsock with TSI flags zero. It also disables the implicit console so the explicit boot-log console is `hvc0`.

## Networking

v0.2 keeps Apple Container's network plugin as the source of truth for attachment allocation and lifetime. The runtime opens a persistent `ContainerNetworkClient` session and requests the configured hostname/MAC, yielding the same `Attachment` data the stock runtime consumes.

Apple's network plugin remains authoritative for attachment allocation and lifetime. For `allocationOnly`, libkrun needs a packet backend, so the runtime launches `vmnet-helper` in shared+isolated mode on the allocated subnet and passes its Unix datagram socket plus the Apple-allocated MAC to `krun_add_net_unixgram`. No second IPAM layer is introduced.

After vminitd is ready, the controller applies the Apple attachment to `eth0`: address, MTU, any required link route, default route, DNS, and the container hostname entry. Network statistics come from vminitd's existing cgroup/network stats surface.

The first slice intentionally supports one `container-network-vmnet` attachment using the `allocationOnly` variant on macOS 26. Published TCP/UDP ports target that first attachment. Multiple attachments and network performance offloads remain follow-up work. `--network none` continues to work without a packet backend, but cannot publish ports because there is no guest IP to target. The default macOS 26 `reserved` variant is rejected: `vmnet_interface_start_with_network` requires the consumer of a serialized network to have the same executable identity as the process that created it, and Apple's stock runtime crosses that boundary through Virtualization.framework rather than raw vmnet I/O.

## Published TCP/UDP ports

Published ports reuse Apple Container's public `SocketForwarder` product rather than introducing a libkrun-specific forwarding protocol. After Apple allocation and guest network setup, the runtime binds each requested host address/port with `TCPForwarder` or `UDPForwarder` and forwards it to the Apple-assigned guest address on the first attachment. Port ranges use the existing `PublishPort.count` semantics.

The forwarders share the controller's NIO event-loop group and are closed before the VMM, vmnet backend, and Apple network session are torn down. If a later bind fails after earlier ports were opened, the runtime closes those already-created forwarders before returning the error. IPv6 publication requires the Apple attachment to contain an IPv6 address.

Apple's stock runtime also invokes its package-scoped `LocalNetworkPrivacy` helper before binding published ports. A standalone runtime plugin cannot import that helper, so this runtime does not copy the private implementation speculatively; the normal Apple `SocketForwarder` path is used and validated on macOS.

## Process lifecycle

The runtime constructs OCI specs directly because `LinuxProcessConfiguration.toOCI()` is package-scoped in Containerization 0.42.0.

The generated spec preserves the stock runtime's important baseline:

- configured process arguments, environment, working directory, user and rlimits;
- OCI default capabilities plus `capAdd`/`capDrop` processing;
- cgroup, IPC, mount, PID and UTS namespaces;
- memory and CPU cgroup limits;
- default masked and read-only paths;
- proc, devtmpfs, devpts, sysfs, mqueue, `/dev/shm`, and cgroup2 mounts;
- configured tmpfs mounts;
- rootfs read-only state;
- `vm.overcommit_memory=1` and `vm.max_map_count=262144`.

`bootstrap` records the init-process request but deliberately does not create it. `createProcess` does the same for an exec request. `start` is the common process boundary for both: it leases stdio ports, opens a dedicated vminitd connection, creates the guest OCI process, waits for its stdio connections, starts it, and starts an asynchronous vminitd wait. This mirrors Apple Containerization's `LinuxContainer.start()` boundary and ensures the CLI can finish its bootstrap progress display before process stdio becomes active. Each started init/exec process owns an independent vminitd connection, matching Apple Containerization's `LinuxProcess` lifecycle and isolating long-running init waits from short-lived exec waits. `wait`, `kill`, and `resize` use that process-owned connection; the controller connection is reserved for VM-level setup, statistics, mount, and teardown operations.

## Stdio

Containerization's `LinuxProcess` normally asks `VirtualMachineInstance.listen()` for dynamic vsock ports. A standalone runtime cannot construct Containerization's `VsockListener`, and libkrun 1.19.4 configures Unix-vsock mappings before VM start.

The runtime avoids both constraints with a fixed pool:

```text
1024                    host -> guest    vminitd gRPC
0x10000000..+95         guest -> host    process stdio
```

For each requested stdin/stdout/stderr stream, the runtime:

1. leases a predeclared port;
2. listens on that mapping's Unix path;
3. tells vminitd to use the guest port for the stream;
4. accepts libkrun's Unix connection;
5. relays data between that connection and the XPC-provided host file handle.

Stdin relay starts only after the guest process starts, matching the stock runtime's ordering and avoiding filling the pipe before the workload consumes it.

## Stop and cleanup

Teardown follows the ordering established by the feasibility experiment:

1. signal the init process;
2. wait for the configured grace period;
3. use SIGKILL if necessary;
4. drain/cancel stdio relays;
5. stop vminitd Unix-socket relays;
6. unmount any block-backed volume staging mounts;
7. unmount the rootfs;
8. sync the guest;
9. delete the vminitd container process;
10. close all published-port forwarders;
11. close the vminitd channel;
12. terminate the VMM helper and remove owned published Unix-socket paths;
13. stop the vmnet packet backend and close the Apple network session;
14. remove the private Unix-socket directory.

The VM ownership is cleared before asynchronous cleanup begins so a concurrent API-server `wait` and user `stop` cannot perform teardown twice.

## Memory reclamation

There is no runtime-side balloon controller. That is intentional.

The Apple kernel already supports page reporting, and libkrun advertises `VIRTIO_BALLOON_F_REPORTING`. Once negotiated, Linux reports unused pages and libkrun marks the corresponding host mappings with `MADV_FREE` on macOS. Host reclamation therefore follows guest memory availability without an application-level feedback loop or a second state machine.

## Current deferred surface

Host directory/virtio-fs mounts, arbitrary `dial`, Rosetta, the `reserved` vmnet variant, nested virtualization, and `clean`/trim remain explicit unsupported boundaries. `copyIn` / `copyOut` and Apple block-backed volumes are provided by v0.3. v0.4 enables `--init`, published Unix sockets, and SSH agent forwarding. v0.5 adds live rootfs snapshot/export and multiple allocation-only network attachments.

Rosetta is intentionally not part of the active parity roadmap. Its integration is specific to Apple's Virtualization.framework-backed runtime, and users requiring x86_64 emulation should use Apple's official runtime.

## Next milestones

### v0.2 follow-ups

Validate outbound connectivity, DNS, network statistics, repeated cleanup, and published TCP/UDP forwarding on the allocation-only path. Supporting Apple's `reserved` variant would require a network-plugin-side integration or an upstream capability rather than another runtime-side vmnet bridge.

### v0.3: host integration

Build host integration in independent slices rather than introducing a second general transport layer.

The first slice is `copyIn` / `copyOut`. Stable libkrun cannot add vsock mappings after VM start, so the runtime predeclares a small guest-to-host copy pool next to the existing stdio pool. Each copy operation leases one mapping, creates its host Unix listener before issuing the vminitd copy RPC, streams the payload, then returns the mapping. Regular files stream as bytes and directories use Containerization's existing tar+gzip archive implementation. Copy uses a separate vminitd control connection and does not reduce the 32-process stdio capacity.

The volume slice preserves the distinction already present in Apple Container: named and anonymous volumes are block-backed filesystems. Apple resolves and owns the volume image; the runtime attaches each unique ext4 volume as a raw libkrun virtio-blk disk, mounts it at `/run/container/<id>/volumes/<n>`, and supplies OCI bind mounts from that staging path to the requested destinations. Repeated destinations for one Apple volume reuse one attached disk. Read-only destinations remain per-mount; the underlying disk is read-only only when every use is read-only. Apple remains authoritative for volume creation, in-use tracking, persistence, and deletion.

Host directory mounts are a separate future slice using virtio-fs. They require an explicit macOS confinement design before they are enabled; merely passing a directory to libkrun is not treated as a sufficient host security boundary.

Published Unix sockets use one fixed host-listening libkrun mapping per configured socket plus vminitd's existing `.outOf` relay. SSH forwarding uses the same mechanism in reverse: vminitd creates a short guest staging socket, libkrun maps guest vsock connections to the host `SSH_AUTH_SOCK`, and the staging socket is bind-mounted at `/var/host-services/ssh-auth.sock` in the container. Apple remains authoritative for both configuration surfaces; the runtime adds no relay registry or persistent state. Arbitrary runtime `dial(port)` remains the final host-integration slice because it requires a dynamic host-to-guest vsock connection after the VM has already started. If stable libkrun cannot provide that operation, prefer a small generic libkrun API addition over an Apple-specific Containerization protocol.

### v0.4: process and socket parity

v0.4 adds `--init`, published Unix sockets, and SSH agent forwarding in independent slices.

The `--init` slice mirrors Apple Containerization's existing behavior without introducing another init implementation: the guest `/sbin/vminitd` binary is bind-mounted read-only at `/.cz-init`, and only the container's initial OCI process is rewritten to `/.cz-init -- <workload>`. `container exec` processes remain direct exec processes.

The Unix-socket slice predeclares relay mappings before VM start because stable libkrun cannot add them dynamically. Published sockets are resolved through the same container-to-guest path mapping used by copy operations, including volume-backed paths. SSH forwarding preserves Apple's guest path and environment behavior while staging the guest listener at a short VM-global path to stay within Unix socket path limits. Published host paths are owned by the runtime and removed after helper termination and bootstrap rollback.

Rosetta is deliberately excluded from the active roadmap. If x86_64 emulation is required, use Apple's official runtime.

### v0.5: storage lifecycle, multiple networks, and measurement

Live export follows Apple's Container 1.3.1 runtime contract. Containerization 0.42 translates the container-relative `/` freeze request to the mounted guest rootfs path before calling vminitd; this runtime talks to vminitd directly, so it freezes that same mounted rootfs path explicitly, copies the root ext4 image on the host, and thaws on both success and copy failure. `FIFREEZE` synchronizes the target filesystem before returning, so no additional guest protocol or global `sync` is required. Booted-but-not-started containers can be copied without a freeze. Attached volumes remain separate and are not folded into the exported root filesystem image.

Filesystem trim remains deferred. Container 1.3.1 does not define the later runtime `clean` route or expose a `container clean` CLI, leaving no supported end-to-end surface for validating the behavior. Revisit trim when the host Container release exposes that command.

Multiple `allocationOnly` network attachments reuse the existing array-based allocation and helper path. Each Apple allocation gets one `vmnet-helper` backend and one libkrun NIC, appearing in guest order as `eth0`, `eth1`, and so on. Only `eth0` installs the default route and supplies fallback DNS/hostname identity; published ports continue to use the first attachment. Cleanup closes every backend and Apple network session.

The v0.5 benchmark harness is observational rather than a CI performance gate. It retains raw samples and summary statistics for startup, exec, CPU, copy, volume I/O, stop/delete latency, idle process footprint, and the established guest-memory release workload under both `container-runtime-linux` and `container-runtime-krun`.
