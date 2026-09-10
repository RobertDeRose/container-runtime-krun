import Containerization

public enum KrunKernelCommandLine {
  public static func make(kernel: Kernel) -> String {
    var args = kernel.commandLine.kernelArgs
    appendDefault(key: "oops", value: "panic", to: &args)
    appendDefault(key: "lsm", value: "lockdown,capability,landlock,yama,apparmor", to: &args)
    args.append(contentsOf: [
      "init=/sbin/vminitd",
      "ro",
      "rootfstype=ext4",
      "root=/dev/vda",
    ])
    if !kernel.commandLine.initArgs.isEmpty {
      args.append("--")
      args.append(contentsOf: kernel.commandLine.initArgs)
    }
    return args.joined(separator: " ")
  }

  private static func appendDefault(key: String, value: String, to args: inout [String]) {
    guard !args.contains(where: { $0 == key || $0.hasPrefix("\(key)=") }) else {
      return
    }
    args.append("\(key)=\(value)")
  }
}
