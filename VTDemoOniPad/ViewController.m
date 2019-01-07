//
//  ViewController.m
//  VTDemoOniPad
//
//  Created by AJB on 16/4/25.
//  Copyright © 2016年 AJB. All rights reserved.
//

#import "ViewController.h"

#import "VideoFileParser.h"
#import "AAPLEAGLLayer.h"
#import <VideoToolbox/VideoToolbox.h>

#define WIDTH_RATIO 0.85f

@interface ViewController ()
{
    // 인코딩
    VTHwEncoderImpl *vtEncoder;
    AVCaptureSession *captureSession;
    bool startCalled;
    NSString *h264FileSavePath;
    NSFileHandle *fileHandle;

    // 디코딩
    NSMutableArray<NSData*> *filePslist;
    VTDecompressionSessionRef _deocderSession;
    CMVideoFormatDescriptionRef _decoderFormatDescription;
    bool playCalled;
}

@property (weak, nonatomic) IBOutlet UIButton *startStopBtn;
@property (weak, nonatomic) IBOutlet UIButton *playerBtn;

@property (weak, nonatomic) IBOutlet UIView *largeView;
@property (weak, nonatomic) IBOutlet UIView *smallView;
@property (weak, nonatomic) IBOutlet UIButton *smallViewBtn;
@property (weak, nonatomic) IBOutlet UILabel *largeLabel;
@property (weak, nonatomic) IBOutlet UILabel *smallLabel;
@property (weak, nonatomic) IBOutlet UIButton *codecTypeBtn;
@property (weak, nonatomic) IBOutlet UILabel *curCodecLabel;


@property (nonatomic) BOOL useSmallView;

@property (strong, nonatomic) AVCaptureVideoPreviewLayer *previewLayer;
@property (strong, nonatomic) AVSampleBufferDisplayLayer *sbDisplayLayer;
@property (nonatomic) dispatch_queue_t aQueue;

@property (nonatomic) BOOL useHEVC;

@property (nonatomic) int cameraWidth;
@property (nonatomic) int cameraHeight;

@end

// decode callback
static void didDecompress( void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef pixelBuffer, CMTime presentationTimeStamp, CMTime presentationDuration ){
#if DIRECT_DECODE
    if(pixelBuffer) {
        CVPixelBufferRetain(pixelBuffer);
        dispatch_sync(dispatch_get_main_queue(), ^{
            ((__bridge ViewController*)sourceFrameRefCon).glLayer.pixelBuffer = pixelBuffer;
            CVPixelBufferRelease(pixelBuffer);
        });
    } else {
        // kVTVideoDecoderBadDataErr
        NSLog(@"decode error %d", (int)status);
    }
#else
    CVPixelBufferRef *outputPixelBuffer = (CVPixelBufferRef *)sourceFrameRefCon;
    *outputPixelBuffer = CVPixelBufferRetain(pixelBuffer);
#endif
}

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    vtEncoder = [VTHwEncoderImpl alloc];
    [vtEncoder initWithConfiguration];
    startCalled = true;
    playCalled = true;
    _useSmallView = NO;
    _useHEVC = NO;
    _curCodecLabel.text = @"";
    _cameraWidth = 0;
    _cameraHeight = 0;
    _aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
#if DIRECT_DECODE
    _playerBtn.hidden = YES;
#else
    // 파일 저장 위치
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    h264FileSavePath = [documentsDirectory stringByAppendingPathComponent:@"test.h264"];
    [fileManager removeItemAtPath:h264FileSavePath error:nil];
    [fileManager createFileAtPath:h264FileSavePath contents:nil attributes:nil];
    
    filePslist = [NSMutableArray array];
#endif
}

- (void)moveDecodeViewToTargetView:(UIView*)targetView {
    if (!_glLayer) {
        float width = targetView.frame.size.width;
        float height = width * 16.f/9.f;
        _glLayer = [[AAPLEAGLLayer alloc] initWithFrame:CGRectMake(0, 0, width, height)];
    }

    [_glLayer removeFromSuperlayer];
    
    float width = targetView.frame.size.width;
    float height = width * 16.f/9.f;
    _glLayer.frame = CGRectMake(0, 0, width, height);

    [targetView.layer addSublayer:_glLayer];
}

