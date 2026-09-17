import ContainerResource

enum KrunCleanPolicy {
  static func targets(for config: ContainerConfiguration) -> [String] {
    var targets: [String] = []
    if !config.readOnly {
      targets.append("/")
    }
    for mount in config.mounts where mount.isBlock && !mount.options.readonly {
      targets.append(mount.destination)
    }
    return targets
  }
}
