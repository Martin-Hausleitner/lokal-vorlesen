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
@property NSMutableArray<NSString *> *events;
@end
@implementation HealthTestApp
- (void)record:(NSString *)event { [self.events addObject:event]; }
- (void)startText:(NSString *)text { self.starts++; self.captured = text; self.automaticRetryUsed = NO; self.silentSince = 0; }
- (void)stop:(id)sender { self.stops++; self.task = nil; }
@end
static HealthTestApp *StalledApp(void) {
 HealthTestApp *app = [HealthTestApp new]; app.task = [RunningTask new];
 app.events = [NSMutableArray array]; app.originalRequestText = @"Originalauftrag";
 app.request = @"active-request";
 app.silentSince = CFAbsoluteTimeGetCurrent()-31; return app;
}
int main(void) {
 @autoreleasepool {
  HealthTestApp *app = StalledApp(); [app checkHealth];
  if(app.starts!=1 || !app.automaticRetryUsed || ![app.captured isEqual:@"Originalauftrag"]) return 1;
  app.silentSince = CFAbsoluteTimeGetCurrent()-31; [app checkHealth];
  if(app.stops!=1 || app.starts!=1) return 2;
  HealthTestApp *paused = StalledApp(); paused.streamPaused=YES; [paused checkHealth];
  if(paused.starts || paused.stops || paused.silentSince!=0) return 3;
  HealthTestApp *cooldown = StalledApp(); cooldown.lastAutomaticRetry=CFAbsoluteTimeGetCurrent(); [cooldown checkHealth];
  if(cooldown.starts || cooldown.stops!=1) { fprintf(stderr,"FAIL: cooldown leaves a stalled request running forever\n"); return 4; }
  HealthTestApp *gap = StalledApp(); gap.nextChunk=2; [gap checkHealth];
  if(gap.starts || gap.stops!=1) { fprintf(stderr,"FAIL: stalled later buffer never terminates\n"); return 5; }
  HealthTestApp *active = StalledApp(); active.player=[LVAudioPlayer new]; [active checkHealth];
  if(active.starts || active.stops || active.silentSince!=0) return 6;
  HealthTestApp *shortGap = StalledApp(); shortGap.silentSince=CFAbsoluteTimeGetCurrent()-5; [shortGap checkHealth];
  if(shortGap.starts || shortGap.stops) return 7;
  HealthTestApp *missing = StalledApp(); missing.originalRequestText=nil; [missing checkHealth];
  if(missing.starts || missing.stops!=1) return 8;
  HealthTestApp *finished = StalledApp(); finished.request=nil; finished.nextChunk=0; [finished checkHealth];
  if(finished.starts || finished.stops!=1) { fprintf(stderr,"FAIL: already completed playback is replayed on delayed worker completion\n"); return 9; }
  printf("PASS: first-buffer retry is bounded; later gaps, cooldown and missing text fail closed; active/paused audio and short gaps are preserved.\n");
 }
 return 0;
}