- (void)movePreviewViewToTargetView:(UIView*)targetView {
    if (!_sbDisplayLayer) {
        _sbDisplayLayer = [[AVSampleBufferDisplayLayer alloc]init];
        _sbDisplayLayer.backgroundColor = [UIColor blackColor].CGColor;
        _sbDisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    }
    
    [_sbDisplayLayer removeFromSuperlayer];
    
    float width = targetView.frame.size.width;
    float height = width * 16.f/9.f;
    _sbDisplayLayer.frame = CGRectMake(0, 0, width, height);
    
    [targetView.layer addSublayer:_sbDisplayLayer];
}

// MARK: - Actions

- (IBAction)PlayAction:(id)sender {
#if DIRECT_DECODE
#else
    if (playCalled) {
        playCalled = false;
        [_playerBtn setTitle:@"close" forState:UIControlStateNormal];
        
        [self moveDecodeViewToTargetView:self.largeView];
        
        dispatch_async(_aQueue, ^{
            [self decodeFile:@"test" fileExt:@"h264"];
        });
    } else {
        playCalled = true;
        [_playerBtn setTitle:@"play" forState:UIControlStateNormal];
        [self clearVTDecoder];
        [_glLayer removeFromSuperlayer];
    }
#endif
}

// Called when start/stop button is pressed
- (IBAction) StartStopAction:(id)sender {
    if (startCalled) {
        BOOL start = [self startEncode];
        if (start) {
            startCalled = false;
            [_startStopBtn setTitle:@"Stop" forState:UIControlStateNormal];
            
            NSString* codec = _useHEVC? @"HEVC" : @"H264";
            _curCodecLabel.text = [NSString stringWithFormat:@"%dx%d (%@)", _cameraHeight, _cameraWidth, codec];
            _curCodecLabel.hidden = NO;
            
            _codecTypeBtn.hidden = YES;
        } else {
            _curCodecLabel.hidden = YES;
            _codecTypeBtn.hidden = NO;
        }
    } else {
        [_startStopBtn setTitle:@"Start" forState:UIControlStateNormal];
        startCalled = true;
        [self stopEncode];
        [vtEncoder End];
#if DIRECT_DECODE
        [self clearVTDecoder];
#endif
        self.smallLabel.text = @"";
        self.largeLabel.text = @"";
        
        _curCodecLabel.hidden = YES;
        _codecTypeBtn.hidden = NO;
    }
}
- (IBAction)toggleSmallBtn:(UIButton*)sender {
    sender.selected = !(sender.selected);
    if (sender.selected) {
        [self moveDecodeViewToTargetView:self.smallView];
        [self movePreviewViewToTargetView:self.largeView];
        
        self.smallLabel.text = @"encoded";
        self.largeLabel.text = @"camera";
    } else {
        [self moveDecodeViewToTargetView:self.largeView];
        [self movePreviewViewToTargetView:self.smallView];
        
        self.smallLabel.text = @"camera";
        self.largeLabel.text = @"encoded";
    }
}

- (IBAction)toggleCodec:(UIButton*)sender {
    sender.selected = !(sender.selected);
    _useHEVC = sender.selected;
}

#pragma mark - Decode

