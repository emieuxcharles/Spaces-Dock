#include "SpacesBridge.h"
#include "MoveCapability.h"
#include <dlfcn.h>
#include <pthread.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#include <string.h>

@interface NSObject (SpacesDockMove)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)spaceID;
@end
static int64_t (*submitMove)(void *);
// Tahoe ABI documented by franzbu/Hammerspoon PR 3889. Resolve the local
// Mach-O symbol with bounds checks; no injection or change to SIP.
static void *findAsyncMove(void) {
    const char *wanted = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation";
    for (uint32_t i=0;i<_dyld_image_count();i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path,"/SkyLight.framework/")) continue;
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i);
        if (h->magic != MH_MAGIC_64) continue;
        uintptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cursor = (const void *)(h+1), *end=cursor+h->sizeofcmds;
        const struct segment_command_64 *link = NULL;
        const struct symtab_command *table = NULL;
        for (uint32_t n=0;n<h->ncmds;n++) {
            if (cursor+sizeof(struct load_command)>end) return NULL;
            const struct load_command *cmd=(const void *)cursor;
            if (cmd->cmdsize<sizeof(*cmd) || cursor+cmd->cmdsize>end) return NULL;
            if (cmd->cmd==LC_SEGMENT_64 && cmd->cmdsize>=sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg=(const void *)cursor;
                if (!strncmp(seg->segname,SEG_LINKEDIT,16)) link=seg;
            }
            if (cmd->cmd==LC_SYMTAB && cmd->cmdsize>=sizeof(struct symtab_command)) table=(const void *)cursor;
            cursor+=cmd->cmdsize;
        }
        if (!link || !table) return NULL;
        if (table->symoff < link->fileoff || table->stroff < link->fileoff ||
            (uint64_t)table->symoff+(uint64_t)table->nsyms*sizeof(struct nlist_64)>link->fileoff+link->filesize ||
            (uint64_t)table->stroff+table->strsize>link->fileoff+link->filesize) return NULL;
        uintptr_t base=slide+link->vmaddr-link->fileoff;
        const struct nlist_64 *symbols=(const void *)(base+table->symoff);
        const char *strings=(const void *)(base+table->stroff);
        for (uint32_t n=0;n<table->nsyms;n++) {
            uint32_t offset=symbols[n].n_un.n_strx;
            if (offset>=table->strsize || !symbols[n].n_value) continue;
            size_t available=table->strsize-offset;
            if (strlen(wanted)+1<=available && !memcmp(strings+offset,wanted,strlen(wanted)+1))
                return (void *)(slide+symbols[n].n_value);
        }
    }
    return NULL;
}

static void *library;
static int (*connection)(void);
static CFArrayRef (*readSpaces)(int);
static CFArrayRef (*windowSpaces)(int,int,CFArrayRef);
static int (*spaceType)(int,uint64_t);
static int (*compat)(int,uint64_t,int);
static int (*moveList)(int,uint32_t*,int,int);
static int (*axWindowID)(AXUIElementRef,uint32_t*);
static Class moveOperationClass;
static SDMoveBackend moveBackend;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void load(void) {
    library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return;
    connection = dlsym(library,"SLSMainConnectionID");
    readSpaces = dlsym(library,"SLSCopyManagedDisplaySpaces");
    windowSpaces = dlsym(library,"SLSCopySpacesForWindows");
    spaceType = dlsym(library,"SLSSpaceGetType");
    compat = dlsym(library,"SLSSpaceSetCompatID");
    moveList = dlsym(library,"SLSSetWindowListWorkspace");
    axWindowID = dlsym(RTLD_DEFAULT,"_AXUIElementGetWindow");
    int major = (int)NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    if (major == 26 || major == 27) {
        submitMove = findAsyncMove();
        moveOperationClass = NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    }
    moveBackend = SDChooseMoveBackend(major, connection && readSpaces && windowSpaces && spaceType,
                                     compat && moveList, submitMove != NULL,
                                     [moveOperationClass instancesRespondToSelector:@selector(initWithWindows:spaceID:)],
                                     axWindowID != NULL);
}
// Private ABI: isolated here, never a hard link or a promise of compatibility.
// Signatures cross-checked against Hammerspoon extensions/spaces/private.h.
bool SDAvailable(void) {
    pthread_once(&once, load);
    return moveBackend != SDMoveUnavailable;
}
int SDAXWindowID(AXUIElementRef element, uint32_t *window) {
    pthread_once(&once, load);
    return axWindowID && element && window ? axWindowID(element,window) : -1;
}
CFArrayRef SDReadSpaces(void) { return SDAvailable() ? readSpaces(connection()) : NULL; }
CFArrayRef SDWindowSpaces(uint32_t window) {
    if (!SDAvailable()) return NULL;
    CFNumberRef n = CFNumberCreate(NULL,kCFNumberSInt32Type,&window);
    const void *values[] = {n};
    CFArrayRef a = CFArrayCreate(NULL,values,1,&kCFTypeArrayCallBacks);
    CFArrayRef r = windowSpaces(connection(),7,a);
    CFRelease(a); CFRelease(n);
    return r;
}
int SDSpaceType(uint64_t space) { return SDAvailable() ? spaceType(connection(),space) : -1; }
int SDMoveWindow(uint32_t window, uint64_t space) {
    if (!SDAvailable() || SDSpaceType(space) != 0) return -1;
    if (moveBackend == SDMoveAsynchronous) {
        if (![moveOperationClass instancesRespondToSelector:@selector(initWithWindows:spaceID:)]) return -2;
        id operation = [[moveOperationClass alloc] initWithWindows:@[@(window)] spaceID:space];
        if (!operation) return -3;
        submitMove((__bridge void *)operation);
        // Operation submission is asynchronous. Swift verifies the resulting membership.
        return 0;
    }
    int cid = connection();
    const int temporary = 0x79616265;
    int result = compat(cid,space,temporary);
    if (result) return result;
    result = moveList(cid,&window,1,temporary);
    int cleanup = compat(cid,space,0);
    return result ? result : cleanup;
}
