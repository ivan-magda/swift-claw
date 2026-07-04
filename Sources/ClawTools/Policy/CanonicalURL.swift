import Foundation

public enum CanonicalURLError: Error, Sendable, Equatable {
  case unparseable
  case unsupportedScheme(String)
  case nonASCIIHost
  case userinfoPresent
  case unsupportedPort(Int)
}

/// The §9.2 canonical form — ONE algorithm serving both the owner's approval display and the
/// grant's exact-match key, plus the full pre-dispatch URL policy (scheme/port/userinfo/IDN), so
/// a URL can never win approval at gate time and then be refused at dispatch time.
public enum CanonicalURL {
  public static func canonicalize(_ raw: String) -> Result<String, CanonicalURLError> {
    guard
      let components = URLComponents(string: raw),
      let rawScheme = components.scheme
    else {
      return .failure(.unparseable)
    }

    let scheme = rawScheme.lowercased()
    guard scheme == "http" || scheme == "https" else {
      return .failure(.unsupportedScheme(scheme))
    }

    guard components.user == nil, components.password == nil else {
      return .failure(.userinfoPresent)
    }

    guard let rawHost = components.host, rawHost.isEmpty == false else {
      return .failure(.unparseable)
    }
    let host = rawHost.lowercased()
    let isASCII = host.allSatisfy(\.isASCII)
    let hasPunycodeLabel = host.split(separator: ".").contains { label in
      label.hasPrefix("xn--")
    }
    guard isASCII, hasPunycodeLabel == false else {
      return .failure(.nonASCIIHost)
    }

    var portSuffix = ""
    if let port = components.port {
      guard port == 80 || port == 443 else {
        return .failure(.unsupportedPort(port))
      }
      let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
      if isDefault == false {
        portSuffix = ":\(port)"
      }
    }

    let rawPath = components.percentEncodedPath
    let path = rawPath.isEmpty ? "/" : normalizeEscapeHex(rawPath)
    let querySuffix = components.percentEncodedQuery.map { query in
      "?" + normalizeEscapeHex(query)  // byte-for-byte after the one pass (rev.1 M2)
    }

    return .success("\(scheme)://\(host)\(portSuffix)\(path)\(querySuffix ?? "")")
    // fragment: dropped — never sent on the wire
  }

  /// The single percent-normalization pass: uppercase the two hex digits of every valid `%XX`
  /// escape; every other byte is preserved verbatim. Deliberately no decoding — decoding would
  /// change the displayed bytes the owner judges.
  static func normalizeEscapeHex(_ text: String) -> String {
    var output = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      guard scalar == "%", index + 2 < scalars.count,
        isHexDigit(scalars[index + 1]), isHexDigit(scalars[index + 2])
      else {
        output.append(scalar)
        index += 1
        continue
      }
      output.append(scalar)
      output.append(uppercased(scalars[index + 1]))
      output.append(uppercased(scalars[index + 2]))
      index += 3
    }
    return String(output)
  }

  private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) || ("A"..."F").contains(scalar)
  }

  private static func uppercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
    guard ("a"..."f").contains(scalar) else {
      return scalar
    }
    return Unicode.Scalar(scalar.value - 32) ?? scalar
  }
}
