import Foundation

/// Google account lifecycle: system-browser OAuth with PKCE + state, refresh
/// tokens in Keychain, short-lived access tokens in memory only (spec §6).
public final class GoogleAuthService: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let clock: Clock
    private let secrets: SecretStore
    private let transport: HTTPTransport
    private let activity: ActivityLog
    public var config: GoogleConfig
    private let lock = NSLock()
    private var accessTokens: [UUID: (token: String, expires: Date)] = [:]
    private var activeReceiver: LoopbackReceiver?

    public init(db: SQLiteDatabase, clock: Clock, secrets: SecretStore, transport: HTTPTransport, activity: ActivityLog, config: GoogleConfig) {
        self.db = db; self.clock = clock; self.secrets = secrets; self.transport = transport; self.activity = activity; self.config = config
    }

    // MARK: Accounts

    public func accounts() -> [ConnectorAccount] {
        ((try? db.query("SELECT * FROM connector_accounts WHERE provider='google' ORDER BY created_at")) ?? []).compactMap(Self.decode)
    }

    public func account(_ id: UUID) -> ConnectorAccount? {
        (try? db.queryOne("SELECT * FROM connector_accounts WHERE id=?", [id])).flatMap(Self.decode)
    }

    // MARK: Sign-in

    /// Runs the desktop OAuth flow. `openURL` opens the system browser.
    public func signIn(mode: GoogleAccessMode = .selectedDocuments, openURL: @Sendable (URL) -> Void) async throws -> ConnectorAccount {
        guard config.isConfigured else {
            throw CompanionError.notConfigured("Google sign-in needs a developer OAuth client ID (see docs/GOOGLE_SETUP.md)")
        }
        let pkce = PKCE()
        let receiver = LoopbackReceiver(expectedState: pkce.state)
        try await receiver.start()
        lock.withLock { activeReceiver = receiver }
        defer { lock.withLock { activeReceiver = nil }; receiver.stop() }
        openURL(pkce.authorizationURL(config: config, redirectURI: receiver.redirectURI, scopes: mode.scopes))
        let code = try await receiver.waitForCode()
        let tokens = try await exchange(code: code, verifier: pkce.verifier, redirectURI: receiver.redirectURI)
        return try storeAccount(tokens: tokens, requestedScopes: mode.scopes)
    }

    public func cancelSignIn() { lock.withLock { activeReceiver }?.cancel() }

    struct TokenResponse { let accessToken: String; let expiresIn: Double; let refreshToken: String?; let idToken: String?; let scope: String? }

    func exchange(code: String, verifier: String, redirectURI: String) async throws -> TokenResponse {
        var form = ["code": code, "client_id": config.clientID, "code_verifier": verifier,
                    "grant_type": "authorization_code", "redirect_uri": redirectURI]
        if let s = config.clientSecret { form["client_secret"] = s }
        return try await tokenRequest(form)
    }

    func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: GoogleConfig.tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(Self.formEncode(form).utf8)
        let (data, http) = try await transport.data(for: req)
        let obj = (try? JSON.object(data)) ?? [:]
        guard http.statusCode == 200, let access = obj["access_token"] as? String else {
            let err = obj["error"] as? String ?? "http_\(http.statusCode)"
            if err == "invalid_grant" { throw CompanionError.permissionDenied("Google access expired or was revoked — reconnect the account") }
            throw CompanionError.google("Token request failed (\(err))")
        }
        return TokenResponse(accessToken: access, expiresIn: obj["expires_in"] as? Double ?? 3_600,
                             refreshToken: obj["refresh_token"] as? String, idToken: obj["id_token"] as? String, scope: obj["scope"] as? String)
    }

    func storeAccount(tokens: TokenResponse, requestedScopes: [String]) throws -> ConnectorAccount {
        guard let idToken = tokens.idToken, let claims = Self.decodeJWTClaims(idToken), let sub = claims["sub"] as? String else {
            throw CompanionError.google("Google did not return an account identity")
        }
        let email = claims["email"] as? String ?? "Google account"
        let granted = tokens.scope?.split(separator: " ").map(String.init) ?? requestedScopes
        // Alpha supports one connected account; same identity reconnects in place.
        let existing = accounts()
        if let other = existing.first(where: { $0.subject != sub && $0.status != .disconnected }) {
            throw CompanionError.unsupported("Disconnect \(other.displayIdentity) before connecting a different Google account")
        }
        let id = existing.first(where: { $0.subject == sub })?.id ?? UUID()
        let keyRef = SecretAccounts.googleRefresh(id)
        if let r = tokens.refreshToken { try secrets.setString(r, for: keyRef) }
        else if secrets.string(keyRef) == nil { throw CompanionError.google("No refresh token returned; try connecting again") }
        let now = clock.now()
        try db.execute("""
            INSERT INTO connector_accounts(id, provider, subject, display_identity, scopes, keychain_ref, status, last_refresh, created_at)
            VALUES(?, 'google', ?, ?, ?, ?, 'connected', ?, ?)
            ON CONFLICT(provider, subject) DO UPDATE SET display_identity=excluded.display_identity, scopes=excluded.scopes,
                status='connected', last_refresh=excluded.last_refresh
            """, [id, sub, email, try JSON.encode(granted), keyRef, now, now])
        lock.withLock { accessTokens[id] = (tokens.accessToken, now.addingTimeInterval(tokens.expiresIn - 60)) }
        activity.record(kind: "google", summary: "Connected Google account \(email)")
        guard let account = account(id) else { throw CompanionError.database("Account not saved") }
        return account
    }

    // MARK: Tokens

    /// Returns a valid access token, refreshing if needed. Never logged or persisted.
    public func accessToken(for accountID: UUID, forceRefresh: Bool = false) async throws -> String {
        let now = clock.now()
        if !forceRefresh, let cached = lock.withLock({ accessTokens[accountID] }), cached.expires > now { return cached.token }
        guard let account = account(accountID), account.status == .connected || account.status == .expired else {
            throw CompanionError.permissionDenied("Google account is not connected")
        }
        guard let refresh = secrets.string(account.keychainRef) else {
            setStatus(accountID, .expired)
            throw CompanionError.permissionDenied("Reconnect your Google account")
        }
        var form = ["refresh_token": refresh, "client_id": config.clientID, "grant_type": "refresh_token"]
        if let s = config.clientSecret { form["client_secret"] = s }
        do {
            let t = try await tokenRequest(form)
            let expiry = clock.now().addingTimeInterval(t.expiresIn - 60)
            lock.withLock { accessTokens[accountID] = (t.accessToken, expiry) }
            try? db.execute("UPDATE connector_accounts SET last_refresh=?, status='connected' WHERE id=?", [clock.now(), accountID])
            return t.accessToken
        } catch let e as CompanionError {
            if case .permissionDenied = e { setStatus(accountID, .revoked) }
            throw e
        }
    }

    func setStatus(_ id: UUID, _ status: ConnectorStatus) {
        try? db.execute("UPDATE connector_accounts SET status=? WHERE id=?", [status.rawValue, id])
    }

    // MARK: Disconnect

    /// Stops polling, optionally revokes the token, removes Keychain secrets and
    /// purges derived caches. Project notes are kept only if requested.
    public func disconnect(_ accountID: UUID, revoke: Bool, purge: (UUID) throws -> Void) async throws {
        guard let account = account(accountID) else { return }
        if revoke, let refresh = secrets.string(account.keychainRef) {
            var req = URLRequest(url: GoogleConfig.revokeEndpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(Self.formEncode(["token": refresh]).utf8)
            _ = try? await transport.data(for: req)
        }
        try? secrets.delete(account.keychainRef)
        lock.withLock { accessTokens[accountID] = nil }
        try purge(accountID)
        try db.execute("DELETE FROM sync_cursors WHERE account_id=?", [accountID])
        try db.execute("DELETE FROM connector_accounts WHERE id=?", [accountID])
        activity.record(kind: "google", summary: "Disconnected \(account.displayIdentity)\(revoke ? " and revoked access" : "") — cached content purged")
    }

    // MARK: Helpers

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
    }

    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = PKCE.decodeBase64URL(String(parts[1])) else { return nil }
        return try? JSON.object(data)
    }

    static func decode(_ r: SQLRow) -> ConnectorAccount? {
        guard let id = r.uuid("id"), let created = r.date("created_at") else { return nil }
        return ConnectorAccount(id: id, provider: r.string("provider") ?? "google", subject: r.string("subject") ?? "",
                                displayIdentity: r.string("display_identity") ?? "", scopes: r.json("scopes", as: [String].self) ?? [],
                                keychainRef: r.string("keychain_ref") ?? "",
                                status: ConnectorStatus(rawValue: r.string("status") ?? "") ?? .disconnected,
                                lastRefresh: r.date("last_refresh"), createdAt: created)
    }
}
