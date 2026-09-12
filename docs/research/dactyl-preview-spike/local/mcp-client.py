import asyncio

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def main() -> None:
    async with streamablehttp_client("http://127.0.0.1:8767/mcp") as streams:
        read_stream, write_stream, _ = streams
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            result = await session.call_tool(
                "render_swiftui",
                {
                    "source": (
                        "import SwiftUI\n"
                        "struct Preview: View { var body: some View { Text(\"Hello\") } }"
                    )
                },
            )
            print(result.content[0].text)


asyncio.run(main())
