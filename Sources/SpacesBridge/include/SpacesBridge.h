#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdint.h>
CFArrayRef SDReadSpaces(void) CF_RETURNS_RETAINED;
CFArrayRef SDWindowSpaces(uint32_t window) CF_RETURNS_RETAINED;
int SDMoveWindow(uint32_t window, uint64_t space);
int SDSpaceType(uint64_t space);
bool SDAvailable(void);
int SDAXWindowID(AXUIElementRef element, uint32_t *window);