//-(BOOL)initVTDecoder {
//    if(_deocderSession) {
//        return YES;
//    }
//
//    const uint8_t* const parameterSetPointers[2] = { _sps, _pps };
//    const size_t parameterSetSizes[2] = { _spsSize, _ppsSize };
//    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
//                                                                          2, //param count
//                                                                          parameterSetPointers,
//                                                                          parameterSetSizes,
//                                                                          4, //nal start code size
//                                                                          &_decoderFormatDescription);
//
//    if(status == noErr) {
//        CFDictionaryRef attrs = NULL;
//        const void *keys[] = { kCVPixelBufferPixelFormatTypeKey };
//
//        //      kCVPixelFormatType_420YpCbCr8Planar is YUV420
//        //      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange is NV12
//        uint32_t v = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
//        const void *values[] = { CFNumberCreate(NULL, kCFNumberSInt32Type, &v) };
//        attrs = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
//
//        VTDecompressionOutputCallbackRecord callBackRecord;
//        callBackRecord.decompressionOutputCallback = didDecompress;
//        callBackRecord.decompressionOutputRefCon = NULL;
//
//        status = VTDecompressionSessionCreate(kCFAllocatorDefault,
//                                              _decoderFormatDescription,
//                                              NULL, attrs,
//                                              &callBackRecord,
//                                              &_deocderSession);
//        CFRelease(attrs);
//    } else {
//        NSLog(@"video format create failed status=%d", (int)status);
//        _deocderSession = nil;
//        return NO;
//    }
//
//    return YES;
//}

-(BOOL)initVTDecoderWithPsList:(NSArray<NSData*>*)psList {
    if(_deocderSession) {
        return YES;
    }
    
    OSStatus status = noErr;
    if (_useHEVC) {
        const uint8_t* const parameterSetPointers[3] = { psList[0].bytes, psList[1].bytes, psList[2].bytes };
        const size_t parameterSetSizes[3] = { psList[0].length, psList[1].length, psList[2].length };
        status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                      3, //param count
                                                                      parameterSetPointers,
                                                                      parameterSetSizes,
                                                                      4, //nal start code size
                                                                      NULL,
                                                                      &_decoderFormatDescription);
    } else {
        const uint8_t* const parameterSetPointers[2] = { psList[0].bytes, psList[1].bytes };
        const size_t parameterSetSizes[2] = { psList[0].length, psList[1].length };
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                      2, //param count
                                                                      parameterSetPointers,
                                                                      parameterSetSizes,
                                                                      4, //nal start code size
                                                                      &_decoderFormatDescription);
    }
    if(status == noErr) {
        CFDictionaryRef attrs = NULL;
        const void *keys[] = { kCVPixelBufferPixelFormatTypeKey };
        //      kCVPixelFormatType_420YpCbCr8Planar is YUV420
        //      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange is NV12
        uint32_t v = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        const void *values[] = { CFNumberCreate(NULL, kCFNumberSInt32Type, &v) };
        attrs = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
        
        VTDecompressionOutputCallbackRecord callBackRecord;
        callBackRecord.decompressionOutputCallback = didDecompress;
        callBackRecord.decompressionOutputRefCon = NULL;
        
        status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                              _decoderFormatDescription,
                                              NULL, attrs,
                                              &callBackRecord,
                                              &_deocderSession);
        CFRelease(attrs);
        if (status != noErr) {
            NSLog(@"VTDecompressionSessionCreate failed statud=%d", (int)status);
            return NO;
        }
    } else {
        NSLog(@"video format create failed status=%d", (int)status);
        _deocderSession = nil;
        return NO;
    }
    
    return YES;
}

-(void)clearVTDecoder {
    dispatch_async(_aQueue, ^{
        [self internalClearVTDecoder];
    });
}

- (void)internalClearVTDecoder {
    if(_deocderSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_deocderSession);
        VTDecompressionSessionInvalidate(_deocderSession);
        CFRelease(_deocderSession);
        _deocderSession = NULL;
    }
    
    if(_decoderFormatDescription) {
        CFRelease(_decoderFormatDescription);
        _decoderFormatDescription = NULL;
    }
}

