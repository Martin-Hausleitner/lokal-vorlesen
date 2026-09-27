#import <AVFoundation/AVFoundation.h>
@class LVAudioPlayer;
@protocol LVAudioPlayerDelegate <NSObject>
- (void)audioPlayerDidFinishPlaying:(LVAudioPlayer *)player successfully:(BOOL)flag;
@end
@interface LVAudioPlayer : NSObject
@property (weak) id<LVAudioPlayerDelegate> delegate;
@property BOOL enableRate;
@property BOOL meteringEnabled;
@property (nonatomic) float rate;
@property NSTimeInterval currentTime;
@property (readonly) NSTimeInterval duration;
@property (readonly,getter=isPlaying) BOOL playing;
- (instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)error;
- (BOOL)prepareToPlay;
- (BOOL)play;
- (void)pause;
- (void)stop;
- (void)updateMeters;
- (float)averagePowerForChannel:(NSUInteger)channel;
@end
