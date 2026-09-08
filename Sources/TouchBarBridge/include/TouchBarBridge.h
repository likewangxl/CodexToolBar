#import <AppKit/AppKit.h>
BOOL CTBGlobalPresentationAvailable(void);
BOOL CTBPresent(NSTouchBar *bar);
void CTBDismiss(NSTouchBar *bar);
void CTBPrepareTray(id target, SEL action);
void CTBRemoveTray(void);

CGFloat CTBDisplayWidth(void);
