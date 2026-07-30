import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var autoplay = true
    var keepScreenAwake = true
}

/// Keeps connection details independent from the media-library snapshot.
///
/// The library is restored asynchronously because it can contain many videos.
/// Engine settings are tiny, so restoring them synchronously prevents an early
/// Fetch tap from seeing an empty configuration.
@MainActor
enum AppSettingsCache {
    private static let storageKey = "dropframe.app-settings.v1"

    static func load() -> AppSettings? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return nil
        }
        return settings
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
