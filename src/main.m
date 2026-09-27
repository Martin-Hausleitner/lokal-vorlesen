#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <WebKit/WebKit.h>
#import "OCRSelection.h"
#import "LVAudioPlayer.h"
#import "LVSpeechWorker.h"
#include <signal.h>

static NSString *Resource(NSString *name) {
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:name];
}
static void RemoveDirectory(NSString *path) {
    if (path.length) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}
static NSString *RuntimePython(void) {
    return [[NSString stringWithContentsOfFile:Resource(@"runtime-path.txt") encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static NSString *StateDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LokalVorlesen"];
}
static NSDictionary *VoiceConfig(void) {
    NSData *data = [NSData dataWithContentsOfFile:[StateDirectory() stringByAppendingPathComponent:@"voice.json"]];
    id config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableDictionary *result = [config isKindOfClass:NSDictionary.class] ? [config mutableCopy] : [NSMutableDictionary dictionary];
    NSData *modeData = [NSData dataWithContentsOfFile:[StateDirectory() stringByAppendingPathComponent:@"player-mode.json"]];
    id mode = modeData ? [NSJSONSerialization JSONObjectWithData:modeData options:0 error:nil] : nil;
    if ([mode isKindOfClass:NSDictionary.class] && mode[@"mode"]) result[@"mode"] = mode[@"mode"];
    return result;
}
static NSString *SelectedModel(NSDictionary *config) {
    id model = config[@"model_path"];
    NSString *prefix = [[StateDirectory() stringByAppendingPathComponent:@"voices"] stringByAppendingString:@"/"];
    if ([model isKindOfClass:NSString.class] && [[model stringByStandardizingPath] hasPrefix:prefix] &&
        [[NSFileManager defaultManager] fileExistsAtPath:model]) return model;
    return model ? nil : Resource(@"model.onnx");
}
static BOOL BackendReady(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *model = SelectedModel(VoiceConfig());
    return [RuntimePython() hasPrefix:@"/"] && [fm isExecutableFileAtPath:RuntimePython()] &&
        [fm fileExistsAtPath:Resource(@"synthesize.py")] &&
        [fm fileExistsAtPath:Resource(@"tts_worker.py")] &&
        model && [fm fileExistsAtPath:model] &&
        [fm fileExistsAtPath:[model stringByAppendingString:@".json"]];
}
static NSTask *BackendTask(NSString *output, NSPipe *input) {
    NSTask *task = [[NSTask alloc] init];
    task.qualityOfService = NSQualityOfServiceUserInitiated;
    task.executableURL = [NSURL fileURLWithPath:RuntimePython()];
    NSDictionary *config = VoiceConfig();
    NSInteger speaker = [config[@"speaker"] integerValue];
    speaker = MAX(0, MIN(1000, speaker));
    task.arguments = @[Resource(@"synthesize.py"), @"--model", SelectedModel(config) ?: @"", @"--output", output, @"--speaker", [@(speaker) stringValue]];
    task.standardInput = input;
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    environment[@"PYTHONUTF8"] = @"1";
    environment[@"PYTHONNOUSERSITE"] = @"1"; environment[@"PYTHONDONTWRITEBYTECODE"] = @"1";
    task.environment = environment;
    return task;
}
static id AXValue(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (!element || AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}
static BOOL SecureElement(AXUIElementRef element) {
    AXUIElementRef current = element;
    if (current) CFRetain(current);
    BOOL secure = NO;
    for (NSUInteger depth = 0; current && depth < 8; depth++) {
        NSString *subrole = AXValue(current, kAXSubroleAttribute);
        if ([subrole isKindOfClass:[NSString class]] &&
            [subrole rangeOfString:@"secure" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            secure = YES; break;
        }
        CFTypeRef parent = NULL;
        AXUIElementCopyAttributeValue(current, kAXParentAttribute, &parent);
        CFRelease(current); current = NULL;
        if (parent && CFGetTypeID(parent) == AXUIElementGetTypeID()) current = (AXUIElementRef)parent;
        else if (parent) CFRelease(parent);
    }
    if (current) CFRelease(current);
    return secure;
}
static NSString *UsableText(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length && text.length <= 100000 ? text : nil;
}

@interface LevelView : NSView
@property double level;
@property BOOL active;
@end
@implementation LevelView
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirty {
    const NSUInteger count = 5;
    CGFloat gap = 2, width = (self.bounds.size.width - (count - 1) * gap) / count;
    for (NSUInteger i = 0; i < count; i++) {
        double profile = 0.35 + 0.65 * fabs(sin((double)i * 1.73));
        CGFloat height = 3 + self.level * profile * (self.bounds.size.height - 4);
        NSRect bar = NSMakeRect(i * (width + gap), (self.bounds.size.height - height) / 2, width, height);
        [[NSColor colorWithCalibratedRed:0.72 green:0.85 blue:1 alpha:self.active ? 0.95 : 0.32] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:width/2 yRadius:width/2] fill];
    }
}
@end
@interface PlayerSurface : NSView
@property (copy) void (^scrollHandler)(NSEvent *event);
@end
@implementation PlayerSurface
- (void)scrollWheel:(NSEvent *)event { if (self.scrollHandler) self.scrollHandler(event); }
@end
@interface FloatingPanel : NSPanel
@end
@implementation FloatingPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface AudioApp : NSObject <NSApplicationDelegate, LVAudioPlayerDelegate, NSWindowDelegate>
@property NSPanel *window;
@property NSPanel *actionPanel;
@property NSPanel *textPanel;
@property BOOL readingTextPinned;
@property NSProgressIndicator *bufferIndicator;
@property NSTextField *liveTextLabel;
@property NSString *currentChunkText;
@property double scrollAccumulator;
@property id audioActivity;
@property CFAbsoluteTime silentSince;
@property CFAbsoluteTime lastAutomaticRetry;
@property CFAbsoluteTime lastServerRestart;
@property NSUInteger serverRestarts;
@property BOOL automaticRetryUsed;
@property NSString *originalRequestText;
@property NSTimer *seekTimer;
@property double pendingSeek;
@property NSTextView *textView;
@property NSTextField *status;
@property NSTextField *speedLabel;
@property NSSlider *speed;
@property NSButton *pauseButton;
@property NSButton *permissionButton;
@property NSStatusItem *statusItem;
@property LVAudioPlayer *player;
@property NSTask *task;
@property LVSpeechWorker *speechWorker;
@property NSString *request;
@property NSString *audioDirectory;
@property NSString *generationDirectory;
@property NSString *hoverText;
@property NSMutableDictionary<NSString *, NSTask *> *pendingTasks;
@property NSTask *voiceServer;
@property NSString *serverToken;
@property NSWindow *settingsWindow;
@property WKWebView *settingsWebView;
@property NSTimer *meterTimer;
@property LevelView *levelView;
@property NSTextField *voiceLabel;
@property NSTextField *clockLabel;
@property NSView *editorView;
@property NSButton *editButton;
@property NSButton *playButton;
@property NSButton *settingsButton;
@property NSButton *speedButton;
@property OCRSelection *ocrSelection;
@property NSUInteger ocrGeneration;
@property NSInteger clipboardChange;
@property BOOL autoClipboard;
@property NSSegmentedControl *modeControl;
@property NSString *positionMode;
@property NSString *playingVoiceName;
@property NSUInteger ticks;
@property NSUInteger nextChunk;
@property BOOL streamDone;
@property BOOL streamPaused;
@property CFAbsoluteTime generationStarted;
@property id mouseMonitor;
@property id dismissMonitor;
@property NSTimer *accessoryTimer;
@property EventHotKeyRef hotKey;
@property EventHotKeyRef selectionHotKey;
@property EventHotKeyRef ocrHotKey;
@property EventHandlerRef hotKeyHandler;
- (void)clipboardAudio:(id)sender;
- (void)selectionAudio:(id)sender;
- (void)ocrAudio:(id)sender;
@end

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    AudioApp *app = (__bridge AudioApp *)userData;
    EventHotKeyID identifier = {0};
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(identifier), NULL, &identifier);
    if (identifier.id == 3) [app ocrAudio:nil];
    else if (identifier.id == 2) [app selectionAudio:nil]; else [app clipboardAudio:nil];
    return noErr;
}

@implementation AudioApp
- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    button.accessibilityLabel = title;
    return button;
}
- (void)record:(NSString *)state {
    // Operational evidence only: no captured text, application names, or audio.
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/LokalVorlesen"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"player-events.jsonl"];
    NSDictionary *entry = @{@"time":@([NSDate date].timeIntervalSince1970), @"event":state, @"rate":@(self.speed.doubleValue), @"position":@(self.player.currentTime), @"duration":@(self.player.duration)};
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:entry options:0 error:nil] mutableCopy];
    [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] > 262144) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:data attributes:@{NSFilePosixPermissions:@0600}];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        @try { [handle seekToEndOfFile]; [handle writeData:data]; [handle closeFile]; } @catch (NSException *exception) {}
    }
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.pendingTasks = [NSMutableDictionary dictionary];
    self.readingTextPinned = [[NSUserDefaults standardUserDefaults] boolForKey:@"readingTextPinned"];
    self.autoClipboard = [[NSUserDefaults standardUserDefaults] boolForKey:@"autoClipboard"];
    self.clipboardChange = NSPasteboard.generalPasteboard.changeCount;
    [NSApp setServicesProvider:self];
    NSUpdateDynamicServices();
    [self buildWindow];
    [self buildMenu];
    [self startVoiceServer];
    EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallEventHandler(GetApplicationEventTarget(), HotKeyHandler, 1, &type, (__bridge void *)self, &_hotKeyHandler);
    EventHotKeyID identifier = {'LoAu', 1};
    RegisterEventHotKey(kVK_ANSI_L, controlKey | optionKey | cmdKey, identifier, GetApplicationEventTarget(), 0, &_hotKey);
    EventHotKeyID selectionIdentifier = {'LoAu', 2};
    OSStatus selectionStatus = RegisterEventHotKey(kVK_ANSI_K, controlKey | optionKey | cmdKey, selectionIdentifier, GetApplicationEventTarget(), 0, &_selectionHotKey);
    if (selectionStatus != noErr) [self record:@"selection_shortcut_registration_failed"];
    else [self record:@"selection_shortcut_registered"];
    [self record:AXIsProcessTrusted() ? @"accessibility_trusted" : @"accessibility_missing"];
    EventHotKeyID ocrIdentifier = {'LoAu', 3};
    if (RegisterEventHotKey(kVK_ANSI_O, controlKey | optionKey | cmdKey, ocrIdentifier, GetApplicationEventTarget(), 0, &_ocrHotKey) != noErr) [self record:@"ocr_shortcut_registration_failed"];
    __weak AudioApp *weakSelf = self;
    self.mouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown handler:^(NSEvent *event) {
        [weakSelf captureAtMouse];
    }];
    self.dismissMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *event) {
        [weakSelf dismissAccessory];
    }];
    [self openWindow:nil];
    [self record:@"ready"];
}
- (NSButton *)iconButton:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label] target:self action:action];
    button.bordered = NO; button.contentTintColor = NSColor.whiteColor;
    button.toolTip = label; button.accessibilityLabel = label;
    return button;
}
- (void)buildWindow {
    self.positionMode = [VoiceConfig()[@"mode"] isEqual:@"bottom"] ? @"bottom" : @"notch";
    self.window = [[FloatingPanel alloc] initWithContentRect:NSMakeRect(0, 0, 180, 32)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Generate Audio"; self.window.floatingPanel = YES;
    self.window.hidesOnDeactivate = NO; self.window.releasedWhenClosed = NO;
    self.window.acceptsMouseMovedEvents = YES;
    self.window.opaque = NO; self.window.backgroundColor = NSColor.clearColor;
    self.window.hasShadow = YES; self.window.level = NSFloatingWindowLevel;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    PlayerSurface *surface = [[PlayerSurface alloc] initWithFrame:NSMakeRect(0, 0, 180, 32)];
    surface.wantsLayer = YES; surface.layer.backgroundColor = [NSColor colorWithWhite:0.015 alpha:1].CGColor;
    surface.layer.cornerRadius = 16; surface.layer.masksToBounds = YES;
    surface.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.13].CGColor; surface.layer.borderWidth = 0.7;
    surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; self.window.contentView = surface;
    NSTrackingArea *tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil];
    [surface addTrackingArea:tracking];
    NSView *controls = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 180, 32)];
    controls.autoresizingMask = NSViewMinYMargin; [surface addSubview:controls];
    self.levelView = [[LevelView alloc] initWithFrame:NSMakeRect(9, 9, 18, 14)];
    self.levelView.accessibilityLabel = @"Audiopegel"; [controls addSubview:self.levelView];
    self.playButton = [self iconButton:@"play.fill" label:@"Start" action:@selector(primaryAction:)];
    self.playButton.frame = NSMakeRect(33, 4, 24, 24); [controls addSubview:self.playButton];
    NSButton *stop = [self iconButton:@"stop.fill" label:@"Stopp" action:@selector(stop:)];
    stop.frame = NSMakeRect(63, 4, 24, 24); [controls addSubview:stop];
    self.speed = [NSSlider sliderWithValue:1 minValue:0.5 maxValue:4 target:self action:@selector(changeSpeed:)];
    self.speed.continuous = YES; self.speed.accessibilityLabel = @"Wiedergabetempo";
    double saved = [[NSUserDefaults standardUserDefaults] doubleForKey:@"playbackRate"];
    if (saved >= 0.5 && saved <= 4) self.speed.doubleValue = saved;
    self.speed.frame = NSMakeRect(113, 10, 80, 20);
    self.speedLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.2f×", self.speed.doubleValue]];
    self.speedLabel.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium];
    self.speedLabel.frame = NSMakeRect(201, 12, 42, 15); self.speedLabel.accessibilityLabel = @"Aktuelles Tempo";
    self.speedButton = [NSButton buttonWithTitle:self.speedLabel.stringValue target:self action:@selector(showSpeed:)];
    self.speedButton.bordered = NO; self.speedButton.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.speedButton.contentTintColor = NSColor.whiteColor; self.speedButton.frame = NSMakeRect(91, 4, 52, 24);
    self.speedButton.toolTip = @"Tempo wählen · Scrollen ändert das Tempo";
    self.speedButton.accessibilityLabel = @"Tempo wählen"; [controls addSubview:self.speedButton];
    self.settingsButton = [self iconButton:@"gearshape" label:@"Einstellungen" action:@selector(showSettings:)];
    self.settingsButton.frame = NSMakeRect(149, 4, 24, 24); self.settingsButton.hidden = NO;
    [controls addSubview:self.settingsButton];
    self.bufferIndicator = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(10, 8, 16, 16)];
    self.bufferIndicator.style = NSProgressIndicatorStyleSpinning;
    self.bufferIndicator.controlSize = NSControlSizeSmall;
    self.bufferIndicator.displayedWhenStopped = NO;
    self.bufferIndicator.accessibilityLabel = @"Audio wird vorbereitet";
    [controls addSubview:self.bufferIndicator];
    surface.toolTip = @"Scrollen spult · Auf dem Tempo scrollen ändert das Tempo";
    self.status = [NSTextField labelWithString:@"Bereit"];
    self.voiceLabel = [NSTextField labelWithString:@"Thorsten · Deutsch"];
    self.clockLabel = [NSTextField labelWithString:@""];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 12, 264, 90)];
    scroll.borderType = NSBezelBorder; scroll.hasVerticalScroller = YES;
    self.textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 256, 90)];
    self.textView.richText = NO; self.textView.font = [NSFont systemFontOfSize:13];
    self.textView.textContainerInset = NSMakeSize(7, 7); self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.verticallyResizable = YES; self.textView.horizontallyResizable = NO;
    self.textView.textContainer.widthTracksTextView = YES; self.textView.accessibilityLabel = @"Text zum Vorlesen";
    scroll.documentView = self.textView; scroll.hidden = YES; [surface addSubview:scroll]; self.editorView = scroll;
    [self positionWindow];
    __weak AudioApp *weakSelf = self;
    surface.scrollHandler = ^(NSEvent *event) { [weakSelf handleScroll:event]; };
    self.meterTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshMeter];
        [weakSelf checkHealth];
        if (weakSelf.autoClipboard && NSPasteboard.generalPasteboard.changeCount != weakSelf.clipboardChange) {
            weakSelf.clipboardChange = NSPasteboard.generalPasteboard.changeCount;
            NSArray *types = NSPasteboard.generalPasteboard.types;
            BOOL concealed = [types containsObject:@"org.nspasteboard.ConcealedType"] || [types containsObject:@"org.nspasteboard.TransientType"];
            NSString *copied = concealed ? nil : [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            if (UsableText(copied)) [weakSelf startText:copied];
        }
        if (weakSelf.window.visible) {
            BOOL inside = NSPointInRect(NSEvent.mouseLocation, weakSelf.window.frame);
            [weakSelf showLiveText:inside];
        } else [weakSelf showLiveText:NO];
    }];
}
- (void)mouseEntered:(NSEvent *)event { [self showLiveText:YES]; }
- (void)mouseExited:(NSEvent *)event { [self showLiveText:NO]; }
- (void)toggleReadingText:(id)sender {
    self.readingTextPinned = !self.readingTextPinned;
    [[NSUserDefaults standardUserDefaults] setBool:self.readingTextPinned forKey:@"readingTextPinned"];
    [self showLiveText:NO];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleReadingText:))
        item.state = self.readingTextPinned ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}
