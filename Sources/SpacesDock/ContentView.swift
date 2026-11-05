import SwiftUI
import AppKit
import ServiceManagement
import SpacesCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @State private var destination: String? = "solo"
    @State private var restoreConfirmation = false
    @State private var showReport = false
    @State private var dragging: AppRule?
    @State private var dropTarget: String?
    @State private var assignmentID: String?
    private let accent = Color.accentColor
    private var isSettings: Bool { destination == "settings" }
    var body: some View {
        NavigationSplitView {
            List(selection:$destination) {
                Section("Profils") {
                    sidebarProfile("solo",title:"MacBook seul",symbol:"laptopcomputer")
                    sidebarProfile("dual",title:"Avec écran externe",symbol:"display.2")
                }
                Section {
                    Label("Réglages",systemImage:"gearshape").tag("settings")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min:195,ideal:220,max:260)
            .safeAreaInset(edge:.bottom,spacing:0) {
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        if store.topologyAvailable {
                            Label("\(store.displays.count) écran\(store.displays.count > 1 ? "s" : "") connecté\(store.displays.count > 1 ? "s" : "")",systemImage:"display")
                                .font(.caption.weight(.medium))
                        } else {
                            Label("Écrans indisponibles",systemImage:"exclamationmark.triangle")
                                .font(.caption.weight(.medium))
                        }
                        Spacer()
                        Button { store.refresh() } label: { Image(systemName:"arrow.clockwise") }
                            .buttonStyle(.borderless).help("Actualiser les écrans").disabled(store.busy)
                            .accessibilityLabel("Actualiser les écrans")
                    }
                    if store.topologyAvailable {
                        ForEach(Array(store.displays.enumerated()),id:\.offset) { _, display in
                            Text("\(display.name) · \(display.spaces.desktops.count) bureau\(display.spaces.desktops.count > 1 ? "x" : "")")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }.padding(16)
            }
        } detail: {
            VStack(spacing:0) {
                if isSettings { settingsPage } else { profilePage }
                Divider()
                footer.padding(.horizontal,20).padding(.vertical,12).background(.bar)
            }
            .navigationTitle(isSettings ? "Réglages" : store.profiles[store.selectedIndex].name)
            .toolbar {
                if !isSettings {
                    ToolbarItem(placement:.primaryAction) {
                        Button { store.addApplication() } label: { Label("Ajouter une app",systemImage:"plus") }
                            .help("Ajouter une application à ce profil").disabled(store.busy || store.configurationUnavailable)
                            .keyboardShortcut("n", modifiers:[.command,.shift])
                    }
                }
            }
            .background(Color(nsColor:.windowBackgroundColor))
        }
        .onAppear { destination = store.settingsRequested ? "settings" : store.selected }
        .onChange(of:destination) { _, value in
            if let value, value != "settings" { store.selected = value; store.settingsRequested = false }
        }
        .onChange(of:store.settingsRequested) { _, requested in if requested { destination = "settings" } }
        .onChange(of:store.selected) { _, selected in
            assignmentID = nil
            if !isSettings { destination = selected }
        }
        .sheet(isPresented:$showReport) { reportSheet }
        .frame(minWidth:900,minHeight:650)
        .confirmationDialog("Restaurer l’organisation d’origine ?",isPresented:$restoreConfirmation,titleVisibility:.visible) {
            Button("Restaurer et suspendre l’automatisation",role:.destructive) { store.restoreOriginal() }
            Button("Annuler",role:.cancel) {}
        } message: { Text("Le Dock et les affectations retrouveront leur état avant la première application. Les fenêtres déjà déplacées resteront à leur place.") }
    }
    func sidebarProfile(_ id:String,title:String,symbol:String)->some View {
        HStack {
            Label(title,systemImage:symbol)
            Spacer(minLength:4)
            if store.topologyAvailable && store.activeID == id {
                Image(systemName:"checkmark").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).help("Profil correspondant aux écrans connectés")
            }
        }.tag(id).accessibilityLabel(title + (store.topologyAvailable && store.activeID == id ? ", profil actuel" : ""))
    }
    var profilePage: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                VStack(alignment:.leading,spacing:8) {
                    HStack(alignment:.firstTextBaseline) {
                        Text("Applications et bureaux").font(.title2.weight(.semibold))
                        Spacer()
                        Text("\(orderedRules.count) app\(orderedRules.count > 1 ? "s" : "") · \(desktopGroups.count) bureau\(desktopGroups.count > 1 ? "x" : "")")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("Glisse une app ou utilise les flèches pour la classer. Clique sur son bureau pour changer son affectation.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                profileGuidance
                if store.topologyAvailable && store.selected != store.activeID {
                    Label("Tu peux préparer ce profil. Connecte l’écran correspondant pour l’appliquer.",systemImage:"display.2")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !store.missingDesktopSummary.isEmpty {
                    VStack(alignment:.leading,spacing:6) {
                        ForEach(store.missingDesktopSummary,id:\.self) { line in
                            Label(line,systemImage:"rectangle.badge.plus")
                        }
                        Text("Les bureaux manquants seront créés avant le déplacement des fenêtres. Mission Control s’ouvrira brièvement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.callout)
                }
                applicationList
                if !orderedRules.isEmpty { dockPreview }
            }.padding(28).frame(maxWidth:860).frame(maxWidth:.infinity)
        }
    }
    // Stable ties preserve the existing order within each desktop.
    var orderedRules: [AppRule] {
        store.profiles[store.selectedIndex].rules.enumerated().sorted {
            if $0.element.desktop != $1.element.desktop { return $0.element.desktop < $1.element.desktop }
            return $0.offset < $1.offset
        }.map(\.element)
    }
    func ruleBinding(_ rule: AppRule) -> Binding<AppRule> {
        let profileID = store.selected
        return Binding(get: {
            store.profiles.first(where: { $0.id == profileID })?.rules.first(where: { $0.id == rule.id }) ?? rule
        }, set: { updated in
            guard let p = store.profiles.firstIndex(where: { $0.id == profileID }),
                  let r = store.profiles[p].rules.firstIndex(where: { $0.id == rule.id }) else { return }
            store.profiles[p].rules[r] = updated
        })
    }
    private var desktopGroups: [DesktopSection] { groupedRules(orderedRules).map { DesktopSection(rules:$0) } }
    var applicationList: some View {
        VStack(alignment:.leading,spacing:20) {
            if orderedRules.isEmpty {
                ContentUnavailableView {
                    Label("Ajoute ta première app",systemImage:"app.dashed")
                } description: {
                    Text("Choisis une application, attribue-lui un bureau, puis applique le profil quand tu es prêt.")
                } actions: {
                    Button("Ajouter une app…") { store.addApplication() }
                        .disabled(store.busy || store.configurationUnavailable)
                }
                .frame(maxWidth:.infinity).padding(.vertical,24)
            }
            ForEach(desktopGroups) { section in
                let group = section.rules
                if let first = group.first {
                    VStack(alignment:.leading,spacing:10) {
                        HStack(alignment:.firstTextBaseline) {
                            Text("Bureau \(first.desktop)").font(.headline)
                            Text(displayName(first.screen)).font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1).help(displayName(first.screen))
                            Spacer()
                            Text(dragging?.desktop == first.desktop && dragging?.screen == first.screen
                                 ? "Réorganiser dans ce bureau" : "\(group.count) app\(group.count > 1 ? "s" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing:0) {
                            ForEach(group) { rule in
                                appRow(ruleBinding(rule))
                                    .overlay(alignment: insertionAtBottom(rule) ? .bottom : .top) {
                                        if dropTarget == rule.id {
                                            Rectangle().fill(accent).frame(height:2).padding(.horizontal,12)
                                        }
                                    }
                                if rule.id != group.last?.id { Divider().padding(.leading,58) }
                            }
                        }
                        .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
                        .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(Color.primary.opacity(0.07)))
                    }
                    .opacity(dragging != nil && (dragging?.desktop != first.desktop || dragging?.screen != first.screen) ? 0.35 : 1)
                }
            }
        }
    }
    func insertionAtBottom(_ rule: AppRule) -> Bool {
        let rules = store.profiles[store.selectedIndex].rules
        guard let dragging, let source = rules.firstIndex(where:{$0.id == dragging.id}),
              let target = rules.firstIndex(where:{$0.id == rule.id}) else { return false }
        return source < target
    }
    func appRow(_ binding: Binding<AppRule>) -> some View {
        let rule = binding.wrappedValue
        let neighbors = orderedRules.filter { $0.screen == rule.screen && $0.desktop == rule.desktop }
        let index = neighbors.firstIndex(where: { $0.id == rule.id }) ?? 0
        let canMoveUp = index > 0
        let canMoveDown = index + 1 < neighbors.count
        let canEdit = !store.busy && !store.configurationUnavailable
        // Width stays local: root state would interrupt native split-view resizing.
        return GeometryReader { geometry in
            HStack(spacing:8) {
                NativeRowDrag(rule:rule, rowWidth:geometry.size.width,
                    enabled:canEdit && neighbors.count > 1,
                    started:{ assignmentID = nil; dragging = rule; dropTarget = nil },
                    ended:{ dragging = nil; dropTarget = nil },
                    accepts:{ id in canEdit && dragging?.id == id && id != rule.id && dragging?.screen == rule.screen && dragging?.desktop == rule.desktop },
                    hovered:{ active in if active { dropTarget = rule.id } else if dropTarget == rule.id { dropTarget = nil } },
                    dropped:{ id in store.moveApp("\(store.selected)|\(id)",onto:rule.id) },
                    moveUp:{ if canEdit && canMoveUp { store.moveApp("\(store.selected)|\(rule.id)",onto:neighbors[index-1].id) } },
                    moveDown:{ if canEdit && canMoveDown { store.moveApp("\(store.selected)|\(rule.id)",onto:neighbors[index+1].id) } })
                    .frame(maxWidth:.infinity).frame(height:RowMetrics.contentHeight)
                Button {
                    assignmentID = rule.id
                } label: {
                    HStack(spacing:4) {
                        Text("Bureau \(rule.desktop)")
                        Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold))
                    }.frame(width:RowMetrics.assignmentWidth)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Changer le bureau de \(rule.name)")
                .accessibilityValue("\(rule.screen == .builtIn ? "MacBook" : "Écran externe"), bureau \(rule.desktop)")
                .help("Changer l’écran ou le bureau de \(rule.name)")
                .popover(isPresented:Binding(get:{ assignmentID == rule.id },set:{ if !$0 { assignmentID = nil } }),arrowEdge:.trailing) {
                    AssignmentPopover(rule:binding,allowsExternal:store.selected == "dual",displays:store.topologyAvailable ? store.displays : [])
                        .disabled(!canEdit)
                }
                HStack(spacing:0) {
                    Button { store.moveApp("\(store.selected)|\(rule.id)",onto:neighbors[index-1].id) } label: {
                        Image(systemName:"chevron.up").frame(width:RowMetrics.reorderWidth,height:26)
                    }
                    .disabled(!canMoveUp)
                    .accessibilityLabel("Monter \(rule.name) d’une place")
                    .help("Monter d’une place · ⌥↑ lorsque la ligne est sélectionnée")
                    Button { store.moveApp("\(store.selected)|\(rule.id)",onto:neighbors[index+1].id) } label: {
                        Image(systemName:"chevron.down").frame(width:RowMetrics.reorderWidth,height:26)
                    }
                    .disabled(!canMoveDown)
                    .accessibilityLabel("Descendre \(rule.name) d’une place")
                    .help("Descendre d’une place · ⌥↓ lorsque la ligne est sélectionnée")
                }.buttonStyle(.borderless)
                Menu {
                    Button("Retirer \(rule.name) du profil",role:.destructive) {
                        store.profiles[store.selectedIndex].rules.removeAll { $0.id == rule.id }
                    }
                } label: { Image(systemName:"ellipsis").frame(width:26,height:26) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Options pour \(rule.name)")
                .help("Options pour \(rule.name)")
            }
            .padding(.horizontal,RowMetrics.horizontalInset).padding(.vertical,RowMetrics.verticalInset)
            .opacity(dragging?.id == rule.id ? 0.35 : 1)
            .disabled(!canEdit)
        }.frame(height:RowMetrics.height)
    }
    @ViewBuilder var profileGuidance: some View {
        if store.configurationUnavailable {
            VStack(alignment:.leading,spacing:8) {
                Label("Tes profils doivent être récupérés",systemImage:"exclamationmark.triangle")
                    .font(.headline)
                Text("Le fichier existant a été conservé. Importe une copie valide pour reprendre la configuration.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Importer des profils…") { store.importConfiguration() }
                    Button("Afficher le fichier") { store.showConfiguration() }
                }
            }
        } else if !store.topologyAvailable {
            VStack(alignment:.leading,spacing:8) {
                Label("Les écrans ne peuvent pas être vérifiés",systemImage:"exclamationmark.triangle")
                    .font(.headline)
                Text("Vérifie leur connexion, puis actualise. Tu peux continuer à préparer les profils.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Actualiser les écrans") { store.refresh() }.disabled(store.busy)
            }
        } else if !store.accessible {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:"accessibility").font(.title2).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:4) {
                    Text("Autorise le déplacement des fenêtres").font(.headline)
                    Text("Dans Réglages Système → Confidentialité et sécurité → Accessibilité, active Spaces Dock, puis reviens ici.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:8)
                Button("Autoriser…") { store.requestAccessibility() }
            }
        } else if !store.hasBackup && !orderedRules.isEmpty {
            Label("Les choix sont enregistrés automatiquement. « Appliquer ce profil » organise le Dock et ouvre les apps nécessaires.",systemImage:"info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func displayName(_ role: ScreenRole) -> String {
        let matches = store.displays.filter { $0.spaces.role == role }
        if store.topologyAvailable && matches.count == 1 { return matches[0].name }
        return role == .builtIn ? "MacBook" : "Écran externe"
    }
    var dockPreview: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("Aperçu du Dock").font(.headline)
                Spacer()
                Text("Dans l’ordre de tes bureaux").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                HStack(alignment:.top,spacing:18) {
                    ForEach(Array(groupedRules(store.profiles[store.selectedIndex].rules).enumerated()),id:\.offset) { index, group in
                        if index > 0 { Rectangle().fill(.separator).frame(width:1,height:32).padding(.top,3).accessibilityHidden(true) }
                        VStack(spacing:6) {
                            HStack(spacing:5) {
                                ForEach(group) { rule in
                                    Image(nsImage:NSWorkspace.shared.icon(forFile:rule.path)).resizable().frame(width:34,height:34)
                                        .help(rule.name).accessibilityLabel(rule.name)
                                }
                            }
                            if let first = group.first {
                                Text("Bureau \(first.desktop)" + (store.selected == "dual" ? " · \(first.screen == .builtIn ? "MacBook" : "Externe")" : ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(14)
            }.background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:10))
            Text("Un espace sépare chaque groupe. Les autres apps épinglées restent à la suite.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    var settingsPage: some View {
        Form {
            Section {
                Toggle(isOn:Binding(get:{store.launchAllAtLogin},set:{store.setLogin($0)})) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Ouvrir les apps de mon profil")
                        Text("À la connexion au Mac, lance toutes les apps du profil correspondant aux écrans connectés et place leurs fenêtres dans les bureaux définis.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }.toggleStyle(.switch)
                    .disabled(store.configurationUnavailable)
                    .accessibilityLabel("Ouvrir les apps de mon profil")
                if store.launchAllAtLogin && !store.loginEnabled {
                    VStack(alignment:.leading,spacing:8) {
                        Label(store.loginNeedsApproval ? "Autorisation macOS en attente" : "Le lancement de Spaces Dock est désactivé dans macOS",systemImage:"exclamationmark.circle")
                            .font(.callout)
                        Button("Vérifier les éléments d’ouverture…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            } header: { Text("À la connexion") } footer: {
                Text("Cette option lance aussi Spaces Dock à la connexion. Les apps déjà ouvertes ne sont pas relancées. Une ouverture manuelle de Spaces Dock ne lance aucune app.")
            }
            Section {
                Toggle(isOn:Binding(get:{store.automatic},set:{store.setAutomatic($0)})) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Adapter automatiquement les profils")
                        Text("Organise le Dock et les fenêtres ouvertes lorsque tu branches ou débranches un écran, ainsi qu’à l’ouverture de Spaces Dock.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }.toggleStyle(.switch)
                    .disabled(store.configurationUnavailable)
                    .accessibilityLabel("Adapter automatiquement les profils")
            } header: { Text("Écrans") } footer: {
                Text("Ce réglage est indépendant du lancement des apps à la connexion et n’ouvre pas les apps fermées.")
            }
            Section {
                HStack(spacing:12) {
                    Image(systemName:"accessibility").font(.title2).foregroundStyle(.secondary).frame(width:28)
                    VStack(alignment:.leading,spacing:4) {
                        Text("Accessibilité")
                        Text("Permet de créer les bureaux manquants et de déplacer les fenêtres. Après autorisation dans macOS, reviens dans Spaces Dock.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.accessible {
                        Label("Autorisée",systemImage:"checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Autoriser…") { store.requestAccessibility() }
                    }
                }
            } header: { Text("Autorisations") }
            Section {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Exporter les profils")
                        Text("Conserve une copie de ta configuration dans un fichier JSON.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Exporter…") { store.exportConfiguration() }
                }
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Importer des profils")
                        Text("Récupère une copie enregistrée. L’importation n’applique aucun profil et ne modifie pas tes réglages de démarrage.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer()
                    Button("Importer…") { store.importConfiguration() }
                }
                HStack {
                    Text("Fichier de configuration")
                    Spacer()
                    Button("Afficher dans le Finder") { store.showConfiguration() }
                }
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Organisation d’origine")
                        Text("Restaure le Dock et les affectations sauvegardés avant la première application.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer()
                    Button("Restaurer…") { restoreConfirmation = true }.disabled(!store.hasBackup)
                }
            } header: { Text("Configuration") }
            Section {
                HStack {
                    VStack(alignment:.leading,spacing:4) {
                        Text("Rapport de diagnostic")
                        Text("Exporte l’état de l’app et des écrans pour comprendre un problème. Tu peux lire le fichier avant de le partager.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer()
                    Button("Exporter…") { store.exportDiagnostics() }
                        .accessibilityLabel("Exporter le rapport de diagnostic")
                }
            } header: { Text("Assistance") }
            Section {
                LabeledContent("Spaces Dock",value:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
            .frame(maxWidth:800).frame(maxWidth:.infinity).disabled(store.busy)
    }
    private var footerMessage: String {
        if let error = store.error { return error }
        if store.busy { return store.status }
        if !store.topologyAvailable { return "Écrans indisponibles — vérifie la connexion, puis actualise." }
        if store.dirty { return "Modifications non enregistrées — réessaie ou exporte tes profils." }
        if !isSettings && store.pendingApplication { return "Modifications enregistrées — applique le profil pour les utiliser." }
        if isSettings && store.status == "Prêt à configurer" { return "Les réglages sont enregistrés automatiquement." }
        return store.status == "Prêt à configurer" ? "Profil enregistré. Applique-le quand tu es prêt." : store.status
    }
    var footer: some View {
        ViewThatFits(in:.horizontal) {
            HStack(spacing:12) {
                footerStatus
                footerActions.fixedSize().layoutPriority(1)
            }.frame(minWidth:720,minHeight:40)
            VStack(alignment:.leading,spacing:10) {
                footerStatus
                HStack { Spacer(minLength:0); footerActions.fixedSize() }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var footerStatus: some View {
        HStack(spacing:10) {
            if store.busy {
                ProgressView().controlSize(.small).accessibilityLabel("Application du profil en cours")
            } else if store.error != nil || store.reportHasFailures {
                Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            }
            VStack(alignment:.leading,spacing:3) {
                Text(footerMessage).font(.caption).lineLimit(2).help(footerMessage)
                    .accessibilityLabel(footerMessage)
                if !isSettings && store.topologyAvailable && store.selected != store.activeID {
                    Text("Connecte les écrans correspondants pour l’appliquer.").font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var footerActions: some View {
        HStack(spacing:10) {
            if store.error != nil || !store.report.isEmpty {
                Button("Voir le bilan…") { showReport = true }
                    .accessibilityLabel("Voir le bilan de la dernière opération")
            }
            if store.busy {
                Button("Annuler") { store.cancelOperation() }
                    .help("Interrompre la suite de l’opération. Les changements déjà effectués restent en place.")
            } else if store.dirty && !store.configurationUnavailable {
                Button("Réessayer l’enregistrement") { store.save() }
                    .buttonStyle(.borderedProminent)
            } else if !isSettings {
                Button { store.undoEdit() } label: { Image(systemName:"arrow.uturn.backward") }
                    .disabled(!store.canUndoEdit || store.configurationUnavailable)
                    .accessibilityLabel("Annuler la dernière modification des profils")
                    .help("Annuler la dernière modification · ⌘Z")
                Button(store.missingDesktopSummary.isEmpty ? "Appliquer ce profil" : "Préparer et appliquer") {
                    Task { await store.applySelected() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.topologyAvailable || store.selected != store.activeID || store.configurationUnavailable || orderedRules.isEmpty)
                .help("Organiser le Dock et les fenêtres. Les apps fermées ou sans fenêtre seront ouvertes.")
            }
        }
    }
    var reportSheet: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.firstTextBaseline) {
                Text(store.reportProfileName.map { "Bilan — \($0)" } ?? "Bilan de l’opération")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Terminé") { showReport = false }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text(store.status).font(.headline)
                    if let error = store.error {
                        Label(error,systemImage:"exclamationmark.triangle")
                            .fixedSize(horizontal:false,vertical:true)
                    }
                    if store.report.isEmpty && store.error == nil {
                        Text("Aucune opération à afficher.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(store.report.enumerated()),id:\.offset) { _, line in
                        Text(line).frame(maxWidth:.infinity,alignment:.leading)
                    }
                }.font(.callout).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            }
            Divider()
            HStack {
                Button("Exporter un diagnostic…") { store.exportDiagnostics() }.disabled(store.busy)
                Spacer()
                if store.busy {
                    ProgressView().controlSize(.small)
                    Button("Annuler l’opération") { store.cancelOperation() }
                }
            }
        }.padding(24).frame(width:600,height:440)
    }

}

private enum RowMetrics {
    static let height: CGFloat = 48
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 3
    static let contentHeight = height - verticalInset * 2
    static let assignmentWidth: CGFloat = 88
    static let reorderWidth: CGFloat = 22
}

private struct AssignmentPopover: View {
    @Binding var rule: AppRule
    let allowsExternal: Bool
    let displays: [LiveDisplay]
    @Environment(\.dismiss) private var dismiss
    @State private var screen: ScreenRole
    @State private var desktop: Int

    init(rule: Binding<AppRule>, allowsExternal: Bool, displays: [LiveDisplay]) {
        self._rule = rule; self.allowsExternal = allowsExternal; self.displays = displays
        self._screen = State(initialValue:rule.wrappedValue.screen)
        self._desktop = State(initialValue:rule.wrappedValue.desktop)
    }
    private var matchingDisplays: [LiveDisplay] { displays.filter { $0.spaces.role == screen } }
    private var desktopCount: Int? {
        matchingDisplays.count == 1 ? matchingDisplays[0].spaces.desktops.count : nil
    }
    private func desktopLabel(_ number: Int) -> String {
        guard let count = desktopCount else { return "Bureau \(number) · à vérifier à la connexion" }
        return "Bureau \(number) · " + (number <= count ? "existant" : "à créer")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(spacing:10) {
                Image(nsImage:NSWorkspace.shared.icon(forFile:rule.path)).resizable().frame(width:28,height:28)
                    .accessibilityHidden(true)
                Text(rule.name).font(.headline).lineLimit(2).help(rule.name)
            }
            VStack(alignment:.leading,spacing:8) {
                Text("Écran").font(.subheadline.weight(.medium))
                Picker("Écran de \(rule.name)",selection:$screen) {
                    Text("MacBook").tag(ScreenRole.builtIn)
                    if allowsExternal { Text("Écran externe").tag(ScreenRole.external) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment:.leading,spacing:8) {
                Picker("Bureau",selection:$desktop) {
                    ForEach(1...16,id:\.self) { number in Text(desktopLabel(number)).tag(number) }
                }.pickerStyle(.menu)
                    .accessibilityLabel("Bureau de \(rule.name)")
                if desktopCount == nil {
                    Label("Connecte cet écran pour vérifier ses bureaux.",systemImage:"display.trianglebadge.exclamationmark")
                        .font(.caption).foregroundStyle(.secondary)
                } else if desktop > (desktopCount ?? 0) {
                    Text("Les bureaux manquants seront créés lorsque tu appliqueras le profil.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("L’affectation prendra effet lorsque tu appliqueras le profil.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Affecter") {
                    var updated = rule; updated.screen = screen; updated.desktop = desktop
                    rule = updated
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width:360)
    }
}

private struct DesktopSection: Identifiable {
    let rules:[AppRule]
    var id:String { "\(rules[0].screen.rawValue)-\(rules[0].desktop)" }
}
private struct NativeRowDrag:NSViewRepresentable {
    let rule:AppRule
    let rowWidth:CGFloat
    let enabled:Bool
    let started:()->Void
    let ended:()->Void
    let accepts:(String)->Bool
    let hovered:(Bool)->Void
    let dropped:(String)->Bool
    let moveUp:()->Void
    let moveDown:()->Void
    func makeNSView(context:Context)->RowDragView { RowDragView() }
    func updateNSView(_ view:RowDragView,context:Context) {
        view.rule = rule; view.rowWidth = rowWidth; view.enabled = enabled
        view.started = started; view.ended = ended; view.accepts = accepts; view.hovered = hovered; view.dropped = dropped
        view.moveUp = moveUp; view.moveDown = moveDown
        view.toolTip = rule.name
        view.needsDisplay = true
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel("\(rule.name), \(rule.screen == .builtIn ? "MacBook" : "écran externe"), bureau \(rule.desktop)")
        view.setAccessibilityHelp("Faire glisser dans ce bureau, ou utiliser Option et les flèches haut et bas pour déplacer d’une place.")
    }
}
private final class RowDragView:NSView {
    var rule:AppRule?
    var enabled = true
    var rowWidth:CGFloat = 600
    var accepts:((String)->Bool)?
    var hovered:((Bool)->Void)?
    var dropped:((String)->Bool)?
    var moveUp:(()->Void)?
    var moveDown:(()->Void)?
    var sessionActive = false
    private var previewPanel:NSPanel?
    private weak var highlighted:RowDragView?
    private var initialPointer = NSPoint.zero
    private var initialFrame = NSRect.zero
    private var escapeMonitor:Any?
    private var resignObserver:NSObjectProtocol?
    private var scrollTimer:Timer?
    private var latestDragEvent:NSEvent?
    override var acceptsFirstResponder:Bool { enabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event:NSEvent) {
        if enabled && event.modifierFlags.contains(.option) {
            if event.keyCode == 126 { moveUp?(); return }
            if event.keyCode == 125 { moveDown?(); return }
        }
        super.keyDown(with:event)
    }
    var started:(()->Void)?
    var ended:(()->Void)?
    var down:NSEvent?
    var hovering = false
    override var isFlipped:Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event:NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovering = false; needsDisplay = true }
    override func resetCursorRects() { if enabled { addCursorRect(bounds,cursor:.openHand) } }
    override func draw(_ dirtyRect:NSRect) {
        guard let rule else { return }
        NSWorkspace.shared.icon(forFile:rule.path).draw(in:NSRect(x:22,y:(bounds.height-28)/2,width:28,height:28),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        drawName(rule.name,in:NSRect(x:62,y:(bounds.height-17)/2,width:max(0,bounds.width-62),height:17))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:4,yRadius:4)
            focus.lineWidth = 2; focus.stroke()
        }
        if hovering && enabled { NSImage(systemSymbolName:"line.3.horizontal",accessibilityDescription:nil)?.draw(in:NSRect(x:0,y:(bounds.height-12)/2,width:12,height:12),from:.zero,operation:.sourceOver,fraction:0.45,respectFlipped:true,hints:nil) }
    }
    private func drawName(_ name:String,in rect:NSRect) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (name as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
    }
    override func mouseDown(with event:NSEvent) { down = event; window?.makeFirstResponder(self) }
    override func mouseUp(with event:NSEvent) {
        if sessionActive { updatePosition(event); finish(commit:true) }
        down = nil
    }
    override func cancelOperation(_ sender:Any?) { finish(commit:false) }
    override func viewWillMove(toWindow newWindow:NSWindow?) {
        if newWindow == nil { finish(commit:false) }
        super.viewWillMove(toWindow:newWindow)
    }
    override func mouseDragged(with event:NSEvent) {
        if sessionActive { updatePosition(event); return }
        guard enabled, let rule, let down, let window,
              hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4 else { return }
        initialPointer = window.convertPoint(toScreen:down.locationInWindow)
        initialFrame = window.convertToScreen(convert(NSRect(x:-RowMetrics.horizontalInset,y:-RowMetrics.verticalInset,width:rowWidth,height:RowMetrics.height),to:nil))
        self.down = nil
        // One fixed-size AppKit image, in points, for the entire session.
        // No detached NSHostingView and no destination-generated text thumbnail.
        let size = NSSize(width:rowWidth,height:RowMetrics.height)
        let icon = NSWorkspace.shared.icon(forFile:rule.path)
        let image = NSImage(size:size,flipped:true) { rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8).stroke()
            icon.draw(in:NSRect(x:36,y:(size.height-28)/2,width:28,height:28),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            self.drawName(rule.name,in:NSRect(x:76,y:(size.height-17)/2,width:max(0,size.width-272),height:17))
            ("Bureau \(rule.desktop)" as NSString).draw(at:NSPoint(x:size.width-181,y:(size.height-17)/2),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor])
            for (symbol, x, width) in [("chevron.down",size.width-111,CGFloat(9)),("chevron.up",size.width-86,CGFloat(12)),("chevron.down",size.width-64,CGFloat(12)),("ellipsis",size.width-37,CGFloat(16))] {
                NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.draw(in:NSRect(x:x,y:(size.height-width)/2,width:width,height:width),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            }
            return true
        }
        // An in-app overlay preserves the exact logical dimensions. It never
        // enters the system pasteboard drag pipeline that can substitute a thumbnail.
        let panel = NSPanel(contentRect:initialFrame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true
        let imageView = NSImageView(frame:NSRect(origin:.zero,size:size))
        imageView.image = image; imageView.imageScaling = .scaleNone
        panel.contentView = imageView
        previewPanel = panel; sessionActive = true
        window.addChildWindow(panel,ordered:.above)
        panel.orderFrontRegardless()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(commit:false); return nil }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.finish(commit:false) }
        started?()
        updatePosition(event)
        let timer = Timer(timeInterval:1.0/60.0,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollAtEdge() }
        }
        scrollTimer = timer
        RunLoop.main.add(timer,forMode:.common)
    }
    private func scrollAtEdge() {
        guard sessionActive, let event = latestDragEvent,
              let scroll = enclosingScrollView, let document = scroll.documentView else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        let pointer = clip.convert(event.locationInWindow,from:nil)
        let edge:CGFloat = 30
        guard pointer.x >= visible.minX, pointer.x <= visible.maxX,
              pointer.y >= visible.minY-edge, pointer.y <= visible.maxY+edge else { return }
        var delta:CGFloat = 0
        if pointer.y < visible.minY+edge {
            delta = -min(12,max(2,(visible.minY+edge-pointer.y)/edge*12))
        } else if pointer.y > visible.maxY-edge {
            delta = min(12,max(2,(pointer.y-visible.maxY+edge)/edge*12))
        }
        guard delta != 0 else { return }
        let low = document.bounds.minY
        let high = max(low,document.bounds.maxY-visible.height)
        let next = min(high,max(low,visible.minY+delta))
        guard abs(next-visible.minY) > 0.1 else { return }
        clip.scroll(to:NSPoint(x:visible.minX,y:next))
        scroll.reflectScrolledClipView(clip)
        // The preview remains fixed to the pointer; only native document bounds
        // scroll. Recompute the target under a stationary pointer after each tick.
        updatePosition(event)
    }
    private func updatePosition(_ event:NSEvent) {
        guard sessionActive, let window, let id = rule?.id else { return }
        latestDragEvent = event
        let pointer = window.convertPoint(toScreen:event.locationInWindow)
        previewPanel?.setFrameOrigin(NSPoint(x:initialFrame.minX+pointer.x-initialPointer.x,y:initialFrame.minY+pointer.y-initialPointer.y))
        func find(in view:NSView)->RowDragView? {
            if let candidate = view as? RowDragView, candidate !== self, candidate.accepts?(id) == true {
                let point = candidate.convert(event.locationInWindow,from:nil)
                // Whole-row target, including the neutral area beside the controls.
                let fullRow = NSRect(x:-RowMetrics.horizontalInset,y:-RowMetrics.verticalInset,width:candidate.rowWidth,height:RowMetrics.height)
                if fullRow.contains(point), candidate.visibleRect.intersects(candidate.bounds) { return candidate }
            }
            for child in view.subviews { if let found = find(in:child) { return found } }
            return nil
        }
        let target = window.contentView.flatMap { find(in:$0) }
        if target !== highlighted {
            highlighted?.hovered?(false); highlighted = target; target?.hovered?(true)
        }
    }
    private func finish(commit:Bool) {
        guard sessionActive else { down = nil; return }
        sessionActive = false
        scrollTimer?.invalidate(); scrollTimer = nil; latestDragEvent = nil
        let target = highlighted
        highlighted?.hovered?(false); highlighted = nil
        if let panel = previewPanel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil); panel.close() }
        previewPanel = nil
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor); escapeMonitor = nil }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer); resignObserver = nil }
        if commit, let id = rule?.id, target?.accepts?(id) == true { _ = target?.dropped?(id) }
        ended?()
    }
}
