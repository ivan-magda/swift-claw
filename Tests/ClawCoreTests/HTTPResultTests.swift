import ClawCore
import Foundation
import Testing

@Suite struct HTTPResultTests {
  @Test func headerLookupIsCaseInsensitive() {
    // given
    let result = HTTPResult(
      statusCode: 200,
      headers: ["X-LiteLLM-Response-Cost": "0.0023", "Retry-After": "7"],
      body: Data()
    )

    // when / then
    #expect(result.header("x-litellm-response-cost") == "0.0023")
    #expect(result.header("RETRY-AFTER") == "7")
    #expect(result.header("absent") == nil)
  }
}