- (void)primaryAction:(id)sender {
    if (self.player) [self togglePause:nil];
    else if (self.audioDirectory.length) {
        self.streamPaused = !self.streamPaused;
        self.status.stringValue = self.streamPaused ? @"Pausiert" : @"Puffere Audio…";
        [self record:self.streamPaused ? @"paused" : @"resumed"];
        if (!self.streamPaused) [self updateBuffer];
    } else if (!self.task.running) [self generate:nil];
}
- (void)showSpeed:(id)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSNumber *value in @[@0.5, @0.75, @1, @1.25, @1.5, @1.75, @2, @2.5, @3, @3.5, @4]) {
        NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithFormat:@"%g×", value.doubleValue] action:@selector(chooseSpeed:) keyEquivalent:@""];
        item.target = self; item.tag = (NSInteger)(value.doubleValue * 100);
        item.state = fabs(value.doubleValue - self.speed.doubleValue) < 0.01 ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSZeroPoint inView:self.speedButton];
}
- (void)chooseSpeed:(NSMenuItem *)sender { self.speed.doubleValue = sender.tag / 100.0; [self changeSpeed:nil]; }
- (void)handleScroll:(NSEvent *)event {
    NSPoint point = [self.speedButton convertPoint:event.locationInWindow fromView:nil];
    double delta = fabs(event.scrollingDeltaY) >= fabs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX;
    if (fabs(delta) < 0.01) return;
    if (NSPointInRect(point, self.speedButton.bounds)) {
        self.scrollAccumulator += delta;
        double threshold = event.hasPreciseScrollingDeltas ? 6 : 1;
        if (fabs(self.scrollAccumulator) >= threshold) {
            self.speed.doubleValue = fmax(0.5, fmin(4,self.speed.doubleValue + (self.scrollAccumulator > 0 ? 0.25 : -0.25)));
            self.scrollAccumulator = 0; [self changeSpeed:nil];
        }
    } else {
        self.pendingSeek += delta * (event.hasPreciseScrollingDeltas ? 0.08 : 2);
        if (!self.seekTimer) {
            __weak AudioApp *weakSelf = self;
            self.seekTimer = [NSTimer scheduledTimerWithTimeInterval:0.04 repeats:NO block:^(NSTimer *timer) {
                double seconds = weakSelf.pendingSeek; weakSelf.pendingSeek = 0; weakSelf.seekTimer = nil; [weakSelf seekBy:seconds];
            }];
        }
    }
}
- (void)setChunkText:(NSUInteger)index {
    NSString *path = [self.audioDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"chunk-%05lu.json",(unsigned long)index]];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *item = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    self.currentChunkText = [item[@"text"] isKindOfClass:NSString.class] ? item[@"text"] : nil;
}
- (BOOL)shouldShowLiveText:(BOOL)hovered {
    return self.window.visible && (hovered || self.readingTextPinned) && self.currentChunkText.length && self.audioDirectory.length;
}
- (void)showLiveText:(BOOL)hovered {
    if (![self shouldShowLiveText:hovered]) { [self.textPanel orderOut:nil]; return; }
    if (!self.textPanel) {
        self.textPanel = [[FloatingPanel alloc] initWithContentRect:NSMakeRect(0,0,320,106) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
        self.textPanel.releasedWhenClosed = NO; self.textPanel.opaque = NO; self.textPanel.backgroundColor = NSColor.clearColor;
        self.textPanel.level = NSFloatingWindowLevel; self.textPanel.hidesOnDeactivate = NO; self.textPanel.ignoresMouseEvents = YES;
        self.textPanel.contentView.wantsLayer = YES; self.textPanel.contentView.layer.backgroundColor = [NSColor colorWithWhite:0.04 alpha:0.98].CGColor;
        self.textPanel.contentView.layer.cornerRadius = 14;
        self.liveTextLabel = [NSTextField wrappingLabelWithString:@""]; self.liveTextLabel.frame = NSMakeRect(12,10,296,86);
        self.liveTextLabel.font = [NSFont systemFontOfSize:12]; self.liveTextLabel.textColor = NSColor.whiteColor;
        self.liveTextLabel.accessibilityLabel = @"Gerade vorgelesener Abschnitt";
        [self.textPanel.contentView addSubview:self.liveTextLabel];
    }
    self.liveTextLabel.stringValue = self.currentChunkText;
    NSRect frame = self.window.frame;
    CGFloat y = [self.positionMode isEqual:@"bottom"] ? NSMaxY(frame)+6 : NSMinY(frame)-112;
    [self.textPanel setFrameOrigin:NSMakePoint(NSMidX(frame)-160,y)]; [self.textPanel orderFrontRegardless];
}
- (void)seekBy:(double)seconds {
    if (!self.player || !self.audioDirectory.length) return;
    BOOL paused = self.streamPaused || !self.player.playing;
    NSUInteger index = self.nextChunk ? self.nextChunk-1 : 0;
    double target = self.player.currentTime + seconds;
    while (target < 0 && index > 0) {
        index--;
        NSString *path = [self.audioDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"chunk-%05lu.wav",(unsigned long)index]];
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:nil];
        if (!file) return;
        target += file.length/file.processingFormat.sampleRate;
    }
    while (YES) {
        NSString *path = [self.audioDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"chunk-%05lu.wav",(unsigned long)index]];
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:nil];
        if (!file) return;
        double duration = file.length/file.processingFormat.sampleRate;
        NSString *next = [self.audioDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"chunk-%05lu.wav",(unsigned long)(index+1)]];
        if (target >= duration && [[NSFileManager defaultManager] fileExistsAtPath:next]) { target -= duration; index++; continue; }
        if (index == self.nextChunk-1) {
            self.player.currentTime = fmax(0,fmin(target,fmax(0,duration-0.05)));
            [self record:@"seeked"]; break;
        }
        self.player.delegate = nil; [self.player stop];
        LVAudioPlayer *player = [[LVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
        if (!player) { [self stop:nil]; return; }
        self.player = player; player.delegate = self; player.enableRate = YES; player.rate = self.speed.floatValue; player.meteringEnabled = YES;
        player.currentTime = fmax(0,fmin(target,fmax(0,duration-0.05)));
        self.nextChunk = index+1; self.streamPaused = paused; [self setChunkText:index];
        if (!paused && ![player play]) { [self stop:nil]; return; }
        [self record:@"seeked"]; break;
    }
}
- (void)showSettings:(id)sender {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Stimmen & Modelle…" action:@selector(openVoices:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Bereich vorlesen…" action:@selector(ocrAudio:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Zwischenablage vorlesen" action:@selector(clipboardAudio:) keyEquivalent:@""].target = self;
    NSMenuItem *automatic = [menu addItemWithTitle:@"Kopiertes automatisch vorlesen" action:@selector(toggleAutoClipboard:) keyEquivalent:@""];
    automatic.target = self; automatic.state = self.autoClipboard ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItemWithTitle:self.editorView.hidden ? @"Text eingeben…" : @"Texteingabe schließen" action:@selector(toggleEditor:) keyEquivalent:@""].target = self;
    NSMenuItem *reading = [menu addItemWithTitle:@"Lesetext anzeigen" action:@selector(toggleReadingText:) keyEquivalent:@"t"];
    reading.target = self; reading.state = self.readingTextPinned ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *top = [menu addItemWithTitle:@"Oben an der Notch" action:@selector(useNotch:) keyEquivalent:@""]; top.target = self; top.state = [self.positionMode isEqual:@"notch"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *bottom = [menu addItemWithTitle:@"Unten über Aqua" action:@selector(useBottom:) keyEquivalent:@""]; bottom.target = self; bottom.state = [self.positionMode isEqual:@"bottom"] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItemWithTitle:@"Mauszugriff aktivieren…" action:@selector(requestPermission:) keyEquivalent:@""].target = self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Player ausblenden" action:@selector(hideWindow:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Beenden" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:self.settingsButton];
}
- (void)toggleAutoClipboard:(id)sender {
    self.autoClipboard = !self.autoClipboard;
    self.clipboardChange = NSPasteboard.generalPasteboard.changeCount;
    [[NSUserDefaults standardUserDefaults] setBool:self.autoClipboard forKey:@"autoClipboard"];
}
- (void)useNotch:(id)sender { [self applyMode:@"notch"]; }
- (void)useBottom:(id)sender { [self applyMode:@"bottom"]; }
- (void)applyMode:(NSString *)mode {
    self.positionMode = mode;
    [[NSFileManager defaultManager] createDirectoryAtPath:StateDirectory() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    [[NSJSONSerialization dataWithJSONObject:@{@"mode":mode} options:0 error:nil] writeToFile:[StateDirectory() stringByAppendingPathComponent:@"player-mode.json"] atomically:YES];
    [self positionWindow]; [self record:@"mode_changed"];
}
- (void)positionWindow {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visible = screen.visibleFrame; NSRect frame = self.window.frame;
    CGFloat x = NSMidX(visible) - frame.size.width / 2;
    CGFloat y = [self.positionMode isEqual:@"bottom"] ? NSMinY(visible) + 88 : NSMaxY(visible) - frame.size.height - 6;
    [self.window setFrameOrigin:NSMakePoint(x, MAX(NSMinY(visible), y))];
}
- (void)hideWindow:(id)sender { [self.window orderOut:nil]; [self.textPanel orderOut:nil]; }
- (void)toggleEditor:(id)sender {
    BOOL expand = self.editorView.hidden;
    NSRect frame = self.window.frame; frame.size.height = expand ? 142 : 32; frame.size.width = expand ? 288 : 180;
    [self.window setFrame:frame display:YES]; self.editorView.hidden = !expand;
    [self positionWindow]; if (expand) [self.window makeFirstResponder:self.textView];
}
- (void)changeMode:(id)sender {
    self.positionMode = self.modeControl.selectedSegment == 1 ? @"bottom" : @"notch";
    NSDictionary *config = @{@"mode":self.positionMode};
    [[NSFileManager defaultManager] createDirectoryAtPath:StateDirectory() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    [[NSJSONSerialization dataWithJSONObject:config options:0 error:nil] writeToFile:[StateDirectory() stringByAppendingPathComponent:@"player-mode.json"] atomically:YES];
    [self positionWindow]; [self record:@"mode_changed"];
}
- (void)openVoices:(id)sender {
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8769/api/health"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url]; request.timeoutInterval = 2;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *health = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.voiceServer.running && [health[@"instance_token"] isEqual:self.serverToken]) {
                if (!self.settingsWindow) {
                    self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 760)
                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                        backing:NSBackingStoreBuffered defer:NO];
                    self.settingsWindow.title = @"Stimmen & Modelle"; self.settingsWindow.releasedWhenClosed = NO;
                    self.settingsWindow.delegate = self; self.settingsWindow.minSize = NSMakeSize(520, 440);
                    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
                    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
                    self.settingsWebView = [[WKWebView alloc] initWithFrame:self.settingsWindow.contentView.bounds configuration:configuration];
                    self.settingsWebView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                    self.settingsWindow.contentView = self.settingsWebView; [self.settingsWindow center];
                }
                [self.settingsWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:8769"]]];
                [NSApp activateIgnoringOtherApps:YES]; [self.settingsWindow makeKeyAndOrderFront:nil];
            }
            else {
                NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Stimmen nicht erreichbar";
                alert.informativeText = @"Die lokale Stimmenseite ist noch nicht bereit. Bitte die App neu starten.";
                [alert runModal];
            }
        });
    }] resume];
}
- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.settingsWindow)
        [self.settingsWebView evaluateJavaScript:@"document.querySelector('audio')?.pause()" completionHandler:nil];
}
- (void)startVoiceServer {
    if (self.voiceServer.running) return;
    self.lastServerRestart = CFAbsoluteTimeGetCurrent();
    if (![[NSFileManager defaultManager] fileExistsAtPath:Resource(@"voices.json")]) return;
    NSTask *server = [[NSTask alloc] init]; server.executableURL = [NSURL fileURLWithPath:RuntimePython()];
    self.serverToken = NSUUID.UUID.UUIDString;
    server.arguments = @[Resource(@"voice_server.py"), @"--web-dir", Resource(@"web"), @"--catalog", Resource(@"voices.json"), @"--state-dir", StateDirectory(), @"--instance-token", self.serverToken];
    server.standardOutput = [NSFileHandle fileHandleWithNullDevice]; server.standardError = [NSFileHandle fileHandleWithNullDevice];
    server.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if ([server launchAndReturnError:nil]) self.voiceServer = server;
}
- (void)refreshMeter {
    [self updateBuffer];
    BOOL active = self.player.playing;
    BOOL transportActive = self.audioDirectory.length && !self.streamPaused;
    self.playButton.image = [NSImage imageWithSystemSymbolName:transportActive ? @"pause.fill" : @"play.fill" accessibilityDescription:transportActive ? @"Pause" : @"Start"];
    self.playButton.accessibilityLabel = transportActive ? @"Pause" : self.audioDirectory.length ? @"Fortsetzen" : @"Start";
    self.playButton.toolTip = self.playButton.accessibilityLabel;
    BOOL buffering = self.audioDirectory.length && !self.player && !self.streamPaused;
    self.levelView.hidden = buffering;
    if (buffering && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) [self.bufferIndicator startAnimation:nil];
    else [self.bufferIndicator stopAnimation:nil];
    if (buffering && NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) self.levelView.hidden = NO;
    self.levelView.toolTip = self.status.stringValue;
    self.levelView.accessibilityLabel = [NSString stringWithFormat:@"Audiopegel · %@", self.status.stringValue];
    self.window.accessibilityLabel = [NSString stringWithFormat:@"Lokal vorlesen · %@", self.status.stringValue];
    [self.player updateMeters];
    double level = active ? pow(10, [self.player averagePowerForChannel:0] / 35.0) : 0;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) level = active ? 0.3 : 0;
    self.levelView.level = MIN(1, level); self.levelView.active = active; self.levelView.needsDisplay = YES;
    if (self.player) self.clockLabel.stringValue = [NSString stringWithFormat:@"%02d:%02d / %02d:%02d", (int)self.player.currentTime / 60, (int)self.player.currentTime % 60, (int)self.player.duration / 60, (int)self.player.duration % 60];
    else self.clockLabel.stringValue = self.task.running ? @"ERZEUGE…" : @"LOKAL";
    if (++self.ticks % 12 == 0) {
        NSDictionary *config = VoiceConfig();
        NSString *mode = [config[@"mode"] isEqual:@"bottom"] ? @"bottom" : @"notch";
        if (![mode isEqual:self.positionMode]) { self.positionMode = mode; self.modeControl.selectedSegment = [mode isEqual:@"bottom"] ? 1 : 0; [self positionWindow]; }
        NSString *name = self.player || self.task.running ? self.playingVoiceName : config[@"name"];
        self.voiceLabel.stringValue = name.length ? name : @"Thorsten · Deutsch";
    }
}
- (void)buildMenu {
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init]; [main addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Player öffnen" action:@selector(openWindow:) keyEquivalent:@""] .target = self;
    [appMenu addItemWithTitle:@"Textfeld ein-/ausblenden" action:@selector(toggleEditor:) keyEquivalent:@"e"].target = self;
    [appMenu addItemWithTitle:@"Lesetext anzeigen" action:@selector(toggleReadingText:) keyEquivalent:@"t"].target = self;
    [appMenu addItemWithTitle:@"Stimmen & Modelle…" action:@selector(openVoices:) keyEquivalent:@","].target = self;
    [appMenu addItemWithTitle:@"Bereich vorlesen…" action:@selector(ocrAudio:) keyEquivalent:@""].target = self;
    [appMenu addItemWithTitle:@"Zwischenablage vorlesen" action:@selector(clipboardAudio:) keyEquivalent:@""].target = self;
    [appMenu addItemWithTitle:@"Mauszugriff aktivieren…" action:@selector(requestPermission:) keyEquivalent:@""].target = self;
    [appMenu addItemWithTitle:@"Beenden" action:@selector(terminate:) keyEquivalent:@"q"].target = NSApp;
    appItem.submenu = appMenu; NSApp.mainMenu = main;
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Bearbeiten" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Bearbeiten"];
    [edit addItemWithTitle:@"Kopieren" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Einsetzen" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Alles auswählen" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit; [main addItem:editItem];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"▶︎";
    self.statusItem.button.toolTip = @"Generate Audio – lokal";
    NSMenu *statusMenu = [[NSMenu alloc] init];
    [statusMenu addItemWithTitle:@"Generate Audio" action:@selector(openWindow:) keyEquivalent:@""].target = self;
    [statusMenu addItemWithTitle:@"Stimmen & Modelle…" action:@selector(openVoices:) keyEquivalent:@""].target = self;
    [statusMenu addItemWithTitle:@"Zwischenablage abspielen" action:@selector(clipboardAudio:) keyEquivalent:@""].target = self;
    [statusMenu addItemWithTitle:@"Beenden" action:@selector(terminate:) keyEquivalent:@""].target = NSApp;
    self.statusItem.menu = statusMenu;
}
- (void)openWindow:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    self.permissionButton.title = AXIsProcessTrusted() ? @"Mauszugriff aktiv" : @"Mauszugriff aktivieren";
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag { [self openWindow:nil]; return YES; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (void)requestPermission:(id)sender {
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES});
    if (!trusted) {
        self.status.stringValue = @"Bedienungshilfen: „Lokal vorlesen“ erlauben.";
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    } else self.status.stringValue = @"Mauszugriff aktiv. Rechtsklick auf lesbaren Text.";
    self.permissionButton.title = trusted ? @"Mauszugriff aktiv" : @"Text am Mauszeiger aktivieren…";
}
- (void)generate:(id)sender {
    if (!UsableText(self.textView.string) && self.editorView.hidden) [self toggleEditor:nil];
    [self startText:self.textView.string];
}
- (void)clipboardAudio:(id)sender {
    NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    [self startText:text];
}
- (void)ocrAudio:(id)sender {
    [self dismissAccessory];
    [self stop:nil];
    NSUInteger generation = ++self.ocrGeneration;
    [self.window orderOut:nil]; [self.textPanel orderOut:nil];
    [self record:@"ocr_selection_started"];
    if (!self.ocrSelection) self.ocrSelection = [[OCRSelection alloc] init];
    __weak AudioApp *weakSelf = self;
    [self.ocrSelection beginWithCompletion:^(NSString *text, NSError *error) {
        AudioApp *self = weakSelf;
        if (!self || generation != self.ocrGeneration) return;
        [self.window orderFrontRegardless];
        if (UsableText(text)) { [self record:@"ocr_text_captured"]; [self startText:text]; }
        else if (error) {
            [self record:@"ocr_unavailable"];
            NSAlert *alert = [[NSAlert alloc] init]; alert.messageText = @"Bereich konnte nicht vorgelesen werden";
            alert.informativeText = error.localizedDescription; [alert addButtonWithTitle:@"OK"]; [alert runModal];
        } else [self record:@"ocr_cancelled"];
    }];
}
- (void)selectionAudio:(id)sender {
    [self record:@"selection_shortcut_received"];
    if (!AXIsProcessTrusted()) { [self openWindow:nil]; self.status.stringValue = @"Mauszugriff benötigt Bedienungshilfen."; [self requestPermission:nil]; return; }
    pid_t pid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.2);
    id focused = AXValue(app, kAXFocusedUIElementAttribute);
    NSString *text = nil;
    if (focused && CFGetTypeID((__bridge CFTypeRef)focused) == AXUIElementGetTypeID() && SecureElement((__bridge AXUIElementRef)focused)) {
        CFRelease(app); [self record:@"selection_protected"]; return;
    }
    if (focused && CFGetTypeID((__bridge CFTypeRef)focused) == AXUIElementGetTypeID()) {
        text = UsableText(AXValue((__bridge AXUIElementRef)focused, kAXSelectedTextAttribute));
    }
    CFRelease(app);
    if (text) { [self record:@"selection_captured"]; [self startText:text]; }
    else { [self record:@"selection_empty"]; [self ocrAudio:nil]; }
}
- (void)speakSelection:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error {
    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    if (!text.length) text = [pasteboard stringForType:@"NSStringPboardType"];
    if (!UsableText(text)) { if (error) *error = @"Kein lesbarer Text (maximal 100.000 Zeichen)."; return; }
    dispatch_async(dispatch_get_main_queue(), ^{ [self startText:text]; });
}
- (void)clearPlayback {
    [self.seekTimer invalidate]; self.seekTimer = nil; self.pendingSeek = 0;
    [self.player stop]; self.player.delegate = nil; self.player = nil;
    self.streamDone = NO; self.streamPaused = NO; self.nextChunk = 0;
    self.currentChunkText = nil; [self.textPanel orderOut:nil];
    self.silentSince = 0;
    if (self.audioActivity) { [NSProcessInfo.processInfo endActivity:self.audioActivity]; self.audioActivity = nil; }
    RemoveDirectory(self.audioDirectory); self.audioDirectory = nil;
    self.pauseButton.enabled = NO; self.pauseButton.title = @"Pause";
}
- (void)stop:(id)sender {
    self.originalRequestText = nil;
    self.ocrGeneration++; [self.ocrSelection cancel];
    self.request = nil;
    if (self.task) { [self.speechWorker invalidate]; self.speechWorker = nil; }
    self.task = nil;
    [self clearPlayback];
    self.status.stringValue = @"Gestoppt";
    [self record:@"stopped"];
}
- (void)startText:(NSString *)text {
    [self dismissAccessory]; [self.window orderFrontRegardless];
    NSString *usable = UsableText(text);
    if (!usable) { self.status.stringValue = @"Bitte Text eingeben (maximal 100.000 Zeichen)."; return; }
    [self stop:nil]; self.textView.string = usable;
    self.originalRequestText = [usable copy];
    self.automaticRetryUsed = NO;
    if (!BackendReady()) { self.status.stringValue = @"Lokales Modell fehlt. Bitte Einrichtung prüfen."; return; }
    NSString *request = NSUUID.UUID.UUIDString;
    self.playingVoiceName = VoiceConfig()[@"name"] ?: @"Thorsten · Deutsch";
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"LokalVorlesen-" stringByAppendingString:request]];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) {
        self.status.stringValue = @"Temporärer Audioordner konnte nicht angelegt werden."; return;
    }
    NSDictionary *config = VoiceConfig();
    NSString *model = SelectedModel(config);
    NSInteger speaker = MAX(0, MIN(1000, [config[@"speaker"] integerValue]));
    if (![self.speechWorker canReuseModel:model speaker:speaker]) {
        [self.speechWorker invalidate];
        self.speechWorker = [[LVSpeechWorker alloc] initWithPython:RuntimePython() script:Resource(@"tts_worker.py") model:model speaker:speaker error:&error];
    }
    if (!self.speechWorker) {
        RemoveDirectory(directory); self.status.stringValue = @"Lokale Sprachengine konnte nicht starten."; return;
    }
    self.audioDirectory = directory; self.generationStarted = CFAbsoluteTimeGetCurrent();
    self.audioActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical reason:@"Lokale Sprachausgabe"];
    self.task = self.speechWorker.task; self.request = request; self.generationDirectory = directory;
    self.pendingTasks[directory] = self.task;
    self.status.stringValue = @"Erzeuge Audio lokal…"; [self record:@"generating"];
    __weak AudioApp *weakSelf = self;
    [self.speechWorker synthesizeText:usable directory:directory request:request completion:^(BOOL success) {
        AudioApp *strongSelf = weakSelf;
        if (!strongSelf) { RemoveDirectory(directory); return; }
        [strongSelf finishGeneration:success request:request directory:directory];
    }];
}
- (void)finishGeneration:(BOOL)success request:(NSString *)request directory:(NSString *)directory {
    [self.pendingTasks removeObjectForKey:directory];
    // Playback may finish from status.json before the protocol's done event.
    // Release the matching generation independently of the playback token.
    if ([self.generationDirectory isEqualToString:directory]) {
        self.task = nil; self.generationDirectory = nil;
    }
    if (![self.request isEqualToString:request]) { RemoveDirectory(directory); return; }
    if (!success) {
        [self clearPlayback]; RemoveDirectory(directory); self.status.stringValue = @"Audio konnte nicht erzeugt werden.";
        [self record:@"generation_failed"]; return;
    }
    self.streamDone = YES; [self updateBuffer];
}
- (void)togglePause:(id)sender {
    if (!self.player) return;
    if (self.player.playing) {
        self.streamPaused = YES; [self.player pause]; self.pauseButton.title = @"Fortsetzen"; self.status.stringValue = @"Pausiert"; [self record:@"paused"];
    } else {
        self.streamPaused = NO;
        if ([self.player play]) {
            self.pauseButton.title = @"Pause"; self.status.stringValue = @"Wiedergabe"; [self record:@"resumed"];
        }
    }
}
- (void)checkHealth {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.voiceServer && !self.voiceServer.running && self.serverRestarts < 3 && now-self.lastServerRestart > 60) {
        self.serverRestarts++; [self record:@"voice_server_restarted"]; [self startVoiceServer];
    }
    if (!self.task.running || self.player || self.streamPaused) { self.silentSince = 0; return; }
    if (!self.silentSince) self.silentSince = now;
    // Recover only an unstarted request. Never interrupt active or paused audio/OCR.
    if (self.nextChunk == 0 && now-self.silentSince > 30 && self.automaticRetryUsed) {
        [self stop:nil]; self.status.stringValue = @"Sprachengine reagiert nicht. Bitte erneut starten."; [self record:@"generation_recovery_failed"]; return;
    }
    if (self.nextChunk == 0 && now-self.silentSince > 30 && !self.automaticRetryUsed && now-self.lastAutomaticRetry > 120) {
        NSString *text = self.originalRequestText;
        self.lastAutomaticRetry = now; [self record:@"generation_stalled_retry"]; [self startText:text]; self.automaticRetryUsed = YES;
    }
}
- (void)changeSpeed:(id)sender {
    double rate = fmax(0.5, fmin(4, self.speed.doubleValue));
    self.player.rate = rate; self.speedLabel.stringValue = [NSString stringWithFormat:@"%.2f×", rate];
    self.speedButton.title = self.speedLabel.stringValue;
    [[NSUserDefaults standardUserDefaults] setDouble:rate forKey:@"playbackRate"];
    [self record:@"rate_changed"];
}
- (void)updateBuffer {
    if (!self.audioDirectory.length || self.player || self.streamPaused) return;
    NSData *data = [NSData dataWithContentsOfFile:[self.audioDirectory stringByAppendingPathComponent:@"status.json"]];
    NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSUInteger count = [state[@"count"] unsignedIntegerValue];
    if (self.nextChunk < count) {
        NSString *path = [self.audioDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"chunk-%05lu.wav", (unsigned long)self.nextChunk]];
        NSError *error = nil;
        LVAudioPlayer *player = [[LVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
        if (!player) { [self stop:nil]; self.status.stringValue = @"Audiopuffer konnte nicht gelesen werden."; return; }
        self.player = player; player.delegate = self; player.enableRate = YES; player.rate = self.speed.floatValue; player.meteringEnabled = YES;
        [player prepareToPlay];
        if (![player play]) { [self stop:nil]; self.status.stringValue = @"Audioausgabe konnte nicht starten."; return; }
        [self setChunkText:self.nextChunk];
        self.nextChunk++;
        self.status.stringValue = @"Wiedergabe · gepuffert";
        if (self.nextChunk == 1) {
            [self record:[NSString stringWithFormat:@"first_audio_%.0fms", (CFAbsoluteTimeGetCurrent() - self.generationStarted) * 1000]];
            [self record:@"playing"];
        } else [self record:@"buffer_playing"];
    } else if ((self.streamDone || [state[@"done"] boolValue]) && self.nextChunk >= count) {
        [self record:@"finished"]; [self clearPlayback]; self.request = nil; self.status.stringValue = @"Fertig";
    }
}
- (void)audioPlayerDidFinishPlaying:(LVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != self.player) return;
    self.player.delegate = nil; self.player = nil;
    if (!flag) { [self stop:nil]; self.status.stringValue = @"Wiedergabe fehlgeschlagen"; return; }
    [self updateBuffer];
}
- (void)dismissAccessory {
    [self.actionPanel orderOut:nil]; [self.accessoryTimer invalidate]; self.accessoryTimer = nil; self.hoverText = nil;
}
- (void)captureAtMouse {
    [self dismissAccessory];
    if (!AXIsProcessTrusted()) return;
    NSPoint mouse = NSEvent.mouseLocation;
    CGPoint point = CGPointMake(mouse.x, CGDisplayBounds(CGMainDisplayID()).size.height - mouse.y);
    AXUIElementRef system = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(system, 0.15);
    AXUIElementRef hit = NULL;
    if (AXUIElementCopyElementAtPosition(system, point.x, point.y, &hit) != kAXErrorSuccess || !hit) { CFRelease(system); return; }
    AXUIElementSetMessagingTimeout(hit, 0.15);
    pid_t pid = 0; AXUIElementGetPid(hit, &pid);
    if (pid == NSProcessInfo.processInfo.processIdentifier || SecureElement(hit)) { CFRelease(hit); CFRelease(system); return; }
    NSString *text = UsableText(AXValue(hit, kAXSelectedTextAttribute));
    if (!text) {
        NSString *role = AXValue(hit, kAXRoleAttribute);
        if ([role isEqualToString:(__bridge NSString *)kAXStaticTextRole] ||
            [role isEqualToString:(__bridge NSString *)kAXTextFieldRole] ||
            [role isEqualToString:(__bridge NSString *)kAXTextAreaRole]) text = UsableText(AXValue(hit, kAXValueAttribute));
        if (!text) text = UsableText(AXValue(hit, kAXTitleAttribute));
    }
    CFRelease(hit); CFRelease(system);
    if (!text) return;
    self.hoverText = text;
    if (!self.actionPanel) {
        self.actionPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 166, 40)
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        self.actionPanel.level = NSPopUpMenuWindowLevel + 1;
        self.actionPanel.hidesOnDeactivate = NO; self.actionPanel.hasShadow = YES;
        self.actionPanel.backgroundColor = NSColor.windowBackgroundColor;
        NSButton *button = [self button:@"▶ Generate Audio" action:@selector(hoverAudio:)];
        button.frame = NSMakeRect(4, 4, 158, 32); self.actionPanel.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 166, 40)];
        [self.actionPanel.contentView addSubview:button];
    }
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *candidate in NSScreen.screens) if (NSPointInRect(mouse, candidate.frame)) screen = candidate;
    NSRect visible = screen.visibleFrame;
    NSPoint origin = NSMakePoint(fmax(NSMinX(visible), fmin(mouse.x - 170, NSMaxX(visible) - 166)),
                                 fmax(NSMinY(visible), fmin(mouse.y + 12, NSMaxY(visible) - 40)));
    [self.actionPanel setFrameOrigin:origin]; [self.actionPanel orderFrontRegardless];
    __weak AudioApp *weakSelf = self;
    self.accessoryTimer = [NSTimer scheduledTimerWithTimeInterval:8 repeats:NO block:^(NSTimer *timer) { [weakSelf dismissAccessory]; }];
}
- (void)hoverAudio:(id)sender {
    NSString *text = self.hoverText;
    [self startText:text];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.meterTimer invalidate];
    if (self.voiceServer.running) [self.voiceServer terminate];
    if (self.voiceServer.running) [self.voiceServer waitUntilExit];
    [self stop:nil];
    [self.speechWorker shutdownAndWait]; self.speechWorker = nil;
    NSDictionary<NSString *, NSTask *> *pending = [self.pendingTasks copy];
    for (NSString *directory in pending) {
        NSTask *task = pending[directory];
        if (task.running) [task terminate];
        if (task.running) [task waitUntilExit];
        RemoveDirectory(directory);
    }
    [self.pendingTasks removeAllObjects]; [self dismissAccessory];
    if (self.mouseMonitor) [NSEvent removeMonitor:self.mouseMonitor];
    if (self.dismissMonitor) [NSEvent removeMonitor:self.dismissMonitor];
    if (self.hotKey) UnregisterEventHotKey(self.hotKey);
    if (self.selectionHotKey) UnregisterEventHotKey(self.selectionHotKey);
    if (self.ocrHotKey) UnregisterEventHotKey(self.ocrHotKey);
    [self.ocrSelection cancel];
    if (self.hotKeyHandler) RemoveEventHandler(self.hotKeyHandler);
}
@end

