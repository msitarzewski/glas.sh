//
//  TailscaleClient.swift
//  glas.sh
//
//  Tailscale REST API v2 client for device discovery
//

import Foundation
import Observation
import os

// MARK: - API Response Models (match Tailscale JSON exactly)

private struct TailscaleAPIDevicesResponse: Decodable {
    let devices: [TailscaleAPIDevice]
}

private struct TailscaleAPIDevice: Decodable {
    let id: String           // Can be numeric string or node ID
    let name: String         // FQDN like "device.tailnet.ts.net"
    let hostname: String     // Short hostname
    let addresses: [String]  // CIDR notation: ["100.64.0.1/32", "fd7a::.../128"]
    let os: String
    let online: Bool?        // nullable
    let lastSeen: String?    // ISO 8601 timestamp, nullable
    let clientVersion: String?
    let authorized: Bool?
    let user: String?        // email or user identifier

    // Extract clean IP from CIDR notation
    var ipv4Address: String? {
        addresses.first { $0.contains(".") }?
            .components(separatedBy: "/").first
    }
}

// MARK: - App Model

struct TailscaleDevice: Identifiable, Hashable {
    let id: String
    let hostname: String
    let displayName: String  // FQDN
    let ipAddress: String
    let os: String
    let online: Bool
    let lastSeen: Date?
    let user: String?

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
        let authMethod = TailscaleAuthMethod(rawValue:
            UserDefaults.standard.string(forKey: UserDefaultsKeys.tailscaleAuthMethod) ?? "apiKey"
        ) ?? .apiKey

        switch authMethod {
        case .apiKey:
            return try KeychainManager.retrieveTailscaleAPIKey()

        case .oauthClient:
            if let cached = cachedOAuthToken { return cached }

            let creds = try KeychainManager.retrieveTailscaleOAuthCredentials()
            let url = URL(string: "https://api.tailscale.com/api/v2/oauth/token")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = "grant_type=client_credentials&client_id=\(creds.clientID)&client_secret=\(creds.clientSecret)"
            request.httpBody = body.data(using: .utf8)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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
        let escapedTailnet = tailnet.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tailnet
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(escapedTailnet)/devices")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Logger.tailscale.info("Fetching devices for tailnet: \(tailnet)")
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            cachedOAuthToken = nil
            throw TailscaleError.authenticationFailed
        }

        guard httpResponse.statusCode == 200 else {
            throw TailscaleError.fetchFailed(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(TailscaleAPIDevicesResponse.self, from: data)

        // ISO 8601 date formatter for lastSeen
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        devices = apiResponse.devices.compactMap { apiDevice in
            guard let ip = apiDevice.ipv4Address else { return nil }

            let lastSeenDate: Date?
            if let ls = apiDevice.lastSeen {
                lastSeenDate = dateFormatter.date(from: ls) ?? fallbackFormatter.date(from: ls)
            } else {
                lastSeenDate = nil
            }

            return TailscaleDevice(
                id: apiDevice.id,
                hostname: apiDevice.hostname,
                displayName: apiDevice.name,
                ipAddress: ip,
                os: apiDevice.os,
                online: apiDevice.online ?? false,
                lastSeen: lastSeenDate,
                user: apiDevice.user
            )
        }
        .filter { $0.online }

        Logger.tailscale.info("Fetched \(apiResponse.devices.count) devices (\(self.devices.count) online with IPv4).")
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
        Logger.tailscale.info("Connection test: \(success ? "succeeded" : "failed (HTTP \(httpResponse.statusCode))")")
        return success
    }

    // MARK: - Convenience

    func loadDevices(tailnet: String) async {
        isLoading = true
        errorMessage = nil

        do {
            try await fetchDevices(tailnet: tailnet)
        } catch {
            errorMessage = error.localizedDescription
            Logger.tailscale.error("Failed to load devices: \(error)")
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
