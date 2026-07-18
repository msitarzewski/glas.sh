//
//  KeychainOperations.swift
//  GlasSecretStore
//
//  Low-level SecItem* CRUD with access group injection.
//  All operations use the configuration's access group and accessibility level.
//

import Foundation
import LocalAuthentication
import Security

public enum KeychainOperations: Sendable {

    // MARK: - Password (String) Operations

    public static func savePassword(
        _ value: String,
        account: String,
        service: String,
        config: SecretStoreConfiguration,
        policy: SecretAccessPolicy = .standard
    ) throws {
        guard !value.isEmpty else {
            throw SecretStoreError.encodingFailed
        }
        guard let data = value.data(using: .utf8) else {
            throw SecretStoreError.encodingFailed
        }
        try saveData(data, account: account, service: service, config: config, policy: policy)
    }

    public static func retrievePassword(
        account: String,
        service: String,
        config: SecretStoreConfiguration,
        authenticationPrompt: String? = nil
    ) throws -> String {
        let data = try retrieveData(
            account: account,
            service: service,
            config: config,
            authenticationPrompt: authenticationPrompt
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.notFound
        }
        return value
    }

    /// Tries the primary service name, then each legacy prefix in order.
    public static func retrievePasswordWithFallback(
        account: String,
        primaryService: String,
        legacySuffix: String,
        config: SecretStoreConfiguration,
        authenticationPrompt: String? = nil
    ) throws -> String {
        // Try primary first, but only fall back when it is genuinely absent.
        do {
            return try retrievePassword(
                account: account,
                service: primaryService,
                config: config,
                authenticationPrompt: authenticationPrompt
            )
        } catch SecretStoreError.notFound {
            // Continue through the explicit legacy services.
        }
        // Try each legacy prefix
        for prefix in config.legacyServiceNamePrefixes {
            let legacyService = "\(prefix).\(legacySuffix)"
            do {
                return try retrievePassword(
                    account: account,
                    service: legacyService,
                    config: config,
                    authenticationPrompt: authenticationPrompt
                )
            } catch SecretStoreError.notFound {
                continue
            }
        }
        throw SecretStoreError.notFound
    }

    public static func deletePassword(
        account: String,
        service: String,
        config: SecretStoreConfiguration
    ) throws {
        try deleteItem(account: account, service: service, config: config)
    }

    // MARK: - Data Operations

    private static let maxPayloadBytes = 1_048_576 // 1 MB