static int RenderTest(NSString *output) {
    if (!BackendReady()) return 2;
    NSPipe *input = [NSPipe pipe]; NSTask *task = BackendTask(output, input); NSError *error = nil;
    if (![task launchAndReturnError:&error]) return 3;
    [input.fileHandleForWriting writeData:[@"Ich spreche Deutsch. Diese Stimme entsteht lokal auf deinem Mac. Grüße aus Österreich." dataUsingEncoding:NSUTF8StringEncoding]];
    [input.fileHandleForWriting closeFile]; [task waitUntilExit];
    if (task.terminationStatus) return task.terminationStatus;
    LVAudioPlayer *player = [[LVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:output] error:&error];
    if (!player || player.duration <= 0) return 4;
    player.enableRate = YES; player.rate = 0.5;
    BOOL slow = fabs(player.rate - 0.5) < 0.01; player.rate = 2;
    BOOL fast = fabs(player.rate - 2) < 0.01;
    NSDictionary *report = @{@"ok":@(slow && fast), @"backend":@"Piper Thorsten low INT8", @"duration":@(player.duration), @"rate_range":@[@0.5,@2], @"gui_tested":@NO};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
    return slow && fast ? 0 : 5;
}
int main(int argc, const char *argv[]) {
    signal(SIGPIPE, SIG_IGN);
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
            printf("{\"backend_ready\":%s,\"gui_tested\":false}\n", BackendReady() ? "true" : "false");
            return BackendReady() ? 0 : 2;
        }
        if (argc == 3 && strcmp(argv[1], "--render-test") == 0) return RenderTest([NSString stringWithUTF8String:argv[2]]);
        NSApplication *app = NSApplication.sharedApplication;
        AudioApp *delegate = [[AudioApp alloc] init]; app.delegate = delegate; [app run];
    }
    return 0;
}
