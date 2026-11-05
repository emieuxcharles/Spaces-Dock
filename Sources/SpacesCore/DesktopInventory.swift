import Foundation

/// Parse the system's ordinary desktops in their visual order.
public func readDesktops(_ items: [[String: Any]], displayName: String) throws -> [Desktop] {
    var spaces: [Desktop] = []
    for item in items {
        guard let type = (item["type"] as? NSNumber)?.intValue else {
            throw LayoutError.invalid("Le format des bureaux macOS n’est pas reconnu. L’opération est arrêtée ; vérifie la disposition avant de réessayer.")
        }
        guard type == 0 else { continue }
        // macOS can use "" for the original desktop. Preserve that exact value
        // for com.apple.spaces/app-bindings; missing/non-string UUIDs still fail.
        // Uniqueness is checked here and again across all connected displays.
        guard let id = (item["ManagedSpaceID"] as? NSNumber)?.uint64Value, id > 0,
              let spaceUUID = item["uuid"] as? String else {
            throw LayoutError.invalid("Un bureau de \(displayName) ne peut pas être identifié. L’opération est arrêtée ; vérifie la disposition avant de réessayer.")
        }
        spaces.append(Desktop(id: id, uuid: spaceUUID))
    }
    guard !spaces.isEmpty, Set(spaces.map(\.id)).count == spaces.count,
          Set(spaces.map(\.uuid)).count == spaces.count else {
        throw LayoutError.invalid("Les bureaux de \(displayName) sont vides ou ambigus. L’opération est arrêtée ; vérifie la disposition avant de réessayer.")
    }
    return spaces
}

public func validateDesktopIdentities(_ desktops: [Desktop]) throws {
    guard Set(desktops.map(\.id)).count == desktops.count,
          Set(desktops.map(\.uuid)).count == desktops.count else {
        throw LayoutError.invalid("Un même bureau est associé à plusieurs écrans. Active les espaces distincts, puis reconnecte ta session.")
    }
}

public func desktopAppBindings(_ resolved: [ResolvedRule], previousIDs: [String],
                               current: [String: String], baseline: [String: String]) -> [String: String] {
    var bindings = current
    let currentIDs = Set(resolved.map { $0.rule.id })
    for id in previousIDs where !currentIDs.contains(id) { bindings[id] = baseline[id] }
    for item in resolved { bindings[item.rule.id] = item.target.uuid }
    return bindings
}
