//
//  TailscaleClient.swift
//  glas.sh
//
//  Tailscale REST API v2 client for device discovery.
//  Field names match the official tailscale-client-go/v2 Device struct.
//

import Foundation
import Observation
import os
import CryptoKit
import GlasSecretStore

extension Notification.Name {
    static let tailscaleCredentialsDidChange = Notification.Name(
        "sh.glas.tailscaleCredentialsDidChange"
    )
}

// MARK: - API Response (matches official Go client exactly)

private struct TailscaleAPIResponse: Decodable {
    let devices: [TailscaleAPIDevice]
}

private struct TailscaleAPIDevice: Decodable {
    // Required fields from official Go client
    let id: String
    let name: String          // FQDN: "device.tailnet.ts.net"
    let hostname: String      // Short hostname
    let addresses: [String]   // Tailscale IPs: ["100.64.0.1", "fd7a:..."]
    let os: String
    let user: String

    // Optional fields used by the app. Other API fields, including machine and
    // node keys, are deliberately not decoded into retained model objects.
    let lastSeen: String?     // ISO 8601
    let tags: [String]?

}

// MARK: - App Model

struct TailscaleDevice: Identifiable, Hashable {
    static let maximumIDLength = 256
    static let maximumHostnameLength = 253
    static let maximumDisplayNameLength = 512
    static let maximumOSLength = 64
    static let maximumUserLength = 256
    static let maximumAddressCount = 32
    static let maximumAddressLength = 64
    static let maximumTagCount = 64
    static let maximumTagLength = 128

    let id: String
    let hostname: String
    let displayName: String
    let ipAddress: String
    let os: String
    let lastSeen: Date?
    let user: String
    let tags: [String]

    var sshAddress: String { ipAddress }

    init?(
        id: String,
        hostname: String,
        displayName: String,
        addresses: [String],
        os: String,
        lastSeen: Date?,
        user: String,
        rawTags: [String]
    ) {
        guard let id = Self.validatedField(id, maximumLength: Self.maximumIDLength),
              let hostname = Self.validatedField(
                hostname,
                maximumLength: Self.maximumHostnameLength
              ),
              let displayName = Self.validatedField(
                displayName,
                maximumLength: Self.maximumDisplayNameLength
              ),
              let os = Self.validatedField(os, maximumLength: Self.maximumOSLength),
              let user = Self.validatedOptionalField(
                user,
                maximumLength: Self.maximumUserLength
              ),
              addresses.count <= Self.maximumAddressCount,
              rawTags.count <= Self.maximumTagCount,
              let ipAddress = addresses.compactMap(Self.normalizedIPv4Address(from:)).first else {
            return nil
        }

        var seenTags = Set<String>()
        var tags: [String] = []
        for rawTag in rawTags {
            guard let tag = Self.normalizedTag(rawTag) else { return nil }
            if seenTags.insert(tag).inserted {
                tags.append(tag)
            }
        }

        self.id = id
        self.hostname = hostname
        self.displayName = displayName
        self.ipAddress = ipAddress
        self.os = os
        self.lastSeen = lastSeen
        self.user = user
        self.tags = tags
    }