-(CVPixelBufferRef)decode:(VideoPacket*)vp {
    CVPixelBufferRef outputPixelBuffer = NULL;
    
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status  = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                          (void*)vp.buffer, vp.size,
                                                          kCFAllocatorNull,
                                                          NULL, 0, vp.size,
                                                          0, &blockBuffer);
    if(status == kCMBlockBufferNoErr) {
        CMSampleBufferRef sampleBuffer = NULL;
        const size_t sampleSizeArray[] = {vp.size};
        status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                           blockBuffer,
                                           _decoderFormatDescription ,
                                           1, 0, NULL, 1, sampleSizeArray,
                                           &sampleBuffer);
        if (status == kCMBlockBufferNoErr && sampleBuffer) {
            VTDecodeFrameFlags flags = 0;
            VTDecodeInfoFlags flagOut = 0;
            OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_deocderSession,
                                                                      sampleBuffer,
                                                                      flags,
                                                                      &outputPixelBuffer,
                                                                      &flagOut);
            
            if(decodeStatus == kVTInvalidSessionErr) {
                NSLog(@"Invalid session, reset decoder session");
            } else if(decodeStatus == kVTVideoDecoderBadDataErr) {
                NSLog(@"decode failed status=%d(Bad data)", (int)decodeStatus);
            } else if(decodeStatus != noErr) {
                NSLog(@"decode failed status=%d", (int)decodeStatus);
            }
            
            CFRelease(sampleBuffer);
        }
        CFRelease(blockBuffer);
    }
    
    return outputPixelBuffer;
}

-(void)decodeVp:(VideoPacket*)vp {
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status  = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                          (void*)vp.buffer, vp.size,
                                                          kCFAllocatorNull,
                                                          NULL, 0, vp.size,
                                                          0, &blockBuffer);
    if(status == kCMBlockBufferNoErr) {
        CMSampleBufferRef sampleBuffer = NULL;
        const size_t sampleSizeArray[] = {vp.size};
        status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                           blockBuffer,
                                           _decoderFormatDescription ,
                                           1, 0, NULL, 1, sampleSizeArray,
                                           &sampleBuffer);
        if (status == kCMBlockBufferNoErr && sampleBuffer) {
            VTDecodeFrameFlags flags = 0;
            VTDecodeInfoFlags flagOut = 0;
            OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_deocderSession,
                                                                      sampleBuffer,
                                                                      flags,
                                                                      (__bridge void *)(self),
                                                                      &flagOut);
            
            if(decodeStatus == kVTInvalidSessionErr) {
                NSLog(@"Invalid session, reset decoder session");
            } else if(decodeStatus == kVTVideoDecoderBadDataErr) {
                NSLog(@"decode failed status=%d(Bad data)", (int)decodeStatus);
            } else if(decodeStatus != noErr) {
                NSLog(@"decode failed status=%d", (int)decodeStatus);
            }
            
            CFRelease(sampleBuffer);
        }
        CFRelease(blockBuffer);
    }
}

-(void)decodeFile:(NSString*)fileName fileExt:(NSString*)fileExt {
    VideoFileParser *parser = [VideoFileParser alloc];
    [parser open:h264FileSavePath];
    
    VideoPacket *vp = nil;
    while(true) {
        vp = [parser nextPacket];
        if(vp == nil) {
            break;
        }
        
        uint32_t nalSize = (uint32_t)(vp.size - 4);
        uint8_t *pNalSize = (uint8_t*)(&nalSize);
        vp.buffer[0] = *(pNalSize + 3);
        vp.buffer[1] = *(pNalSize + 2);
        vp.buffer[2] = *(pNalSize + 1);
        vp.buffer[3] = *(pNalSize);
        
        CVPixelBufferRef pixelBuffer = NULL;
        int nalType = vp.buffer[4] & 0x1F;
        switch (nalType) {
            case 0x05:
                NSLog(@"Nal type is IDR frame");
                if([self initVTDecoderWithPsList:filePslist]) {
                    pixelBuffer = [self decode:vp];
                }
                break;
            case 0x07: {
                NSLog(@"Nal type is SPS");
//                _spsSize = vp.size - 4;
//                _sps = malloc(_spsSize);
//                memcpy(_sps, vp.buffer + 4, _spsSize);
                NSData* sps = [NSData dataWithBytes:(vp.buffer + 4) length:(vp.size - 4)];
                [filePslist addObject:sps];
                break;
            }
            case 0x08: {
                NSLog(@"Nal type is PPS");
//                _ppsSize = vp.size - 4;
//                _pps = malloc(_ppsSize);
//                memcpy(_pps, vp.buffer + 4, _ppsSize);
                NSData* pps = [NSData dataWithBytes:(vp.buffer + 4) length:(vp.size - 4)];
                [filePslist addObject:pps];
                break;
            }
            default:
                NSLog(@"Nal type is B/P frame");
                pixelBuffer = [self decode:vp];
                break;
        }
        
        if(pixelBuffer) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                self.glLayer.pixelBuffer = pixelBuffer;
            });
            
            CVPixelBufferRelease(pixelBuffer);
        }
