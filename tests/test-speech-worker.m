#import <Foundation/Foundation.h>
#import "../src/LVSpeechWorker.h"
#include <signal.h>
static BOOL Await(BOOL (^condition)(void), double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}
int main(int argc, const char **argv) {
 @autoreleasepool {
    signal(SIGPIPE, SIG_IGN);
    if (argc != 4) return 90;
    NSString *python = @(argv[1]), *script = @(argv[2]), *model = @(argv[3]);
    NSError *error = nil;
    LVSpeechWorker *worker = [[LVSpeechWorker alloc] initWithPython:python script:script model:model speaker:0 error:&error];
    if (!worker) { NSLog(@"%@",error); return 1; }
    pid_t pid = worker.task.processIdentifier;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    for (NSUInteger i=0; i<2; i++) {
        __block BOOL done = NO, success = NO;
        NSString *directory = [root stringByAppendingPathComponent:[@(i) stringValue]];
        [worker synthesizeText:@"Dieser Satz prüft die wiederverwendete lokale Stimme." directory:directory request:[@(i) stringValue] completion:^(BOOL ok){success=ok;done=YES;}];
        if (!Await(^BOOL{return done;}, 15) || !success) return 2;
        if (worker.task.processIdentifier != pid || ![worker canReuseModel:model speaker:0]) return 3;
        if ([worker canReuseModel:model speaker:1] || [worker canReuseModel:@"other" speaker:0]) return 4;
    }
    __block NSUInteger callbacks=0; __block BOOL cancelled=NO;
    NSMutableString *longText = [NSMutableString new];
    for(NSUInteger i=0;i<500;i++) [longText appendString:@"Dieser längere Satz dient der Prüfung eines sofortigen Abbruchs. "];
    [worker synthesizeText:longText directory:[root stringByAppendingPathComponent:@"cancel"] request:@"cancel" completion:^(BOOL ok){callbacks++;cancelled=!ok;}];
    CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
    [worker invalidate];
    if (CFAbsoluteTimeGetCurrent()-start > .5) return 5;
    if (!Await(^BOOL{return callbacks>0 && !worker.task.running;}, 5) || !cancelled || callbacks!=1) return 6;
    if ([worker canReuseModel:model speaker:0]) return 7;
    NSString *fixture = [root stringByAppendingPathComponent:@"ignore-term.py"];
    NSString *code = @"import sys,json,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nfor line in sys.stdin:\n r=json.loads(line); print(json.dumps({'event':'done','request_id':r['request_id']}),flush=True)\nwhile True: time.sleep(1)\n";
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [code writeToFile:fixture atomically:YES encoding:NSUTF8StringEncoding error:nil];
    LVSpeechWorker *stubborn = [[LVSpeechWorker alloc] initWithPython:python script:fixture model:model speaker:0 error:&error];
    __block BOOL idle = NO;
    [stubborn synthesizeText:@"test" directory:root request:@"idle" completion:^(BOOL ok){idle=ok;}];
    if (!Await(^BOOL{return idle;}, 5)) return 8;
    start=CFAbsoluteTimeGetCurrent(); [stubborn shutdownAndWait];
    if(stubborn.task.running || CFAbsoluteTimeGetCurrent()-start>4) return 9;
    [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    printf("PASS: native worker reuses PID, rejects changed voice, cancels promptly, completes once and exits.\n");
 }
 return 0;
}
