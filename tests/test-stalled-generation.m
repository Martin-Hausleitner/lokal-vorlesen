#define main ProductMain
#import "../src/main.m"
#undef main
@interface StalledGenerationApp : AudioApp
@property NSMutableArray<NSString *> *events;
@end
@implementation StalledGenerationApp
- (void)record:(NSString *)event { [self.events addObject:event]; }
@end
static BOOL Await(BOOL (^condition)(void), double seconds) {
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(!condition() && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 return condition();
}
int main(void) {
 @autoreleasepool {
  signal(SIGPIPE,SIG_IGN);
  NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *fixture=[root stringByAppendingPathComponent:@"hung.py"], *ready=[root stringByAppendingPathComponent:@"ready"];
  NSString *code=@"import sys,signal,json,time,pathlib\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nr=json.loads(sys.stdin.readline())\npathlib.Path(r['text']).touch()\nwhile True: time.sleep(1)\n";
  [code writeToFile:fixture atomically:YES encoding:NSUTF8StringEncoding error:nil];
  LVSpeechWorker *worker=[[LVSpeechWorker alloc] initWithPython:@"/usr/bin/python3" script:fixture model:@"fixture" speaker:0 error:nil];
  if(!worker) return 1;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,7*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{if(worker.task.running)kill(worker.task.processIdentifier,SIGKILL);});
  StalledGenerationApp *app=[StalledGenerationApp new]; app.events=[NSMutableArray array]; app.pendingTasks=[NSMutableDictionary dictionary];
  app.speechWorker=worker; app.task=worker.task; app.request=@"stalled"; app.generationDirectory=[root stringByAppendingPathComponent:@"audio"]; app.audioDirectory=app.generationDirectory;
  app.pendingTasks[app.generationDirectory]=worker.task; app.originalRequestText=@"Test";
  NSString *directory=app.generationDirectory;
  __block NSUInteger callbacks=0;
  [worker synthesizeText:ready directory:directory request:app.request completion:^(BOOL ok){callbacks++; [app finishGeneration:ok request:@"stalled" directory:directory];}];
  if(!Await(^BOOL{return [[NSFileManager defaultManager] fileExistsAtPath:ready];},3)){[worker shutdownAndWait];return 2;}
  app.nextChunk=2; app.silentSince=CFAbsoluteTimeGetCurrent()-31;
  CFAbsoluteTime start=CFAbsoluteTimeGetCurrent(); [app checkHealth];
  if(CFAbsoluteTimeGetCurrent()-start>.3 || app.task || app.request || app.audioDirectory || ![app.events containsObject:@"generation_buffer_stalled"]) return 3;
  if(!Await(^BOOL{return !worker.task.running && callbacks==1 && !app.pendingTasks.count && !app.generationDirectory;},4))return 4;
  if(CFAbsoluteTimeGetCurrent()-start>3.5)return 5;
  [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
  printf("PASS: later-buffer timeout cancels a real SIGTERM-ignoring worker without blocking caller; child exits and callback/ownership cleanup completes once.\n");
 }
 return 0;
}
