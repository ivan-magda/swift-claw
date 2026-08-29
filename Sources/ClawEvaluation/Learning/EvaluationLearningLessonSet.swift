import ClawCore
import Foundation

package struct EvaluationLearningLessonSet: Codable, Sendable, Equatable {
  package let schemaVersion: Int
  package let lessons: [String]

  package var canonicalData: Data {
    get throws {
      try EvaluationCanonicalJSON.data(encoding: self)
    }
  }

  package var sha256: String {
    get throws {
      SHA256Digest.hex(try canonicalData)
    }
  }

  package static func decodeCanonical(_ data: Data) throws -> Self {
    let object = try EvaluationLearningClosedJSON.object(from: data)
    guard Set(object.keys) == ["lessons", "schema_version"] else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }

    let lessonSet: Self
    do {
      lessonSet = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
    guard
      lessonSet.schemaVersion == 1,
      lessonSet.lessons.count <= 3,
      lessonSet.lessons.allSatisfy({ lesson in
        lesson.isEmpty == false && lesson.lengthOfBytes(using: .utf8) <= 512
      }),
      Set(lessonSet.lessons).count == lessonSet.lessons.count,
      try lessonSet.canonicalData == data
    else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
    return lessonSet
  }

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case lessons
  }
}

package struct EvaluationLearningPageTask: Codable, Sendable, Equatable {
  package let beforeHTML: String
  package let afterHTML: String
  package let regionIDs: [String]

  enum CodingKeys: String, CodingKey {
    case beforeHTML = "before_html"
    case afterHTML = "after_html"
    case regionIDs = "region_ids"
  }
}

package struct EvaluationLearningTaskCarrier: Codable, Sendable, Equatable {
  package let activeLessons: EvaluationLearningLessonSet
  package let schemaVersion: Int
  package let task: EvaluationLearningPageTask
  package let taskID: String

  package static func loadCanonical(from url: URL) throws -> (Self, Data) {
    let data = try EvaluationPathSecurity.readRegularSingleLinkFile(at: url)
    let object = try EvaluationLearningClosedJSON.object(from: data)
    guard
      Set(object.keys) == ["active_lessons", "schema_version", "task", "task_id"],
      let activeLessons = object["active_lessons"] as? [String: Any],
      Set(activeLessons.keys) == ["lessons", "schema_version"],
      let task = object["task"] as? [String: Any],
      Set(task.keys) == ["before_html", "after_html", "region_ids"]
    else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }

    _ = try EvaluationLearningLessonSet.decodeCanonical(
      EvaluationCanonicalJSON.data(fromJSONObject: activeLessons)
    )

    let carrier: Self
    do {
      carrier = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
    guard carrier.schemaVersion == 1, carrier.taskID.isEmpty == false else {
      throw EvaluationLearningAdmissionError.invalidJSON
    }
    return (carrier, data)
  }

  enum CodingKeys: String, CodingKey {
    case activeLessons = "active_lessons"
    case schemaVersion = "schema_version"
    case task
    case taskID = "task_id"
  }
}
