import ClawCore
import Foundation

struct SystemStatusDocument: Decodable {
  let status: String
}

// All four fields stay required even though only appName/version drive the gate: decoding pins
// the expected v1.1.0 CLI row shape and rejects unrelated {appName, version} payloads from a
// different command.
struct SystemVersionDocument: Decodable {
  let version: String
  let buildType: String
  let commit: String
  let appName: String
}

struct ListedContainer: Decodable, Sendable {
  struct Configuration: Decodable, Sendable {
    let id: String?
    let labels: [String: String]?
  }

  let id: String?
  let configuration: Configuration?

  var resolvedIdentifier: String? {
    id ?? configuration?.id
  }

  var labels: [String: String] {
    configuration?.labels ?? [:]
  }
}

struct SystemPropertiesDocument: Decodable {
  struct Vminit: Decodable {
    let image: String
  }

  let vminit: Vminit
}

struct ImageInspectDocument: Decodable {
  struct Configuration: Decodable {
    struct Descriptor: Decodable {
      let digest: String
    }

    let name: String

    let descriptor: Descriptor
  }

  let configuration: Configuration
}

struct ContainerInspectDocument: Decodable {
  struct Configuration: Decodable {
    struct Image: Decodable {
      struct Descriptor: Decodable {
        let digest: String
      }

      let reference: String

      let descriptor: Descriptor
    }

    struct Resources: Decodable {
      let cpus: Int
      let memoryInBytes: UInt64
    }

    let id: String
    let image: Image
    let labels: [String: String]
    let resources: Resources
    let readOnly: Bool
    let useInit: Bool
    let capAdd: [String]
    let capDrop: [String]
  }

  struct Status: Decodable {
    let state: String
  }

  let configuration: Configuration

  let status: Status
}
