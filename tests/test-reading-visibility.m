#define main ProductMain
#import "../src/main.m"
#undef main
@interface TestVisibilityWindow : NSObject
@property(getter=isVisible) BOOL visible;
@end
@implementation TestVisibilityWindow
@end
int main(void) {
 @autoreleasepool {
    AudioApp *app = [AudioApp new];
    TestVisibilityWindow *window = [TestVisibilityWindow new];
    app.window = (NSPanel *)(id)window;
    window.visible = YES;
    app.readingTextPinned = YES;
    if ([app shouldShowLiveText:NO]) return 1;
    app.currentChunkText = @"Neutraler Testtext"; app.audioDirectory = @"test-fixture";
    if (![app shouldShowLiveText:NO]) return 2;
    app.streamPaused = YES;
    if (![app shouldShowLiveText:NO]) return 3;
    window.visible = NO;
    if ([app shouldShowLiveText:YES]) return 4;
    window.visible = YES; app.readingTextPinned = NO;
    if ([app shouldShowLiveText:NO] || ![app shouldShowLiveText:YES]) return 5;
    app.audioDirectory = nil;
    if ([app shouldShowLiveText:YES]) return 6;
    printf("PASS: reading section supports pinned/paused visibility and hides for idle, hidden player, and cleared playback.\n");
 }
 return 0;
}
