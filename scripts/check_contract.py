#!/usr/bin/env python3
"""Static checks that do not require resolving Swift package dependencies."""
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
main = (ROOT / "Sources/KrunRuntimePlugin/main.swift").read_text()
helper_directory = ROOT / "Sources/KrunVMMHelper"
if (helper_directory / "main.swift").exists():
    print(
        "KrunVMMHelper uses @main; keep its entry point in KrunVMMHelperMain.swift, not main.swift",
        file=sys.stderr,
    )
    raise SystemExit(1)
helper = (helper_directory / "KrunVMMHelperMain.swift").read_text()
config = (ROOT / "plugin/container-runtime-krun/config.toml").read_text()

with (ROOT / "mise.toml").open("rb") as stream:
    mise = tomllib.load(stream)
for task_name in ("build", "release:build"):
    sources = mise["tasks"][task_name].get("sources", [])
    if "Sources/**/*" not in sources:
        print(
            f"mise task {task_name} must track all Sources files so C/header changes rebuild SwiftPM products",
            file=sys.stderr,
        )
        raise SystemExit(1)

runtime_dial_task = mise["tasks"]["validate:runtime-dial"]
if runtime_dial_task.get("run") != "scripts/validate_runtime_dial.sh --install":
    print(
        "mise task validate:runtime-dial must install this checkout before behavioral validation",
        file=sys.stderr,
    )
    raise SystemExit(1)

benchmark_task = ROOT / ".mise/tasks/benchmark/runtimes"
if not benchmark_task.is_file():
    print("benchmark:runtimes must be a mise file task", file=sys.stderr)
    raise SystemExit(1)
benchmark_task_text = benchmark_task.read_text()
for required in (
    '#USAGE flag "--iterations <iterations>"',
    'default="5"',
    'exec /usr/bin/caffeinate -i "$MISE_PROJECT_ROOT/scripts/benchmark_runtimes.sh"',
):
    if required not in benchmark_task_text:
        print(f"benchmark:runtimes mise usage contract is missing {required}", file=sys.stderr)
        raise SystemExit(1)
network_stream_task = ROOT / ".mise/tasks/benchmark/network-streams"
if not network_stream_task.is_file():
    print("benchmark:network-streams must be a mise file task", file=sys.stderr)
    raise SystemExit(1)
network_stream_task_text = network_stream_task.read_text()
for required in (
    '#USAGE flag "--streams <streams>"',
    'default="1,4,8"',
    '#USAGE flag "--seconds <seconds>"',
    '#USAGE flag "--iterations <iterations>"',
    'default="4"',
    'exec /usr/bin/caffeinate -i python3 "$MISE_PROJECT_ROOT/scripts/benchmark_network_streams.py"',
):
    if required not in network_stream_task_text:
        print(f"benchmark:network-streams mise usage contract is missing {required}", file=sys.stderr)
        raise SystemExit(1)

network_stream_script = (ROOT / "scripts/benchmark_network_streams.py").read_text()
for required in (
    '"guest_to_host"',
    '"host_to_guest"',
    'endpoint.guest_ip',
    'SinkServer(endpoint.gateway)',
    'threading.Barrier(streams + 1',
    'runtime_b_over_a',
):
    if required not in network_stream_script:
        print(f"sustained network benchmark contract is missing {required}", file=sys.stderr)
        raise SystemExit(1)

vmnet_batch_task = ROOT / ".mise/tasks/validate/vmnet-batching"
if not vmnet_batch_task.is_file():
    print("validate:vmnet-batching must be a mise file task", file=sys.stderr)
    raise SystemExit(1)
vmnet_batch_task_text = vmnet_batch_task.read_text()
for required in (
    '#USAGE flag "--iterations <iterations>"',
    '#USAGE flag "--payload-mib <mib>"',
    'exec /usr/bin/caffeinate -i "$MISE_PROJECT_ROOT/scripts/validate_vmnet_batching.sh"',
):
    if required not in vmnet_batch_task_text:
        print(f"validate:vmnet-batching mise usage contract is missing {required}", file=sys.stderr)
        raise SystemExit(1)

