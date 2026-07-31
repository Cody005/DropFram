import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    var autoplay = true
    var keepScreenAwake = true
    var appLockEnabled = false

    private enum CodingKeys: String, CodingKey {
        case autoplay
        case keepScreenAwake
        case appLockEnabled
    }

    init(
        autoplay: Bool = true,
        keepScreenAwake: Bool = true,
        appLockEnabled: Bool = false
    ) {
        self.autoplay = autoplay
        self.keepScreenAwake = keepScreenAwake
        self.appLockEnabled = appLockEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoplay = try container.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        keepScreenAwake = try container.decodeIfPresent(
            Bool.self,
            forKey: .keepScreenAwake
        ) ?? true
        appLockEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .appLockEnabled
        ) ?? false
    }
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
