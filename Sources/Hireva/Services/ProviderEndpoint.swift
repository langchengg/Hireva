import Foundation

/// A provider endpoint that has passed the complete URL safety policy.
///
/// The raw input is deliberately never retained. Callers persist and display
/// `absoluteString`, which is reconstructed from validated components.
struct ProviderEndpoint: Hashable, Sendable {
    enum Policy: Hashable, Sendable {
        case deepSeek
        case openAICompatible
        case cloudEmbedding
        case ollamaLocal
    }

    enum ValidationError: LocalizedError, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        case invalidSyntax
        case unsafeComponent
        case missingHost
        case unsupportedScheme
        case remoteHTTP
        case unsafeHost
        case unsafePath
        case deepSeekEndpointRequired
        case ollamaEndpointRequired

        var errorDescription: String? {
            switch self {
            case .invalidSyntax:
                return "The provider endpoint is not a valid absolute URL."
            case .unsafeComponent:
                return "The provider endpoint contains a component that is not allowed."
            case .missingHost:
                return "The provider endpoint must include a host."
            case .unsupportedScheme:
                return "The provider endpoint must use HTTPS, except for an approved local endpoint."
            case .remoteHTTP:
                return "Unencrypted HTTP is allowed only for a canonical loopback endpoint."
            case .unsafeHost:
                return "The provider endpoint host is not in an accepted canonical form."
            case .unsafePath:
                return "The provider endpoint path is not in an accepted canonical form."
            case .deepSeekEndpointRequired:
                return "DeepSeek must use its pinned HTTPS API endpoint."
            case .ollamaEndpointRequired:
                return "Ollama must use the fixed local port and an empty base path."
            }
        }

        var description: String { errorDescription ?? "Invalid provider endpoint." }
        var debugDescription: String { description }
    }

    struct Origin: Hashable, Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    static let deepSeekDefault: ProviderEndpoint = {
        // This literal is controlled by the application and covered by tests.
        try! ProviderEndpoint("https://api.deepseek.com", policy: .deepSeek)
    }()

    static let ollamaDefault: ProviderEndpoint = {
        // A numeric loopback address avoids DNS or search-domain resolution.
        try! ProviderEndpoint("http://127.0.0.1:11434", policy: .ollamaLocal)
    }()

    let url: URL
    let absoluteString: String
    let origin: Origin
    let isLocal: Bool

    init(_ input: String, policy: Policy) throws {
        guard input.utf8.count <= 2_048,
              !input.isEmpty,
              !input.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.whitespacesAndNewlines.contains($0)
              }),
              !input.contains("\\"),
              !input.contains("%") else {
            throw ValidationError.unsafeComponent
        }

        guard let parsed = URLComponents(string: input, encodingInvalidCharacters: false),
              let rawScheme = parsed.scheme,
              parsed.url != nil else {
            throw ValidationError.invalidSyntax
        }
        guard parsed.user == nil,
              parsed.password == nil,
              parsed.query == nil,
              parsed.fragment == nil else {
            throw ValidationError.unsafeComponent
        }
        guard let rawHost = parsed.host, !rawHost.isEmpty else {
            throw ValidationError.missingHost
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw ValidationError.unsupportedScheme
        }

        let host = rawHost.lowercased()
        guard Self.isCanonicalHost(host) else {
            throw ValidationError.unsafeHost
        }

        let isLocal = Self.isCanonicalLoopbackHost(host)
        if scheme == "http", !isLocal {
            throw ValidationError.remoteHTTP
        }

        let path = try Self.canonicalPath(parsed.path)
        let suppliedPort = parsed.port
        let defaultPort = scheme == "https" ? 443 : 80
        let effectivePort = suppliedPort ?? defaultPort

        switch policy {
        case .deepSeek:
            guard scheme == "https",
                  host == "api.deepseek.com",
                  effectivePort == 443,
                  path.isEmpty || path == "/v1" else {
                throw ValidationError.deepSeekEndpointRequired
            }
        case .openAICompatible, .cloudEmbedding:
            break
        case .ollamaLocal:
            guard scheme == "http",
                  isLocal,
                  effectivePort == 11_434,
                  path.isEmpty else {
                throw ValidationError.ollamaEndpointRequired
            }
        }

        var canonical = URLComponents()
        canonical.scheme = scheme
        canonical.host = host
        canonical.port = suppliedPort == defaultPort ? nil : suppliedPort
        canonical.path = path
        guard let canonicalURL = canonical.url,
              let canonicalString = canonical.string else {
            throw ValidationError.invalidSyntax
        }

        self.url = canonicalURL
        self.absoluteString = canonicalString
        self.origin = Origin(scheme: scheme, host: host, port: effectivePort)
        self.isLocal = isLocal
    }

    func appendingPathComponent(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }

    static func policy(for kind: LLMProviderKind) -> Policy? {
        switch kind {
        case .deepSeek:
            return .deepSeek
        case .openAICompatible, .openAI, .anthropic, .gemini:
            return .openAICompatible
        case .ollamaLocal:
            return .ollamaLocal
        }
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        guard let firstOrigin = canonicalOrigin(of: first),
              let secondOrigin = canonicalOrigin(of: second) else {
            return false
        }
        return firstOrigin == secondOrigin
    }

    private static func canonicalOrigin(of url: URL) -> Origin? {
        let input = url.absoluteString
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !input.contains("\\"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              isCanonicalHost(host) else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        return Origin(scheme: scheme, host: host, port: components.port ?? defaultPort)
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard path.utf8.count <= 512 else {
            throw ValidationError.unsafePath
        }
        if path.isEmpty || path == "/" {
            return ""
        }
        guard path.hasPrefix("/"),
              !path.dropFirst().contains("//") else {
            throw ValidationError.unsafePath
        }

        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        for segment in normalized.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
            guard !segment.isEmpty,
                  segment != ".",
                  segment != "..",
                  segment.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw ValidationError.unsafePath
            }
        }
        return normalized
    }

    private static func isCanonicalHost(_ host: String) -> Bool {
        guard host.utf8.count <= 253,
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              !host.contains(".."),
              host.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return false
        }

        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]") else { return false }
            let body = host.dropFirst().dropLast()
            return !body.isEmpty && body.allSatisfy { $0.isHexDigit || $0 == ":" }
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isCanonicalLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "[::1]"
    }
}

