import AppKit
import ApplicationServices
import SpacesCore

/// One bounded Mission Control session for the whole profile. Uses the Dock's
/// accessibility identifiers, not localized button titles or screen coordinates.
/// Reference: Hammerspoon hs.spaces (mc.display / AXDisplayID / mc.spaces.add).
@MainActor
private final class MissionControlSession {
    private let system: SystemAdapter
    private let initial: [LiveDisplay]
    private let isCurrent: () -> Bool
    private var openedHere = false
    private var probeDeadline: TimeInterval = 0
    private let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    init(system: SystemAdapter, initial: [LiveDisplay], isCurrent: @escaping () -> Bool) {
        self.system = system; self.initial = initial; self.isCurrent = isCurrent
    }
    private func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        let remaining = probeDeadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        return BoundedAX.value(element, key, timeout: Float(min(0.3, remaining)))
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private func identifier(_ element: AXUIElement) -> String? { value(element, kAXIdentifierAttribute) as? String }
    private func group() -> AXUIElement? {
        probeDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        return children(element).first { identifier($0) == "mc" }
    }
    private func check() throws -> [LiveDisplay] {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        let now = try system.inventory()
        guard Set(now.map(\.uuid)) == Set(initial.map(\.uuid)), now.count == initial.count else { throw CancellationError() }
        return now
    }
    private func toggle() throws {
        guard NSWorkspace.shared.open(missionControlURL) else {
            throw LayoutError.invalid("Impossible d’ouvrir Mission Control. Aucun bureau n’a été ajouté.")
        }
    }
    private func open() async throws {
        guard AXIsProcessTrusted() else {
            throw LayoutError.invalid("Autorise Spaces Dock dans Réglages → Accessibilité pour créer les bureaux manquants.")
        }
        _ = try check()
        if group() != nil { return }
        try toggle(); openedHere = true
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        for _ in 0..<40 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            try await Task.sleep(for: .milliseconds(100))
            _ = try check()
            if group() != nil { return }
        }
        throw LayoutError.invalid("Mission Control ne répond pas. Aucun déplacement de fenêtre n’a été lancé ; réessaie.")
    }
    func close() async throws {
        guard openedHere else { return }
        openedHere = false
        // Do not toggle a second time if the user has already closed Mission Control.
        guard group() != nil else { return }
        try toggle()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        for _ in 0..<30 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            if group() == nil { return }
            // The close command is already sent even when the operation was cancelled.
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LayoutError.invalid("Ferme Mission Control, puis réapplique le profil. Les bureaux ajoutés sont conservés.")
    }
    func add(on role: ScreenRole) async throws {
        let before = try check()
        guard let target = before.first(where: { $0.spaces.role == role }),
              let number = target.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw LayoutError.invalid("L’écran cible n’est plus disponible.")
        }
        let oldIDs = target.spaces.desktops.map(\.id)
        try await open()
        var button: AXUIElement?
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        for _ in 0..<30 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            _ = try check()
            if let mc = group(),
               let display = children(mc).first(where: { identifier($0) == "mc.display" && (value($0, "AXDisplayID") as? NSNumber)?.uint32Value == number.uint32Value }),
               let spaces = children(display).first(where: { identifier($0) == "mc.spaces" }) {
                button = children(spaces).first { identifier($0) == "mc.spaces.add" }
            }
            if button != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let button else {
            throw LayoutError.invalid("Le bouton d’ajout de bureau est indisponible sur \(target.name). Aucun déplacement de fenêtre n’a été lancé.")
        }
        let latest = try check().first { $0.uuid == target.uuid }!
        guard Array(latest.spaces.desktops.map(\.id).prefix(oldIDs.count)) == oldIDs else { throw CancellationError() }
        if latest.spaces.desktops.count > oldIDs.count { return }
        guard (value(button, kAXEnabledAttribute) as? Bool) == true, BoundedAX.prepare(button) else {
            throw LayoutError.invalid("Le bouton d’ajout ne peut pas être vérifié sur \(target.name). Aucun ajout n’a été demandé ; réessaie.")
        }
        _ = try check()
        let pressResult = try performAuthorizedRuntimeMutation(isTrusted: AXIsProcessTrusted) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        guard pressResult == .success || pressResult == .cannotComplete else {
            throw LayoutError.invalid("macOS n’a pas accepté l’ajout d’un bureau sur \(target.name). Vérifie Accessibilité et la limite de bureaux de cet écran.")
        }
        // A timed-out AX reply may still have created the desktop. One press
        // only, followed by observation; never press again after a timeout.
        do {
            try await waitForDesktopCreation(previousIDs: oldIDs, readIDs: {
                try self.check().first { $0.uuid == target.uuid }!.spaces.desktops.map(\.id)
            }, wait: { try await Task.sleep(for: .milliseconds(100)) }, isCurrent: isCurrent)
        } catch {
            throw LayoutError.invalid("Création demandée sur \(target.name), mais non confirmée. Le nouveau bureau peut déjà exister ; vérifie Mission Control avant de réessayer. Aucun déplacement de fenêtre n’a été lancé.")
        }
    }
}

extension SystemAdapter {
    func prepareMissingDesktops(profile: LayoutProfile, isCurrent: @escaping () -> Bool,
                                didCreate: (ScreenRole, Int) -> Void) async throws {
        let session = MissionControlSession(system: self, initial: try inventory(), isCurrent: isCurrent)
        do {
            try await prepareDesktops(profile: profile, readDisplays: { try self.inventory().map(\.spaces) },
                                      addDesktop: { try await session.add(on: $0) },
                                      isCurrent: isCurrent, didCreate: didCreate)
        } catch {
            try? await session.close()
            throw error
        }
        try await session.close()
    }
}
