#define main ProductMain
#import "../src/main.m"
#undef main
@interface FakeOCR : OCRSelection
@property (copy) void (^callback)(NSString *, NSError *);
@end
@implementation FakeOCR
- (void)beginWithCompletion:(void (^)(NSString *, NSError *))completion { self.callback = completion; }
- (void)cancel {}
@end
@interface OCRTestApp : AudioApp
@property NSUInteger starts;
@end
@implementation OCRTestApp
- (void)record:(NSString *)event {}
- (void)startText:(NSString *)text { self.starts++; }
@end
int main(void) {
 @autoreleasepool {
  OCRTestApp *app = [OCRTestApp new]; FakeOCR *ocr = [FakeOCR new]; app.ocrSelection = ocr;
  [app ocrAudio:nil]; void (^late)(NSString *,NSError *) = ocr.callback;
  [app stop:nil]; late(@"Old text", nil);
  if (app.starts) return 1;
  [app ocrAudio:nil]; ocr.callback(@"Current text", nil);
  if (app.starts != 1) return 2;
  printf("PASS: cancelled OCR cannot start stale speech; current result starts once.\n");
 }
 return 0;
}
