#define main ProductMain
#import "../src/main.m"
#undef main
@interface TestAudioApp : AudioApp
@property NSUInteger bufferUpdates;
@end
@implementation TestAudioApp
- (void)updateBuffer { self.bufferUpdates++; }
- (void)record:(NSString *)event {}
@end
int main(void) {
    @autoreleasepool {
        TestAudioApp *app = [TestAudioApp new];
        app.audioDirectory = @"/nonexistent-test-directory";
        app.streamPaused = NO;
        [app primaryAction:nil];
        if (!app.streamPaused || app.bufferUpdates != 0) return 1;
        [app primaryAction:nil];
        if (app.streamPaused || app.bufferUpdates != 1) return 2;
        printf("PASS: buffering pause blocks auto-start; resume requests buffer playback.\n");
    }
    return 0;
}
