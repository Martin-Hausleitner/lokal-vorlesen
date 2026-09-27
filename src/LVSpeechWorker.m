#import "LVSpeechWorker.h"
#include <signal.h>

@interface LVSpeechWorker ()
@property (nonatomic) NSTask *task;
@property NSString *model;
@property NSInteger speaker;
@property NSFileHandle *input;
@property NSString *request;
@property (copy) void (^completion)(BOOL);
@property BOOL invalidated;
@end

@implementation LVSpeechWorker
- (instancetype)initWithPython:(NSString *)python script:(NSString *)script model:(NSString *)model speaker:(NSInteger)speaker error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _model = [model copy]; _speaker = speaker;
    _task = [NSTask new]; _task.qualityOfService = NSQualityOfServiceUserInitiated;
    _task.executableURL = [NSURL fileURLWithPath:python];
    _task.arguments = @[script, @"--model", model, @"--speaker", [@(speaker) stringValue], @"--idle-timeout", @"300"];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"PYTHONUTF8"] = @"1"; environment[@"PYTHONNOUSERSITE"] = @"1"; environment[@"PYTHONDONTWRITEBYTECODE"] = @"1";
    _task.environment = environment;
    NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
    _task.standardInput = input; _task.standardOutput = output;
    _task.standardError = NSFileHandle.fileHandleWithNullDevice;
    _input = input.fileHandleForWriting;
    if (![_task launchAndReturnError:error]) return nil;
    // This read loop owns the worker until EOF. Completion events are ordered
    // before EOF on the main queue, even when process exit races the final line.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buffer = [NSMutableData data];
        @try {
            for (;;) {
                NSData *data = [output.fileHandleForReading availableData];
                if (!data.length) break;
                [buffer appendData:data];
                if (buffer.length > 1024 * 1024) break;
                for (;;) {
                    const unsigned char *bytes = buffer.bytes;
                    NSUInteger newline = 0;
                    while (newline < buffer.length && bytes[newline] != '\n') newline++;
                    if (newline == buffer.length) break;
                    NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline)];
                    [buffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
                    id event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                    if ([event isKindOfClass:NSDictionary.class]) {
                        dispatch_async(dispatch_get_main_queue(), ^{ [self handleEvent:event]; });
                    }
                }
            }
        } @catch (NSException *exception) {}
        @try { [output.fileHandleForReading closeFile]; } @catch (NSException *exception) {}
        dispatch_async(dispatch_get_main_queue(), ^{
            [self invalidate];
            [self finish:NO];
        });
    });
    return self;
}
- (BOOL)canReuseModel:(NSString *)model speaker:(NSInteger)speaker {
    return !self.invalidated && self.task.running && !self.request && [self.model isEqualToString:model] && self.speaker == speaker;
}
- (void)finish:(BOOL)success {
    void (^completion)(BOOL) = self.completion;
    self.completion = nil; self.request = nil;
    if (completion) completion(success);
}
- (void)handleEvent:(NSDictionary *)event {
    if (self.invalidated || !self.request || ![event[@"request_id"] isEqual:self.request]) return;
    if ([event[@"event"] isEqual:@"done"]) [self finish:YES];
    else if ([event[@"event"] isEqual:@"error"] || [event[@"event"] isEqual:@"cancelled"]) [self finish:NO];
}
- (void)synthesizeText:(NSString *)text directory:(NSString *)directory request:(NSString *)request completion:(void (^)(BOOL))completion {
    NSAssert(!self.request, @"Only one synthesis may use a worker at a time.");
    self.request = request; self.completion = completion;
    if (self.invalidated || !self.task.running) { [self finish:NO]; return; }
    NSDictionary *message = @{@"command": @"synthesize", @"request_id": request, @"text": text,
        @"stream_directory": directory, @"output": [directory stringByAppendingPathComponent:@"audio.wav"], @"speaker": @(self.speaker)};
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    NSFileHandle *input = self.input;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try { [input writeData:data]; }
        @catch (NSException *exception) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self invalidate]; });
        }
    });
}
- (void)shutdownAndWait {
    [self invalidate];
    if (self.task.running) [self.task waitUntilExit];
}
- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES;
    NSTask *task = self.task;
    if (task.running) {
        [task terminate];
        // Bound shutdown without blocking the UI or retaining a stuck writer.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (task.running) kill(task.processIdentifier, SIGKILL);
        });
    }
    NSFileHandle *input = self.input;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try { [input closeFile]; } @catch (NSException *exception) {}
    });
}
@end
