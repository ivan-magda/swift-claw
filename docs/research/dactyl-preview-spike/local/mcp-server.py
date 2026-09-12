from mcp.server.fastmcp import FastMCP


mcp = FastMCP("swiftui-preview-spike", host="127.0.0.1", port=8767)


@mcp.tool()
def render_swiftui(source: str) -> str:
    """Accept SwiftUI source and return the handoff used by the connectivity probe."""
    return f"accepted {len(source)} characters; preview transport is reachable"


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
