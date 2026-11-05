import Foundation

public struct Configuration: Codable, Equatable {
    public var version = 1
    public var profiles: [LayoutProfile]
    public var automatic = false
    public var launchAllAtLogin: Bool? = nil
    public var lastManagedIDs: [String] = []
    public var lastAppliedProfile: LayoutProfile? = nil

    public init(profiles: [LayoutProfile]) { self.profiles = profiles }

    public func validated() throws -> Configuration {
        guard version == 1, Set(profiles.map(\.id)) == Set(["solo", "dual"]), profiles.count == 2 else {
            throw LayoutError.invalid("Format de configuration non reconnu.")
        }
        func validID(_ id: String) -> Bool {
            !id.isEmpty && id.count <= 255 && id.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
            }
        }
        for profile in profiles {
            guard !profile.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, profile.name.count <= 100,
                  profile.rules.count <= 128 else { throw LayoutError.invalid("Profil invalide : un nom et au maximum 128 applications sont nécessaires.") }
            var seen = Set<String>()
            for rule in profile.rules {
                guard validID(rule.id), seen.insert(rule.id).inserted else { throw LayoutError.invalid("Identifiant d’application invalide ou en double dans « \(profile.name) ».") }
                guard !rule.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, rule.name.count <= 200,
                      rule.path.hasPrefix("/"), rule.path.count <= 4096,
                      URL(fileURLWithPath:rule.path).pathExtension.lowercased() == "app",
                      !rule.path.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains),
                      (1...16).contains(rule.desktop), profile.id != "solo" || rule.screen == .builtIn else {
                    throw LayoutError.invalid("Affectation invalide pour \(rule.name). Choisis une app macOS, un écran disponible dans ce profil et un bureau de 1 à 16.")
                }
            }
        }
        guard lastManagedIDs.count <= 256, lastManagedIDs.allSatisfy(validID) else { throw LayoutError.invalid("Liste des applications gérées invalide.") }
        return self
    }
}
