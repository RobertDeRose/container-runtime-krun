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
2. Reject unsupported v0.2 configuration before starting a VM.
3. If a network is requested, allocate it through Apple's network plugin and attach libkrun to the resulting vmnet network.
4. Create a short private directory under `/tmp` for Unix sockets.
5. Predeclare the vminitd, stdio, and virtio-net mappings in the helper configuration.
6. Start `container-krun-vmm-helper`.
7. Connect to guest port 1024 through libkrun's Unix proxy.
8. Require a successful read-only vminitd RPC before considering the guest ready.
9. Run `Vminitd.standardSetup()` and the stock runtime sysctls.
10. Mount `/dev/vdb` at `/run/container/<id>/rootfs`.
11. Configure `eth0`, routes, DNS, and `/etc/hosts` from the Apple network allocation.
12. Record the init-process configuration and XPC-provided stdio handles without creating the guest process.
13. Transition the runtime to `booted` and return from `bootstrap`.

The helper attaches the initfs as `/dev/vda` and rootfs as `/dev/vdb`. The kernel command line retains Apple's vminitd contract:

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

The runtime constructs OCI specs directly because `LinuxProcessConfiguration.toOCI()` is package-scoped in Containerization 0.43.0.

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
5. unmount the rootfs;
6. sync the guest;
7. delete the vminitd container process;
8. close all published-port forwarders;
9. close the vminitd channel;
10. terminate the VMM helper;
11. stop the vmnet packet backend and close the Apple network session;
12. remove the private Unix-socket directory.

The VM ownership is cleared before asynchronous cleanup begins so a concurrent API-server `wait` and user `stop` cannot perform teardown twice.

## Memory reclamation

There is no runtime-side balloon controller. That is intentional.

The Apple kernel already supports page reporting, and libkrun advertises `VIRTIO_BALLOON_F_REPORTING`. Once negotiated, Linux reports unused pages and libkrun marks the corresponding host mappings with `MADV_FREE` on macOS. Host reclamation therefore follows guest memory availability without an application-level feedback loop or a second state machine.

## v0.2 unsupported surface

Multiple network attachments, host mounts, published Unix sockets, arbitrary `dial`, copy, snapshots, trim, Rosetta, nested virtualization, SSH forwarding, and `--init` return explicit unsupported errors.

This is intentional. v0.2 keeps the working packet path and published TCP/UDP forwarding narrow while deferring unrelated host-integration and multi-network work.

## Next milestones

### v0.2 follow-ups

Validate outbound connectivity, DNS, network statistics, repeated cleanup, and published TCP/UDP forwarding on the allocation-only path. Once those gates pass, the one-attachment v0.2 networking scope is complete. Multiple attachments should be added only if a concrete use case justifies them. Supporting Apple's `reserved` variant would require a network-plugin-side integration or an upstream capability rather than another runtime-side vmnet bridge.

### v0.3: host integration

Add host/volume mounts through libkrun virtiofs, copy operations, published Unix sockets, and a solution for arbitrary runtime `dial(port)`. If stable libkrun cannot add host-to-guest mappings after boot, prefer a small generic libkrun API addition over an Apple-specific Containerization change.

### v0.4: parity and benchmarks

Add Rosetta/remaining lifecycle behavior where justified and publish repeatable comparisons against `container-runtime-linux`: boot latency, idle RSS, memory returned after workload release, pressure behavior, CPU overhead, and compatibility coverage.
