# Implementation references

- Apple ServiceManagement SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice
- Dock plist tile schema and spacer behavior: https://github.com/kcrawford/dockutil
- Application bindings observations: https://gist.github.com/0xdevalias/8bc497546d5f036cbaeae5d0e389aa35
- SkyLight ABI signatures: https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/private.h
- Tahoe asynchronous operation discovery: https://github.com/Hammerspoon/hammerspoon/pull/3889 by franzbu. The bridge isolates these private interfaces, checks the Mach-O table boundaries and verifies resulting Space membership in Swift. No Dock injection or SIP change.

The bridged operation is asynchronous. Its return value is never taken as proof of completion. Private ABI remains experimental; one process and cross-process live probes passed locally on 26.5.2.

## Original desktop identity (0.6.1)
Some macOS sessions expose an explicitly empty `uuid` for the original desktop. It is a native Dock binding value, not a missing key. `readDesktops` preserves it together with the positive `ManagedSpaceID`; it does not generate a UUID or substitute `Main`, `primary` or `AllSpaces`. Missing/non-string UUIDs, absent/zero session IDs and duplicate identities within or across displays still stop the operation. The empty UUID is not tied to visual position 1: the original desktop can be reordered.

The previous nonempty-string guard reproduced the tester's error with this fixture. The complete parser → resolution → app-binding path now has regression coverage, including empty binding serialization and unrelated binding preservation. This explains a known matching failure; the tester's raw inventory was not received, so validation on their MacBook Air / macOS 26.5.1 remains pending.

Primary implementation reference for the original desktop's empty UUID: https://github.com/noobomancer/space-renamer#how-it-works-high-level . Native empty Dock-binding observation: https://apple.stackexchange.com/a/18999 . No code from those projects was copied.


## Automatic desktop preparation (0.5)
`desktopRequirements` derives the highest assigned ordinal per role and validates the full profile before any creation. `prepareDesktops` uses live inventories before and after each add, checks existing desktop ID prefixes, and fails instead of repeating an unconfirmed request. Native `MissionControlSession` opens/closes the system Mission Control app, finds Dock AX identifiers `mc` → `mc.display` with `AXDisplayID` → `mc.spaces` → `mc.spaces.add`, then presses once. Normal polling is bounded to 5 seconds; cancellation after a press is reported as unconfirmed, not as proof no desktop was added. No desktop removal APIs are used. AppStore clears the previous attempt report, preflights application paths, prepares, then resolves fresh IDs before its existing Dock transaction and window movement. Native preparation strategy cross-checked against https://www.hammerspoon.org/docs/hs.spaces.html#addSpaceToScreen and https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/spaces.lua .
