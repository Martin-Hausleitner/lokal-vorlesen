#import <Foundation/Foundation.h>
#import "../src/LVSpeechWorker.h"
#include <signal.h>
static BOOL Await(BOOL (^condition)(void), double seconds) {
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(!condition() && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 return condition();
}
static LVSpeechWorker *Worker(NSString *mode) {
 NSString *script=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"tests/fixtures/worker_faults.py"];
 return [[LVSpeechWorker alloc] initWithPython:@"/usr/bin/python3" script:script model:mode speaker:0 error:nil];
}
int main(void) {
 @autoreleasepool {
  signal(SIGPIPE,SIG_IGN);
  NSUInteger cases=0;
  for(NSString *mode in @[@"malformed",@"truncated",@"exit",@"closed-output",@"oversized"]) {
   LVSpeechWorker *worker=Worker(mode); if(!worker)return 1;
   __block NSUInteger callbacks=0; __block BOOL success=YES;
   [worker synthesizeText:@"Neutral test" directory:@"/unused-fixture-path" request:@"fault" completion:^(BOOL ok){callbacks++;success=ok;}];
   BOOL prompt=Await(^BOOL{return callbacks>0;},1.5);
   [worker shutdownAndWait];
   Await(^BOOL{return callbacks>0;},1);
   if(!prompt || callbacks!=1 || success || worker.task.running || [worker canReuseModel:mode speaker:0]) {
    fprintf(stderr,"FAIL: %s did not fail promptly/exactly once\n",mode.UTF8String);return 2;
   }
   cases++;
  }
  LVSpeechWorker *worker=Worker(@"stale"); __block NSUInteger callbacks=0; __block BOOL first=NO, second=NO;
  [worker synthesizeText:@"one" directory:@"/unused-fixture-path" request:@"one" completion:^(BOOL ok){callbacks++;first=ok;}];
  if(!Await(^BOOL{return callbacks==1;},2) || !first){[worker shutdownAndWait];return 3;}
  CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
  [worker synthesizeText:@"two" directory:@"/unused-fixture-path" request:@"two" completion:^(BOOL ok){callbacks++;second=ok;}];
  BOOL done=Await(^BOOL{return callbacks==2;},2);
  double elapsed=CFAbsoluteTimeGetCurrent()-start; [worker shutdownAndWait];
  if(!done || !second || elapsed<.15 || callbacks!=2)return 4;
  printf("PASS: %lu real protocol/exit faults fail once; stale completion cannot finish a replacement.\n",(unsigned long)cases);
 }
 return 0;
}
