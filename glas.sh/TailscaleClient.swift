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

// MARK: - Client

@MainActor
@Observable
class TailscaleClient {
    var devices: [TailscaleDevice] = []
    var isLoading = false
    var errorMessage: String?

    private var cachedOAuthToken: String?
    private let session = URLSession.shared

    // MARK: - Token Resolution

    private func resolveToken() async throws -> String {
        let authMethodRaw = UserDefaults.standard.string(forKey: UserDefaultsKeys.tailscaleAuthMethod) ?? "apiKey"
        let authMethod = TailscaleAuthMethod(rawValue: authMethodRaw) ?? .apiKey
        Logger.tailscale.info("Resolving token, auth method: \(authMethodRaw)")

        switch authMethod {
        case .apiKey:
            do {
                let key = try KeychainManager.retrieveTailscaleAPIKey()
                Logger.tailscale.info("API key found (\(key.prefix(8))...)")
                return key
            } catch {
                Logger.tailscale.error("No API key in Keychain: \(error)")
                throw TailscaleError.notAuthenticated
            }

        case .oauthClient:
            if let cached = cachedOAuthToken { return cached }

            let creds: (clientID: String, clientSecret: String)
            do {
                creds = try KeychainManager.retrieveTailscaleOAuthCredentials()
            } catch {
                Logger.tailscale.error("No OAuth credentials in Keychain: \(error)")
                throw TailscaleError.notAuthenticated
            }

            let url = URL(string: "https://api.tailscale.com/api/v2/oauth/token")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "grant_type=client_credentials&client_id=\(creds.clientID)&client_secret=\(creds.clientSecret)"
            request.httpBody = body.data(using: .utf8)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                Logger.tailscale.error("OAuth token exchange failed: \(body)")
                throw TailscaleError.authenticationFailed
            }

            struct TokenResponse: Decodable { let access_token: String }
            let token = try JSONDecoder().decode(TokenResponse.self, from: data).access_token
            cachedOAuthToken = token
            Logger.tailscale.info("OAuth token exchanged successfully")
            return token
        }
    }

    // MARK: - Fetch Devices

    func fetchDevices(tailnet: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let token = try await resolveToken()
        let effectiveTailnet = tailnet.isEmpty ? "-" : tailnet
        let escapedTailnet = effectiveTailnet.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? effectiveTailnet
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(escapedTailnet)/devices")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Logger.tailscale.info("GET \(url.absoluteString)")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

        Logger.tailscale.info("Response: HTTP \(httpResponse.statusCode), \(data.count) bytes")

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            cachedOAuthToken = nil
            let body = String(data: data, encoding: .utf8) ?? ""
            Logger.tailscale.error("Auth failed: \(body)")
            throw TailscaleError.authenticationFailed
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            Logger.tailscale.error("API error \(httpResponse.statusCode): \(body)")
            throw TailscaleError.fetchFailed(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let apiResponse: TailscaleAPIResponse
        do {
            apiResponse = try decoder.decode(TailscaleAPIResponse.self, from: data)
        } catch {
            // Log first 500 chars of response to help debug
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            Logger.tailscale.error("Decode failed: \(error)\nResponse preview: \(preview)")
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
                Logger.tailscale.debug("Skipping \(d.hostname): mobile OS (\(d.os))")
                return nil
            }
            guard let ip = d.ipv4Address else {
                Logger.tailscale.debug("Skipping \(d.hostname): no IPv4 address")
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
        let token = try await resolveToken()
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=default")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

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
        } catch let decodingError as DecodingError {
            errorMessage = "Failed to decode API response."
            Logger.tailscale.error("Decoding error: \(decodingError)")
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
            Logger.tailscale.error("Load failed: \(error)")
        }

        isLoading = false
    }

    func clearCachedToken() {
        cachedOAuthToken = nil
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
