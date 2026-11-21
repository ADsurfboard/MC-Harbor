- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.harborInputLink.paused = YES;
}

- (void)harborRemoveInputObservers {
    [self.harborInputLink invalidate];
    self.harborInputLink = nil;
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    id tokens[] = { self.mouseConnectCallback, self.mouseDisconnectCallback,
                   self.controllerConnectCallback, self.controllerDisconnectCallback };
    for (NSUInteger index = 0; index < sizeof(tokens) / sizeof(tokens[0]); index++) {
        if (tokens[index]) [notifications removeObserver:tokens[index]];
    }
    self.mouseConnectCallback = nil;
    self.mouseDisconnectCallback = nil;
    self.controllerConnectCallback = nil;
    self.controllerDisconnectCallback = nil;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.view.window || self.harborCleanedInput) return;
    self.harborCleanedInput = YES;
    [self harborRemoveInputObservers];
    if (pojavWindow == self.surfaceView) {
        for (GCMouse *mouse in GCMouse.mice) {
            GCMouseInput *input = mouse.mouseInput;
            input.mouseMovedHandler = nil;
            input.leftButton.pressedChangedHandler = nil;
            input.middleButton.pressedChangedHandler = nil;
            input.rightButton.pressedChangedHandler = nil;
            [input.auxiliaryButtons makeObjectsPerformSelector:@selector(setPressedChangedHandler:) withObject:nil];
            input.scroll.xAxis.valueChangedHandler = nil;
            input.scroll.yAxis.valueChangedHandler = nil;
        }
        for (GCController *controller in GCController.controllers) {
            [ControllerInput unregisterControllerCallbacks:controller];
        }
        pojavWindow = nil;
        UIApplication.sharedApplication.idleTimerDisabled = NO;
        HBRNotifyGameStopped();
    }
}

- (void)dealloc {
    [self harborRemoveInputObservers];
}

- (void)updateAudioSettings {
