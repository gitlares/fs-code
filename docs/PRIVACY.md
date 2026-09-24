# Privacy

FS Code does not include a product analytics collector or a crash-reporting SDK. Local agent activity records exist to display progress and restore conversation history. They are not sent to a separate FS Code analytics service.

The app contacts the AI provider you configure for sign-in, model discovery, and model requests. Requests can contain your messages, project instructions, referenced file content, and tool results. Review provider policies before using confidential code. Local storage is not a claim of end-to-end encryption or provider-side privacy.

Project metadata is stored locally under Application Support and project `.fs/` / `.fscode/` folders. Credentials use macOS Keychain. Exclude project state from public repositories; it can contain conversation text, paths, and previous file content.

Sparkle update checks require a configured feed. Automatic checks and automatic installation are disabled by default. Manual checks, when enabled in a distribution build, contact its update host. Downloading releases contacts GitHub. macOS system diagnostics and tools you run have their own behavior.

The integrated terminal runs your local shell. Commands, MCP servers if added later, and other external tools have their own network/data practices. FS Code's no-analytics policy does not control those services.
