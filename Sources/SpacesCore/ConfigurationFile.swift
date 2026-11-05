import Foundation

/// Local, atomic storage. A damaged file may only be replaced by explicit recovery.
public struct ConfigurationFile {
    public let url: URL
    public var previousURL: URL { url.deletingLastPathComponent().appendingPathComponent("configuration.previous.json") }
    public init(url: URL) { self.url = url }
    public static func decode(_ data: Data) throws -> Configuration {
        guard data.count <= 2_097_152 else { throw LayoutError.invalid("Le fichier de profils dépasse la taille autorisée (2 Mo).") }
        return try JSONDecoder().decode(Configuration.self, from:data).validated()
    }
    public func load() throws -> Configuration {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 2_097_152 else { throw LayoutError.invalid("Le fichier de profils dépasse la taille autorisée (2 Mo).") }
        return try Self.decode(Data(contentsOf:url))
    }
    public func save(_ configuration: Configuration, recovering: Bool = false) throws {
        _ = try configuration.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(configuration)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:url.path) {
            let old = try Data(contentsOf:url)
            if recovering {
                let archive = url.deletingLastPathComponent().appendingPathComponent("configuration-recovered-\(UUID().uuidString).json")
                try old.write(to:archive,options:.atomic)
            } else {
                // Refuse to overwrite a file changed or damaged outside the app.
                _ = try Self.decode(old)
                if old != data { try old.write(to:previousURL,options:.atomic) }
            }
        }
        try data.write(to:url,options:.atomic)
    }
}
