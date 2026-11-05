#ifndef SPACES_DOCK_MOVE_CAPABILITY_H
#define SPACES_DOCK_MOVE_CAPABILITY_H
#include <stdbool.h>

typedef enum { SDMoveUnavailable, SDMoveLegacy, SDMoveAsynchronous } SDMoveBackend;

// Selection is shared by preflight and movement, and can be checked without
// loading SkyLight or touching a user's Spaces.
static inline SDMoveBackend SDChooseMoveBackend(int osMajor, bool reads, bool legacy,
                                                bool submit, bool operation, bool axWindowID) {
    if (!reads || !axWindowID) return SDMoveUnavailable;
    if (osMajor == 26 || osMajor == 27) return submit && operation ? SDMoveAsynchronous : SDMoveUnavailable;
    if (osMajor == 14 || osMajor == 15) return legacy ? SDMoveLegacy : SDMoveUnavailable;
    // An ABI from a future macOS release needs assessment before any writes.
    return SDMoveUnavailable;
}
#endif
