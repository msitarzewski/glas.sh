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

    // Optional fields
    let authorized: Bool?
    let lastSeen: String?     // ISO 8601
    let created: String?
    let clientVersion: String?
    let tags: [String]?
    let keyExpiryDisabled: Bool?
    let blocksIncomingConnections: Bool?
    let isExternal: Bool?
    let updateAvailable: Bool?
    let machineKey: String?
    let nodeKey: String?
    let tailnetLockError: String?
    let tailnetLockKey: String?

    var ipv4Address: String? {
        addresses.first { $0.contains(".") && !$0.contains(":") }?
            .components(separatedBy: "/").first  // Strip /32 if present
    }
}

// MARK: - App Model

struct TailscaleDevice: Identifiable, Hashable {
    let id: String
    let hostname: String
    let displayName: String
    let ipAddress: String
    let os: String
    let lastSeen: Date?
    let user: String

    var sshAddress: String { ipAddress }
}

enum TailscaleAuthMethod: String, Codable {
    case apiKey
    case oauthClient
}

struct TailscaleOAuthTokenCache {
    private var token: SecureBytes?
    private var credentialIdentity: Data?
    private var expiresAt: Date?

    static let expirySkew: TimeInterval = 30

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
        guard !token.isEmpty, expiresIn > Self.expirySkew else {
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
    var devices: [TailscaleDevice] = []
    var isLoading = false
    var errorMessage: String?

    private var oauthTokenCache = TailscaleOAuthTokenCache()
    private var oauthInFlightExchange: TailscaleOAuthInFlightExchange?
    private let session = URLSession.shared

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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            Logger.tailscale.error("OAuth token exchange failed: status=\(statusCode), bytes=\(data.count)")
            throw TailscaleError.authenticationFailed
        }

        let responseBody = try JSONDecoder().decode(TailscaleOAuthTokenResponse.self, from: data)
        guard !responseBody.access_token.isEmpty else {
            throw TailscaleError.authenticationFailed
        }
        return TailscaleOAuthExchangeResult(
            accessToken: responseBody.access_token,
            expiresIn: responseBody.expires_in
        )
    }

    private func authorizedData(for url: URL) async throws -> (Data, HTTPURLResponse) {
        for attempt in 0..<2 {
            let token = try await resolveToken()
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TailscaleError.invalidResponse
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                clearCachedToken()
                if attempt == 0 {
                    continue
                }
                Logger.tailscale.error("Tailscale request authentication failed after credential refresh: status=\(httpResponse.statusCode), bytes=\(data.count)")
                throw TailscaleError.authenticationFailed
            }
            return (data, httpResponse)
        }
        throw TailscaleError.authenticationFailed
    }

    // MARK: - Fetch Devices

    func fetchDevices(tailnet: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let effectiveTailnet = tailnet.isEmpty ? "-" : tailnet
        let pathComponentCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-._~"))
        let escapedTailnet = effectiveTailnet.addingPercentEncoding(withAllowedCharacters: pathComponentCharacters) ?? "-"
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(escapedTailnet)/devices")!

        Logger.tailscale.info("Fetching Tailscale device inventory")
        let (data, httpResponse) = try await authorizedData(for: url)

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
            Logger.tailscale.error("Tailscale response decode failed: bytes=\(data.count), error=\(String(describing: error), privacy: .public)")
            throw error
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        // Filter out iOS/iPadOS/Android — they don't run SSH servers
        let nonMobileOS = Set(["iOS", "iPadOS", "android"])

        devices = apiResponse.devices.compactMap { d in
            guard !nonMobileOS.contains(d.os) else {
                Logger.tailscale.debug("Skipping mobile Tailscale device")
                return nil
            }
            guard let ip = d.ipv4Address else {
                Logger.tailscale.debug("Skipping Tailscale device without IPv4")
                return nil
            }

            let lastSeenDate: Date?
            if let ls = d.lastSeen {
                lastSeenDate = dateFormatter.date(from: ls) ?? fallbackFormatter.date(from: ls)
            } else {
                lastSeenDate = nil
            }

            return TailscaleDevice(
                id: d.id,
                hostname: d.hostname,
                displayName: d.name,
                ipAddress: ip,
                os: d.os,
                lastSeen: lastSeenDate,
                user: d.user
            )
        }

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
        isLoading = true
        errorMessage = nil

        do {
            try await fetchDevices(tailnet: tailnet)
        } catch is DecodingError {
            errorMessage = "Failed to decode API response."
            Logger.tailscale.error("Tailscale response decoding failed")
        } catch let error as TailscaleError {
            errorMessage = error.localizedDescription
        } catch {
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