    public static func saveData(
        _ data: Data,
        account: String,
        service: String,
        config: SecretStoreConfiguration,
        policy: SecretAccessPolicy = .standard
    ) throws {
        guard data.count <= maxPayloadBytes else {
            throw SecretStoreError.payloadTooLarge(data.count)
        }

        // Atomic upsert: try update first, fall back to add
        let updateQuery = baseQuery(account: account, service: service, config: config)
        var updateValues: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrComment as String: config.migrationMarkerComment
        ]
        if policy == .standard {
            updateValues[kSecAttrAccessible as String] = config.accessibility
        }
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateValues as CFDictionary)
        if updateStatus == errSecSuccess { return }

        guard updateStatus == errSecItemNotFound else {
            throw SecretStoreError.unableToSave
        }

        // Item does not exist — add it. A concurrent creator wins rather than
        // being overwritten by this upsert attempt.
        guard try addDataIfAbsent(
            data,
            account: account,
            service: service,
            config: config,
            policy: policy
        ) else {
            throw SecretStoreError.unableToSave
        }
    }

    /// Atomically inserts a generic-password item only when the account is
    /// absent. Returns `false` for a duplicate without modifying its bytes.
    public static func addDataIfAbsent(
        _ data: Data,
        account: String,
        service: String,
        config: SecretStoreConfiguration,
        policy: SecretAccessPolicy = .standard
    ) throws -> Bool {
        guard data.count <= maxPayloadBytes else {
            throw SecretStoreError.payloadTooLarge(data.count)
        }

        var addQuery = baseQuery(account: account, service: service, config: config)
        addQuery[kSecAttrComment as String] = config.migrationMarkerComment
        addQuery[kSecValueData as String] = data
        switch policy {
        case .standard:
            addQuery[kSecAttrAccessible as String] = config.accessibility
        case .userPresence:
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                config.accessibility,
                .userPresence,
                &accessControlError
            ) else {
                throw SecretStoreError.accessControlCreationFailed
            }
            addQuery[kSecAttrAccessControl as String] = accessControl
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return false
        }
        guard addStatus == errSecSuccess else {
            throw SecretStoreError.unableToSave
        }
        return true
    }

    public static func retrieveData(
        account: String,
        service: String,
        config: SecretStoreConfiguration,
        authenticationPrompt: String? = nil
    ) throws -> Data {
        var query = baseQuery(account: account, service: service, config: config)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let authenticationPrompt {
            let context = LAContext()
            context.localizedReason = authenticationPrompt
            query[kSecUseAuthenticationContext as String] = context
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw SecretStoreError.notFound
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.queryFailed(status: status)
        }
        guard let data = result as? Data else { throw SecretStoreError.encodingFailed }
        return data
    }

    public static func deleteItem(
        account: String,
        service: String,
        config: SecretStoreConfiguration
    ) throws {
        let query = baseQuery(account: account, service: service, config: config)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unableToDelete
        }
    }

    // MARK: - Query Building

    private static func baseQuery(
        account: String,
        service: String,
        config: SecretStoreConfiguration
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        if let accessGroup = config.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        useDataProtectionKeychain(&query, enabled: config.useDataProtectionKeychain)
        return query
    }

    /// On macOS, opt into the modern data-protection Keychain used by iOS,
    /// iPadOS, and visionOS. Other platforms already use that implementation
    /// and do not accept this query key.
    private static func useDataProtectionKeychain(_ query: inout [String: Any], enabled: Bool) {
        #if os(macOS)
        if enabled {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
    }

    // MARK: - Bulk Query (for migration)

    package static func allItems(
        service: String,
        config: SecretStoreConfiguration
    ) throws -> [[String: Any]] {
        // Two-pass approach: macOS returns errSecParam (-50) when combining
        // kSecReturnData with kSecMatchLimitAll. Fetch attributes first,
        // then retrieve data per-item.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        if let accessGroup = config.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        useDataProtectionKeychain(&query, enabled: config.useDataProtectionKeychain)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw SecretStoreError.queryFailed(status: status)
        }
        guard let items = result as? [[String: Any]] else {
            throw SecretStoreError.encodingFailed
        }

        // Fetch data for each item individually
        return try items.map { item in
            var enriched = item
            if let account = item[kSecAttrAccount as String] as? String {
                var dataQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: account,
                    kSecAttrService as String: service,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecReturnData as String: true
                ]
                if let accessGroup = config.accessGroup {
                    dataQuery[kSecAttrAccessGroup as String] = accessGroup
                }
                useDataProtectionKeychain(&dataQuery, enabled: config.useDataProtectionKeychain)
                var dataResult: AnyObject?
                let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
                guard dataStatus == errSecSuccess else {
                    throw SecretStoreError.queryFailed(status: dataStatus)
                }
                guard let data = dataResult as? Data else { throw SecretStoreError.encodingFailed }
                enriched[kSecValueData as String] = data
            }
            return enriched
        }
    }

    package static func updateItem(
        account: String,
        service: String,
        data: Data,
        config: SecretStoreConfiguration
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service
        ]
        if let accessGroup = config.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        useDataProtectionKeychain(&query, enabled: config.useDataProtectionKeychain)

        let updateValues: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: config.accessibility,
            kSecAttrComment as String: config.migrationMarkerComment
        ]
        let status = SecItemUpdate(query as CFDictionary, updateValues as CFDictionary)
        guard status == errSecSuccess else {
            throw SecretStoreError.updateFailed(account: account, status: status)
        }
    }

    public static func itemCount(
        service: String,
        legacyOnly: Bool,
        config: SecretStoreConfiguration
    ) -> Int {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        if let accessGroup = config.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        useDataProtectionKeychain(&query, enabled: config.useDataProtectionKeychain)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return 0
        }
        if !legacyOnly { return items.count }
        return items.filter { item in
            let comment = item[kSecAttrComment as String] as? String
            return comment != config.migrationMarkerComment
        }.count
    }
}