benchmark_script = (ROOT / "scripts/benchmark_runtimes.sh").read_text()
benchmark_network_script = (ROOT / "scripts/benchmark_network_metrics.py").read_text()
if "network_prefix = args.prefix.lower()" not in benchmark_network_script:
    print(
        "network benchmark must normalize generated Apple Container network names to lowercase",
        file=sys.stderr,
    )
    raise SystemExit(1)
if (
    "published_tcp_host_to_guest_" not in benchmark_network_script
    or "endpoint.guest_ip" in benchmark_network_script
    or 'lambda endpoint, _: http_upload("127.0.0.1"' not in benchmark_network_script
):
    print(
        "network benchmark must send host-to-guest bulk payload through Apple Container published ports",
        file=sys.stderr,
    )
    raise SystemExit(1)
if (
    "with host_sink_server(endpoint.gateway, payload_bytes)" not in benchmark_network_script
    or "guest_http_upload(" not in benchmark_network_script
):
    print(
        "network benchmark must send guest-to-host bulk payload to the host gateway",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "--install-krun" in benchmark_script or "mise run install" in benchmark_script:
    print(
        "runtime benchmark must not install or restart the runtime under its bounded measurement harness",
        file=sys.stderr,
    )
    raise SystemExit(1)
if 'bench.log("RUN paired-dial-probe")' not in benchmark_network_script:
    print("RuntimeClient.dial benchmark must use the paired A/B B/A probe", file=sys.stderr)
    raise SystemExit(1)
benchmark_dial_test = (ROOT / "Tests/KrunRuntimeCoreTests/KrunRuntimeDialBehavioralTests.swift").read_text()
if "readExactly(handle: handle, count: payload.count)" not in benchmark_dial_test:
    print(
        "RuntimeClient.dial benchmark must time the echoed payload, not peer EOF/connection teardown",
        file=sys.stderr,
    )
    raise SystemExit(1)

routes = {
    "bootstrap",
    "createProcess",
    "state",
    "stop",
    "kill",
    "resize",
    "wait",
    "start",
    "dial",
    "shutdown",
    "statistics",
    "copyIn",
    "copyOut",
    "snapshotDisk",
    "clean",
}
wired = set(re.findall(r"RuntimeRoutes\.([A-Za-z0-9_]+)\.rawValue", main))
wired.discard("createEndpoint")
missing = sorted(routes - wired)
extra = sorted(wired - routes)
if missing or extra:
    print(f"runtime route mismatch: missing={missing}, extra={extra}", file=sys.stderr)
    raise SystemExit(1)

required_symbols = {
    "krun_init_log",
    "krun_create_ctx2",
    "krun_free_ctx",
    "krun_set_vm_config",
    "krun_disable_implicit_vsock",
    "krun_add_vsock",
    "krun_add_vsock_port2",
    "krun_add_net_vmnet_shared",
    "krun_add_disk",
    "krun_disable_implicit_console",
    "krun_add_virtio_console_default",
    "krun_set_kernel",
    "krun_vsock_connect",
    "krun_start_enter",
}
missing_symbols = sorted(symbol for symbol in required_symbols if f'"{symbol}"' not in helper)
if missing_symbols:
    print(f"helper symbol set incomplete: {missing_symbols}", file=sys.stderr)
    raise SystemExit(1)

if 'type = "runtime"' not in config:
    print("plugin config does not declare a runtime service", file=sys.stderr)
    raise SystemExit(1)

if "ContainerNetworkClient" not in (ROOT / "Package.swift").read_text():
    print("runtime target is missing ContainerNetworkClient", file=sys.stderr)
    raise SystemExit(1)

runtime_service = (ROOT / "Sources/KrunRuntimeCore/KrunRuntimeService.swift").read_text()
if "controller.dialVsock(port: UInt32(port))" not in runtime_service:
    print("runtime dial route is not wired to the live libkrun VMM", file=sys.stderr)
    raise SystemExit(1)
if "reply.set(key: RuntimeKeys.fd.rawValue, value: handle)" not in runtime_service:
    print("runtime dial route does not return the connected file descriptor", file=sys.stderr)
    raise SystemExit(1)
cleanup_match = re.search(
    r"private func cleanupContainer\(\) async \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if cleanup_match is None:
    print("could not locate cleanupContainer", file=sys.stderr)
    raise SystemExit(1)
if "processes = [:]" in cleanup_match.group("body"):
    print(
        "cleanupContainer must preserve completed process records for concurrent/late waiters",
        file=sys.stderr,
    )
    raise SystemExit(1)

wait_match = re.search(
    r"private func waitForProcess\(_ id: String\) async throws -> ExitStatus \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if wait_match is None:
    print("could not locate waitForProcess", file=sys.stderr)
    raise SystemExit(1)
wait_body = wait_match.group("body")
if "cleanupContainer" in wait_body or "waitForOutput" in wait_body:
    print(
        "waitForProcess must only await the shared process-exit task",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "await io.waitForOutput()" not in runtime_service and "await io?.waitForOutput()" not in runtime_service:
    print(
        "the shared process wait task must own stdout/stderr drain before publishing exit",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "await self.finalizeProcessExit(id: id, status: status)" not in runtime_service:
    print(
        "the shared process wait task must finalize cleanup before releasing XPC waiters",
        file=sys.stderr,
    )
    raise SystemExit(1)

if "if state != .stopping" not in runtime_service:
    print(
        "init exit finalization must not tear down the VM while explicit stop is in progress",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "await waitForStopCompletion()" not in wait_body:
    print(
        "init waiters must remain gated until explicit stop cleanup completes",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "releaseStopWaiters()" not in cleanup_match.group("body"):
    print(
        "container cleanup must release waiters blocked behind explicit stop",
        file=sys.stderr,
    )
    raise SystemExit(1)

if "var agent: Vminitd?" not in runtime_service:
    print(
        "each process record must own a dedicated vminitd connection",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "controller.dialAgent()" not in runtime_service:
    print(
        "process start must dial a dedicated vminitd agent",
        file=sys.stderr,
    )
    raise SystemExit(1)
if "processAgent.waitProcess(id: id, containerID: containerID)" not in runtime_service:
    print(
        "process wait must use its dedicated vminitd agent",
        file=sys.stderr,
    )
    raise SystemExit(1)

bootstrap_match = re.search(
    r"public func bootstrap\(_ message: XPCMessage\) async throws -> XPCMessage \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if bootstrap_match is None:
    print("could not locate bootstrap", file=sys.stderr)
    raise SystemExit(1)
bootstrap_body = bootstrap_match.group("body")
if "KrunProcessIO.prepare" in bootstrap_body or ".createProcess(" in bootstrap_body:
    print(
        "bootstrap must stop at VM/guest setup and defer init process/stdout setup to startProcess",
        file=sys.stderr,
    )
    raise SystemExit(1)

start_match = re.search(
    r"public func startProcess\(_ message: XPCMessage\) async throws -> XPCMessage \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if start_match is None:
    print("could not locate startProcess", file=sys.stderr)
    raise SystemExit(1)
start_body = start_match.group("body")
for required in (
    "KrunProcessIO.prepare",
    "controller.dialAgent()",
    "processAgent.createProcess",
    "io.waitForGuestConnections()",
    "processAgent.startProcess",
):
    if required not in start_body:
        print(f"startProcess lifecycle is missing {required}", file=sys.stderr)
        raise SystemExit(1)
if "if !isInit" in start_body:
    print("init and exec must share the same create/start lifecycle", file=sys.stderr)
    raise SystemExit(1)

if "prepareNetworking(" not in bootstrap_body:
    print("bootstrap must allocate network attachments before VM boot", file=sys.stderr)
    raise SystemExit(1)
if "networkAttachments: networkResources.attachments" not in bootstrap_body:
    print("VM boot must receive allocated network attachments", file=sys.stderr)
    raise SystemExit(1)

for required in (
    "prepareContainerLog(bundle.containerLog)",
    "KrunProcessLog(path: controller.bundle.containerLog)",
    "processLog: processLog",
):
    if required not in runtime_service:
        print(f"persistent container logging is missing {required}", file=sys.stderr)
        raise SystemExit(1)

clean_match = re.search(
    r"public func clean\(_ message: XPCMessage\) async throws -> XPCMessage \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if clean_match is None:
    print("could not locate clean route", file=sys.stderr)
    raise SystemExit(1)
clean_body = clean_match.group("body")
for required in (
    "KrunCleanPolicy.targets(for: config)",
    "operation: .trim",
    "containerID: config.id",
):
    if required not in clean_body:
        print(f"clean route is missing {required}", file=sys.stderr)
        raise SystemExit(1)

snapshot_match = re.search(
    r"public func snapshotDisk\(_ message: XPCMessage\) async throws -> XPCMessage \{(?P<body>.*?)\n  \}",
    runtime_service,
    re.DOTALL,
)
if snapshot_match is None:
    print("could not locate snapshotDisk route", file=sys.stderr)
    raise SystemExit(1)
snapshot_body = snapshot_match.group("body")
for required in (
    'let filesystemPath = "/"',
    "operation: .freeze",
    "operation: .thaw",
    "containerID: controller.id",
):
    if required not in snapshot_body:
        print(f"snapshotDisk route is missing {required}", file=sys.stderr)
        raise SystemExit(1)
if "path: controller.rootPath" in snapshot_body:
    print(
        "snapshotDisk must target / inside the container mount namespace, not the VM staging path",
        file=sys.stderr,
    )
    raise SystemExit(1)


network_policy = (ROOT / "Sources/KrunRuntimeCore/KrunNetworkPolicy.swift").read_text()
for required in (
    'managedDefaultNetworkName = "krun"',
    'supportedPlugin = "container-network-vmnet"',
    'supportedVariant = "allocationOnly"',
    r'192.168.\(thirdOctet).0/24',
):
    if required not in network_policy:
        print(f"network policy is missing {required}", file=sys.stderr)
        raise SystemExit(1)

for required in (
    "ContainerAPIClient.NetworkClient.defaultNetworkName",
    "ensureManagedDefaultNetwork",
    "validateCompatible",
):
    if required not in runtime_service:
        print(f"runtime networking is missing {required}", file=sys.stderr)
        raise SystemExit(1)

vmnet_backend = (ROOT / "Sources/KrunRuntimeCore/KrunVMNetBackend.swift").read_text()
for required in (
    'case "allocationOnly"',
    'case "reserved"',
    "ipv4Gateway: attachment.ipv4Gateway.description",
    "macAddress: macAddress.bytes",
):
    if required not in vmnet_backend:
        print(f"vmnet backend is missing {required}", file=sys.stderr)
        raise SystemExit(1)
for forbidden in (
    "vmnet_network_create_with_serialization",
    "vmnet_interface_start_with_network(",
    "vmnet_read(",
    "vmnet_write(",
):
    if forbidden in vmnet_backend:
        print(
            f"runtime must not attempt reserved-network raw vmnet I/O: found {forbidden}",
            file=sys.stderr,
        )
        raise SystemExit(1)

vm_controller = (ROOT / "Sources/KrunRuntimeCore/KrunVMController.swift").read_text()
for required in (
    "agent.addressAdd(",
    "agent.up(",
    "agent.routeAddDefault(",
    "agent.configureDNS(",
    "agent.configureHosts(",
):
    if required not in vm_controller:
        print(f"guest network setup is missing {required}", file=sys.stderr)
        raise SystemExit(1)

print(
    "PASS: runtime routes, helper ABI surface, plugin type, lifecycle durability, and v0.2 allocation-only network wiring are complete"
)