//        NSLog(@"Read Nalu size %ld", (long)vp.size);
    }
    [parser close];
}

#pragma mark - Encode

- (BOOL) startEncode {
    _cameraWidth = 0;
    _cameraHeight = 0;
    
    if (![self startCamera]) {
        return NO;
    }
    
#if DIRECT_DECODE
    [self moveDecodeViewToTargetView:self.largeView];
    [self movePreviewViewToTargetView:self.smallView];
    
    self.smallViewBtn.selected = NO;
    self.smallLabel.text = @"camera";
    self.largeLabel.text = @"encoded";
#else
    // preview display
    [self movePreviewViewToTargetView:self.largeView];
    fileHandle = [NSFileHandle fileHandleForWritingAtPath:h264FileSavePath];
#endif
    
    [vtEncoder initEncode:_cameraHeight height:_cameraWidth hevc:_codecTypeBtn.selected];
    vtEncoder.delegate = self;
    
    return YES;
}

- (void) stopEncode {
    [captureSession stopRunning];
    [_previewLayer removeFromSuperlayer];

#if DIRECT_DECODE
    [_glLayer removeFromSuperlayer];
    [_sbDisplayLayer removeFromSuperlayer];
#else
    [fileHandle closeFile];
    fileHandle = NULL;
    
    [_sbDisplayLayer removeFromSuperlayer];
#endif
}

- (BOOL) startCamera {
    int targetWidth = 3088; //2560;
    int targetHeight = 2320; //1440;
    int targetFps = 24;
    BOOL useFrontCam = NO;
    
    NSError *deviceError;
    AVCaptureDevice* cameraDevice = (useFrontCam)? [self frontCamera] : [self backCamera];
    AVCaptureDeviceInput *inputDevice = [AVCaptureDeviceInput deviceInputWithDevice:cameraDevice error:&deviceError];
    
    AVCaptureVideoDataOutput *outputDevice = [[AVCaptureVideoDataOutput alloc] init];
    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;
    NSNumber* val = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange];
    NSDictionary* videoSettings = [NSDictionary dictionaryWithObject:val forKey:key];
    outputDevice.videoSettings = videoSettings;
    
    [outputDevice setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    
    // initialize capture session
    captureSession = [[AVCaptureSession alloc] init];
    
    [captureSession addInput:inputDevice];
    [captureSession addOutput:outputDevice];
    
    // begin configuration for the AVCaptureSession
    [captureSession beginConfiguration];
    
    // found device format
    AVCaptureDeviceFormat* deviceFormat = nil;
    const NSInteger requestedVideoFormatArea = targetWidth*targetHeight;
    NSInteger diffNeedArea = INT_MAX;
    
    for (AVCaptureDeviceFormat* format in cameraDevice.formats) {
        CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        
        const NSInteger deviceFormatArea = dimension.width * dimension.height;
        const NSInteger diffArea = labs(requestedVideoFormatArea - deviceFormatArea);
        
        if (diffArea == 0 && targetWidth == dimension.width && targetHeight == dimension.height) {
            if (mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                // requestedVideoFormatArea 과 일치하고, 실제 크기도 똑같고
                // PixelFormat도 맞으면 더 찾을 필요없음
                deviceFormat = format;
                break;
            } else if (diffArea < diffNeedArea) {
                // requestedVideoFormatArea 과 일치하고, 실제 크기도 똑같으나 PixelFormat이 다르다
                // 사이즈 비교해서 먼저 설정된 후보군의 범위보다 작을때만 후보군 교체
                deviceFormat = format;
                diffNeedArea = diffArea;
            }
        } else if (diffArea < diffNeedArea) {
            // requestedVideoFormatArea에 더 가까운 videoFormat값을 찾았으면, 후보군으로 등록
            deviceFormat = format;
            diffNeedArea = diffArea;
        } else if (diffArea == diffNeedArea) {
            // 기존과 동일한 video format을 찾았으면, media foramt을 보고 후보군을 교체
            CMVideoDimensions desiredDimension = CMVideoFormatDescriptionGetDimensions(deviceFormat.formatDescription);
            if (desiredDimension.width == dimension.width &&
                desiredDimension.height == dimension.height &&
                mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                deviceFormat = format;
                diffNeedArea = diffArea;
            }
        }
    }
    
    // save camera size
    CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(deviceFormat.formatDescription);
    _cameraWidth = dimension.width;
    _cameraHeight = dimension.height;
    NSLog(@"camera %d x %d", _cameraWidth, _cameraHeight);
    
    if ([cameraDevice lockForConfiguration:&deviceError]) {
        @try {
            cameraDevice.activeFormat = deviceFormat;
            cameraDevice.activeVideoMinFrameDuration = CMTimeMake(1, (int32_t)targetFps);
            cameraDevice.activeVideoMaxFrameDuration = CMTimeMake(1, (int32_t)targetFps);

            if ([cameraDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
                cameraDevice.focusMode = AVCaptureFocusModeContinuousAutoFocus;
            }
            
        } @catch (NSException* exception) {
            NSLog(@"Failed to set active format!\n User info:%@", exception.userInfo);
            return NO;
        }
        [cameraDevice unlockForConfiguration];
    } else {
        NSLog(@"Failed to lock device %@. Error: %@", inputDevice, deviceError.userInfo);
        return NO;
    }
    
    // fixed portrait
    AVCaptureConnection* connection = [outputDevice connectionWithMediaType:AVMediaTypeVideo];
    connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    connection.videoMirrored = useFrontCam? YES : NO;
    
    [captureSession commitConfiguration];
    [captureSession startRunning];
    
    return YES;
}

- (AVCaptureDevice*)frontCamera {
    AVCaptureDevice *cameraDevice = nil;
    for (AVCaptureDevice *captureDevice in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == AVCaptureDevicePositionFront) {
            return captureDevice;
        }
    }
    return cameraDevice;
}