    static func normalizedIPv4Address(from rawAddress: String) -> String? {
        guard !rawAddress.isEmpty,
              rawAddress.count <= maximumAddressLength,
              !rawAddress.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        let addressAndPrefix = rawAddress.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard addressAndPrefix.count == 1
                || (addressAndPrefix.count == 2 && addressAndPrefix[1] == "32") else {
            return nil
        }
        let octets = addressAndPrefix[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard octets.count == 4 else { return nil }

        var canonicalOctets: [String] = []
        canonicalOctets.reserveCapacity(4)
        for octet in octets {
            guard !octet.isEmpty,
                  octet.allSatisfy(\.isNumber),
                  let value = Int(octet),
                  (0...255).contains(value) else {
                return nil
            }
            canonicalOctets.append(String(value))
        }
        return canonicalOctets.joined(separator: ".")
    }

    static func normalizedTag(_ rawTag: String) -> String? {
        var tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.lowercased(with: Locale(identifier: "en_US_POSIX")).hasPrefix("tag:") {
            tag.removeFirst(4)
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !tag.isEmpty,
              tag.count <= maximumTagLength,
              !tag.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return tag.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func validatedField(
        _ value: String,
        maximumLength: Int
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumLength,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return trimmed
    }

    private static func validatedOptionalField(
        _ value: String,
        maximumLength: Int
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumLength,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return trimmed
    }
}

enum TailscaleAuthMethod: String, Codable {
    case apiKey
    case oauthClient
}

enum TailscaleCredentialPresence: Equatable, Sendable {
    case configured
    case absent
    case unavailable
}

struct TailscaleOAuthTokenCache {
    private var token: SecureBytes?
    private var credentialIdentity: Data?
    private var expiresAt: Date?

    nonisolated static let expirySkew: TimeInterval = 30

    mutating func token(
        for credentials: (clientID: String, clientSecret: String),
        now: Date = Date()
    ) -> String? {
        let currentIdentity = Self.identity(for: credentials)
        guard credentialIdentity == currentIdentity,
              let expiresAt,
              expiresAt.timeIntervalSince(now) > Self.expirySkew,
              let token = token?.toUTF8String(),
              !token.isEmpty else {
            clear()
            return nil
        }
        return token
    }

    @discardableResult
    mutating func store(
        _ token: String,
        expiresIn: TimeInterval,
        for credentials: (clientID: String, clientSecret: String),
        now: Date = Date()
    ) -> Bool {
        guard TailscaleClient.oauthExchangeFieldsAreValid(
            accessToken: token,
            expiresIn: expiresIn
        ) else {
            clear()
            return false
        }
        self.token = SecureBytes(Data(token.utf8))
        credentialIdentity = Self.identity(for: credentials)
        expiresAt = now.addingTimeInterval(expiresIn)
        return true
    }

    mutating func clear() {
        token = nil
        credentialIdentity = nil
        expiresAt = nil
    }

    static func identity(
        for credentials: (clientID: String, clientSecret: String)
    ) -> Data {
        var input = Data(credentials.clientID.utf8)
        input.append(0)
        input.append(contentsOf: credentials.clientSecret.utf8)
        let identity = Data(SHA256.hash(data: input))
        input.resetBytes(in: input.startIndex..<input.endIndex)
        return identity
    }
}

private struct TailscaleOAuthExchangeResult: Sendable {
    let accessToken: String
    let expiresIn: TimeInterval
}

private struct TailscaleOAuthInFlightExchange {
    let credentialIdentity: Data
    let task: Task<TailscaleOAuthExchangeResult, Error>
}

private struct TailscaleOAuthTokenResponse: Decodable {
    let access_token: String
    let expires_in: TimeInterval
}

// MARK: - Client

@MainActor
@Observable
class TailscaleClient {
    static let maximumInventoryResponseBytes = 4 * 1024 * 1024
    static let maximumInventoryDeviceCount = 10_000
    nonisolated static let maximumOAuthResponseBytes = 64 * 1024
    nonisolated static let maximumOAuthAccessTokenBytes = 16 * 1024
    nonisolated static let maximumOAuthTokenLifetime: TimeInterval = 365 * 24 * 60 * 60

    static func inventoryResponseByteCountIsAllowed(_ count: Int) -> Bool {
        count >= 0 && count <= maximumInventoryResponseBytes
    }

    static func inventoryDeviceCountIsAllowed(_ count: Int) -> Bool {
        count >= 0 && count <= maximumInventoryDeviceCount
    }

    nonisolated static func oauthExchangeFieldsAreValid(
        accessToken: String,
        expiresIn: TimeInterval
    ) -> Bool {
        let tokenBytes = accessToken.utf8
        return !tokenBytes.isEmpty
            && tokenBytes.count <= maximumOAuthAccessTokenBytes
            && !accessToken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && expiresIn.isFinite
            && expiresIn > TailscaleOAuthTokenCache.expirySkew
            && expiresIn <= maximumOAuthTokenLifetime
    }

    var devices: [TailscaleDevice] = []
    var isLoading = false
    var errorMessage: String?

    private var oauthTokenCache = TailscaleOAuthTokenCache()
    private var oauthInFlightExchange: TailscaleOAuthInFlightExchange?
    private var inventoryGeneration: UInt64 = 0
    private let session = URLSession.shared

    static func credentialsAreConfigured(
        authMethod: TailscaleAuthMethod,
        apiKey: String? = nil,
        oauthClientID: String? = nil,
        oauthClientSecret: String? = nil
    ) -> Bool {
        switch authMethod {
        case .apiKey:
            return !(apiKey ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        case .oauthClient:
            return !(oauthClientID ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                && !(oauthClientSecret ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
        }
    }

    static func hasConfiguredCredentials(defaults: UserDefaults = .standard) -> Bool {
        credentialPresence(defaults: defaults) == .configured
    }

    static func credentialPresence(
        defaults: UserDefaults = .standard,
        apiKeyProvider: () throws -> String = {
            try KeychainManager.retrieveTailscaleAPIKey()
        },
        oauthCredentialsProvider: () throws -> (clientID: String, clientSecret: String) = {
            try KeychainManager.retrieveTailscaleOAuthCredentials()
        }
    ) -> TailscaleCredentialPresence {
        let authMethod = TailscaleAuthMethod(
            rawValue: defaults.string(forKey: UserDefaultsKeys.tailscaleAuthMethod) ?? "apiKey"
        ) ?? .apiKey

        switch authMethod {
        case .apiKey:
            do {
                let apiKey = try apiKeyProvider()
                return credentialsAreConfigured(authMethod: authMethod, apiKey: apiKey)
                    ? .configured
                    : .absent
            } catch SecretStoreError.notFound {
                Logger.tailscale.debug("Tailscale API credential is not configured")
                return .absent
            } catch {
                Logger.tailscale.error("Unable to determine whether the Tailscale API credential is configured")
                return .unavailable
            }
        case .oauthClient:
            do {
                let credentials = try oauthCredentialsProvider()
                return credentialsAreConfigured(
                    authMethod: authMethod,
                    oauthClientID: credentials.clientID,
                    oauthClientSecret: credentials.clientSecret
                ) ? .configured : .absent
            } catch SecretStoreError.notFound {
                Logger.tailscale.debug("Tailscale OAuth credentials are not configured")
                return .absent
            } catch {
                Logger.tailscale.error("Unable to determine whether Tailscale OAuth credentials are configured")
                return .unavailable
            }
        }
    }

    // MARK: - Token Resolution

    private func resolveToken() async throws -> String {
        let authMethodRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.tailscaleAuthMethod) ?? "apiKey"
        let authMethod = TailscaleAuthMethod(rawValue: authMethodRaw) ?? .apiKey
        Logger.tailscale.info("Resolving Tailscale credential using configured method")

        switch authMethod {
        case .apiKey:
            // A method transition invalidates any token issued under the
            // previous OAuth credential identity.
            clearCachedToken()
            do {
                let key = try KeychainManager.retrieveTailscaleAPIKey()
                return key
            } catch {
                Logger.tailscale.error("Tailscale API credential is unavailable")
                throw TailscaleError.notAuthenticated
            }

        case .oauthClient:
            let creds: (clientID: String, clientSecret: String)
            do {
                creds = try KeychainManager.retrieveTailscaleOAuthCredentials()
            } catch {
                Logger.tailscale.error("Tailscale OAuth credential is unavailable")
                throw TailscaleError.notAuthenticated
            }

            if let cached = oauthTokenCache.token(for: creds) {
                return cached
            }

            let credentialIdentity = TailscaleOAuthTokenCache.identity(for: creds)
            let exchange: Task<TailscaleOAuthExchangeResult, Error>
            if let inFlight = oauthInFlightExchange,
               inFlight.credentialIdentity == credentialIdentity {
                exchange = inFlight.task
            } else {
                oauthInFlightExchange?.task.cancel()
                let session = session
                exchange = Task {
                    try await Self.exchangeOAuthToken(credentials: creds, session: session)
                }
                oauthInFlightExchange = TailscaleOAuthInFlightExchange(
                    credentialIdentity: credentialIdentity,
                    task: exchange
                )
            }

            let result: TailscaleOAuthExchangeResult
            do {
                result = try await exchange.value
            } catch {
                if oauthInFlightExchange?.credentialIdentity == credentialIdentity {
                    oauthInFlightExchange = nil
                }
                throw error
            }
            if oauthInFlightExchange?.credentialIdentity == credentialIdentity {
                oauthInFlightExchange = nil
            }

            // Actor reentrancy permits credentials to change while the HTTP
            // request is in flight. Never cache or return a token issued for
            // an identity that is no longer current.
            let currentCreds: (clientID: String, clientSecret: String)
            do {
                currentCreds = try KeychainManager.retrieveTailscaleOAuthCredentials()
            } catch {
                throw TailscaleError.notAuthenticated
            }
            guard TailscaleOAuthTokenCache.identity(for: currentCreds) == credentialIdentity else {
                return try await resolveToken()
            }
            guard oauthTokenCache.store(
                result.accessToken,
                expiresIn: result.expiresIn,
                for: currentCreds
            ) else {
                throw TailscaleError.authenticationFailed
            }
            Logger.tailscale.info("OAuth token exchanged successfully")
            return result.accessToken
        }
    }

    private static func exchangeOAuthToken(
        credentials: (clientID: String, clientSecret: String),
        session: URLSession
    ) async throws -> TailscaleOAuthExchangeResult {
        let url = URL(string: "https://api.tailscale.com/api/v2/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedBody([
            ("grant_type", "client_credentials"),
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
        ])

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }
        let data = try await boundedData(
            from: bytes,
            expectedContentLength: httpResponse.expectedContentLength,
            maximumBytes: maximumOAuthResponseBytes
        )
        guard httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            Logger.tailscale.error("OAuth token exchange failed: status=\(statusCode), bytes=\(data.count)")
            throw TailscaleError.authenticationFailed
        }

        let responseBody = try JSONDecoder().decode(TailscaleOAuthTokenResponse.self, from: data)
        guard oauthExchangeFieldsAreValid(
            accessToken: responseBody.access_token,
            expiresIn: responseBody.expires_in
        ) else {
            throw TailscaleError.authenticationFailed
        }
        return TailscaleOAuthExchangeResult(
            accessToken: responseBody.access_token,
            expiresIn: responseBody.expires_in
        )
    }

    private func authorizedData(
        for url: URL,
        maximumResponseBytes: Int = maximumInventoryResponseBytes
    ) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            let token = try await resolveToken()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TailscaleError.invalidResponse
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                clearCachedToken()
                if attempt == 0 {
                    continue
                }
                Logger.tailscale.error("Tailscale request authentication failed after credential refresh: status=\(httpResponse.statusCode)")
                throw TailscaleError.authenticationFailed
            }
            let data = try await Self.boundedData(
                from: bytes,
                expectedContentLength: httpResponse.expectedContentLength,
                maximumBytes: maximumResponseBytes
            )
            return (data, httpResponse)
        }
        throw TailscaleError.authenticationFailed
    }

    nonisolated static func boundedData<Bytes: AsyncSequence>(
        from bytes: Bytes,
        expectedContentLength: Int64,
        maximumBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maximumBytes >= 0,
              expectedContentLength < 0
                || expectedContentLength <= Int64(maximumBytes) else {
            throw TailscaleError.invalidResponse
        }

        var data = Data()
        if expectedContentLength > 0 {
            data.reserveCapacity(Int(expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw TailscaleError.invalidResponse
            }
            data.append(byte)
        }
        return data
    }

    // MARK: - Fetch Devices

    func fetchDevices(tailnet: String) async throws {
        let requestGeneration = beginInventoryRequest()
        try await fetchDevices(tailnet: tailnet, requestGeneration: requestGeneration)
    }

    private func beginInventoryRequest() -> UInt64 {
        inventoryGeneration &+= 1
        return inventoryGeneration
    }

    private func fetchDevices(
        tailnet: String,
        requestGeneration: UInt64
    ) async throws {
        isLoading = true
        errorMessage = nil
        defer {
            if inventoryGeneration == requestGeneration {
                isLoading = false
            }
        }

        let effectiveTailnet = tailnet.isEmpty ? "-" : tailnet
        let pathComponentCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        let escapedTailnet = effectiveTailnet.addingPercentEncoding(withAllowedCharacters: pathComponentCharacters) ?? "-"
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(escapedTailnet)/devices")!

        Logger.tailscale.info("Fetching Tailscale device inventory")
        let (data, httpResponse) = try await authorizedData(for: url)

        guard Self.inventoryResponseByteCountIsAllowed(data.count) else {
            throw TailscaleError.invalidResponse
        }

        Logger.tailscale.info("Response: HTTP \(httpResponse.statusCode), \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            Logger.tailscale.error("Tailscale device request failed: status=\(httpResponse.statusCode), bytes=\(data.count)")
            throw TailscaleError.fetchFailed(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let apiResponse: TailscaleAPIResponse
        do {
            apiResponse = try decoder.decode(TailscaleAPIResponse.self, from: data)
        } catch {
            Logger.tailscale.error("Tailscale response decode failed: bytes=\(data.count)")
            throw error
        }
        guard Self.inventoryDeviceCountIsAllowed(apiResponse.devices.count) else {
            throw TailscaleError.invalidResponse
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        // Filter out iOS/iPadOS/Android — they don't run SSH servers
        let nonMobileOS = Set(["ios", "ipados", "android"])

        let loadedDevices: [TailscaleDevice] = apiResponse.devices.compactMap { d -> TailscaleDevice? in
            let lastSeenDate: Date?
            if let ls = d.lastSeen {
                guard ls.count <= 64,
                      !ls.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    Logger.tailscale.debug("Skipping Tailscale device with invalid timestamp metadata")
                    return nil
                }
                lastSeenDate = dateFormatter.date(from: ls) ?? fallbackFormatter.date(from: ls)
            } else {
                lastSeenDate = nil
            }

            guard let device = TailscaleDevice(
                id: d.id,
                hostname: d.hostname,
                displayName: d.name,
                addresses: d.addresses,
                os: d.os,
                lastSeen: lastSeenDate,
                user: d.user,
                rawTags: d.tags ?? []
            ) else {
                Logger.tailscale.debug("Skipping invalid Tailscale device metadata")
                return nil
            }
            guard !nonMobileOS.contains(device.os.lowercased()) else {
                Logger.tailscale.debug("Skipping mobile Tailscale device")
                return nil
            }
            return device
        }

        try Task.checkCancellation()
        guard inventoryGeneration == requestGeneration else {
            throw CancellationError()
        }
        devices = loadedDevices

        Logger.tailscale.info("Loaded \(self.devices.count) devices with IPv4 (of \(apiResponse.devices.count) total)")
    }

    // MARK: - Test Connection

    func testConnection() async throws -> Bool {
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=default")!
        let (_, httpResponse) = try await authorizedData(for: url)

        let success = httpResponse.statusCode == 200
        Logger.tailscale.info("Connection test: HTTP \(httpResponse.statusCode)")
        return success
    }

    // MARK: - Convenience

    func loadDevices(tailnet: String) async {
        let requestGeneration = beginInventoryRequest()
        do {
            try await fetchDevices(
                tailnet: tailnet,
                requestGeneration: requestGeneration
            )
        } catch is CancellationError {
            return
        } catch is DecodingError {
            guard inventoryGeneration == requestGeneration else { return }
            errorMessage = "Failed to decode API response."
            Logger.tailscale.error("Tailscale response decoding failed")
        } catch let error as TailscaleError {
            guard inventoryGeneration == requestGeneration else { return }
            errorMessage = error.localizedDescription
        } catch {
            guard inventoryGeneration == requestGeneration else { return }
            let authMethod = TailscaleAuthMethod(rawValue:
                UserDefaults.standard.string(forKey: UserDefaultsKeys.tailscaleAuthMethod) ?? "apiKey"
            ) ?? .apiKey
            switch authMethod {
            case .apiKey:
                errorMessage = "No API key found. Add one in Settings → Tailscale."
            case .oauthClient:
                errorMessage = "No OAuth credentials found. Add them in Settings → Tailscale."
            }
            Logger.tailscale.error("Tailscale device load failed")
        }
    }

    func invalidateCredentialState() {
        inventoryGeneration &+= 1
        clearCachedToken()
        devices.removeAll(keepingCapacity: false)
        errorMessage = nil
        isLoading = false
    }

    func clearCachedToken() {
        oauthTokenCache.clear()
        oauthInFlightExchange?.task.cancel()
        oauthInFlightExchange = nil
    }

    static func formEncodedBody(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        let body = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed)?
                .replacingOccurrences(of: "%20", with: "+") ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed)?
                .replacingOccurrences(of: "%20", with: "+") ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

// MARK: - Errors

enum TailscaleError: LocalizedError {
    case invalidResponse
    case authenticationFailed
    case notAuthenticated
    case fetchFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Tailscale API."
        case .authenticationFailed:
            return "Authentication failed. Check your credentials."
        case .notAuthenticated:
            return "No Tailscale credentials configured. Add them in Settings."
        case .fetchFailed(let code):
            return "Failed to fetch devices (HTTP \(code))."
        }
    }
}
