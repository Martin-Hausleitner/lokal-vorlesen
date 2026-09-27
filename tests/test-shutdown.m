#define main ProductMain
#import "../src/main.m"
#undef main
@interface ShutdownTestApp : AudioApp
@end
@implementation ShutdownTestApp
- (void)record:(NSString *)event {}
@end
int main(void) {
 @autoreleasepool {
  NSTask *stubborn=[NSTask new];
  stubborn.executableURL=[NSURL fileURLWithPath:@"/usr/bin/python3"];
  stubborn.arguments=@[@"-c",@"import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"];
  NSPipe *ready=[NSPipe pipe]; stubborn.standardOutput=ready;
  stubborn.standardError=NSFileHandle.fileHandleWithNullDevice;
  if (![stubborn launchAndReturnError:nil] || ![ready.fileHandleForReading availableData].length) return 1;
  // Test-owned rescue prevents the regression test itself hanging forever.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
    if(stubborn.running) kill(stubborn.processIdentifier,SIGKILL);
  });
  ShutdownTestApp *app=[ShutdownTestApp new]; app.voiceServer=stubborn;
  CFAbsoluteTime start=CFAbsoluteTimeGetCurrent(); [app applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:nil]];
  double elapsed=CFAbsoluteTimeGetCurrent()-start;
  if(stubborn.running || elapsed>3.5) { fprintf(stderr,"FAIL: app shutdown waits unboundedly for gallery process (%.2fs)\n",elapsed); return 2; }
  printf("PASS: app shutdown terminates SIGTERM-ignoring gallery in %.2fs.\n",elapsed);
 }
 return 0;
}
