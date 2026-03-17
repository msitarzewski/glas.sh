//
//  TailscaleClient.swift
//  glas.sh
//
//  Tailscale REST API v2 client for device discovery
//

import Foundation
import Observation
import os

struct TailscaleDevice: Identifiable, Codable, Hashable {
    let id: String
    let hostname: String
    let addresses: [String]
    let os: String
    let online: Bool
    let lastSeen: Date
    let name: String

    var sshAddress: String? { addresses.first }

    enum CodingKeys: String, CodingKey {
        case id, hostname, addresses, os, online, lastSeen, name
    }
}

enum TailscaleAuthMethod: String, Codable {
    case apiKey     // Direct API key (admin generates at admin console → Keys)
    case oauthClient // OAuth client ID + secret (exchanged for short-lived token)
}

@MainActor
@Observable
class TailscaleClient {
    var devices: [TailscaleDevice] = []
    var isLoading = false
    var errorMessage: String?

    private var cachedOAuthToken: String?
    private let session = URLSession.shared

    // MARK: - Resolve Bearer Token

    /// Get a usable Bearer token — either the API key directly, or exchange OAuth credentials.
    private func resolveToken() async throws -> String {
        let authMethod = TailscaleAuthMethod(rawValue:
            UserDefaults.standard.string(forKey: UserDefaultsKeys.tailscaleAuthMethod) ?? "apiKey"
        ) ?? .apiKey

        switch authMethod {
        case .apiKey:
            return try KeychainManager.retrieveTailscaleAPIKey()

        case .oauthClient:
            // Exchange OAuth client credentials for short-lived access token
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
            cachedOAuthToken = nil // Invalidate cached token
            throw TailscaleError.authenticationFailed
        }

        guard httpResponse.statusCode == 200 else {
            throw TailscaleError.fetchFailed(statusCode: httpResponse.statusCode)
        }

        struct DevicesResponse: Decodable { let devices: [TailscaleDevice] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let devicesResponse = try decoder.decode(DevicesResponse.self, from: data)
        devices = devicesResponse.devices.filter { $0.online }
        Logger.tailscale.info("Fetched \(devicesResponse.devices.count) devices (\(self.devices.count) online).")
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
