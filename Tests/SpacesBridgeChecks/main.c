#include "MoveCapability.h"
#include <stdio.h>
static int failures;
static int checks;
static void check(bool passes, const char *message) {
    checks++;
    if (!passes) { fprintf(stderr, "FAIL: %s\n", message); failures++; }
}
int main(void) {
    check(SDChooseMoveBackend(26, true, true, false, true, true) == SDMoveUnavailable,
          "Tahoe without async entry must fail before preferences change");
    check(SDChooseMoveBackend(26, true, true, true, false, true) == SDMoveUnavailable,
          "missing operation selector must fail in preflight");
    check(SDChooseMoveBackend(26, true, false, true, true, true) == SDMoveAsynchronous,
          "modern move must not require unrelated legacy symbols");
    check(SDChooseMoveBackend(15, true, true, false, false, true) == SDMoveLegacy,
          "legacy systems select complete legacy backend");
    check(SDChooseMoveBackend(15, true, false, true, true, true) == SDMoveUnavailable,
          "legacy systems do not guess newer ABI");
    check(SDChooseMoveBackend(26, false, true, true, true, true) == SDMoveUnavailable,
          "missing read capabilities fail preflight");
    check(SDChooseMoveBackend(26, true, true, true, true, false) == SDMoveUnavailable,
          "missing AX window mapper fails before writes");
    check(SDChooseMoveBackend(27, true, false, true, true, true) == SDMoveAsynchronous,
          "macOS 27 uses complete asynchronous backend");
    check(SDChooseMoveBackend(27, true, true, false, true, true) == SDMoveUnavailable,
          "macOS 27 must not fall back to unreliable legacy movement");
    check(SDChooseMoveBackend(27, true, true, true, false, true) == SDMoveUnavailable,
          "macOS 27 requires the operation initializer");
    check(SDChooseMoveBackend(27, false, true, true, true, true) == SDMoveUnavailable,
          "macOS 27 requires complete inventory capabilities");
    check(SDChooseMoveBackend(27, true, true, true, true, false) == SDMoveUnavailable,
          "macOS 27 requires accessibility window mapping");
    check(SDChooseMoveBackend(28, true, true, true, true, true) == SDMoveUnavailable,
          "unassessed future macOS ABI rejected");
    printf("SpacesBridgeChecks: %d/%d passed\n", checks - failures, checks);
    return failures ? 1 : 0;
}
