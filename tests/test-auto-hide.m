#define main ProductMain
#import "../src/main.m"
#undef main
@interface IdleWindow : NSObject
@property(getter=isVisible) BOOL visible;
@property(getter=isKeyWindow) BOOL keyWindow;
@end
@implementation IdleWindow
@end
@interface IdleView : NSObject
@property(getter=isHidden) BOOL hidden;
@end
@implementation IdleView
@end
@interface IdlePopover : NSObject
@property(getter=isShown) BOOL shown;
@end
@implementation IdlePopover
@end
@interface BusyTask : NSTask
@end
@implementation BusyTask
- (BOOL)isRunning { return YES; }
@end
@interface IdleApp : AudioApp
@property NSUInteger hides;
@end
@implementation IdleApp
- (void)hideWindow:(id)sender { self.hides++; [(IdleWindow *)(id)self.window setVisible:NO]; }
- (void)record:(NSString *)event {}
@end
int main(void) { @autoreleasepool {
 IdleApp *app=[IdleApp new]; IdleWindow *window=[IdleWindow new];
 app.window=(NSPanel *)(id)window; window.visible=YES; app.lastPlayerUse=100;
 [app checkAutoHideAtTime:102.9 mouseInside:NO]; if(app.hides) return 1;
 [app checkAutoHideAtTime:103 mouseInside:NO]; if(app.hides!=1 || window.visible) return 2;
 [app checkAutoHideAtTime:110 mouseInside:YES]; if(app.hides!=1 || window.visible) return 3;
 window.visible=YES; [app checkAutoHideAtTime:120 mouseInside:YES];
 [app checkAutoHideAtTime:122 mouseInside:NO]; if(app.hides!=1) return 4;
 app.task=[BusyTask new]; [app checkAutoHideAtTime:130 mouseInside:NO]; if(app.hides!=1) return 5;
 app.task=nil; app.audioDirectory=@"fixture"; app.streamPaused=YES;
 [app checkAutoHideAtTime:140 mouseInside:NO]; if(app.hides!=1) return 6;
 app.streamPaused=NO; [app checkAutoHideAtTime:150 mouseInside:NO]; if(app.hides!=1) return 7;
 app.audioDirectory=nil; IdleView *editor=[IdleView new]; app.editorView=(NSScrollView *)(id)editor;
 window.keyWindow=YES; [app checkAutoHideAtTime:160 mouseInside:NO]; if(app.hides!=1) return 8;
 window.keyWindow=NO; [app checkAutoHideAtTime:163 mouseInside:NO]; if(app.hides!=2) return 9;
 window.visible=YES; editor.hidden=YES; window.keyWindow=YES; app.lastPlayerUse=170;
 [app checkAutoHideAtTime:173 mouseInside:NO]; if(app.hides!=3) return 10;
 window.visible=YES; IdlePopover *popover=[IdlePopover new]; popover.shown=YES; app.controlsPopover=(NSPopover *)(id)popover;
 [app checkAutoHideAtTime:180 mouseInside:NO]; if(app.hides!=3) return 11;
 popover.shown=NO; app.showingSpeedMenu=YES; [app checkAutoHideAtTime:190 mouseInside:NO]; if(app.hides!=3) return 12;
 app.showingSpeedMenu=NO; [app checkAutoHideAtTime:192 mouseInside:NO]; if(app.hides!=3) return 13;
 [app checkAutoHideAtTime:193 mouseInside:NO]; if(app.hides!=4) return 14;
 puts("PASS: idle hides after 3s; hidden stays hidden; hover, generation, buffered/paused playback, focused editor and menus preserve visibility; unfocused editor can hide.");
 } return 0; }
