#define main ProductMain
#import "../src/main.m"
#undef main
@interface RunningTask : NSTask
@end
@implementation RunningTask
- (BOOL)isRunning { return YES; }
@end
@interface HealthTestApp : AudioApp
@property NSUInteger starts;
@property NSString *captured;
@property NSUInteger stops;
@end
@implementation HealthTestApp
- (void)record:(NSString *)event {}
- (void)startText:(NSString *)text { self.starts++; self.captured = text; self.automaticRetryUsed = NO; self.silentSince = 0; }
- (void)stop:(id)sender { self.stops++; self.task = nil; }
@end
int main(void) {
 @autoreleasepool {
  HealthTestApp *app = [HealthTestApp new]; app.task = [RunningTask new];
  app.originalRequestText = @"Originalauftrag"; app.silentSince = CFAbsoluteTimeGetCurrent()-31; [app checkHealth];
  if(app.starts!=1 || !app.automaticRetryUsed || ![app.captured isEqual:@"Originalauftrag"]) return 1;
  app.silentSince = CFAbsoluteTimeGetCurrent()-31; [app checkHealth];
  if(app.stops!=1 || app.starts!=1) return 2;
  app.task=[RunningTask new]; app.automaticRetryUsed=NO; app.silentSince=CFAbsoluteTimeGetCurrent()-31; app.streamPaused=YES; [app checkHealth];
  if(app.starts!=1 || app.stops!=1) return 3;
  app.streamPaused=NO; app.silentSince=CFAbsoluteTimeGetCurrent()-31; [app checkHealth];
  if(app.starts!=1) return 4;
  printf("PASS: stalled first buffer retries once, failed retry stops, pause and cooldown suppress recovery.\n");
 }
 return 0;
}
