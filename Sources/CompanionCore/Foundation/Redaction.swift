import Foundation
import os

/// Redacts secrets before anything reaches diagnostics. Logs are content-free by default.
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_\-]{8,}"#,                 // OpenAI / Anthropic / DeepSeek style keys
        #"sk-ant-[A-Za-z0-9_\-]{8,}"#,
        #"ya29\.[A-Za-z0-9_\-\.]+"#,                // Google access tokens
        #"1//[A-Za-z0-9_\-]{10,}"#,                 // Google refresh tokens
        #"(?i)(bearer\s+)[A-Za-z0-9_\-\.=]+"#,
        #"(?i)(access_token|refresh_token|code|client_secret|api_key|x-api-key)=([^&\s]+)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        var result = text
        for regex in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "[REDACTED]")
        }
        return result
    }
}

public enum Log {
    public static let subsystem = "app.companion.mac"
    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let index = Logger(subsystem: subsystem, category: "index")
    public static let policy = Logger(subsystem: subsystem, category: "policy")
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    public static let google = Logger(subsystem: subsystem, category: "google")

    /// Content-free diagnostic message with secrets removed.
    public static func info(_ logger: Logger, _ message: String) {
        let safe = Redactor.redact(message)
        logger.info("\(safe, privacy: .public)")
    }

    public static func error(_ logger: Logger, _ message: String) {
        let safe = Redactor.redact(message)
        logger.error("\(safe, privacy: .public)")
    }
}