- (AVCaptureDevice*)backCamera {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

-(void) captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection {
    [_sbDisplayLayer enqueueSampleBuffer:sampleBuffer];
    
    [vtEncoder encode:sampleBuffer];
}

#pragma mark - H264HwEncoderImplDelegate delegate

- (void)gotPsList:(NSArray<NSData*>*)pslist
{
#if DIRECT_DECODE
    // nothing to do
#else
    const char bytes[] = "\x00\x00\x00\x01";
    size_t length = (sizeof bytes) - 1; //string literals have implicit trailing '\0'
    NSData *ByteHeader = [NSData dataWithBytes:bytes length:length];
    for(NSData* ps in pslist) {
        [fileHandle writeData:ByteHeader];
        [fileHandle writeData:ps];
    }
#endif
}

- (void)gotEncodedData:(NSData*)data isKeyFrame:(BOOL)isKeyFrame
{
//    NSLog(@"gotEncodedData %d", (int)data.length);
#if DIRECT_DECODE
    if (isKeyFrame) {
        if (![self initVTDecoderWithPsList:vtEncoder.psList])
        {
            NSLog(@"initH264Decoder failed");
            return;
        }
    }
    
    if (!_deocderSession) {
        NSLog(@"decoder session is nil");
        return;
    }
    
    VideoPacket *vp = [[VideoPacket alloc] initWithSize:data.length];
    memcpy(vp.buffer, data.bytes, data.length);
    
    dispatch_async(_aQueue, ^{
        [self decodeVp:vp];
    });
#else
    if (fileHandle != NULL)
    {
        const char bytes[] = "\x00\x00\x00\x01";
        size_t length = (sizeof bytes) - 1;
        NSData *ByteHeader = [NSData dataWithBytes:bytes length:length];
        [fileHandle writeData:ByteHeader];
        [fileHandle writeData:data];
    }
#endif
}

@end
