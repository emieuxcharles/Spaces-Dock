import Foundation
import CoreGraphics

var failures = 0
var checks = 0
func check(_ passes: Bool, _ message: String) {
    checks += 1
    if !passes { print("FAIL: \(message)"); failures += 1 }
}
let builtIn = RuntimeDisplayDescriptor(identifier: "internal", builtIn: true, mirrored: false)
let external = RuntimeDisplayDescriptor(identifier: "external", builtIn: false, mirrored: false)
let second = RuntimeDisplayDescriptor(identifier: "second", builtIn: false, mirrored: false)
check(runtimeTopologyIssue([builtIn], separateSpaces: false) == nil, "one built-in works without separate Spaces")
check(runtimeTopologyIssue([builtIn, external], separateSpaces: true) == nil, "built-in plus one external supported")
check(runtimeTopologyIssue([], separateSpaces: true) != nil, "headless inventory rejected")
check(runtimeTopologyIssue([external], separateSpaces: true) != nil, "closed-lid/external-only rejected")
check(runtimeTopologyIssue([builtIn, external, second], separateSpaces: true) != nil, "third display rejected before role resolution")
check(runtimeTopologyIssue([builtIn, external], separateSpaces: false) != nil, "shared Spaces on two displays rejected")
check(runtimeTopologyIssue([.init(identifier: "internal", builtIn: true, mirrored: true)], separateSpaces: true) != nil, "mirrored displays rejected")
check(runtimeTopologyIssue([builtIn, builtIn], separateSpaces: true) != nil, "ambiguous built-in and UUID rejected")
check(runtimeTopologyIssue([.init(identifier: "", builtIn: true, mirrored: false)], separateSpaces: true) != nil, "missing display identity rejected")
check(runtimeTargetIsCurrent(7, desktopNumber: 2, desktops: [5, 7]), "resolved target still occupies requested desktop number")
check(!runtimeTargetIsCurrent(7, desktopNumber: 2, desktops: [7, 5]), "reordered desktops invalidate a previously resolved target")
check(!runtimeTargetIsCurrent(7, desktopNumber: 2, desktops: [5]), "deleted desktop invalidates target")
check(!runtimeTargetIsCurrent(7, desktopNumber: 0, desktops: [5, 7]), "invalid desktop index rejected")

var permission = false
var mutations = 0
var rejected = false
do { try performAuthorizedRuntimeMutation(isTrusted: { permission }) { mutations += 1 } }
catch RuntimeSafetyFailure.accessibilityRequired { rejected = true }
check(rejected && mutations == 0, "missing Accessibility permission prevents the mutation callback")
permission = true
try performAuthorizedRuntimeMutation(isTrusted: { permission }) { mutations += 1 }
permission = false
rejected = false
do { try performAuthorizedRuntimeMutation(isTrusted: { permission }) { mutations += 1 } }
catch RuntimeSafetyFailure.accessibilityRequired { rejected = true }
check(rejected && mutations == 1, "permission is rechecked at each mutation boundary after withdrawal")

let target = CGRect(x: 1440, y: -900, width: 1920, height: 1080)
let placed = CGRect(x: 1600, y: -800, width: 900, height: 700)
let wrongDisplay = CGRect(x: 50, y: 80, width: 900, height: 700)
check(windowPlacementIsVerified(spaceIDs: [77], targetSpace: 77, frame: placed, targetDisplay: target), "space and display verified with negative vertical coordinates")
check(!windowPlacementIsVerified(spaceIDs: [77], targetSpace: 77, frame: wrongDisplay, targetDisplay: target), "accepted AX request cannot hide wrong physical display")
check(!windowPlacementIsVerified(spaceIDs: [76], targetSpace: 77, frame: placed, targetDisplay: target), "right physical display cannot hide wrong Space")
check(!windowPlacementIsVerified(spaceIDs: [77], targetSpace: 77, frame: nil, targetDisplay: target), "missing frame is unverified")
check(!windowPlacementIsVerified(spaceIDs: [77], targetSpace: 77, frame: .zero, targetDisplay: target), "empty frame is unverified")
check(!windowPlacementIsVerified(spaceIDs: [77], targetSpace: 77, frame: CGRect(x: 400, y: -800, width: 1100, height: 700), targetDisplay: target), "edge overlap without window center on target is not success")

let finished = Process()
finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
check((try? runRuntimeProcess(finished, timeout: 2)) == 0, "finished utility reports exit status")
let slow = Process()
slow.executableURL = URL(fileURLWithPath: "/bin/sleep")
slow.arguments = ["0.4"]
var timedOut = false
do { _ = try runRuntimeProcess(slow, timeout: 0.03) }
catch RuntimeProcessError.timedOut { timedOut = true }
catch { print("Unexpected utility failure: \(error)") }
check(timedOut, "utility exceeding its deadline stops with a timeout")
print("RuntimeSafetyChecks: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
