import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import SpacesCore

enum ApplyOutcome { case completed, skipped, topologyChanged }

@MainActor
final class AppStore: ObservableObject {
    @Published var profiles: [LayoutProfile] = [] { didSet { profilesEdited(from:oldValue) } }
    @Published var selected = "solo"
    @Published var settingsRequested = false
    @Published var automatic = false
    @Published var launchAllAtLogin = false
    @Published var displays: [LiveDisplay] = []
    @Published var busy = false
    @Published var status = "Prêt à configurer"
    @Published var report: [String] = []
    @Published var reportProfileName: String?
    @Published var reportHasFailures = false
    @Published var error: String?
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var hasBackup = false
    @Published var accessible = AXIsProcessTrusted()
    private var saved: Configuration
    @Published private var loadFailed = false
    @Published private(set) var topologyAvailable = false
    private var editingReady = false
    private var restoringEdit = false
    private var undoHistory: [[LayoutProfile]] = []
    private var openRequest: CallbackOperation<NSRunningApplication>?
    private var userCancelled = false
    private var terminateAfterOperation = false
    private var observations: [NSObjectProtocol] = []
    private var loginTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var generation = OperationGeneration()
    private var topologyGeneration = OperationGeneration()
    private var topologyTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?
    private let system = SystemAdapter()
    let directory: URL
    var configURL: URL { directory.appendingPathComponent("configuration.json") }
    var backupURL: URL { directory.appendingPathComponent("original.plist") }
    var activeID: String { displays.count > 1 ? "dual" : "solo" }
    var dirty: Bool { profiles != saved.profiles }
    var configurationUnavailable: Bool { loadFailed }
    var canUndoEdit: Bool { !undoHistory.isEmpty && !busy && !loadFailed }
    var pendingApplication: Bool {
        guard let profile = profiles.first(where:{$0.id == selected}), !profile.rules.isEmpty else { return false }
        return saved.lastAppliedProfile != profile
    }
    var selectedIndex: Int { profiles.firstIndex { $0.id == selected } ?? 0 }

