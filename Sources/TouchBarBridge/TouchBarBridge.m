#import "TouchBarBridge.h"
#import <objc/message.h>
#import <dlfcn.h>

static NSString *const trayIdentifier = @"local.codex.touchbar.tray";
static NSCustomTouchBarItem *trayItem;
static void *dfrHandle;
typedef void (*PresenceFunction)(NSString *, BOOL);

// DisplayServices is private; resolve it once and report unavailable on failure.
static int (*readBrightness)(CGDirectDisplayID, float *);
static int (*writeBrightness)(CGDirectDisplayID, float);
static void prepareBrightness(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
        if (handle) {
            readBrightness = dlsym(handle, "DisplayServicesGetBrightness");
            writeBrightness = dlsym(handle, "DisplayServicesSetBrightness");
        }
    });
}
BOOL CTBReadBrightness(CGDirectDisplayID *display, float *value) {
    prepareBrightness();
    if (!readBrightness || !writeBrightness) return NO;
    CGDirectDisplayID displays[16]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i]) && CGDisplayIsActive(displays[i])) {
            *display = displays[i];
            return readBrightness(*display, value) == 0;
        }
    }
    return NO;
}
BOOL CTBWriteBrightness(CGDirectDisplayID display, float value) {
    prepareBrightness();
    if (!writeBrightness || !CGDisplayIsBuiltin(display) || !CGDisplayIsActive(display)) return NO;
    return writeBrightness(display, fminf(1, fmaxf(0.05, value))) == 0;
}

void CTBPrepareTray(id target, SEL action) {
    SEL add = NSSelectorFromString(@"addSystemTrayItem:");
    if (![NSTouchBarItem respondsToSelector:add]) return;
    if (!dfrHandle) dfrHandle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    if (!dfrHandle) return;
    void (*closeBox)(BOOL) = dlsym(dfrHandle, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    if (closeBox) closeBox(YES);
    trayItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:trayIdentifier];
    trayItem.view = [NSButton buttonWithTitle:@"C" target:target action:action];
    ((void (*)(id, SEL, id))objc_msgSend)(NSTouchBarItem.class, add, trayItem);
    PresenceFunction presence = dlsym(dfrHandle, "DFRElementSetControlStripPresenceForIdentifier");
    if (presence) presence(trayIdentifier, YES);
}
void CTBRemoveTray(void) {
    PresenceFunction presence = dfrHandle ? dlsym(dfrHandle, "DFRElementSetControlStripPresenceForIdentifier") : NULL;
    if (presence) presence(trayIdentifier, NO);
    SEL remove = NSSelectorFromString(@"removeSystemTrayItem:");
    if (trayItem && [NSTouchBarItem respondsToSelector:remove])
        ((void (*)(id, SEL, id))objc_msgSend)(NSTouchBarItem.class, remove, trayItem);
    trayItem = nil;
}

// System modal presentation is private AppKit API. Keep all private calls here,
// resolve at runtime, and fail back to the ordinary application Touch Bar.
static SEL presentSelector(void) {
    return NSSelectorFromString(@"presentSystemModalTouchBar:systemTrayItemIdentifier:");
}
static SEL dismissSelector(void) {
    return NSSelectorFromString(@"dismissSystemModalTouchBar:");
}
BOOL CTBGlobalPresentationAvailable(void) {
    return [NSTouchBar respondsToSelector:presentSelector()] &&
           [NSTouchBar respondsToSelector:dismissSelector()];
}
BOOL CTBPresent(NSTouchBar *bar) {
    if (!CTBGlobalPresentationAvailable()) return NO;
    @try {
        SEL placement = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
        if ([NSTouchBar respondsToSelector:placement])
            ((void (*)(id, SEL, id, NSInteger, id))objc_msgSend)(NSTouchBar.class, placement, bar, 1, trayIdentifier);
        else
            ((void (*)(id, SEL, id, id))objc_msgSend)(NSTouchBar.class, presentSelector(), bar, trayIdentifier);
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}
void CTBDismiss(NSTouchBar *bar) {
    if (![NSTouchBar respondsToSelector:dismissSelector()]) return;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(NSTouchBar.class, dismissSelector(), bar);
    } @catch (NSException *exception) {}
}

CGFloat CTBDisplayWidth(void) {
    if (!dfrHandle) dfrHandle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    CGSize (*screenSize)(void) = dfrHandle ? dlsym(dfrHandle, "DFRGetScreenSize") : NULL;
    CGFloat width = screenSize ? screenSize().width : 1004;
    return width >= 600 && width <= 2200 ? width : 1004;
}
