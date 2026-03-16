//
//  ServerHealthWidget.swift
//  glasWidgets
//
//  Displays server connection health status in a visionOS widget
//

import WidgetKit
import SwiftUI

// MARK: - Lightweight Server Info for Widgets

struct WidgetServerInfo: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let host: String
    let username: String
    let lastConnected: Date?
    let isFavorite: Bool
    let colorTag: String

    var statusColor: Color {
        guard let lastConnected else { return .red }
        let elapsed = Date().timeIntervalSince(lastConnected)
        if elapsed < 3600 { return .green }       // < 1 hour
        if elapsed < 86400 { return .yellow }     // < 24 hours
        return .red
    }

    var lastSeenText: String {
        guard let lastConnected else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastConnected, relativeTo: Date())
    }
}

// MARK: - Timeline Provider

struct ServerHealthTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ServerHealthEntry {
        ServerHealthEntry(date: Date(), servers: [
            WidgetServerInfo(
                id: UUID(),
                name: "Example Server",
                host: "example.com",
                username: "user",
                lastConnected: Date(),
                isFavorite: true,
                colorTag: "Blue"
            )
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ServerHealthEntry) -> Void) {
        let servers = loadServers()
        completion(ServerHealthEntry(date: Date(), servers: servers))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ServerHealthEntry>) -> Void) {
        let servers = loadServers()
        let entry = ServerHealthEntry(date: Date(), servers: servers)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadServers() -> [WidgetServerInfo] {
        guard let defaults = UserDefaults(suiteName: "group.sh.glas.shared"),
              let data = defaults.data(forKey: "servers") else {
            return []
        }

        // Decode the full ServerConfiguration array and map to lightweight widget info
        guard let decoded = try? JSONDecoder().decode([WidgetServerConfig].self, from: data) else {
            return []
        }

        return decoded
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
            .prefix(6)
            .map { config in
                WidgetServerInfo(
                    id: config.id,
                    name: config.name,
                    host: config.host,
                    username: config.username,
                    lastConnected: config.lastConnected,
                    isFavorite: config.isFavorite,
                    colorTag: config.colorTag?.rawValue ?? "Blue"
                )
            }
    }
}

// Minimal Codable struct matching ServerConfiguration's relevant fields
private struct WidgetServerConfig: Codable {
    let id: UUID
    let name: String
    let host: String
    let username: String
    let lastConnected: Date?
    let isFavorite: Bool
    let colorTag: ServerColorTag?

    enum ServerColorTag: String, Codable {
        case blue = "Blue"
        case green = "Green"
        case orange = "Orange"
        case purple = "Purple"
        case red = "Red"
        case pink = "Pink"
        case yellow = "Yellow"
        case gray = "Gray"
    }
}

// MARK: - Timeline Entry

struct ServerHealthEntry: TimelineEntry {
    let date: Date
    let servers: [WidgetServerInfo]
}

// MARK: - Widget Views

struct ServerHealthSmallView: View {
    let entry: ServerHealthEntry

    var body: some View {
        if let server = entry.servers.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(server.statusColor)
                        .frame(width: 8, height: 8)
                    Text(server.name)
                        .font(.headline)
                        .lineLimit(1)
                }

                Spacer()

                Text(server.lastSeenText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .widgetURL(URL(string: "glassh://connect?serverID=\(server.id.uuidString)")!)
        } else {
            ContentUnavailableView("No Servers", systemImage: "server.rack")
        }
    }
}

struct ServerHealthMediumView: View {
    let entry: ServerHealthEntry

    var body: some View {
        if entry.servers.isEmpty {
            ContentUnavailableView("No Servers", systemImage: "server.rack")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.servers.prefix(3)) { server in
                    Link(destination: URL(string: "glassh://connect?serverID=\(server.id.uuidString)")!) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(server.statusColor)
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(server.username)@\(server.host)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(server.lastSeenText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            Image(systemName: "arrow.right.circle")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Widget Definition

struct ServerHealthWidget: Widget {
    let kind = "ServerHealthWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ServerHealthTimelineProvider()) { entry in
            Group {
                switch entry.servers.isEmpty {
                case true:
                    ContentUnavailableView("No Servers", systemImage: "server.rack")
                case false:
                    ServerHealthMediumView(entry: entry)
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Server Health")
        .description("Monitor your SSH server connection status.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Preview

#Preview(as: .systemMedium) {
    ServerHealthWidget()
} timeline: {
    ServerHealthEntry(date: Date(), servers: [
        WidgetServerInfo(id: UUID(), name: "Production", host: "prod.example.com", username: "deploy", lastConnected: Date().addingTimeInterval(-1800), isFavorite: true, colorTag: "Green"),
        WidgetServerInfo(id: UUID(), name: "Staging", host: "staging.example.com", username: "dev", lastConnected: Date().addingTimeInterval(-43200), isFavorite: false, colorTag: "Yellow"),
        WidgetServerInfo(id: UUID(), name: "Legacy", host: "old.example.com", username: "admin", lastConnected: nil, isFavorite: false, colorTag: "Red"),
    ])
}
