#import <Cocoa/Cocoa.h>
@interface OCRSelection : NSObject
- (void)beginWithCompletion:(void (^)(NSString *text, NSError *error))completion;
- (void)cancel;
@end
