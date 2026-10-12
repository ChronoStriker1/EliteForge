import EliteKit
import Foundation

/// Setups saved on this Mac (the Library), which can be loaded onto any of the controller's three profiles.
struct ProfileLibrary: Codable {
    var profiles: [EliteProfile] = []
    /// Which library profile was last written to each controller slot.
    var slotAssignments: [Int: UUID] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([EliteProfile].self, forKey: .profiles)
        // Libraries saved before assignments were tracked don't have the key.
        slotAssignments = try container.decodeIfPresent([Int: UUID].self, forKey: .slotAssignments) ?? [:]
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EliteForge", isDirectory: true).appendingPathComponent("profiles.json")
    }

    /// Where profiles lived before the app was renamed from XBElite2.
    static var legacyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("XBElite2", isDirectory: true).appendingPathComponent("profiles.json")
    }

    static func load() -> ProfileLibrary {
        let url = FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : legacyFileURL
        guard let data = try? Data(contentsOf: url) else { return ProfileLibrary() }
        do {
            return try JSONDecoder().decode(ProfileLibrary.self, from: data)
        } catch {
            // Keep the unreadable file so the next save doesn't destroy it.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return ProfileLibrary()
        }
    }

    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// File format for sharing a single setup.
enum ProfileFile {
    static let fileExtension = "elitesetup"
    /// Exports from earlier versions.
    static let legacyFileExtensions = ["eliteprofile", "xbe2profile"]

    static func encode(_ profile: EliteProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(profile)
    }

    static func decode(_ data: Data) throws -> EliteProfile {
        var profile = try JSONDecoder().decode(EliteProfile.self, from: data)
        profile.id = UUID()
        return profile
    }
}
