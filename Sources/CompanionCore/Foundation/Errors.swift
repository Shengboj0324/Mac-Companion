import Foundation

/// Product-level error taxonomy. Messages are user-facing and must never contain
/// credentials, tokens or document bodies.
public enum CompanionError: Error, Equatable, LocalizedError, Sendable {
    case database(String)
    case incompatibleDatabase(found: Int, supported: Int)
    case notFound(String)
    case permissionDenied(String)
    case policyViolation(String)
    case approvalInvalid(String)
    case staleSource(String)
    case collision(String)
    case pathEscape(String)
    case unsupported(String)
    case invalidArgument(String)
    case malformedResponse(String)
    case keychain(String)
    case budgetExceeded(String)
    case provider(ProviderErrorKind, String)
    case google(String)
    case notConfigured(String)
    case cancelled
    case outcomeUnknown(String)

    public var errorDescription: String? {
        switch self {
        case .database(let m): return "Database error: \(m)"
        case .incompatibleDatabase(let f, let s):
            return "This database uses schema version \(f), but this version of Companion supports up to \(s). Update Companion instead of downgrading."
        case .notFound(let m): return "Not found: \(m)"
        case .permissionDenied(let m): return "Permission needed: \(m)"
        case .policyViolation(let m): return "Blocked by policy: \(m)"
        case .approvalInvalid(let m): return "Approval is no longer valid: \(m)"
        case .staleSource(let m): return "The source changed since it was reviewed: \(m)"
        case .collision(let m): return "A file already exists at the destination: \(m)"
        case .pathEscape(let m): return "Path is outside the approved locations: \(m)"
        case .unsupported(let m): return "Not supported: \(m)"
        case .invalidArgument(let m): return "Invalid argument: \(m)"
        case .malformedResponse(let m): return "Unexpected response: \(m)"
        case .keychain(let m): return "Keychain error: \(m)"
        case .budgetExceeded(let m): return "Budget limit reached: \(m)"
        case .provider(let kind, let m): return "\(kind.userMessage) \(m)"
        case .google(let m): return "Google: \(m)"
        case .notConfigured(let m): return "Not configured: \(m)"
        case .cancelled: return "Cancelled."
        case .outcomeUnknown(let m): return "Outcome unknown until reconciled: \(m)"
        }
    }
}

public enum ProviderErrorKind: String, Codable, Sendable {
    case invalidKey, insufficientBalance, unsupportedModel, rateLimited, overloaded,
         timeout, network, badRequest, refused, server, unknown

    public var userMessage: String {
        switch self {
        case .invalidKey: return "The API key was rejected. Check it in Settings → Providers."
        case .insufficientBalance: return "The provider account has insufficient balance or quota."
        case .unsupportedModel: return "The selected model is not available for this key."
        case .rateLimited: return "The provider is rate limiting requests. Try again shortly."
        case .overloaded: return "The provider is temporarily overloaded."
        case .timeout: return "The request timed out."
        case .network: return "The network is unavailable. Local search still works."
        case .badRequest: return "The provider rejected the request."
        case .refused: return "The model declined this request."
        case .server: return "The provider returned a server error."
        case .unknown: return "The provider returned an unexpected error."
        }
    }

    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .timeout, .network, .server: return true
        default: return false
        }
    }
}
