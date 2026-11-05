import Foundation
var failures = 0
var checks = 0
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: String = #file, line: Int = #line) { checks += 1; if a != b { print("FAIL \(line): \(a) != \(b)"); failures += 1 } }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, line: Int = #line) { checks += 1; do { _ = try value(); print("FAIL \(line): expected rejection"); failures += 1 } catch {} }
import Foundation
import SpacesCore

final class ModelTests {
    let a = AppRule(id: "notion.id", name: "Notion", path: "/Applications/Notion.app")
    func testMissingDesktopDoesNotPartiallyApply() {
        var b = a; b.id = "terminal"; b.desktop = 2
        XCTAssertThrowsError(try resolve(profile: .init(id: "solo", name: "Solo", rules: [a,b]), displays: [.init(role: .builtIn, desktops: [.init(id: 5, uuid: "first")])]))
    }
    func testMissingExternalDisplayIsAnError() {
        var b = a; b.screen = .external
        XCTAssertThrowsError(try resolve(profile: .init(id: "dual", name: "Dual", rules: [b]), displays: [.init(role: .builtIn, desktops: [.init(id: 5, uuid: "first")])]))
    }
    func testDesktopUsesVisualPositionNotManagedID() throws {
        var b = a; b.desktop = 2
        let result = try resolve(profile: .init(id: "solo", name: "Solo", rules: [b]), displays: [.init(role: .builtIn, desktops: [.init(id: 55, uuid: "first"), .init(id: 3, uuid: "second")])])
        XCTAssertEqual(result.first?.target.uuid, "second")
    }
    func testDuplicateApplicationRejected() {
        XCTAssertThrowsError(try resolve(profile: .init(id: "solo", name: "Solo", rules: [a,a]), displays: [.init(role: .builtIn, desktops: [.init(id: 5, uuid: "first")])]))
    }
    func testDockPreservesUnmanagedTilesAndOrdersGroups() {
        var b = a; b.id = "terminal"; b.name = "Terminal"; b.path = "/System/Applications/Utilities/Terminal.app"; b.desktop = 2
        let unknown: [String: Any] = ["tile-type": "file-tile", "tile-data": ["bundle-identifier": "other", "file-label": "Keep"]]
        let oldA: [String: Any] = ["tile-type": "file-tile", "tile-data": ["bundle-identifier": a.id, "file-label": a.name]]
        let output = dockItems(rules: [b,a], existing: [unknown, oldA])
        XCTAssertEqual(output.count, 5) // A, gap, B, gap, preserved app
        XCTAssertEqual((output.first?["tile-data"] as? [String: Any])?["bundle-identifier"] as? String, a.id)
        XCTAssertEqual((output.last?["tile-data"] as? [String: Any])?["file-label"] as? String, "Keep")
        XCTAssertEqual(output.filter { $0["tile-type"] as? String == "spacer-tile" }.count, 2)
    }
    func testEmptyRulesLeaveDockUntouched() {
        let item: [String: Any] = ["tile-type":"spacer-tile"]
        XCTAssertEqual(dockItems(rules: [], existing: [item]).count, 1)
    }
    func testDockReapplyDoesNotAccumulateSpacers() {
        let first = dockItems(rules: [a], existing: [])
        XCTAssertEqual(dockItems(rules: [a], existing: first).count, first.count)
    }
    func testProfileRoundTripPreservesLaunchChoice() throws {
        var b = a; b.launch = true; b.screen = .external
        let profile = LayoutProfile(id: "dual", name: "Double écran", rules: [b])
        XCTAssertEqual(try JSONDecoder().decode(LayoutProfile.self, from: JSONEncoder().encode(profile)), profile)
    }
}

