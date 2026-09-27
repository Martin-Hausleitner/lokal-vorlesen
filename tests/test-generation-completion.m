#define main ProductMain
#import "../src/main.m"
#undef main
int main(void) {
 @autoreleasepool {
    AudioApp *app = [AudioApp new];
    app.pendingTasks = [NSMutableDictionary dictionary];
    NSTask *current = [NSTask new];
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    app.task=current; app.generationDirectory=directory; app.request=nil;
    app.pendingTasks[directory]=current;
    [app finishGeneration:YES request:@"finished-playback" directory:directory];
    if(app.task || app.generationDirectory || app.pendingTasks.count) return 1;
    app.task=current; app.generationDirectory=@"new-directory"; app.request=@"new-request";
    [app finishGeneration:YES request:@"old-request" directory:directory];
    if(app.task!=current || ![app.generationDirectory isEqual:@"new-directory"] || ![app.request isEqual:@"new-request"]) return 2;
    printf("PASS: late completion clears matching generation after playback ends without touching a replacement.\n");
 }
 return 0;
}