enum ProviderCredentialAccount {
    static func providerAccount(
        id: UUID,
        kind: LLMProviderKind,
        endpoint: ProviderEndpoint?
    ) -> String {
        if kind == .deepSeek {
            if id == LLMProviderConfiguration.deepSeekDefaultID {
                return KeychainConstants.deepSeekAccount
            }
            return "deepseek.\(id.uuidString.lowercased())"
        }

        let scope = endpoint.map(accountScope) ?? "unconfigured"
        return "provider.\(kind.rawValue).\(id.uuidString.lowercased()).\(scope)"
    }

    static func embeddingAccount(
        kind: EmbeddingProviderKind,
        endpoint: ProviderEndpoint
    ) -> String {
        if kind == .openAICompatibleCloud,
           endpoint.absoluteString == "https://api.openai.com/v1" {
            return KeychainConstants.defaultEmbeddingAccount
        }
        return "embedding.\(kind.rawValue).\(accountScope(endpoint))"
    }

    static func isReservedForDeepSeek(_ account: String?) -> Bool {
        guard let account else { return false }
        return account == KeychainConstants.deepSeekAccount || account.hasPrefix("deepseek.")
    }

    private static func accountScope(_ endpoint: ProviderEndpoint) -> String {
        let host = endpoint.origin.host.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        }
        return "\(endpoint.origin.scheme).\(String(host)).\(endpoint.origin.port)"
    }
}

extension LLMProviderConfiguration {
    static let deepSeekDefaultID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func validatedForLiveUse() throws -> LLMProviderConfiguration {
        var result = self
        let endpoint: ProviderEndpoint?
        if let policy = ProviderEndpoint.policy(for: kind) {
            endpoint = try ProviderEndpoint(baseURL, policy: policy)
            result.baseURL = endpoint?.absoluteString ?? baseURL
        } else {
            endpoint = nil
        }

        if kind == .ollamaLocal {
            result.apiKeyAccount = nil
        } else if let endpoint {
            result.apiKeyAccount = ProviderCredentialAccount.providerAccount(
                id: id,
                kind: kind,
                endpoint: endpoint
            )
        }
        return result
    }

    var endpointIsLocal: Bool {
        guard let policy = ProviderEndpoint.policy(for: kind),
              let endpoint = try? ProviderEndpoint(baseURL, policy: policy) else {
            return false
        }
        return endpoint.isLocal
    }
}

extension AppSettings {
    func validatedForLiveUse() throws -> AppSettings {
        var result = self
        switch embeddingProviderKind {
        case .openAICompatibleCloud, .customCloud:
            let endpoint = try ProviderEndpoint(embeddingBaseURL, policy: .cloudEmbedding)
            result.embeddingBaseURL = endpoint.absoluteString
            result.embeddingApiKeyAccount = ProviderCredentialAccount.embeddingAccount(
                kind: embeddingProviderKind,
                endpoint: endpoint
            )
        case .disabled, .localOllama, .mock:
            if ProviderCredentialAccount.isReservedForDeepSeek(embeddingApiKeyAccount) {
                result.embeddingApiKeyAccount = KeychainConstants.defaultEmbeddingAccount
            }
        }
        return result
    }
}

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let destinationURL = request.url,
              ProviderEndpoint.sameOrigin(originalURL, destinationURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum ProviderNetworkSession {
    static func sameOriginProtected(copying session: URLSession) -> URLSession {
        URLSession(
            configuration: session.configuration,
            delegate: SameOriginRedirectDelegate(),
            delegateQueue: nil
        )
    }
}
