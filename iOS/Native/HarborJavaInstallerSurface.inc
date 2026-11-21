@interface SurfaceView () {
    JNIEnv *surfaceJNIEnv;
    JavaVM *surfaceVM;
    jclass class_CTCScreen;
    jmethodID method_GetRGB;
}
@property(nonatomic) CGColorSpaceRef colorSpace;
@property(atomic) BOOL harborVisible;
@property(atomic) BOOL harborFramePending;
- (void)harborRunFrameLoop;
@end

@implementation SurfaceView

- (BOOL)harborAttachRenderer {
    if (surfaceJNIEnv) return method_GetRGB != NULL;
    surfaceVM = runtimeJavaVMPtr;
    if (!surfaceVM || (*surfaceVM)->AttachCurrentThread(surfaceVM, &surfaceJNIEnv, NULL) != JNI_OK) return NO;
    JavaVM *vm = surfaceVM;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (runtimeJavaVMPtr == vm && !runtimeJNIEnvPtr) {
            (*vm)->AttachCurrentThread(vm, &runtimeJNIEnvPtr, NULL);
        }
    });
    class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "net/java/openjdk/cacio/ctc/CTCScreen");
    if ((*surfaceJNIEnv)->ExceptionCheck(surfaceJNIEnv)) {
        (*surfaceJNIEnv)->ExceptionClear(surfaceJNIEnv);
        class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "com/github/caciocavallosilano/cacio/ctc/CTCScreen");
    }
    if (class_CTCScreen) {
        method_GetRGB = (*surfaceJNIEnv)->GetStaticMethodID(surfaceJNIEnv, class_CTCScreen, "getCurrentScreenRGB", "()[I");
    }
    if ((*surfaceJNIEnv)->ExceptionCheck(surfaceJNIEnv)) (*surfaceJNIEnv)->ExceptionClear(surfaceJNIEnv);
    return method_GetRGB != NULL;
}

- (void)refreshBuffer {
    if (!self.harborVisible || self.harborFramePending || ![self harborAttachRenderer] || runtimeJavaVMPtr != surfaceVM) return;
    jintArray array = (jintArray)(*surfaceJNIEnv)->CallStaticObjectMethod(surfaceJNIEnv, class_CTCScreen, method_GetRGB);
    if ((*surfaceJNIEnv)->ExceptionCheck(surfaceJNIEnv)) {
        (*surfaceJNIEnv)->ExceptionClear(surfaceJNIEnv);
        if (array) (*surfaceJNIEnv)->DeleteLocalRef(surfaceJNIEnv, array);
        return;
    }
    if (!array) return;
    NSInteger width = windowWidth, height = windowHeight;
    NSUInteger count = width > 0 && height > 0 && width <= 8192 && height <= 8192 ? (NSUInteger)width * height : 0;
    NSMutableData *frame = nil;
    if (count > 0 && count <= 16 * 1024 * 1024 && (NSUInteger)(*surfaceJNIEnv)->GetArrayLength(surfaceJNIEnv, array) >= count) {
        frame = [NSMutableData dataWithLength:count * sizeof(jint)];
        (*surfaceJNIEnv)->GetIntArrayRegion(surfaceJNIEnv, array, 0, (jsize)count, frame.mutableBytes);
        if ((*surfaceJNIEnv)->ExceptionCheck(surfaceJNIEnv)) {
            (*surfaceJNIEnv)->ExceptionClear(surfaceJNIEnv);
            frame = nil;
        }
    }
    // An attached native thread has no Java return boundary to clear local references.
    (*surfaceJNIEnv)->DeleteLocalRef(surfaceJNIEnv, array);
    if (!frame) return;
    const jint *pixels = frame.bytes;
    BOOL middleIsVisible = pixels[(height / 2) * width + width / 2] != 0;
    self.harborFramePending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.harborFramePending = NO;
        if (!self.harborVisible) return;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)frame);
        if (!provider) return;
        CGImageRef bitmap = CGImageCreate(width, height, 8, 32, sizeof(jint) * width,
            self.colorSpace, kCGImageAlphaFirst | kCGBitmapByteOrder32Little,
            provider, NULL, false, kCGRenderingIntentDefault);
        if (bitmap) {
            self.layer.contents = (__bridge id)bitmap;
            CGImageRelease(bitmap);
        }
        CGDataProviderRelease(provider);
        if (shouldHitEnterAfterWindowShown && middleIsVisible) {
            shouldHitEnterAfterWindowShown = NO;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (weakSelf.harborVisible) AWTInputBridge_sendKey('\n');
            });
        }
    });
}

- (void)harborRunFrameLoop {
    @autoreleasepool {
        NSThread *thread = NSThread.currentThread;
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(refreshBuffer)];
        int framesPerSecond = getPrefBool(@"video.max_framerate") ? 120 : 60;
        link.preferredFrameRateRange = CAFrameRateRangeMake(30, framesPerSecond, framesPerSecond);
        NSRunLoop *runLoop = NSRunLoop.currentRunLoop;
        [link addToRunLoop:runLoop forMode:NSDefaultRunLoopMode];
        while (!thread.cancelled) {
            @autoreleasepool {
                if (![runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]]) {
                    [NSThread sleepForTimeInterval:0.05];
                }
            }
        }
        [link invalidate];
        if (surfaceJNIEnv && runtimeJavaVMPtr == surfaceVM) {
            if (class_CTCScreen) (*surfaceJNIEnv)->DeleteLocalRef(surfaceJNIEnv, class_CTCScreen);
            (*surfaceVM)->DetachCurrentThread(surfaceVM);
        }
        surfaceJNIEnv = NULL;
    }
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.opaque = YES;
        self.colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    if (_colorSpace) CGColorSpaceRelease(_colorSpace);
}
@end

