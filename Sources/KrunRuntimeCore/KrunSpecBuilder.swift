import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS

public enum KrunSpecBuilder {
  public static func make(
    container: ContainerConfiguration,
    process: ProcessConfiguration,
    rootPath: String,
    wrapWithInit: Bool = false
  ) throws -> Spec {
    try make(
      container: container,
      process: process,
      rootPath: rootPath,
      volumeAttachments: [],
      socketMounts: [],
      wrapWithInit: wrapWithInit
    )
  }

  static func make(
    container: ContainerConfiguration,
    process: ProcessConfiguration,
    rootPath: String,
    volumeAttachments: [KrunVolumeAttachment],
    socketMounts: [ContainerizationOCI.Mount] = [],
    wrapWithInit: Bool = false
  ) throws -> Spec {
    let safe = ["nosuid", "noexec", "nodev"]
    var mounts: [ContainerizationOCI.Mount] = [
      .init(type: "proc", source: "proc", destination: "/proc"),
      .init(
        type: "devtmpfs", source: "none", destination: "/dev", options: ["nosuid", "mode=755"]),
      .init(
        type: "devpts",
        source: "devpts",
        destination: "/dev/pts",
        options: ["nosuid", "noexec", "newinstance", "gid=5", "mode=0620", "ptmxmode=0666"]
      ),
      .init(type: "sysfs", source: "sysfs", destination: "/sys", options: safe),
      .init(type: "mqueue", source: "mqueue", destination: "/dev/mqueue", options: safe),
      .init(
        type: "tmpfs",
        source: "tmpfs",
        destination: "/dev/shm",
        options: safe + ["mode=1777", "size=\(container.shmSize ?? 64 * 1024 * 1024)"]
      ),
      .init(type: "cgroup2", source: "none", destination: "/sys/fs/cgroup", options: safe),
    ]
    mounts.append(contentsOf: try KrunVolumeLayout.ociMounts(
      for: container,
      attachments: volumeAttachments
    ))
    mounts.append(contentsOf: socketMounts)
    if wrapWithInit {
      mounts.append(
        .init(
          type: "bind",
          source: "/sbin/vminitd",
          destination: "/.cz-init",
          options: ["bind", "ro"]
        )
      )
    }

    let caps = try effectiveCapabilities(capAdd: container.capAdd, capDrop: container.capDrop)
    let user: ContainerizationOCI.User
    switch process.user {
    case .raw(let name):
      user = .init(
        uid: 0,
        gid: 0,
        umask: nil,
        additionalGids: process.supplementalGroups,
        username: name
      )
    case .id(let uid, let gid):
      user = .init(
        uid: uid,
        gid: gid,
        umask: nil,
        additionalGids: process.supplementalGroups,
        username: ""
      )
    }

    let arguments =
      (wrapWithInit ? ["/.cz-init", "--"] : []) + [process.executable] + process.arguments
    var environment = process.environment
    if container.ssh,
      !environment.contains(where: { $0.hasPrefix("\(KrunUnixSocketRelays.sshAuthSocketEnvVar)=") })
    {
      environment.append(
        "\(KrunUnixSocketRelays.sshAuthSocketEnvVar)=\(KrunUnixSocketRelays.sshGuestPath)"
      )
    }
    let ociProcess = ContainerizationOCI.Process(
      args: arguments,
      cwd: process.workingDirectory,
      env: environment,
      capabilities: caps.toOCI(),
      user: user,
      rlimits: process.rlimits.map {
        POSIXRlimit(type: $0.limit, hard: $0.hard, soft: $0.soft)
      },
      terminal: process.terminal
    )

    return Spec(
      process: ociProcess,
      hostname: hostname(for: container),
      mounts: mounts,
      root: .init(path: rootPath, readonly: container.readOnly),
      linux: .init(
        resources: .init(
          memory: .init(limit: Int64(container.resources.memoryInBytes)),
          cpu: .init(
            quota: Int64(container.resources.cpus * 100_000),
            period: 100_000
          )
        ),
        cgroupsPath: "/container/\(container.id)",
        namespaces: [
          .init(type: .cgroup),
          .init(type: .ipc),
          .init(type: .mount),
          .init(type: .pid),
          .init(type: .uts),
        ],
        maskedPaths: container.maskedPaths ?? LinuxContainer.defaultMaskedPaths(),
        readonlyPaths: container.readonlyPaths ?? LinuxContainer.defaultReadonlyPaths()
      )
    )
  }

  public static func guestRootPath(containerID: String) -> String {
    "/run/container/\(containerID)/rootfs"
  }

  public static func guestSysctls(_ config: ContainerConfiguration) -> [String: String] {
    var result = config.sysctls
    result["vm.overcommit_memory"] = "1"
    result["vm.max_map_count"] = "262144"
    return result
  }

  public static func hostname(for config: ContainerConfiguration) -> String {
    let source = config.networks.first?.options.hostname ?? config.id
    return source.split(separator: ".", maxSplits: 1).first.map(String.init) ?? config.id
  }

  private static func effectiveCapabilities(capAdd: [String], capDrop: [String]) throws
    -> Containerization.LinuxCapabilities
  {
    var caps: Set<ContainerizationOS.CapabilityName>
    if capDrop.contains("ALL") {
      caps = []
    } else {
      caps = Set(Containerization.LinuxCapabilities.defaultOCICapabilities.effective)
    }

    if capAdd.contains("ALL") {
      caps = Set(ContainerizationOS.CapabilityName.allCases)
    } else {
      for name in capAdd {
        caps.insert(try ContainerizationOS.CapabilityName(rawValue: name))
      }
    }
    for name in capDrop where name != "ALL" {
      caps.remove(try ContainerizationOS.CapabilityName(rawValue: name))
    }
    return Containerization.LinuxCapabilities(capabilities: Array(caps))
  }
}
