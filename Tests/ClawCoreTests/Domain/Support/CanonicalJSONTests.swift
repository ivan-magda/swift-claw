import ClawCore
import Foundation
import Testing

@Suite struct CanonicalJSONTests {
  @Test func strictIntegerRejectsJSONBooleans() throws {
    // given
    let object = try #require(
      JSONSerialization.jsonObject(
        with: Data(#"{"integer":1,"fraction":1.5,"boolean":true}"#.utf8)
      )
        as? [String: Any]
    )

    // when
    let integer = CanonicalJSON.integer(object["integer"])
    let fraction = CanonicalJSON.integer(object["fraction"])
    let booleanAsInteger = CanonicalJSON.integer(object["boolean"])
    let boolean = CanonicalJSON.boolean(object["boolean"])
    let integerAsBoolean = CanonicalJSON.boolean(object["integer"])

    // then
    #expect(integer == 1)
    #expect(fraction == nil)
    #expect(booleanAsInteger == nil)
    #expect(boolean == true)
    #expect(integerAsBoolean == nil)
  }
}
