import Foundation

public struct DesktopRequirement: Equatable {
    public let screen: ScreenRole
    public let existing: Int
    public let required: Int
    public var missing: Int { max(0, required - existing) }
}

/// The native request has already been accepted. Cancellation no longer proves
/// that nothing happened, so callers must report an uncertain creation outcome.
public struct DesktopCreationInterrupted: Error {}

@MainActor
public func waitForDesktopCreation(previousIDs: [UInt64], readIDs: () throws -> [UInt64],
                                   wait: () async throws -> Void, isCurrent: () -> Bool) async throws {
    do {
        for _ in 0..<50 {
            try await wait()
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
            let ids = try readIDs()
            guard Array(ids.prefix(previousIDs.count)) == previousIDs else { throw CancellationError() }
            if ids.count > previousIDs.count { return }
        }
    } catch is CancellationError {
        throw DesktopCreationInterrupted()
    }
    throw LayoutError.invalid("La création du bureau n’a pas été confirmée. Vérifie Mission Control avant de réessayer.")
}

public func desktopRequirements(profile: LayoutProfile, displays: [DisplaySpaces]) throws -> [DesktopRequirement] {
    var seen = Set<String>()
    var counts: [ScreenRole: Int] = [:]
    for rule in profile.rules {
        guard !rule.id.isEmpty, seen.insert(rule.id).inserted else {
            throw LayoutError.invalid("Une application figure plusieurs fois dans ce profil.")
        }
        guard (1...16).contains(rule.desktop) else {
            throw LayoutError.invalid("\(rule.name) : choisis un bureau entre 1 et 16.")
        }
        counts[rule.screen] = max(counts[rule.screen] ?? 0, rule.desktop)
    }
    return try ScreenRole.allCases.compactMap { role in
        guard let required = counts[role] else { return nil }
        let matches = displays.filter { $0.role == role }
        guard matches.count == 1, let display = matches.first, !display.desktops.isEmpty else {
            throw LayoutError.invalid("Écran \(role == .builtIn ? "MacBook" : "externe") absent, ambigu ou bureaux indisponibles.")
        }
        return DesktopRequirement(screen: role, existing: display.desktops.count, required: required)
    }
}

/// The native add operation waits for system confirmation. A failed/unconfirmed
/// press must not be retried: it could create an unwanted extra desktop later.
@MainActor
public func prepareDesktops(profile: LayoutProfile, readDisplays: () throws -> [DisplaySpaces],
                            addDesktop: (ScreenRole) async throws -> Void, isCurrent: () -> Bool,
                            didCreate: (ScreenRole, Int) -> Void) async throws {
    func checkCurrent() throws {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
    }
    try checkCurrent()
    let plan = try desktopRequirements(profile: profile, displays: readDisplays())
    for requirement in plan {
        for _ in 0..<requirement.missing {
            try checkCurrent()
            let before = try readDisplays()
            let fresh = try desktopRequirements(profile: profile, displays: before)
            guard fresh.first(where: { $0.screen == requirement.screen })!.missing > 0 else { break }
            let oldIDs = before.first(where: { $0.role == requirement.screen })!.desktops.map(\.id)
            try await addDesktop(requirement.screen)
            let after = try readDisplays()
            _ = try desktopRequirements(profile: profile, displays: after)
            let newIDs = after.first(where: { $0.role == requirement.screen })!.desktops.map(\.id)
            guard newIDs.count > oldIDs.count, Array(newIDs.prefix(oldIDs.count)) == oldIDs else {
                throw LayoutError.invalid("La création du bureau n’a pas été confirmée. Aucun déplacement de fenêtre n’a été lancé ; réessaie après avoir vérifié Mission Control.")
            }
            didCreate(requirement.screen, newIDs.count)
            try checkCurrent()
        }
    }
    try checkCurrent()
    _ = try resolve(profile: profile, displays: readDisplays())
}
