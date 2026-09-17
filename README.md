# container-runtime-krun

`container-runtime-krun` is an experimental Apple Container runtime plugin that boots the normal Apple Container Linux guest stack with [libkrun](https://github.com/libkrun/libkrun) and Hypervisor.framework instead of Virtualization.framework.

The project exists to validate and productize one specific advantage demonstrated by the preceding feasibility experiment: Apple's stock Container kernel negotiates `VIRTIO_BALLOON_F_REPORTING` with libkrun, allowing guest-released pages to become reclaimable by macOS while the VM remains running.

No changes to `apple/container` or `apple/containerization` are required. The plugin uses Apple Container's public `runtime` plugin contract.

## Current scope

v0.4.0 establishes the lifecycle, networking, host-integration, and selected parity baseline. Development on v0.5 adds live rootfs export, multiple network attachments, and repeatable runtime comparisons:

| Capability | Current |
| --- | --- |
| Boot Apple kernel + vminitd with libkrun | yes |
| Run initial container process | yes |
| `container exec` | yes |
| stdin/stdout/stderr | yes, fixed predeclared vsock pool |
| terminal resize | yes |
| signal / stop / wait | yes |
| container statistics | yes |
| automatic free-page reporting | yes, provided by libkrun + Apple kernel |
| Networking | yes, managed default `allocationOnly` network plus explicit compatible attachments |
| Published TCP/UDP ports | yes, through Apple `SocketForwarder` on the first attachment |
| Apple named/anonymous volumes | yes, libkrun virtio-blk |
| Host bind/virtiofs mounts | no |
| Published Unix sockets | yes, fixed libkrun vsock mappings + vminitd relay |
| Arbitrary runtime `dial(port)` | no |
| `copyIn` / `copyOut` | yes, dedicated predeclared vsock pool |
| Disk snapshot / export | yes, live rootfs export |
| Persistent `container logs` | yes, init stdout/stderr plus VM boot log |
| Filesystem trim / `container clean` | yes, writable rootfs and block-backed mounts |
| Rosetta | no, intentionally deferred; use Apple's official runtime for x86_64 emulation |
| Nested virtualization | no |
| SSH agent forwarding | yes, reverse fixed-vsock relay from host `SSH_AUTH_SOCK` |
| `--init` | yes, guest vminitd mounted as the minimal container init |

Remaining unsupported features fail with `ContainerizationError(.unsupported)` rather than silently degrading. Rosetta is intentionally deferred; users requiring x86_64 emulation should use Apple's official runtime.

v0.2 supports the `allocationOnly` variant of Apple's `container-network-vmnet` plugin through `vmnet-helper`. Apple's default macOS 26 `reserved` variant is intentionally unsupported: macOS only permits `vmnet_interface_start_with_network` to consume a serialized network when the consuming executable has the same identity as the executable that created it, while Apple crosses that boundary through Virtualization.framework. `--network none` remains supported.

## Prerequisites

- Apple Silicon Mac
- Apple Container 1.4.1 / commit `9a8917ca2da5cd6ba059b9ba5ca5a74892e9bb7d`
- Containerization `0.45.0`
- mise 2026.9.3+
- Swift 6.2+ from Xcode
- Homebrew `llvm`, `lld`, and `xz` as libkrun build dependencies
- `vmnet-helper` when using networking

The release build fetches and builds the exact libkrun source used by this runtime:

```text
repository=https://github.com/RobertDeRose/libkrun
commit=d37b5c0f72998df5cddd79ae71af4d0006f5f543
version=1.19.4
```

The fetch transport can be overridden without changing the pinned source commit, for example `LIBKRUN_REPO=git@github.com:RobertDeRose/libkrun.git mise run libkrun`.

No Homebrew or system libkrun installation is used at runtime. Install the build and networking dependencies with:

```bash
brew install llvm lld xz
brew tap nirs/vmnet-helper
brew trust nirs/vmnet-helper
brew install vmnet-helper
```

## Build and install

```bash
mise install
mise run release
mise run install
```

The build, release, and test tasks use `--force-resolved-versions` to enforce the committed `Package.resolved`,
including transitive dependency versions. Use the same flag with direct `swift build` or `swift test` commands.
For an intentional dependency change, resolve or update dependencies separately, review and commit
`Package.resolved`, then rerun validation. Do not delete the lockfile to clear build warnings.

`mise run install` derives the Apple Container installation root from the resolved `container` executable. mise pins Rust 1.98.1 for the libkrun build. Override the installation root when necessary:

```bash
INSTALL_ROOT=/path/to/container/install/root mise run install
```

The installed layout is:

```text
$INSTALL_ROOT/libexec/container-plugins/container-runtime-krun/
├── config.toml
├── bin/
│   ├── container-runtime-krun
│   └── container-krun-vmm-helper
├── lib/
│   ├── libkrun.dylib
│   └── libkrun.provenance
└── share/licenses/libkrun/LICENSE
```

The VMM helper is ad-hoc signed with the `com.apple.security.hypervisor` entitlement. The runtime plugin does not need that entitlement because libkrun is isolated in the helper process. The runtime resolves the packaged `lib/libkrun.dylib` by default. `LIBKRUN_DYLIB` remains available as an explicit development/test override.

Restart the Apple Container system after installing so the API server rescans runtime plugins:

```bash
container system stop
container system start
```

## Use

Start with the runtime selected explicitly and networking disabled:

```bash
container run --rm \
  --runtime container-runtime-krun \
  --network none \
  alpine:3.20 echo hello-from-libkrun
```

Run a workload under the minimal init process for signal forwarding and zombie reaping:

```bash
container run --rm \
  --runtime container-runtime-krun \
  --network none \
  --init \
  alpine:3.20 sh -c 'echo pid=$$; sleep 1'
```

Networking works without any setup. When Apple Container requests its built-in `default` network,
`container-runtime-krun` uses it directly when it is already a compatible `allocationOnly` network. On macOS 26,
where Apple's built-in default uses the incompatible `reserved` variant, the runtime creates and uses a managed `krun`
network instead. The managed network is a `container-network-vmnet` NAT network with `variant=allocationOnly`; subnet
selection chooses the first unused `/24` from `192.168.200.0/24` through `192.168.254.0/24`.

```bash
container run --rm \
  --runtime container-runtime-krun \
  alpine:3.20 ping -c 1 1.1.1.1
```

Explicit networks are still honored. They must already exist and use `container-network-vmnet`, NAT mode, and
`variant=allocationOnly`; incompatible networks fail before allocation with an actionable error. Additional
compatible networks become `eth1`, `eth2`, ... while `eth0` remains primary:

```bash
container network create \
  --subnet 192.168.220.0/24 \
  --option variant=allocationOnly \
  krun-secondary

container run --rm \
  --runtime container-runtime-krun \
  --network krun \
  --network krun-secondary \
  alpine:3.20 ip route
```

TCP and UDP ports can be published through the same Apple `SocketForwarder` implementation used by the stock runtime:

```bash
container run --rm \
  --runtime container-runtime-krun \
  --publish 127.0.0.1:8080:80/tcp \
  nginx:alpine
```

Unix sockets can be published without a network attachment:

```bash
container run --rm \
  --runtime container-runtime-krun \
  --network none \
  --publish-socket /tmp/service.sock:/run/service.sock \
  your-image
```

SSH agent forwarding uses the launching process's `SSH_AUTH_SOCK`, matching Apple's runtime behavior:

```bash
container run --rm \
  --runtime container-runtime-krun \
  --network none \
  --ssh \
  your-image ssh-add -l
```

Choose a different private subnet if `192.168.200.0/24` overlaps an existing Apple Container network.

Apple named and anonymous volumes are attached as libkrun virtio-blk devices while Apple Container remains authoritative for volume creation, ownership, and deletion:

```bash
container volume create app-data
container run --rm \
  --runtime container-runtime-krun \
  --network none \
  -v app-data:/data \
  alpine:3.20 sh -c 'echo persisted >/data/value.txt'
```

Host directory mounts remain unsupported pending a safe macOS confinement boundary for virtio-fs.

Once feature parity is sufficient, a separately installed user plugin named `container-runtime-linux` can shadow Apple's bundled runtime. v0.2 deliberately does not install itself that way.

## Design constraints

The runtime is one plugin process per Apple Container sandbox. It starts one child `container-krun-vmm-helper` process that owns libkrun and the Hypervisor.framework entitlement.

libkrun's vsock mappings are configured before VM start. The runtime currently reserves:

- guest port `1024` for the host-to-guest vminitd control channel;
- 96 guest-to-host ports beginning at `0x10000000` for process stdio;
- 8 guest-to-host ports immediately after the stdio range for copy transfers;
- one fixed mapping per configured published Unix socket or active SSH-agent relay, beginning after the copy range.

The stdio pool supports 32 simultaneously connected processes when all three stdio streams are present. Ports are returned to the pool when a process is cleaned up.

Apple's network plugin remains authoritative for attachment allocation/IPAM. A request for Apple Container's built-in `default` network uses that resource directly when it is compatible; on macOS 26 the incompatible `reserved` default is resolved to the runtime-managed `krun` `allocationOnly` network, which is created through Apple Container's public network API when missing. Explicit network names are preserved and must be compatible (`container-network-vmnet`, NAT, `variant=allocationOnly`). The Apple-assigned address and MTU are configured on `eth0`, `eth1`, ... in request order. `eth0` remains authoritative for the default route, fallback DNS, hostname identity, and published TCP/UDP forwarding.

See [docs/design.md](docs/design.md) for the lifecycle and rationale.

## Status

The v0.1 runtime lifecycle and memory-reclamation path are validated on macOS. The v0.2 `allocationOnly` packet path is also validated end to end for interface configuration, routing, gateway reachability, outbound IPv4, resolver configuration, DNS, statistics, cleanup, and published TCP/UDP ports. The startup readiness race caused by connecting to libkrun's host socket just before vminitd begins serving has been fixed with bounded RPC probes while preserving the overall readiness deadline and successful-RPC requirement.

v0.3.0 completes the copy and Apple block-backed volume baseline. v0.4.0 adds `--init`, published Unix sockets, and SSH agent forwarding. Current development adds live rootfs snapshot/export, multiple allocation-only attachments, persistent `container logs`, filesystem trim through `container clean`, and a non-gating comparison harness against Apple's default runtime. Run the dedicated scripts under `scripts/validate_*.sh` before tagging each slice.
