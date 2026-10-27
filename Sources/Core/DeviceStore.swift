import Foundation

@MainActor
enum DeviceStore {
    private static let devicesKey = "devices.v1"
    private static let currentKey = RemoteActivityPersistence.selectedDeviceKey

    static func load() -> [TVDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let devices = try? JSONDecoder().decode([TVDevice].self, from: data) else { return [] }
        return devices
    }

    static func save(_ devices: [TVDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
        CloudSettings.set(CloudSettings.encode(devices.map(\.withoutCredentials)), forKey: CloudSettings.devices)
    }

    /// The TVs saved on all of the user's devices, without pairing credentials.
    static func loadShared() -> [TVDevice]? {
        UserDefaults.standard.data(forKey: CloudSettings.devices).flatMap { try? JSONDecoder().decode([TVDevice].self, from: $0) }
    }

    static var currentID: String? {
        get { UserDefaults.standard.string(forKey: currentKey) }
        set { UserDefaults.standard.set(newValue, forKey: currentKey) }
    }
}
