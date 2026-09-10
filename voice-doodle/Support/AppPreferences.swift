import Foundation

/// UserDefaults-backed app preferences (v3 schema). API config lives in config.json.
@MainActor
final class AppPreferences {
    private let defaults = UserDefaults.standard

    var triggerConfig: TriggerConfig {
        get {
            guard
                let data = defaults.data(forKey: Constants.Defaults.triggerConfig),
                let config = try? JSONDecoder().decode(TriggerConfig.self, from: data)
            else { return .default }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Constants.Defaults.triggerConfig)
            }
        }
    }

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Constants.Defaults.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Constants.Defaults.onboardingCompleted) }
    }

    /// Login-item opt-in. Unset key reads false — launch-at-login stays off
    /// until the user enables it in the dashboard.
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Constants.Defaults.launchAtLogin) }
        set { defaults.set(newValue, forKey: Constants.Defaults.launchAtLogin) }
    }
}
