// Copy this file to Secrets.swift (gitignored) and fill in your values.
// Secrets.swift is compiled into the app AND the widget extension — the
// widget has no UI, so it reads its connection details from here.
enum Secrets {
    /// Paperclip host on your tailnet, host:port — no scheme.
    static let host = "atlas.your-tailnet.ts.net:3100"
    /// Board API key (Authorization: Bearer …), minted via POST /api/board-api-keys.
    static let token = "pcp_board_..."
    /// Company UUID.
    static let companyId = "00000000-0000-0000-0000-000000000000"
    /// paperclip-bridge (SSE live stream), host:port — see agents/paperclip-bridge.
    static let bridgeHost = "atlas.your-tailnet.ts.net:3111"
}
