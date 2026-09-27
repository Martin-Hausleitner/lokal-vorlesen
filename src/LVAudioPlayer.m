#import "LVAudioPlayer.h"
#include <math.h>
@interface LVAudioPlayer ()
@property AVAudioEngine *engine;
@property AVAudioPlayerNode *node;
@property AVAudioUnitTimePitch *pitch;
@property AVAudioMixerNode *converter;
@property AVAudioFile *file;
@property AVAudioFramePosition startFrame;
@property NSUInteger generation;
@property BOOL scheduled;
@property float power;
@property NSTimeInterval heldTime;
@end
@implementation LVAudioPlayer
- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error {
    if (!(self = [super init])) return nil;
    self.file = [[AVAudioFile alloc] initForReading:url error:error]; if (!self.file) return nil;
    _rate = 1; _power = -80;
    self.engine = [AVAudioEngine new]; self.node = [AVAudioPlayerNode new]; self.pitch = [AVAudioUnitTimePitch new];
    self.converter = [AVAudioMixerNode new];
    [self.engine attachNode:self.node]; [self.engine attachNode:self.pitch]; [self.engine attachNode:self.converter];
    AVAudioFormat *renderFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    [self.engine connect:self.node to:self.converter format:self.file.processingFormat];
    [self.engine connect:self.converter to:self.pitch format:renderFormat];
    [self.engine connect:self.pitch to:self.engine.mainMixerNode format:renderFormat];
    __weak LVAudioPlayer *weakSelf = self;
    [self.engine.mainMixerNode installTapOnBus:0 bufferSize:512 format:nil block:^(AVAudioPCMBuffer *buffer,AVAudioTime *when) {
        LVAudioPlayer *self = weakSelf; if (!self || !self.meteringEnabled || !buffer.floatChannelData || !buffer.frameLength) return;
        float *samples = buffer.floatChannelData[0]; double square = 0;
        for (AVAudioFrameCount i=0;i<buffer.frameLength;i++) square += samples[i]*samples[i];
        self.power = (float)(10*log10(MAX(square/buffer.frameLength,1e-8)));
    }];
    return self;
}
- (NSTimeInterval)duration { return self.file.length / self.file.processingFormat.sampleRate; }
- (BOOL)isPlaying { return self.node.isPlaying; }
- (NSTimeInterval)currentTime {
    if (!self.node.isPlaying) return self.heldTime;
    AVAudioTime *render = self.node.lastRenderTime;
    AVAudioTime *time = render ? [self.node playerTimeForNodeTime:render] : nil;
    double frames = self.startFrame + (time && time.sampleTimeValid ? time.sampleTime : 0);
    return MIN(self.duration,MAX(0,frames/self.file.processingFormat.sampleRate));
}
- (void)setCurrentTime:(NSTimeInterval)time {
    BOOL playing = self.playing; self.generation++; [self.node stop]; self.scheduled = NO;
    self.startFrame = MIN(self.file.length,MAX(0,(AVAudioFramePosition)(time*self.file.processingFormat.sampleRate)));
    self.heldTime = self.startFrame/self.file.processingFormat.sampleRate;
    if (playing) [self play];
}
- (void)setRate:(float)rate { _rate = fmaxf(0.5,fminf(4,rate)); self.pitch.rate = _rate; }
- (BOOL)prepareToPlay { [self.engine prepare]; return YES; }
- (BOOL)play {
    NSError *error = nil;
    if (!self.engine.running && ![self.engine startAndReturnError:&error]) return NO;
    if (!self.scheduled) {
        AVAudioFramePosition frames = self.file.length-self.startFrame;
        if (frames <= 0) return NO;
        self.scheduled = YES; NSUInteger generation = ++self.generation;
        __weak LVAudioPlayer *weakSelf = self;
        [self.node scheduleSegment:self.file startingFrame:self.startFrame frameCount:(AVAudioFrameCount)frames atTime:nil completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
            dispatch_async(dispatch_get_main_queue(),^{
                LVAudioPlayer *self = weakSelf; if (!self || self.generation != generation) return;
                self.startFrame = self.file.length; self.heldTime = self.duration; self.scheduled = NO; [self.node stop];
                [self.delegate audioPlayerDidFinishPlaying:self successfully:YES];
            });
        }];
    }
    [self.node play]; return YES;
}
- (void)pause { self.heldTime = self.currentTime; [self.node pause]; }
- (void)stop { self.generation++; [self.node stop]; self.scheduled = NO; self.startFrame = 0; self.heldTime = 0; [self.engine stop]; }
- (void)updateMeters {}
- (float)averagePowerForChannel:(NSUInteger)channel { return self.power; }
- (void)dealloc { [self.engine.mainMixerNode removeTapOnBus:0]; [self.engine stop]; }
@end
