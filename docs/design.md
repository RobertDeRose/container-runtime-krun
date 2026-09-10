# v0.1 design

## Objective

Provide a standalone Apple Container runtime handler that uses libkrun without requiring modifications to either `apple/container` or `apple/containerization`.

The design optimizes for a narrow, testable runtime rather than immediate feature parity. The first milestone is to make ordinary non-networked `container run` and `container exec` workloads work while preserving the memory-reclamation behavior demonstrated by the feasibility experiment.

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
2. Reject v0.1-incompatible configuration before starting a VM.
3. Create a short private directory under `/tmp` for Unix sockets.
4. Predeclare the vminitd and stdio vsock mappings in the helper configuration.
5. Start `container-krun-vmm-helper`.
6. Connect to guest port 1024 through libkrun's Unix proxy.
7. Require a successful read-only vminitd RPC before considering the guest ready.
8. Run `Vminitd.standardSetup()` and the stock runtime sysctls.
9. Mount `/dev/vdb` at `/run/container/<id>/rootfs`.
10. Record the init-process configuration and XPC-provided stdio handles without creating the guest process.
11. Transition the runtime to `booted` and return from `bootstrap`.

The helper attaches the initfs as `/dev/vda` and rootfs as `/dev/vdb`. The kernel command line retains Apple's vminitd contract:

```text
console=hvc0 ... init=/sbin/vminitd ro rootfstype=ext4 root=/dev/vda
```

The helper disables libkrun's implicit vsock because its macOS default enables TSI when no virtio-net device exists. It then creates a plain virtio-vsock with TSI flags zero. It also disables the implicit console so the explicit boot-log console is `hvc0`.

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

v0.1 avoids both constraints with a fixed pool:

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
8. close the vminitd channel;
9. terminate the VMM helper;
10. remove the private Unix-socket directory.

The VM ownership is cleared before asynchronous cleanup begins so a concurrent API-server `wait` and user `stop` cannot perform teardown twice.

## Memory reclamation

There is no runtime-side balloon controller. That is intentional.

The Apple kernel already supports page reporting, and libkrun advertises `VIRTIO_BALLOON_F_REPORTING`. Once negotiated, Linux reports unused pages and libkrun marks the corresponding host mappings with `MADV_FREE` on macOS. Host reclamation therefore follows guest memory availability without an application-level feedback loop or a second state machine.

## v0.1 unsupported surface

Networking, published ports, host mounts, published sockets, arbitrary `dial`, copy, snapshots, trim, Rosetta, nested virtualization, SSH forwarding, and `--init` return explicit unsupported errors.

This is intentional. v0.1 should establish reliability and quantify benefits before adding parity work.

## Next milestones

### v0.2: networking

Translate Apple network-plugin allocations into libkrun's virtio-net Unix-stream backend. Validate normal outbound connectivity, DNS, isolation semantics, and published ports before enabling networking by default.

### v0.3: host integration

Add host/volume mounts through libkrun virtiofs, copy operations, published Unix sockets, and a solution for arbitrary runtime `dial(port)`. If stable libkrun cannot add host-to-guest mappings after boot, prefer a small generic libkrun API addition over an Apple-specific Containerization change.

### v0.4: parity and benchmarks

Add Rosetta/remaining lifecycle behavior where justified and publish repeatable comparisons against `container-runtime-linux`: boot latency, idle RSS, memory returned after workload release, pressure behavior, CPU overhead, and compatibility coverage.
