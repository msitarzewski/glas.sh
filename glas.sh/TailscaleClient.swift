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

@MainActor
@Observable
class TailscaleClient {
    var devices: [TailscaleDevice] = []
    var isLoading = false
    var errorMessage: String?

    private let session = URLSession.shared

    // MARK: - Fetch Devices

    /// Fetch devices using an API key (generated at admin console → Settings → Keys).
    /// The API key is sent as Basic auth with the key as username and empty password.
    func fetchDevices(apiKey: String, tailnet: String) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let escapedTailnet = tailnet.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tailnet
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/\(escapedTailnet)/devices")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        Logger.tailscale.info("Fetching devices for tailnet: \(tailnet)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            Logger.tailscale.error("Fetch devices failed: HTTP \(httpResponse.statusCode) - \(bodyText)")
            throw TailscaleError.fetchFailed(statusCode: httpResponse.statusCode)
        }

        struct DevicesResponse: Decodable {
            let devices: [TailscaleDevice]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let devicesResponse = try decoder.decode(DevicesResponse.self, from: data)
        devices = devicesResponse.devices.filter { $0.online }
        Logger.tailscale.info("Fetched \(devicesResponse.devices.count) devices (\(self.devices.count) online).")
    }

    // MARK: - Test Connection

    func testConnection(apiKey: String) async throws -> Bool {
        let url = URL(string: "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=default")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TailscaleError.invalidResponse
        }

        let success = httpResponse.statusCode == 200
        Logger.tailscale.info("Tailscale connection test: \(success ? "succeeded" : "failed (HTTP \(httpResponse.statusCode))")")
        return success
    }

    // MARK: - Convenience

    /// Load devices from stored Keychain API key.
    func loadDevices(tailnet: String) async {
        isLoading = true
        errorMessage = nil

        do {
            let apiKey = try KeychainManager.retrieveTailscaleAPIKey()
            try await fetchDevices(apiKey: apiKey, tailnet: tailnet)
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
    case notAuthenticated
    case fetchFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Tailscale API."
        case .notAuthenticated:
            return "No Tailscale API key configured. Add one in Settings."
        case .fetchFailed(let code):
            return "Failed to fetch devices (HTTP \(code)). Check your API key."
        }
    }
}
