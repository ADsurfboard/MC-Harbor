    // The dedicated UI renderer owns its JNI thread and exits when it is cancelled.
    SurfaceView *renderer = surfaceView;
    self.harborFrameSurface = renderer;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        [renderer harborRunFrameLoop];
    }];
    thread.name = @"MC Harbor Java installer renderer";
    self.harborFrameThread = thread;
    [thread start];

