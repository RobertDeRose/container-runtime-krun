import Foundation
import KrunVMMProtocol

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private struct PrivilegeError: Error, CustomStringConvertible {
  let description: String
}

/// The privileged entry point only accepts a bounded, caller-owned configuration.
/// All guest paths remain unopened until drop(to:) has irreversibly completed.
enum NativeVMNetPrivileges {
  struct Identity {
    let uid: uid_t
    let gid: gid_t
  }

  private static let maximumConfigurationBytes = 1_048_576

  private static func sudoIdentity() throws -> Identity {
    let environment = ProcessInfo.processInfo.environment
    guard let uidText = environment["SUDO_UID"], let uid = UInt32(uidText), uid != 0,
      let gidText = environment["SUDO_GID"], let gid = UInt32(gidText), gid != 0
    else {
      throw PrivilegeError(
        description: "native vmnet requires sudo from a non-root user with a non-root primary group"
      )
    }
    return Identity(uid: uid, gid: gid)
  }

  static func loadConfiguration(path: String) throws -> Data {
    guard geteuid() == 0 else {
      return try Data(contentsOf: URL(fileURLWithPath: path))
    }
    let caller = try sudoIdentity()
    guard path.hasPrefix("/"), URL(fileURLWithPath: path).lastPathComponent == "krun-vmm.json"
    else {
      throw PrivilegeError(description: "privileged helper requires an absolute krun-vmm.json path")
    }
    // O_NONBLOCK prevents a caller-supplied FIFO from blocking before fstat.
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0,
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      info.st_uid == caller.uid, info.st_mode & 0o022 == 0,
      info.st_size > 0, info.st_size <= maximumConfigurationBytes
    else {
      throw PrivilegeError(
        description:
          "config must be a caller-owned regular file, at most 1 MiB, not group/other-writable")
    }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    // Do not use readToEnd: the caller can grow the file after fstat.
    let data = try file.read(upToCount: maximumConfigurationBytes + 1) ?? Data()
    guard !data.isEmpty, data.count <= maximumConfigurationBytes else {
      throw PrivilegeError(description: "configuration is empty or exceeds 1 MiB")
    }
    return data
  }

  static func validate(config: KrunVMMConfig) throws -> Identity? {
    guard geteuid() == 0 else {
      guard config.networks.isEmpty else {
        throw PrivilegeError(
          description:
            "native vmnet must start through the installed privileged helper; run mise run native:install"
        )
      }
      return nil
    }
    #if !os(macOS)
      throw PrivilegeError(description: "privileged native vmnet is supported only on macOS")
    #else
      guard #available(macOS 26, *) else {
        throw PrivilegeError(description: "native vmnet requires macOS 26 or newer")
      }
      let caller = try sudoIdentity()
      guard !config.networks.isEmpty, config.networks.count <= 16 else {
        throw PrivilegeError(
          description: "privileged helper requires between 1 and 16 native vmnet attachments")
      }
      guard CommandLine.arguments[0] == KrunDefaults.nativeHelperPath,
        config.libkrun == KrunDefaults.nativeLibkrunPath
      else {
        throw PrivilegeError(
          description:
            "privileged helper and libkrun must use the fixed root-owned native installation")
      }
      try requireTrustedPath(KrunDefaults.nativeHelperPath)
      try requireTrustedPath(KrunDefaults.nativeLibkrunPath)
      for network in config.networks {
        try network.validateNativeVMNet()
      }
      return caller
    #endif
  }

  static func drop(to target: Identity) throws {
    guard geteuid() == 0, target.uid != 0, target.gid != 0 else {
      throw PrivilegeError(description: "invalid native vmnet privilege-drop state")
    }
    guard setgroups(0, nil) == 0, setgid(target.gid) == 0, setuid(target.uid) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard getuid() == target.uid, geteuid() == target.uid,
      getgid() == target.gid, getegid() == target.gid
    else {
      throw PrivilegeError(description: "helper did not reach the caller's unprivileged identity")
    }
    errno = 0
    guard seteuid(0) == -1, errno == EPERM else {
      throw PrivilegeError(description: "helper could regain root after privilege drop")
    }
    errno = 0
    guard setegid(0) == -1, errno == EPERM else {
      throw PrivilegeError(description: "helper could regain group 0 after privilege drop")
    }
  }

  #if os(macOS)
    private static func requireTrustedPath(_ path: String) throws {
      var current = ""
      let components = path.split(separator: "/")
      for (index, component) in components.enumerated() {
        current += "/" + component
        var info = stat()
        let expected = index == components.count - 1 ? S_IFREG : S_IFDIR
        guard lstat(current, &info) == 0,
          info.st_uid == 0, info.st_mode & 0o022 == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(expected)
        else {
          throw PrivilegeError(description: "untrusted privileged code path: \(current)")
        }
        // POSIX mode bits alone do not rule out an ACL write grant. Reject all
        // allow entries; deny-only system ACLs do not weaken the mode check.
        if let acl = acl_get_file(current, ACL_TYPE_EXTENDED) {
          defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
          var entry: acl_entry_t?
          var selector = ACL_FIRST_ENTRY.rawValue
          while acl_get_entry(acl, selector, &entry) == 0 {
            var tag = ACL_UNDEFINED_TAG
            guard let entry, acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY else {
              throw PrivilegeError(
                description: "ACL may grant access to privileged code path: \(current)")
            }
            selector = ACL_NEXT_ENTRY.rawValue
          }
          guard errno == EINVAL else {
            throw PrivilegeError(description: "could not enumerate code-path ACL: \(current)")
          }
        } else if errno != ENOENT {
          throw PrivilegeError(description: "could not inspect code-path ACL: \(current)")
        }
      }
    }
  #endif
}
