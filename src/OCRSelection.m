#import "OCRSelection.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <Vision/Vision.h>
#import <ApplicationServices/ApplicationServices.h>

@class OCRSurface;
@interface OCRWindow : NSWindow
@end
@implementation OCRWindow
- (BOOL)canBecomeKeyWindow { return YES; }
@end
@interface OCRSelection ()
@property OCRWindow *window;
@property NSScreen *screen;
@property NSRunningApplication *previousApp;
@property (copy) void (^completion)(NSString *, NSError *);
@property NSUInteger generation;
@property BOOL cursorPushed;
@property NSTimer *timeout;
- (void)captureRect:(NSRect)rect;
@end
@interface OCRSurface : NSView
@property (weak) OCRSelection *owner;
@property NSPoint anchor;
@property NSRect selection;
@property BOOL dragging;
@property NSInteger button;
@end
@implementation OCRSurface
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithWhite:0 alpha:0.23] setFill]; NSRectFill(self.bounds);
    if (!NSIsEmptyRect(self.selection)) {
        [[NSColor colorWithWhite:1 alpha:0.15] setFill]; NSRectFill(self.selection);
        [NSColor.whiteColor setStroke]; NSBezierPath *border = [NSBezierPath bezierPathWithRect:self.selection]; border.lineWidth = 1.5; [border stroke];
    }
    [@"Bereich ziehen · Esc beendet" drawAtPoint:NSMakePoint(24, 24) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:14 weight:NSFontWeightMedium], NSForegroundColorAttributeName:NSColor.whiteColor}];
}
- (void)updatePoint:(NSPoint)point {
    point.x = MAX(0, MIN(self.bounds.size.width, point.x)); point.y = MAX(0, MIN(self.bounds.size.height, point.y));
    self.selection = NSMakeRect(MIN(point.x, self.anchor.x), MIN(point.y, self.anchor.y), fabs(point.x-self.anchor.x), fabs(point.y-self.anchor.y));
    self.needsDisplay = YES;
}
- (void)mouseDown:(NSEvent *)event { self.button = 0; self.dragging = YES; self.anchor = [self convertPoint:event.locationInWindow fromView:nil]; [self updatePoint:self.anchor]; }
- (void)mouseDragged:(NSEvent *)event { if (self.dragging && self.button == 0) [self updatePoint:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (void)mouseUp:(NSEvent *)event { if (self.dragging && self.button == 0) { [self mouseDragged:event]; self.dragging = NO; [self.owner captureRect:self.selection]; } }
- (void)otherMouseDown:(NSEvent *)event { if (event.buttonNumber == 3) { self.button = 3; self.dragging = YES; self.anchor = [self convertPoint:event.locationInWindow fromView:nil]; [self updatePoint:self.anchor]; } }
- (void)otherMouseDragged:(NSEvent *)event { if (self.dragging && self.button == 3) [self updatePoint:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (void)otherMouseUp:(NSEvent *)event { if (self.dragging && self.button == 3 && event.buttonNumber == 3) { [self otherMouseDragged:event]; self.dragging = NO; [self.owner captureRect:self.selection]; } }
- (void)keyDown:(NSEvent *)event { if (event.keyCode == 53) [self.owner cancel]; else [super keyDown:event]; }
- (void)cancelOperation:(id)sender { [self.owner cancel]; }
@end
@implementation OCRSelection
- (NSError *)error:(NSString *)message { return [NSError errorWithDomain:@"LokalVorlesen.OCR" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
- (void)closeOverlay {
    [self.timeout invalidate]; self.timeout = nil;
    [self.window orderOut:nil]; [self.window close]; self.window = nil;
    if (self.cursorPushed) { [NSCursor pop]; self.cursorPushed = NO; }
    if (self.previousApp && self.previousApp.processIdentifier != NSProcessInfo.processInfo.processIdentifier) [self.previousApp activateWithOptions:0];
    self.previousApp = nil;
}
- (void)finish:(NSString *)text error:(NSError *)error {
    void (^completion)(NSString *,NSError *) = self.completion; self.completion = nil;
    [self closeOverlay];
    if (completion) completion(text,error);
}
- (void)cancel { self.generation++; [self finish:nil error:nil]; }
- (void)beginWithCompletion:(void (^)(NSString *,NSError *))completion {
    [self cancel]; self.completion = completion; NSUInteger generation = self.generation;
    if (@available(macOS 15.2, *)) {} else { [self finish:nil error:[self error:@"Die Bereichsauswahl benötigt macOS 15.2 oder neuer."]]; return; }
    if (!CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess()) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        [self finish:nil error:[self error:@"Bitte „Lokal vorlesen“ unter Datenschutz → Bildschirmaufnahme erlauben und die App neu öffnen."]]; return;
    }
    NSPoint pointer = NSEvent.mouseLocation; self.screen = NSScreen.mainScreen;
    for (NSScreen *screen in NSScreen.screens) if (NSPointInRect(pointer,screen.frame)) { self.screen = screen; break; }
    if (!self.screen) { [self finish:nil error:[self error:@"Kein Bildschirm verfügbar."]]; return; }
    self.previousApp = NSWorkspace.sharedWorkspace.frontmostApplication;
    self.window = [[OCRWindow alloc] initWithContentRect:self.screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    self.window.releasedWhenClosed = NO; self.window.opaque = NO; self.window.backgroundColor = NSColor.clearColor;
    self.window.level = NSScreenSaverWindowLevel; self.window.hasShadow = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    OCRSurface *surface = [[OCRSurface alloc] initWithFrame:NSMakeRect(0,0,self.screen.frame.size.width,self.screen.frame.size.height)];
    surface.owner = self; self.window.contentView = surface;
    if (NSEvent.pressedMouseButtons & (1UL << 3)) { surface.button = 3; surface.dragging = YES; surface.anchor = NSMakePoint(pointer.x-self.screen.frame.origin.x,pointer.y-self.screen.frame.origin.y); }
    [NSCursor.crosshairCursor push]; self.cursorPushed = YES;
    [NSApp activateIgnoringOtherApps:YES]; [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:surface];
    __weak OCRSelection *weakSelf = self;
    self.timeout = [NSTimer scheduledTimerWithTimeInterval:45 repeats:NO block:^(NSTimer *timer) { if (weakSelf.generation == generation) [weakSelf cancel]; }];
}
- (void)captureRect:(NSRect)rect {
    if (!self.completion) return;
    if (rect.size.width < 5 || rect.size.height < 5) { [self cancel]; return; }
    NSUInteger generation = self.generation;
    CGDirectDisplayID display = [self.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
    CGRect displayBounds = CGDisplayBounds(display);
    CGRect capture = CGRectMake(displayBounds.origin.x+rect.origin.x, displayBounds.origin.y+self.screen.frame.size.height-NSMaxY(rect),rect.size.width,rect.size.height);
    [self closeOverlay];
    __weak OCRSelection *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.15*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        OCRSelection *self = weakSelf; if (!self || self.generation != generation || !self.completion) return;
        if (@available(macOS 15.2, *)) {
            [SCScreenshotManager captureImageInRect:capture completionHandler:^(CGImageRef image,NSError *error) {
                if (!image) { dispatch_async(dispatch_get_main_queue(),^{ if (self.generation == generation) [self finish:nil error:error ?: [self error:@"Der ausgewählte Bereich konnte nicht aufgenommen werden."]]; }); return; }
                CGImageRef retained = CGImageRetain(image);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
                    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate; request.usesLanguageCorrection = YES;
                    request.automaticallyDetectsLanguage = YES; request.recognitionLanguages = @[@"de-DE",@"en-US"];
                    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:retained options:@{}]; NSError *recognitionError = nil;
                    [handler performRequests:@[request] error:&recognitionError]; CGImageRelease(retained);
                    NSMutableArray<NSString *> *lines = [NSMutableArray array];
                    for (VNRecognizedTextObservation *observation in request.results) { NSString *line = [observation topCandidates:1].firstObject.string; if (line.length) [lines addObject:line]; }
                    NSString *text = [lines componentsJoinedByString:@"\n"];
                    dispatch_async(dispatch_get_main_queue(),^{
                        if (self.generation != generation || !self.completion) return;
                        [self finish:text.length ? text : nil error:recognitionError ?: (text.length ? nil : [self error:@"In diesem Bereich wurde kein lesbarer Text erkannt."])];
                    });
                });
            }];
        }
    });
}
@end
