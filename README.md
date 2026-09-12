# container-runtime-krun

`container-runtime-krun` is an experimental Apple Container runtime plugin that boots the normal Apple Container Linux guest stack with [libkrun](https://github.com/libkrun/libkrun) and Hypervisor.framework instead of Virtualization.framework.

The project exists to validate and productize one specific advantage demonstrated by the preceding feasibility experiment: Apple's stock Container kernel negotiates `VIRTIO_BALLOON_F_REPORTING` with libkrun, allowing guest-released pages to become reclaimable by macOS while the VM remains running.

No changes to `apple/container` or `apple/containerization` are required. The plugin uses Apple Container's public `runtime` plugin contract.

## Current scope

v0.3.0 establishes the lifecycle, networking, copy, and block-backed volume baseline. Development on v0.4 adds selected runtime-parity features in independent slices:

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
| Networking | yes, one Apple `container-network-vmnet` `allocationOnly` attachment |
| Published TCP/UDP ports | yes, through Apple `SocketForwarder` on the first attachment |
| Apple named/anonymous volumes | yes, libkrun virtio-blk |
| Host bind/virtiofs mounts | no |
| Published Unix sockets | yes, fixed libkrun vsock mappings + vminitd relay |
| Arbitrary runtime `dial(port)` | no |
| `copyIn` / `copyOut` | yes, dedicated predeclared vsock pool |
| Disk snapshot / trim | no |
| Rosetta | no, intentionally deferred; use Apple's official runtime for x86_64 emulation |
| Nested virtualization | no |
| SSH agent forwarding | yes, reverse fixed-vsock relay from host `SSH_AUTH_SOCK` |
| `--init` | yes, guest vminitd mounted as the minimal container init |

Remaining unsupported features fail with `ContainerizationError(.unsupported)` rather than silently degrading. Rosetta is intentionally deferred; users requiring x86_64 emulation should use Apple's official runtime.

v0.2 supports the `allocationOnly` variant of Apple's `container-network-vmnet` plugin through `vmnet-helper`. Apple's default macOS 26 `reserved` variant is intentionally unsupported: macOS only permits `vmnet_interface_start_with_network` to consume a serialized network when the consuming executable has the same identity as the executable that created it, while Apple crosses that boundary through Virtualization.framework. `--network none` remains supported.

## Prerequisites

- Apple Silicon Mac
- Apple Container source/API compatible with commit `eee7ad097079cc3b02d5309ec10160143f2d0c6a`
- Containerization `0.43.0`
- Swift 6.2+
- libkrun 1.19.4
- `vmnet-helper` when using networking
- the libkrun Homebrew tap's matching `virglrenderer` (`0.10.4e`), not Homebrew core's newer incompatible ABI

Recommended libkrun and networking installation:

```bash
brew tap libkrun/krun
brew install libkrun/krun/virglrenderer
brew install libkrun/krun/libkrun
brew tap nirs/vmnet-helper
brew trust nirs/vmnet-helper
brew install vmnet-helper
```

## Build and install

```bash
make release
make install
```

`make install` derives the Apple Container installation root from the resolved `container` executable. Override it when necessary:

```bash
make install INSTALL_ROOT=/path/to/container/install/root
```

The installed layout is:

```text
$INSTALL_ROOT/libexec/container-plugins/container-runtime-krun/
├── config.toml
└── bin/
    ├── container-runtime-krun
    └── container-krun-vmm-helper
```

The VMM helper is ad-hoc signed with the `com.apple.security.hypervisor` entitlement. The runtime plugin does not need that entitlement because libkrun is isolated in the helper process.

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

For networking, create a non-overlapping `allocationOnly` network once and select it explicitly:

```bash
container network create \
  --subnet 192.168.200.0/24 \
  --option variant=allocationOnly \
  krun

container run --rm \
  --runtime container-runtime-krun \
  --network krun \
  alpine:3.20 ping -c 1 1.1.1.1
```

TCP and UDP ports can be published through the same Apple `SocketForwarder` implementation used by the stock runtime:

```bash
container run --rm \
  --runtime container-runtime-krun \
  --network krun \
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

For the first v0.2 networking slice, Apple's network plugin remains authoritative for attachment allocation/IPAM and the runtime supports its `allocationOnly` variant through an external `vmnet-helper` packet backend. The Apple-assigned address, gateway, DNS, hosts entry, and MTU are configured in the guest with vminitd. The default `reserved` variant is rejected with an actionable error because a runtime-only plugin cannot legally attach raw vmnet I/O to a serialized network created by `container-network-vmnet`. Published TCP/UDP ports reuse Apple Container's `SocketForwarder` implementation and target the Apple-assigned address on the first attachment. Multiple attachments remain intentionally unsupported.

See [docs/design.md](docs/design.md) for the lifecycle and rationale.

## Status

The v0.1 runtime lifecycle and memory-reclamation path are validated on macOS. The v0.2 `allocationOnly` packet path is also validated end to end for interface configuration, routing, gateway reachability, outbound IPv4, resolver configuration, DNS, statistics, cleanup, and published TCP/UDP ports. The startup readiness race caused by connecting to libkrun's host socket just before vminitd begins serving has been fixed with bounded RPC probes while preserving the overall readiness deadline and successful-RPC requirement.

v0.3.0 completes the copy and Apple block-backed volume baseline. v0.4 parity development has validated `--init`; the current slice adds published Unix sockets and SSH agent forwarding over fixed pre-boot libkrun vsock mappings and vminitd's existing relay RPCs. Run `scripts/validate_init.sh --install` and `scripts/validate_unix_sockets.sh --install` for the corresponding macOS behavioral gates.
