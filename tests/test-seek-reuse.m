#define main ProductMain
#import "../src/main.m"
#undef main
@interface SeekPlayer : LVAudioPlayer
@property double position;
@end
@implementation SeekPlayer
- (BOOL)isPlaying { return YES; }
- (NSTimeInterval)currentTime { return self.position; }
- (void)setCurrentTime:(NSTimeInterval)value { self.position = value; }
@end
@interface SeekApp : AudioApp
@end
@implementation SeekApp
- (void)record:(NSString *)event {}
@end
int main(void) {
 @autoreleasepool {
  NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"chunk-00000.wav"]];
  AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:16000 channels:1];
  AVAudioFile *file=[[AVAudioFile alloc] initForWriting:url settings:format.settings error:nil];
  AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:48000]; buffer.frameLength=48000;
  memset(buffer.floatChannelData[0],0,48000*sizeof(float)); [file writeFromBuffer:buffer error:nil]; file=nil;
  SeekApp *app=[SeekApp new]; SeekPlayer *player=[SeekPlayer new]; player.position=1;
  app.player=player; app.audioDirectory=directory; app.nextChunk=1;
  [app seekBy:.5];
  BOOL passed=app.player==player && fabs(player.position-1.5)<.01;
  [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
  if(!passed) return 1;
  printf("PASS: same-buffer seek preserves the player and adjusts only position.\n");
 }
 return 0;
}
