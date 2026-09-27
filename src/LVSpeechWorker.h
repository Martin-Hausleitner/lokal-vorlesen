#import <Foundation/Foundation.h>

@interface LVSpeechWorker : NSObject
@property (nonatomic, readonly) NSTask *task;
- (instancetype)initWithPython:(NSString *)python script:(NSString *)script model:(NSString *)model speaker:(NSInteger)speaker error:(NSError **)error;
- (BOOL)canReuseModel:(NSString *)model speaker:(NSInteger)speaker;
- (void)synthesizeText:(NSString *)text directory:(NSString *)directory request:(NSString *)request completion:(void (^)(BOOL success))completion;
- (void)invalidate;
- (void)shutdownAndWait;
@end
