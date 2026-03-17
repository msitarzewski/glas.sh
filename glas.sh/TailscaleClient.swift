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
        case id
        case hostname
        case addresses
        case os
        case online
        case lastSeen
        case name
    }
}

@MainActor
@Observable
class TailscaleClient {
    var devices: [TailscaleDevice] = []
    var isLoading = false
    var errorMessage: String?

    private var accessToken: String?
    private let session = URLSession.shared

    // MARK: - Authentication

    func authenticate(clientID: String, clientSecret: String) async throws {
        let url = URL(string: "https://api.tailscale.com/api/v2/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=client_credentials&client_id=\(clientID)&client_secret=\(clientSecret)"
        request.httpBody = body.data(using: .utf8)

        Logger.tailscale.info("Authenticating with Tailscale OAuth2...")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "No body"
            Logger.tailscale.error("OAuth2 authentication failed: HTTP \(httpResponse.statusCode) - \(bodyText)")
            throw TailscaleError.authenticationFailed(statusCode: httpResponse.statusCode)
        }

        struct TokenResponse: Decodable {
            let access_token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = tokenResponse.access_token
        Logger.tailscale.info("Tailscale OAuth2 authentication successful.")
    }

    // MARK: - Fetch Devices

    func fetchDevices(tailnet: String) async throws {
        guard let token = accessToken else {
            throw TailscaleError.notAuthenticated
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let escapedTailnet = tailnet.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tailnet
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(escapedTailnet)/devices")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Logger.tailscale.info("Fetching devices for tailnet: \(tailnet)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? "No body"
            Logger.tailscale.error("Fetch devices failed: HTTP \(httpResponse.statusCode) - \(bodyText)")
            throw TailscaleError.fetchFailed(statusCode: httpResponse.statusCode)
        }

        struct DevicesResponse: Decodable {
            let devices: [TailscaleDevice]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let devicesResponse = try decoder.decode(DevicesResponse.self, from: data)
        devices = devicesResponse.devices
        Logger.tailscale.info("Fetched \(devicesResponse.devices.count) Tailscale devices.")
    }

    // MARK: - Test Connection

    func testConnection() async throws -> Bool {
        guard let credentials = try? KeychainManager.retrieveTailscaleCredentials() else {
            throw TailscaleError.notAuthenticated
        }

        try await authenticate(clientID: credentials.clientID, clientSecret: credentials.clientSecret)

        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=default")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

        let success = httpResponse.statusCode == 200
        if success {
            Logger.tailscale.info("Tailscale connection test succeeded.")
        } else {
            Logger.tailscale.error("Tailscale connection test failed: HTTP \(httpResponse.statusCode)")
        }
        return success
    }

    // MARK: - Convenience

    /// Authenticate from stored Keychain credentials and fetch devices for the given tailnet.
    func loadDevices(tailnet: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let credentials = try KeychainManager.retrieveTailscaleCredentials()
            try await authenticate(clientID: credentials.clientID, clientSecret: credentials.clientSecret)
            try await fetchDevices(tailnet: tailnet)
        } catch {
            errorMessage = error.localizedDescription
            Logger.tailscale.error("Failed to load Tailscale devices: \(error)")
        }

        isLoading = false
    }
}

// MARK: - Errors

enum TailscaleError: LocalizedError {
    case invalidResponse
    case authenticationFailed(statusCode: Int)
    case notAuthenticated
    case fetchFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Tailscale API."
        case .authenticationFailed(let code):
            return "Tailscale authentication failed (HTTP \(code)). Check your OAuth credentials."
        case .notAuthenticated:
            return "Not authenticated with Tailscale. Configure OAuth credentials in Settings."
        case .fetchFailed(let code):
            return "Failed to fetch Tailscale devices (HTTP \(code))."
        }
    }
}