let tests = ModelTests()
tests.testMissingDesktopDoesNotPartiallyApply()
tests.testMissingExternalDisplayIsAnError()
try tests.testDesktopUsesVisualPositionNotManagedID()
tests.testDuplicateApplicationRejected()
tests.testDockPreservesUnmanagedTilesAndOrdersGroups()
tests.testEmptyRulesLeaveDockUntouched()
tests.testDockReapplyDoesNotAccumulateSpacers()
try tests.testProfileRoundTripPreservesLaunchChoice()
// Transaction failures must roll back, including failures saving ownership.
var state = 1
XCTAssertThrowsError(try applyTransaction(prepare:{ 2 }, snapshot:{ state }, mutate:{ state = $0 }, persist:{ _ in throw LayoutError.invalid("disk full") }, restore:{ state = $0 }))
XCTAssertEqual(state, 1)
var writes = 0
XCTAssertThrowsError(try applyTransaction(prepare:{ () throws -> Int in throw LayoutError.invalid("inventory unavailable") }, snapshot:{ 1 }, mutate:{ _ in writes += 1 }, persist:{ _ in }, restore:{ _ in writes += 1 }))
XCTAssertEqual(writes, 0)
var gate = OperationGeneration()
let token = gate.value
gate.invalidate()
XCTAssertEqual(gate.accepts(token), false)
var moves = MoveReport(); moves.failed = 1
XCTAssertEqual(moves.hasFailures, true)
// macOS normalizes spacer tiles and removes custom metadata.
var rule2 = tests.a; rule2.id = "terminal"; rule2.name = "Terminal"; rule2.desktop = 2; rule2.path = "/Applications/Terminal.app"
let initialDock = dockItems(rules:[tests.a,rule2],existing:[])
let normalizedDock = initialDock.map { tile -> [String:Any] in
    if tile["tile-type"] as? String == "spacer-tile" { return ["tile-type":"spacer-tile","tile-data":["file-label":""]] }
    return tile
}
let rebuilt = dockItems(rules:[tests.a,rule2],existing:normalizedDock)
XCTAssertEqual(rebuilt.count,initialDock.count)
let gap:[String:Any] = ["tile-type":"spacer-tile","tile-data":["file-label":""]]
let accumulated = normalizedDock + Array(repeating:gap,count:9)
XCTAssertEqual(dockItems(rules:[tests.a,rule2],existing:accumulated).count,initialDock.count)
var claude = tests.a; claude.id = "claude"; claude.desktop = 4
var claw = claude; claw.id = "claw"
var chat = claude; chat.id = "chat"
let arrangement = [tests.a, claude, rule2, claw, chat]
let reordered = moveWithinDesktop(arrangement,sourceID:"chat",targetID:"claude")
XCTAssertEqual(reordered.map(\.id),[tests.a.id,"chat",rule2.id,"claude","claw"])
XCTAssertEqual(moveWithinDesktop(reordered,sourceID:"chat",targetID:"claw"),arrangement)
XCTAssertEqual(moveWithinDesktop(arrangement,sourceID:"chat",targetID:tests.a.id),arrangement)
var externalChat = chat; externalChat.screen = .external
XCTAssertEqual(moveWithinDesktop([claude,externalChat],sourceID:"chat",targetID:"claude"),[claude,externalChat])
let roundTrip = try JSONDecoder().decode([AppRule].self,from:JSONEncoder().encode(reordered))
XCTAssertEqual(groupedRules(roundTrip).last?.map(\.id),["chat","claude","claw"])
// Opening the utility manually must never launch the selected apps.
XCTAssertEqual(shouldLaunchAtLogin(enabled:true, loginEnabled:true, launchedAtLogin:false), false)
XCTAssertEqual(shouldLaunchAtLogin(enabled:true, loginEnabled:true, launchedAtLogin:true), true)
XCTAssertEqual(shouldLaunchAtLogin(enabled:false, loginEnabled:true, launchedAtLogin:true), false)
XCTAssertEqual(shouldLaunchAtLogin(enabled:true, loginEnabled:false, launchedAtLogin:true), false)
// Global launch includes every app, regardless of former per-app choices.
var unchecked = tests.a; unchecked.launch = false
var checked = rule2; checked.launch = true
let loginProfile = LayoutProfile(id:"solo",name:"Solo",rules:[unchecked,checked])
XCTAssertEqual(appsToLaunch(profile:loginProfile,runningIDs:[]).map(\.id),[unchecked.id,checked.id])
XCTAssertEqual(appsToLaunch(profile:loginProfile,runningIDs:[unchecked.id]).map(\.id),[checked.id])
XCTAssertEqual(appsToLaunch(profile:loginProfile,runningIDs:[unchecked.id,checked.id]).count,0)
// Missing desktops are prepared before resolving, without deleting existing ones.
let builtIn = DisplaySpaces(role:.builtIn,desktops:(1...5).map { Desktop(id:UInt64($0),uuid:"mac-\($0)") })
let external = DisplaySpaces(role:.external,desktops:[Desktop(id:20,uuid:"lg-1")])
var extRule = tests.a; extRule.id = "chat"; extRule.screen = .external; extRule.desktop = 3
let preparationProfile = LayoutProfile(id:"dual",name:"Dual",rules:[tests.a,extRule])
let requirements = try desktopRequirements(profile:preparationProfile,displays:[builtIn,external])
XCTAssertEqual(requirements.map(\.required),[1,3])
XCTAssertEqual(requirements.map(\.missing),[0,2])
XCTAssertEqual(try desktopRequirements(profile:.init(id:"solo",name:"Empty"),displays:[builtIn]).count,0)
var invalidRule = extRule; invalidRule.desktop = 17
XCTAssertThrowsError(try desktopRequirements(profile:.init(id:"dual",name:"Bad",rules:[invalidRule]),displays:[builtIn,external]))
invalidRule.desktop = 0
XCTAssertThrowsError(try desktopRequirements(profile:.init(id:"dual",name:"Bad",rules:[invalidRule]),displays:[builtIn,external]))
XCTAssertThrowsError(try desktopRequirements(profile:preparationProfile,displays:[builtIn]))
XCTAssertThrowsError(try desktopRequirements(profile:preparationProfile,displays:[builtIn,external,external]))
XCTAssertThrowsError(try desktopRequirements(profile:.init(id:"dual",name:"Duplicate",rules:[extRule,extRule]),displays:[builtIn,external]))
var fixtureDisplays = [builtIn,external]
var createdRoles: [ScreenRole] = []
var creationEvents: [Int] = []
try await prepareDesktops(profile:preparationProfile,readDisplays:{fixtureDisplays},addDesktop:{role in
    createdRoles.append(role)
    let index = fixtureDisplays.firstIndex(where:{$0.role == role})!
    let old = fixtureDisplays[index]
    fixtureDisplays[index] = DisplaySpaces(role:role,desktops:old.desktops + [Desktop(id:UInt64(20+old.desktops.count),uuid:"lg-\(old.desktops.count+1)")])
},isCurrent:{true},didCreate:{_,number in creationEvents.append(number)})
XCTAssertEqual(createdRoles,[.external,.external])
XCTAssertEqual(creationEvents,[2,3])
XCTAssertEqual(fixtureDisplays[0].desktops,builtIn.desktops)
XCTAssertEqual(fixtureDisplays[1].desktops.map(\.id),[20,21,22])
try await prepareDesktops(profile:preparationProfile,readDisplays:{fixtureDisplays},addDesktop:{_ in failures += 1},isCurrent:{true},didCreate:{_,_ in failures += 1})
XCTAssertEqual(try resolve(profile:preparationProfile,displays:fixtureDisplays).last?.target.id,22)
// A press with no confirmed creation fails immediately, never blindly repeats.
var presses = 0
checks += 1
do {
    try await prepareDesktops(profile:preparationProfile,readDisplays:{[builtIn,external]},addDesktop:{_ in presses += 1},isCurrent:{true},didCreate:{_,_ in failures += 1})
    failures += 1
} catch {}
XCTAssertEqual(presses,1)
// A cancellation after one confirmed creation stops further work but reports it.
fixtureDisplays = [builtIn,external]; var current = true; creationEvents = []; presses = 0
checks += 1
do {
    try await prepareDesktops(profile:preparationProfile,readDisplays:{fixtureDisplays},addDesktop:{_ in
        presses += 1
        fixtureDisplays[1] = DisplaySpaces(role:.external,desktops:external.desktops + [Desktop(id:21,uuid:"lg-2")])
    },isCurrent:{current},didCreate:{_,n in creationEvents.append(n); current = false})
    failures += 1
} catch {}
XCTAssertEqual(presses,1)
XCTAssertEqual(creationEvents,[2])
// Disconnection or malformed rules are validated across all screens before any press.
checks += 1; presses = 0
do {
    try await prepareDesktops(profile:preparationProfile,readDisplays:{[builtIn]},addDesktop:{_ in presses += 1},isCurrent:{true},didCreate:{_,_ in})
    failures += 1
} catch {}
XCTAssertEqual(presses,0)
checks += 1
do {
    try await prepareDesktops(profile:preparationProfile,readDisplays:{[builtIn,external]},addDesktop:{_ in throw LayoutError.invalid("AX failed")},isCurrent:{true},didCreate:{_,_ in failures += 1})
    failures += 1
} catch {}
// An accepted native press followed by cancellation has an uncertain outcome,
// distinct from a cancellation that happened before any request was sent.
checks += 1
do {
    try await waitForDesktopCreation(previousIDs:[20],readIDs:{[20,21]},wait:{throw CancellationError()},isCurrent:{true})
    failures += 1
} catch is DesktopCreationInterrupted {} catch { failures += 1 }
checks += 1
do {
    try await waitForDesktopCreation(previousIDs:[20],readIDs:{[20,21]},wait:{},isCurrent:{false})
    failures += 1
} catch is DesktopCreationInterrupted {} catch { failures += 1 }
try await waitForDesktopCreation(previousIDs:[20],readIDs:{[20,21]},wait:{},isCurrent:{true})
checks += 1
var pollingAttempts = 0
checks += 1
do {
    try await waitForDesktopCreation(previousIDs:[20],readIDs:{[20]},wait:{pollingAttempts += 1},isCurrent:{true})
    failures += 1
} catch {}
XCTAssertEqual(pollingAttempts,50)
checks += 1
do {
    try await waitForDesktopCreation(previousIDs:[20],readIDs:{[99,100]},wait:{},isCurrent:{true})
    failures += 1
} catch is DesktopCreationInterrupted {} catch { failures += 1 }
// Explicit Apply must open apps even when login/display automation is off.
XCTAssertEqual(ProfileApplyReason.manual.isAllowed(automatic:false,launchAtLogin:false,loginService:false),true)
XCTAssertEqual(ProfileApplyReason.login.isAllowed(automatic:false,launchAtLogin:true,loginService:true),true)
XCTAssertEqual(ProfileApplyReason.login.isAllowed(automatic:true,launchAtLogin:false,loginService:true),false)
XCTAssertEqual(ProfileApplyReason.login.isAllowed(automatic:true,launchAtLogin:true,loginService:false),false)
XCTAssertEqual(ProfileApplyReason.automatic.isAllowed(automatic:false,launchAtLogin:true,loginService:true),false)
XCTAssertEqual(ProfileApplyReason.automatic.isAllowed(automatic:true,launchAtLogin:false,loginService:false),true)
// Closing an app (not running) and closing its last window (still running)
// both need an open/reopen request on Apply. Existing windows must stay unique.
let openingProfile = LayoutProfile(id:"solo",name:"Manual",rules:[unchecked,checked])
XCTAssertEqual(appsToOpen(profile:openingProfile,reason:.manual,runningIDs:[unchecked.id],windowedIDs:[]).map(\.id),[unchecked.id,checked.id])
XCTAssertEqual(appsToOpen(profile:openingProfile,reason:.manual,runningIDs:[unchecked.id],windowedIDs:[unchecked.id]).map(\.id),[checked.id])
XCTAssertEqual(appsToOpen(profile:openingProfile,reason:.manual,runningIDs:[unchecked.id,checked.id],windowedIDs:[unchecked.id,checked.id]).count,0)
XCTAssertEqual(appsToOpen(profile:openingProfile,reason:.login,runningIDs:[unchecked.id],windowedIDs:[]).map(\.id),[checked.id])
XCTAssertEqual(appsToOpen(profile:openingProfile,reason:.automatic,runningIDs:[],windowedIDs:[]).count,0)
// Configuration must reject dangerous/malformed imported profiles before writes.
let validConfig = Configuration(profiles:[.init(id:"solo",name:"MacBook",rules:[tests.a]),.init(id:"dual",name:"Deux écrans")])
XCTAssertEqual(try validConfig.validated(),validConfig)
var malformed = validConfig
malformed.profiles[0].rules.append(tests.a)
XCTAssertThrowsError(try malformed.validated())
malformed = validConfig; malformed.profiles[0].rules[0].desktop = 17
XCTAssertThrowsError(try malformed.validated())
malformed = validConfig; malformed.profiles[0].rules[0].path = "/bin/sh"
XCTAssertThrowsError(try malformed.validated())
malformed = validConfig; malformed.profiles[0].rules[0].id = "bad|drag-token"
XCTAssertThrowsError(try malformed.validated())
malformed = validConfig; malformed.profiles[0].rules[0].screen = .external
XCTAssertThrowsError(try malformed.validated())
malformed = validConfig; malformed.profiles[0].name = ""
XCTAssertThrowsError(try malformed.validated())
malformed = validConfig; malformed.profiles[0].rules = (0..<129).map { i in AppRule(id:"id.\(i)",name:"App",path:"/Applications/App.app") }
XCTAssertThrowsError(try malformed.validated())
// A bad edit, failed replacement or recovery must preserve the user's prior bytes.
let configFolder = FileManager.default.temporaryDirectory.appendingPathComponent("SpacesDock-config-check-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at:configFolder) }
let configurationFile = ConfigurationFile(url:configFolder.appendingPathComponent("configuration.json"))
try configurationFile.save(validConfig)
let beforeBytes = try Data(contentsOf:configurationFile.url)
var invalidWrite = validConfig; invalidWrite.profiles[0].rules[0].desktop = 0
XCTAssertThrowsError(try configurationFile.save(invalidWrite))
XCTAssertEqual(try Data(contentsOf:configurationFile.url),beforeBytes)
try configurationFile.save(validConfig)
var updatedConfig = validConfig; updatedConfig.profiles[0].rules[0].desktop = 2
try configurationFile.save(updatedConfig)
XCTAssertEqual(try? ConfigurationFile(url:configurationFile.previousURL).load(),validConfig)
let corruptBytes = Data("damaged-json".utf8)
try corruptBytes.write(to:configurationFile.url)
XCTAssertThrowsError(try configurationFile.save(validConfig))
XCTAssertEqual(try Data(contentsOf:configurationFile.url),corruptBytes)
try corruptBytes.write(to:configurationFile.url)
try configurationFile.save(validConfig,recovering:true)
XCTAssertEqual(try configurationFile.load(),validConfig)
let recoveredFiles = try FileManager.default.contentsOfDirectory(at:configFolder,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("configuration-recovered-") }
XCTAssertEqual(recoveredFiles.count,1)
XCTAssertEqual(recoveredFiles.first.flatMap { try? Data(contentsOf:$0) },corruptBytes)
XCTAssertThrowsError(try ConfigurationFile.decode(Data(repeating:32,count:2_097_153)))
// Callback completion must be one-shot even when LaunchServices replies late.
let callback = CallbackOperation<Int>()
let callbackValue = try await callback.run(timeout:.seconds(1)) { complete in complete(.success(7)); complete(.success(8)) }
XCTAssertEqual(callbackValue,7)
let cancelledCallback = CallbackOperation<Int>()
cancelledCallback.cancel()
checks += 1
do {
    _ = try await cancelledCallback.run(timeout:.milliseconds(5)) { complete in complete(.success(9)) }
    failures += 1
} catch is CancellationError {} catch { failures += 1 }
let silentCallback = CallbackOperation<Int>()
checks += 1
do {
    _ = try await silentCallback.run(timeout:.milliseconds(5)) { _ in }
    failures += 1
} catch is LayoutError {} catch { failures += 1 }
let interruptedCallback = CallbackOperation<Int>()
checks += 1
do {
    _ = try await interruptedCallback.run(timeout:.seconds(1)) { completion in
        interruptedCallback.cancel()
        completion(.success(10))
    }
    failures += 1
} catch is CancellationError {} catch { failures += 1 }
// Restore preparation must compensate login registration if disabled settings cannot be saved.
var loginRegistered = true
try corruptBytes.write(to:configurationFile.url)
XCTAssertThrowsError(try applyTransaction(prepare:{ validConfig },snapshot:{ loginRegistered },mutate:{ _ in loginRegistered = false },persist:{ try configurationFile.save($0) },restore:{ loginRegistered = $0 }))
XCTAssertEqual(loginRegistered,true)
XCTAssertEqual(try Data(contentsOf:configurationFile.url),corruptBytes)
// The original macOS desktop may have an explicitly empty UUID. Missing keys
// are different: never synthesize an identity or silently discard a desktop.
let originalDesktop: [String: Any] = ["ManagedSpaceID": 1, "id64": 1, "type": 0, "uuid": ""]
let otherDesktop: [String: Any] = ["ManagedSpaceID": 8, "id64": 8, "type": 0, "uuid": "A2F438A5-0090-4FF8-82CE-32A781272BA6"]
let fullScreen: [String: Any] = ["ManagedSpaceID": 12, "id64": 12, "type": 4, "uuid": "fullscreen"]
let parsedOriginal = try? readDesktops([originalDesktop], displayName: "Test")
XCTAssertEqual(parsedOriginal, [Desktop(id: 1, uuid: "")])
let parsedReordered = try? readDesktops([otherDesktop, fullScreen, originalDesktop], displayName: "Test")
XCTAssertEqual(parsedReordered, [Desktop(id: 8, uuid: "A2F438A5-0090-4FF8-82CE-32A781272BA6"), Desktop(id: 1, uuid: "")])
let parsedExternal = try readDesktops([otherDesktop], displayName: "External")
XCTAssertEqual(parsedExternal.map(\.id), [8])
XCTAssertThrowsError(try readDesktops([["ManagedSpaceID": 1, "type": 0]], displayName: "Test"))
XCTAssertThrowsError(try readDesktops([["ManagedSpaceID": 1, "type": 0, "uuid": 3]], displayName: "Test"))
XCTAssertThrowsError(try readDesktops([["type": 0, "uuid": ""]], displayName: "Test"))
XCTAssertThrowsError(try readDesktops([["ManagedSpaceID": 0, "type": 0, "uuid": ""]], displayName: "Test"))
XCTAssertThrowsError(try readDesktops([["ManagedSpaceID": 1, "uuid": ""]], displayName: "Test"))
XCTAssertThrowsError(try readDesktops([fullScreen], displayName: "Test"))
XCTAssertThrowsError(try readDesktops([otherDesktop, otherDesktop], displayName: "Test"))
XCTAssertThrowsError(try readDesktops([originalDesktop, ["ManagedSpaceID": 3, "type": 0, "uuid": ""]], displayName: "Test"))
// Check cross-screen ambiguity too; empty is one real binding, never a wildcard.
XCTAssertThrowsError(try validateDesktopIdentities([Desktop(id: 1, uuid: ""), Desktop(id: 3, uuid: "")]))
XCTAssertThrowsError(try validateDesktopIdentities([Desktop(id: 8, uuid: "first"), Desktop(id: 8, uuid: "second")]))
checks += 1
do {
    let internalSpaces = try readDesktops([originalDesktop], displayName: "Test")
    try validateDesktopIdentities(internalSpaces + parsedExternal)
    let app = AppRule(id: "test.app", name: "Test", path: "/Applications/Test.app")
    let targets = try resolve(profile: .init(id: "dual", name: "Test", rules: [app]), displays: [
        .init(role: .builtIn, desktops: internalSpaces), .init(role: .external, desktops: parsedExternal)
    ])
    let bindings = desktopAppBindings(targets, previousIDs: ["old.app", "removed.app"],
        current: ["test.app": "previous", "keep.app": "AllSpaces", "old.app": "old", "removed.app": "old"],
        baseline: ["old.app": ""])
    // A present empty string pins to the original desktop; removing the key unpins.
    XCTAssertEqual(bindings, ["test.app": "", "keep.app": "AllSpaces", "old.app": ""])
    XCTAssertEqual(targets.first?.target.id, 1)
    let data = try PropertyListSerialization.data(fromPropertyList: bindings, format: .binary, options: 0)
    XCTAssertEqual(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String], bindings)
} catch { failures += 1; print("FAIL original desktop through resolution and Dock bindings: \(error)") }
print("\(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
