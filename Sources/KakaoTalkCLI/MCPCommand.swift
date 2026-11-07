import ArgumentParser
import Darwin
import KakaoMCP

extension KakaoTalkCLI {
    struct MCPCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mcp",
            abstract: "Run the local MCP server over standard input/output for LLM clients."
        )

        @Flag(help: "Disable outbound message sending. Search/open/read tools remain available and can mark chats read.")
        var readOnly = false

        func run() async throws {
            guard isatty(STDIN_FILENO) == 0 else {
                throw ValidationError("The MCP server must be launched by an MCP client with piped input, not an interactive terminal.")
            }
            try await KakaoMCPService.run(allowsSending: !readOnly)
        }
    }
}