import Foundation

public enum ScreenRole: String, Codable, CaseIterable { case builtIn, external }
public struct AppRule: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var screen: ScreenRole
    public var desktop: Int
    // Legacy per-app preference retained for configuration compatibility; no longer used.
    public var launch: Bool
    public init(id: String, name: String, path: String, screen: ScreenRole = .builtIn, desktop: Int = 1, launch: Bool = false) {
        self.id = id; self.name = name; self.path = path; self.screen = screen; self.desktop = desktop; self.launch = launch
    }
}
public struct LayoutProfile: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var rules: [AppRule]
    public init(id: String, name: String, rules: [AppRule] = []) { self.id = id; self.name = name; self.rules = rules }
}
public struct Desktop: Equatable {
    public let id: UInt64
    /// Native Dock binding value. An explicitly empty string identifies the
    /// original desktop on some Macs; it is different from a missing binding.
    public let uuid: String
    public init(id: UInt64, uuid: String) { self.id = id; self.uuid = uuid }
}
public struct DisplaySpaces {
    public let role: ScreenRole
    public let desktops: [Desktop]
    public init(role: ScreenRole, desktops: [Desktop]) { self.role = role; self.desktops = desktops }
}
public struct ResolvedRule { public let rule: AppRule; public let target: Desktop }
public enum LayoutError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public func resolve(profile: LayoutProfile, displays: [DisplaySpaces]) throws -> [ResolvedRule] {
    var seen = Set<String>()
    return try profile.rules.map { rule in
        guard !rule.id.isEmpty, seen.insert(rule.id).inserted else { throw LayoutError.invalid("Une application figure plusieurs fois dans ce profil.") }
        let matches = displays.filter { $0.role == rule.screen }
        guard matches.count == 1, let display = matches.first else {
            throw LayoutError.invalid("\(rule.name) : écran \(rule.screen == .builtIn ? "MacBook" : "externe") absent ou ambigu.")
        }
        guard rule.desktop > 0, rule.desktop <= display.desktops.count else {
            throw LayoutError.invalid("\(rule.name) : bureau \(rule.desktop) absent. Crée-le dans Mission Control ou change l’affectation.")
        }
        return ResolvedRule(rule: rule, target: display.desktops[rule.desktop - 1])
    }
}
public func groupedRules(_ rules: [AppRule]) -> [[AppRule]] {
    let sorted = rules.enumerated().sorted {
        let a = $0.element, b = $1.element
        if a.screen != b.screen { return a.screen == .builtIn }
        if a.desktop != b.desktop { return a.desktop < b.desktop }
        return $0.offset < $1.offset
    }.map(\.element)
    var groups: [[AppRule]] = []
    for rule in sorted {
        if let previous = groups.last?.last, previous.screen == rule.screen && previous.desktop == rule.desktop {
            groups[groups.count - 1].append(rule)
        } else { groups.append([rule]) }
    }
    return groups
}
public func dockItems(rules: [AppRule], existing: [[String: Any]]) -> [[String: Any]] {
    guard !rules.isEmpty else { return existing }
    let ids = Set(rules.map(\.id)), paths = Set(rules.map(\.path))
    let candidates = existing.filter { tile in
        let data = tile["tile-data"] as? [String: Any] ?? [:]
        if data["spaces-dock-owned"] as? Bool == true { return false }
        if let id = data["bundle-identifier"] as? String, ids.contains(id) { return false }
        if let file = data["file-data"] as? [String: Any], let url = file["_CFURLString"] as? String,
           let path = URL(string: url)?.path, paths.contains(path) { return false }
        return true
    }
    // Dock removes custom tile metadata. Normalize the remaining separators
    // structurally: no leading/trailing gaps, at most one between unmanaged apps.
    var remainder: [[String: Any]] = []
    var pendingGap: [String: Any]?
    for tile in candidates {
        let type = tile["tile-type"] as? String
        if type == "spacer-tile" || type == "small-spacer-tile" || type == "flex-spacer-tile" {
            if !remainder.isEmpty { pendingGap = tile }
            continue
        }
        if let separator = pendingGap { remainder.append(separator); pendingGap = nil }
        remainder.append(tile)
    }
    let gap: [String: Any] = ["tile-type": "spacer-tile", "tile-data": ["spaces-dock-owned":true]]
    var output: [[String: Any]] = []
    for group in groupedRules(rules) {
        if !output.isEmpty { output.append(gap) }
        for rule in group {
            output.append(["tile-type":"file-tile", "tile-data":[
                "bundle-identifier":rule.id, "file-label":rule.name, "file-type":41,
                "file-data":["_CFURLString":URL(fileURLWithPath:rule.path).absoluteString, "_CFURLStringType":15]
            ]])
        }
    }
    if !remainder.isEmpty { output.append(gap); output.append(contentsOf: remainder) }
    return output
}

public func moveWithinDesktop(_ rules: [AppRule], sourceID: String, targetID: String) -> [AppRule] {
    guard sourceID != targetID,
          let source = rules.first(where: { $0.id == sourceID }),
          let target = rules.first(where: { $0.id == targetID }),
          source.screen == target.screen, source.desktop == target.desktop else { return rules }
    let indices = rules.indices.filter { rules[$0].screen == source.screen && rules[$0].desktop == source.desktop }
    var group = indices.map { rules[$0] }
    guard let from = group.firstIndex(where: { $0.id == sourceID }),
          let to = group.firstIndex(where: { $0.id == targetID }) else { return rules }
    group.insert(group.remove(at:from),at:to)
    var result = rules
    for (index, value) in zip(indices, group) { result[index] = value }
    return result
}

public func shouldLaunchAtLogin(enabled: Bool, loginEnabled: Bool, launchedAtLogin: Bool) -> Bool {
    enabled && loginEnabled && launchedAtLogin
}

public func appsToLaunch(profile: LayoutProfile, runningIDs: Set<String>) -> [AppRule] {
    profile.rules.filter { !runningIDs.contains($0.id) }
}

public enum ProfileApplyReason {
    case manual, login, automatic

    public var opensApps: Bool { self != .automatic }
    public func isAllowed(automatic: Bool, launchAtLogin: Bool, loginService: Bool) -> Bool {
        switch self {
        case .manual: return true
        case .login: return launchAtLogin && loginService
        case .automatic: return automatic
        }
    }
}

public func appsToOpen(profile: LayoutProfile, reason: ProfileApplyReason,
                       runningIDs: Set<String>, windowedIDs: Set<String>) -> [AppRule] {
    switch reason {
    case .automatic: return []
    case .login: return appsToLaunch(profile: profile, runningIDs: runningIDs)
    case .manual: return profile.rules.filter { !runningIDs.contains($0.id) || !windowedIDs.contains($0.id) }
    }
}