    init(directory suppliedDirectory: URL? = nil) {
        directory = suppliedDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SpacesDock", isDirectory: true)
        saved = Configuration(profiles:[.init(id:"solo",name:"MacBook seul"),.init(id:"dual",name:"Avec écran externe")])
        let url = directory.appendingPathComponent("configuration.json")
        if FileManager.default.fileExists(atPath:url.path) {
            do {
                let decoded = try ConfigurationFile(url:url).load()
                saved = decoded
            } catch {
                loadFailed = true
                self.error = "Configuration illisible : \(error.localizedDescription). Le fichier est conservé. Importe une sauvegarde depuis Réglages pour récupérer tes profils."
            }
        }
        profiles = saved.profiles; automatic = saved.automatic
        launchAllAtLogin = saved.launchAllAtLogin ?? false
        hasBackup = FileManager.default.fileExists(atPath: backupURL.path)
        refresh()
        selected = activeID
        editingReady = true
        let nc = NotificationCenter.default
        observations.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        })
        observations.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object:nil,queue:.main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.appLaunched(app.bundleIdentifier) }
        })
    }
    func startAutomation(launchedAtLogin: Bool) {
        guard startupTask == nil, loginTask == nil, !loadFailed else { return }
        if shouldLaunchAtLogin(enabled:launchAllAtLogin, loginEnabled:loginEnabled, launchedAtLogin:launchedAtLogin) {
            loginTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for:.seconds(3)) } catch { return }
                guard let self else { return }
                defer { self.loginTask = nil }
                for _ in 0..<3 {
                    while self.busy {
                        do { try await Task.sleep(for:.milliseconds(200)) } catch { return }
                    }
                    guard self.launchAllAtLogin, self.loginEnabled, !Task.isCancelled else { return }
                    let outcome = await self.applySaved(reason:.login,configure:true)
                    guard outcome == .topologyChanged else { return }
                    do { try await Task.sleep(for:.seconds(2)) } catch { return }
                }
                self.error = "Les écrans changent encore. Stabilise leur connexion, puis applique le profil actif."

            }
        } else if automatic {
            startupTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for:.seconds(3)) } catch { return }
                guard let self, self.automatic, !Task.isCancelled else { return }
                await self.applySaved(reason:.automatic,configure:true)
            }
        }
    }
    func refresh() {
        do { displays = try system.inventory(); topologyAvailable = true } catch { topologyAvailable = false; self.error = error.localizedDescription }
        accessible = AXIsProcessTrusted()
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func persist(_ config: Configuration) throws {
        guard !loadFailed else { throw LayoutError.invalid("Configuration illisible : le fichier existant ne sera pas écrasé.") }
        try ConfigurationFile(url:configURL).save(config)
        saved = config
    }
    private func profilesEdited(from previous: [LayoutProfile]) {
        guard editingReady, previous != profiles else { return }
        if !restoringEdit {
            undoHistory.append(previous)
            if undoHistory.count > 30 { undoHistory.removeFirst() }
        }
        do {
            var next = saved; next.profiles = profiles
            try persist(next)
            status = "Modifications enregistrées — prêtes à appliquer"
            error = nil
        } catch {
            self.error = "Enregistrement impossible : \(error.localizedDescription). Les changements restent ouverts ; exporte-les avant de quitter."
        }
    }
    func save() {
        do {
            var next = saved; next.profiles = profiles
            try persist(next)
            status = "Profils enregistrés"; error = nil
        } catch { self.error = "Enregistrement impossible : \(error.localizedDescription)" }
    }
    func undoEdit() {
        guard canUndoEdit, let previous = undoHistory.popLast() else { return }
        restoringEdit = true; profiles = previous; restoringEdit = false
    }
    func shouldTerminate() -> Bool {
        if busy {
            let alert = NSAlert(); alert.messageText = "Une disposition est en cours d’application"
            alert.informativeText = "Tu peux attendre ou arrêter les étapes restantes. Les apps ouvertes, les bureaux créés et les fenêtres déjà déplacées seront conservés."
            alert.addButton(withTitle:"Attendre"); alert.addButton(withTitle:"Arrêter et quitter")
            if alert.runModal() == .alertSecondButtonReturn { terminateAfterOperation = true; cancelOperation() }
            return false
        }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Des modifications n’ont pas été enregistrées"
        alert.informativeText = "Réessaie l’enregistrement ou reviens à l’app pour exporter tes profils."
        alert.addButton(withTitle:"Revenir à l’app"); alert.addButton(withTitle:"Réessayer l’enregistrement")
        if alert.runModal() == .alertSecondButtonReturn { save(); return !dirty }
        return false
    }
    func cancelOperation() {
        guard busy else { return }
        userCancelled = true; generation.invalidate()
        openRequest?.cancel()
        loginTask?.cancel(); startupTask?.cancel(); topologyTask?.cancel(); launchTask?.cancel()
        status = "Arrêt des étapes restantes…"
    }
    func setAutomatic(_ enabled: Bool) {
        guard !loadFailed, !dirty else { error = "Enregistre ou récupère les profils avant d’activer l’automatisation."; return }
        do {
            var next = saved; next.automatic = enabled
            try persist(next); automatic = enabled
            if !enabled { stopPendingAutomation() }
            status = enabled ? "Changement de profil automatique activé" : "Automatisation suspendue"
            if enabled && loginTask == nil { startupTask = Task { await applySaved(reason:.automatic,configure:true) } }
        } catch { self.error = error.localizedDescription }
    }
    func setLogin(_ enabled: Bool) {
        guard !loadFailed, !dirty else { error = "Enregistre ou récupère les profils avant de configurer le démarrage."; return }
        let previousStatus = SMAppService.mainApp.status
        var serviceChanged = false
        do {
            if enabled && previousStatus != .enabled && previousStatus != .requiresApproval {
                try SMAppService.mainApp.register(); serviceChanged = true
            } else if !enabled && previousStatus != .notRegistered {
                try SMAppService.mainApp.unregister(); serviceChanged = true
            }
            var next = saved; next.launchAllAtLogin = enabled
            try persist(next)
            launchAllAtLogin = enabled
            if !enabled, loginTask != nil {
                loginTask?.cancel(); loginTask = nil; generation.invalidate()
            }
            refresh(); error = nil
            status = loginNeedsApproval ? "Autorise Spaces Dock dans les éléments d’ouverture de macOS" : (enabled ? "Les apps du profil s’ouvriront à la connexion" : "Lancement des apps à la connexion désactivé")
        } catch {
            let originalError = error.localizedDescription
            var rollbackError = ""
            if serviceChanged {
                do {
                    if previousStatus == .enabled || previousStatus == .requiresApproval { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch { rollbackError = " Vérifie aussi l’élément d’ouverture dans macOS : \(error.localizedDescription)." }
            }
            self.error = "Ouverture à la connexion : \(originalError). Place l’app dans Applications et réessaie." + rollbackError
            refresh()
        }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        accessible = AXIsProcessTrustedWithOptions(options)
        if !accessible { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    }
    func addApplication() {
        guard !busy, !loadFailed else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath:"/Applications"); panel.prompt = "Ajouter"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url:url)?.bundleIdentifier else { error = "Application non reconnue : \(url.lastPathComponent)"; continue }
            guard !profiles[selectedIndex].rules.contains(where: { $0.id == id }) else { continue }
            profiles[selectedIndex].rules.append(.init(id:id,name:url.deletingPathExtension().lastPathComponent,path:url.path))
        }
    }
    @discardableResult
    func moveApp(_ token: String, onto targetID: String) -> Bool {
        guard !busy else { return false }
        let parts = token.split(separator:"|",maxSplits:1).map(String.init)
        guard parts.count == 2, parts[0] == selected else { return false }
        let index = selectedIndex
        let before = profiles[index].rules
        let after = moveWithinDesktop(before,sourceID:parts[1],targetID:targetID)
        guard before != after else { return false }
        profiles[index].rules = after
        status = "Ordre modifié — applique le profil pour mettre à jour le Dock"
        return true
    }
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "SpacesDock-profils.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { var next = saved; next.profiles = profiles; let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]; try e.encode(next).write(to:url,options:.atomic); status = "Profils exportés" }
        catch { self.error = error.localizedDescription }
    }
    func importConfiguration() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.prompt = "Choisir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var imported = try ConfigurationFile(url:url).load().profiles
            for p in imported.indices {
                for r in imported[p].rules.indices {
                    // Resolve by bundle ID on this Mac; exports may come from another user.
                    let rule = imported[p].rules[r]
                    if Bundle(path:rule.path)?.bundleIdentifier != rule.id,
                       let local = NSWorkspace.shared.urlForApplication(withBundleIdentifier:rule.id) {
                        imported[p].rules[r].path = local.path
                    }
                }
            }
            let count = imported.reduce(0) { $0 + $1.rules.count }
            let alert = NSAlert(); alert.messageText = "Importer ces deux profils ?"
            alert.informativeText = "Ils contiennent \(count) affectations et remplaceront les profils actuels. Une copie de la configuration actuelle sera conservée. Aucune app ne sera ouverte maintenant et les options de démarrage ne seront pas importées."
            alert.addButton(withTitle:"Importer les profils"); alert.addButton(withTitle:"Annuler")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            var next = saved; next.profiles = imported; next.lastAppliedProfile = nil
            try ConfigurationFile(url:configURL).save(next,recovering:true)
            if !loadFailed { undoHistory.append(profiles) }
            saved = next; editingReady = false; profiles = imported; editingReady = true
            loadFailed = false; error = nil; status = "Profils importés — vérifie les affectations puis applique le profil"
        } catch { self.error = "Import impossible : \(error.localizedDescription). Les profils actuels ont été conservés." }
    }
    func exportDiagnostics() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "SpacesDock-diagnostic.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        // No configuration paths, document/window titles, serial numbers or credentials.
        let lines = [
            "Spaces Dock \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "Date : \(ISO8601DateFormatter().string(from:Date()))",
            system.diagnostic(),
            "Configuration lisible : \(!loadFailed)",
            "Modifications non enregistrées : \(dirty)",
            "Adaptation automatique : \(automatic)",
            "Lancement à la connexion : \(launchAllAtLogin), autorisé : \(loginEnabled)",
            "Apps : \(profiles.map { "\($0.id)=\($0.rules.count)" }.joined(separator:", "))",
            "Dernière application avec erreurs : \(reportHasFailures)",
            "Aucun titre de fenêtre ni contenu de document n’est inclus."
        ]
        do { try lines.joined(separator:"\n").write(to:url,atomically:true,encoding:.utf8); status = "Diagnostic exporté" }
        catch { self.error = "Export impossible : \(error.localizedDescription)" }
    }
    func showConfiguration() { NSWorkspace.shared.open(directory) }
    func readBackup() throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from:Data(contentsOf:backupURL),format:nil) as? [String:Any] else { throw LayoutError.invalid("Sauvegarde illisible.") }
        return value
    }
    func writeSnapshot(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:true)
        try PropertyListSerialization.data(fromPropertyList:value,format:.xml,options:0).write(to:url,options:.atomic)
    }
    func applySelected() async { await applyManual(profileID:selected) }
    func applyActive() async {
        refresh()
        guard topologyAvailable else { return }
        await applyManual(profileID:activeID)
    }
    private func applyManual(profileID: String) async {
        guard !busy, !loadFailed else { return }
        report = []; reportHasFailures = false; reportProfileName = nil
        refresh()
        guard topologyAvailable else { return }
        guard profileID == activeID else { error = "Connecte les écrans du profil choisi pour l’appliquer. Tes choix sont déjà enregistrés."; return }
        // Both entry points persist the current editor before invoking the same pipeline.
        save(); guard !dirty, error == nil else { return }
        await applySaved(reason:.manual,configure:true)
    }
    private func validateApplications(_ profile: LayoutProfile) throws {
        if displays.count > 1 && !NSScreen.screensHaveSeparateSpaces {
            throw LayoutError.invalid("Active « Les écrans disposent d’espaces distincts » dans Réglages Système → Bureau et Dock, puis déconnecte et reconnecte ta session.")
        }
        for rule in profile.rules {
            guard FileManager.default.fileExists(atPath:rule.path), Bundle(path:rule.path)?.bundleIdentifier == rule.id else {
                throw LayoutError.invalid("\(rule.name) est introuvable ou a changé d’identifiant. Retire-la puis ajoute-la à nouveau.")
            }
        }
    }
    private func validate(_ profile: LayoutProfile) throws -> [ResolvedRule] {
        try validateApplications(profile)
        return try resolve(profile:profile, displays:displays.map(\.spaces))
    }
    var missingDesktopSummary: [String] {
        guard selected == activeID,
              let requirements = try? desktopRequirements(profile:profiles[selectedIndex],displays:displays.map(\.spaces)) else { return [] }
        return requirements.filter { $0.missing > 0 }.map { item in
            let name = displays.first(where:{$0.spaces.role == item.screen})?.name ?? "Écran"
            return "\(name) : \(item.missing) bureau\(item.missing > 1 ? "x" : "") à créer (\(item.existing) présent\(item.existing > 1 ? "s" : ""), \(item.required) nécessaires)."
        }
    }
    @discardableResult
    func applySaved(reason: ProfileApplyReason, configure: Bool) async -> ApplyOutcome {
        func allowed() -> Bool {
            reason.isAllowed(automatic:automatic,launchAtLogin:launchAllAtLogin,loginService:loginEnabled)
        }
        guard !busy, !loadFailed, !dirty, allowed() else { return .skipped }
        let ticket = generation.value
        let topologyTicket = topologyGeneration.value
        busy = true; userCancelled = false; error = nil; report = []; reportHasFailures = false; reportProfileName = nil
        status = "Vérification des bureaux…"
        defer {
            busy = false; openRequest = nil
            if terminateAfterOperation { terminateAfterOperation = false; NSApp.terminate(nil) }
        }
        do {
            displays = try system.inventory()
            guard !displays.isEmpty else { throw LayoutError.invalid("Aucun écran disponible. Réessaie après la connexion de l’écran.") }
            guard let profile = saved.profiles.first(where: { $0.id == activeID }) else { return .skipped }
            reportProfileName = profile.name
            guard !profile.rules.isEmpty else { throw LayoutError.invalid("Ajoute une application à ce profil avant de l’appliquer.") }
            guard AXIsProcessTrusted() else { accessible = false; throw LayoutError.invalid("Autorise Spaces Dock dans Réglages Système → Confidentialité et sécurité → Accessibilité, puis réessaie.") }
            try validateApplications(profile)
            let requirements = try desktopRequirements(profile:profile,displays:displays.map(\.spaces))
            let needsCreation = requirements.contains { $0.missing > 0 }
            if needsCreation {
                status = "Création des bureaux manquants…"
                let displayNames = Dictionary(displays.map { ($0.spaces.role,$0.name) }, uniquingKeysWith: { first, _ in first })
                try await system.prepareMissingDesktops(profile:profile,isCurrent: {
                    self.generation.accepts(ticket) && self.topologyGeneration.accepts(topologyTicket)
                    && self.activeID == profile.id && allowed()
                },didCreate: { role, number in
                    self.report.append("\(displayNames[role] ?? "Écran") : bureau \(number) créé.")
                })
                displays = try system.inventory()
            }
            guard generation.accepts(ticket), topologyGeneration.accepts(topologyTicket), !Task.isCancelled, activeID == profile.id else { throw CancellationError() }
            let resolved = try validate(profile)
            status = "Application de la disposition…"
            if configure || needsCreation {
                _ = try applyTransaction(prepare: { try system.validateTargets(resolved); return resolved }, snapshot: {
                    let before = system.snapshot()
                    if !FileManager.default.fileExists(atPath:backupURL.path) { try writeSnapshot(before,to:backupURL); hasBackup = true }
                    try writeSnapshot(before,to:directory.appendingPathComponent("last-apply.plist"))
                    return before
                }, mutate: { items in
                    try system.configure(items,previousIDs:saved.lastManagedIDs,original:readBackup())
                }, persist: { items in
                    var next = saved; next.lastManagedIDs = items.map { $0.rule.id }; next.lastAppliedProfile = nil; try persist(next)
                }, restore: { try system.restore($0) })
                try await Task.sleep(for:.seconds(1.2))
            }
            guard generation.accepts(ticket), !Task.isCancelled, allowed() else { throw CancellationError() }
            var requestedApps: [AppRule] = []
            if reason.opensApps {
                guard topologyGeneration.accepts(topologyTicket), activeID == profile.id else { throw CancellationError() }
                let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                let windowedIDs = reason == .manual ? await system.appsWithWindows(Set(profile.rules.map(\.id)),isCurrent:{ self.generation.accepts(ticket) && self.topologyGeneration.accepts(topologyTicket) }) : []
                let pending = appsToOpen(profile:profile,reason:reason,runningIDs:runningIDs,windowedIDs:windowedIDs)
                for rule in pending {
                    guard !Task.isCancelled, generation.accepts(ticket), topologyGeneration.accepts(topologyTicket), activeID == profile.id, allowed() else { throw CancellationError() }
                    let alreadyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier:rule.id).isEmpty
                    guard AXIsProcessTrusted() else { accessible = false; throw LayoutError.invalid("L’autorisation Accessibilité a été retirée. Autorise Spaces Dock, puis réapplique le profil.") }
                    if alreadyRunning {
                        if reason == .login { continue }
                        let windowed = await system.appsWithWindows([rule.id],isCurrent:{ self.generation.accepts(ticket) && self.topologyGeneration.accepts(topologyTicket) })
                        guard generation.accepts(ticket), topologyGeneration.accepts(topologyTicket), !Task.isCancelled else { throw CancellationError() }
                        if windowed.contains(rule.id) { continue }
                    }
                    guard AXIsProcessTrusted() else { accessible = false; throw LayoutError.invalid("L’autorisation Accessibilité a été retirée. Autorise Spaces Dock, puis réapplique le profil.") }
                    status = "Ouverture de \(rule.name)…"
                    let options = NSWorkspace.OpenConfiguration()
                    // A manual reopen needs the normal foreground activation path:
                    // some apps recreate their last window only when activated.
                    options.activates = reason == .manual
                    options.createsNewApplicationInstance = false
                    do {
                        // LaunchServices sends a reopen request to an existing process
                        // when its last window was closed. Never start a second instance.
                        let request = CallbackOperation<NSRunningApplication>()
                        openRequest = request
                        _ = try await request.run(timeout:.seconds(15)) { completion in
                            NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:rule.path),configuration:options) { application, error in
                                Task { @MainActor in
                                    if let error { completion(.failure(error)) }
                                    else if let application { completion(.success(application)) }
                                    else { completion(.failure(LayoutError.invalid("macOS n’a pas confirmé l’ouverture."))) }
                                }
                            }
                        }
                        openRequest = nil
                    } catch is CancellationError { throw CancellationError() } catch {
                        throw LayoutError.invalid("Impossible d’ouvrir \(rule.name) : \(error.localizedDescription)")
                    }
                    requestedApps.append(rule)
                    report.append("\(rule.name) : ouverture demandée.")
                }
                if !requestedApps.isEmpty {
                    status = "Attente des fenêtres…"
                    let requestedIDs = Set(requestedApps.map(\.id))
                    for _ in 0..<40 {
                        guard !Task.isCancelled, generation.accepts(ticket), topologyGeneration.accepts(topologyTicket), activeID == profile.id, allowed() else { throw CancellationError() }
                        if requestedIDs.isSubset(of:await system.appsWithWindows(requestedIDs,isCurrent:{ self.generation.accepts(ticket) && self.topologyGeneration.accepts(topologyTicket) })) { break }
                        try await Task.sleep(for:.milliseconds(200))
                    }
                }
            }
            // Re-resolve after Dock restart: never reuse stale space IDs after a topology change.
            displays = try system.inventory()
            guard generation.accepts(ticket), topologyGeneration.accepts(topologyTicket), !Task.isCancelled else { throw CancellationError() }
            guard activeID == profile.id else { throw LayoutError.invalid("Les écrans ont changé pendant l’application. Le nouveau profil sera réessayé.") }
            let fresh = try validate(profile)
            status = "Placement des fenêtres…"
            let result = await system.moveWindows(fresh,displays:displays,requiringWindows:reason == .manual ? Set(profile.rules.map(\.id)) : Set(requestedApps.map(\.id)), isCurrent: {
                self.generation.accepts(ticket) && self.topologyGeneration.accepts(topologyTicket) && allowed()
            })
            guard !Task.isCancelled, generation.accepts(ticket), topologyGeneration.accepts(topologyTicket), activeID == profile.id else { throw CancellationError() }
            report.append(contentsOf:result.lines); reportHasFailures = result.hasFailures
            if result.hasFailures {
                var next = saved; next.lastAppliedProfile = nil; try persist(next)
                error = "Certaines fenêtres n’ont pas été déplacées. Consulte le rapport ; les affectations et le Dock ont été enregistrés."
                status = "Disposition partiellement appliquée"
            } else {
                var next = saved; next.lastAppliedProfile = profile; try persist(next)
                status = "Profil « \(profile.name) » appliqué · \(result.verified) fenêtre\(result.verified > 1 ? "s" : "") vérifiée\(result.verified > 1 ? "s" : "")"
            }
            return .completed
        } catch is CancellationError {
            reportHasFailures = true
            error = userCancelled ? "Opération arrêtée. Les changements déjà effectués sont conservés ; réapplique le profil pour terminer." : "Les écrans ou l’automatisation ont changé pendant l’opération. Les bureaux déjà ajoutés sont conservés."
            status = "Application interrompue ; disposition à revérifier"
        } catch {
            self.error = error.localizedDescription
            reportHasFailures = true
            status = "Disposition non appliquée complètement"
        }
        return reason == .login && !Task.isCancelled && !topologyGeneration.accepts(topologyTicket) ? .topologyChanged : .skipped
    }
    func restoreOriginal() {
        guard !busy else { return }
        do {
            let original = try readBackup()
            var next = saved; next.automatic = false; next.launchAllAtLogin = false; next.lastAppliedProfile = nil
            _ = try applyTransaction(prepare:{ next },snapshot:{ SMAppService.mainApp.status },mutate:{ _ in
                if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            },persist:{ try persist($0) },restore:{ previous in
                if previous == .enabled || previous == .requiresApproval { try SMAppService.mainApp.register() }
            })
            automatic = false; launchAllAtLogin = false
            loginTask?.cancel(); loginTask = nil
            stopPendingAutomation()
            try system.restore(original)
            next.lastManagedIDs = []; try persist(next)
            refresh()
            status = "Dock et affectations d’origine restaurés ; automatisation suspendue"
            report = []; error = nil
        } catch {
            let message = error.localizedDescription
            refresh(); self.error = "Restauration interrompue : \(message)"
        }
    }
    private func stopPendingAutomation() {
        if loginTask == nil { generation.invalidate() }
        startupTask?.cancel(); topologyTask?.cancel(); launchTask?.cancel()
    }
    private func screensChanged() {
        topologyGeneration.invalidate()
        topologyTask?.cancel()
        topologyTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(2)) } catch { return }
            guard let self else { return }
            self.refresh()
            guard self.automatic else { return }
            while self.busy {
                do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
            }
            guard !Task.isCancelled, self.automatic else { return }
            await self.applySaved(reason:.automatic,configure:true)
        }
    }
    private func appLaunched(_ id: String?) {
        guard automatic, let id,
              saved.profiles.first(where: { $0.id == activeID })?.rules.contains(where: { $0.id == id }) == true else { return }
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(1.5)) } catch { return }
            guard let self, self.automatic else { return }
            while self.busy {
                do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled, self.automatic else { return }
            await self.applySaved(reason:.automatic,configure:false)
        }
    }
}
