import Testing

@testable import ClawMCP

@Suite("MCP tool namer")
struct MCPToolNamerTests {
  @Test("fragments outside the tool-name charset fold to underscores")
  func sanitizesFragments() {
    // given
    let coordinates = [MCPToolCoordinate(server: "my-server", remoteName: "list issues!")]

    // when
    let assigned = MCPToolNamer.assign(coordinates)

    // then
    #expect(assigned.map(\.localName) == ["mcp__my_server__list_issues_"])
  }

  @Test("a verbose server name is capped before it can crowd out the tool")
  func capsServerFragment() throws {
    // given
    let server = String(repeating: "s", count: 45)
    let coordinates = [MCPToolCoordinate(server: server, remoteName: "list")]

    // when
    let name = try #require(MCPToolNamer.assign(coordinates).first?.localName)

    // then
    #expect(name == "mcp__" + String(repeating: "s", count: 30) + "__list")
  }

  @Test("a composed name never exceeds the total cap")
  func capsTotalName() throws {
    // given
    let coordinates = [
      MCPToolCoordinate(
        server: String(repeating: "s", count: 40),
        remoteName: String(repeating: "t", count: 90)
      )
    ]

    // when
    let name = try #require(MCPToolNamer.assign(coordinates).first?.localName)

    // then
    #expect(name.count == MCPToolNamer.nameLimit)
    #expect(name.hasPrefix("mcp__" + String(repeating: "s", count: 30) + "__"))
  }

  @Test("names that fold together get deterministic numeric suffixes")
  func suffixesCollisions() {
    // given — distinct remote names that sanitize to the same fragment
    let coordinates = [
      MCPToolCoordinate(server: "linear", remoteName: "list issues"),
      MCPToolCoordinate(server: "linear", remoteName: "list-issues"),
      MCPToolCoordinate(server: "linear", remoteName: "list.issues"),
    ]

    // when
    let names = MCPToolNamer.assign(coordinates).map(\.localName)

    // then
    #expect(
      names == [
        "mcp__linear__list_issues", "mcp__linear__list_issues_2", "mcp__linear__list_issues_3",
      ]
    )
    #expect(MCPToolNamer.assign(coordinates).map(\.localName) == names)
  }

  @Test("a suffixed name still fits the total cap")
  func suffixedNameStaysCapped() {
    // given
    let remote = String(repeating: "t", count: 90)
    let coordinates = [
      MCPToolCoordinate(server: "linear", remoteName: remote),
      MCPToolCoordinate(server: "linear", remoteName: remote),
    ]

    // when
    let names = MCPToolNamer.assign(coordinates).map(\.localName)

    // then
    #expect(names.allSatisfy { $0.count <= MCPToolNamer.nameLimit })
    #expect(names[1].hasSuffix("_2"))
    #expect(names[0] != names[1])
  }

  @Test("appending a server leaves the earlier servers' names untouched")
  func configOrderIsStable() {
    // given
    let existing = [
      MCPToolCoordinate(server: "linear", remoteName: "list"),
      MCPToolCoordinate(server: "notion", remoteName: "list"),
    ]
    let extended = existing + [MCPToolCoordinate(server: "github", remoteName: "list")]

    // when
    let before = MCPToolNamer.assign(existing).map(\.localName)
    let after = MCPToolNamer.assign(extended).map(\.localName)

    // then
    #expect(Array(after.prefix(before.count)) == before)
    #expect(after.last == "mcp__github__list")
  }

  @Test("a fragment that folds away to nothing still yields a usable name")
  func emptyFragmentsFallBack() {
    // given
    let coordinates = [MCPToolCoordinate(server: "linear", remoteName: "")]

    // when
    let names = MCPToolNamer.assign(coordinates).map(\.localName)

    // then
    #expect(names == ["mcp__linear__tool"])
  }

  @Test("every composed name carries the mcp prefix no built-in uses")
  func neverCollidesWithBuiltIns() {
    // given — the built-in registry vocabulary a remote tool must not be able to shadow
    let builtIns = [
      "file_read", "file_write", "web_fetch", "web_search", "memory_write", "execute_code",
    ]
    let coordinates = builtIns.map { name in
      MCPToolCoordinate(server: "linear", remoteName: name)
    }

    // when
    let names = MCPToolNamer.assign(coordinates).map(\.localName)

    // then
    #expect(names.allSatisfy { $0.hasPrefix(MCPToolNamer.prefix) })
    #expect(builtIns.allSatisfy { $0.hasPrefix(MCPToolNamer.prefix) == false })
    #expect(Set(names).isDisjoint(with: Set(builtIns)))
  }
}
