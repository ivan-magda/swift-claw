import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

struct CoderProcessIdentity: Sendable {
  let pid: Int32
  let pgid: Int32
  let birth: String
  let isZombie: Bool

  static func bootID() throws -> String {
    #if canImport(Darwin)
      var size = 0
      guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else {
        throw IdentityError.unreadable
      }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else {
        throw IdentityError.unreadable
      }
      let content = bytes.prefix { byte in
        byte != 0
      }.map { byte in
        UInt8(bitPattern: byte)
      }
      guard let bootID = String(bytes: content, encoding: .utf8), !bootID.isEmpty else {
        throw IdentityError.unreadable
      }
      return bootID
    #else
      return try String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #endif
  }

  static func read(_ pid: Int32) throws -> Self? {
    #if canImport(Darwin)
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.size
      var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0 else {
        throw IdentityError.unreadable
      }
      guard size > 0 else {
        return nil
      }
      let start = info.kp_proc.p_un.__p_starttime
      return Self(
        pid: pid,
        pgid: info.kp_eproc.e_pgid,
        birth: "\(start.tv_sec):\(start.tv_usec)",
        isZombie: info.kp_proc.p_stat == SZOMB
      )
    #else
      let path = "/proc/\(pid)/stat"
      let text: String
      do {
        text = try String(contentsOfFile: path, encoding: .utf8)
      } catch {
        if kill(pid, 0) == -1 && errno == ESRCH {
          return nil
        }
        throw IdentityError.unreadable
      }
      guard let end = text.lastIndex(of: ")") else {
        throw IdentityError.unreadable
      }
      let fields = text[text.index(after: end)...].split(separator: " ")
      guard fields.count > 19, let group = Int32(fields[2]) else {
        throw IdentityError.unreadable
      }
      return Self(pid: pid, pgid: group, birth: String(fields[19]), isZombie: fields[0] == "Z")
    #endif
  }

  static func members(of pgid: Int32) throws -> [Self] {
    #if canImport(Darwin)
      let byteCount = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), nil, 0)
      guard byteCount >= 0 else {
        throw IdentityError.unreadable
      }
      var capacity = Int(byteCount) / MemoryLayout<Int32>.size + 32
      while true {
        var pids = [Int32](repeating: 0, count: capacity)
        let bufferSize = Int32(pids.count * MemoryLayout<Int32>.size)
        let filled = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids, bufferSize)
        guard filled >= 0 else {
          throw IdentityError.unreadable
        }
        if filled == bufferSize {
          capacity *= 2
          continue
        }
        return try pids.prefix(Int(filled) / MemoryLayout<Int32>.size).compactMap { pid in
          try read(pid)
        }.filter { member in
          member.pgid == pgid
        }
      }
    #else
      return try FileManager.default.contentsOfDirectory(atPath: "/proc")
        .compactMap { entry in
          Int32(entry)
        }.compactMap { pid in
          try read(pid)
        }.filter { member in
          member.pgid == pgid
        }
    #endif
  }

  static func childExited(_ pid: Int32) throws -> Bool {
    var info = siginfo_t()
    guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
      throw IdentityError.unreadable
    }
    // si_signo is set only when waitid found a waitable child on both supported platforms.
    return info.si_signo != 0
  }
}

enum IdentityError: Error { case unreadable }
