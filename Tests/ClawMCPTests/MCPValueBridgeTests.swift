import ClawCore
import MCP
import Testing

@testable import ClawMCP

@Suite struct MCPValueBridgeTests {
  @Test func integerIdentifiersRoundTripWithoutLosingPrecision() {
    // given
    let identifier = 9_007_199_254_740_993

    // when
    let json = MCPValueBridge.jsonValue(.int(identifier))
    let roundTrip = MCPValueBridge.value(json)

    // then
    #expect(json == .integer(identifier))
    #expect(roundTrip == .int(identifier))
  }
}
