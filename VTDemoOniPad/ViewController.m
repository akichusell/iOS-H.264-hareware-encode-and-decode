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
    AVCaptureVideoPreviewLayer *previewLayer;
    NSString *h264FileSavePath;
    int fd;
    NSFileHandle *fileHandle;
    AVCaptureConnection* connection;
    AVSampleBufferDisplayLayer *sbDisplayLayer;
    
    // 디코딩
    uint8_t *_sps;
    NSInteger _spsSize;
    uint8_t *_pps;
    NSInteger _ppsSize;
    VTDecompressionSessionRef _deocderSession;
    CMVideoFormatDescriptionRef _decoderFormatDescription;
    bool playCalled;
}

@property (weak, nonatomic) IBOutlet UIButton *startStopBtn;
@property (weak, nonatomic) IBOutlet UIButton *playerBtn;
#if DIRECT_DECODE
@property (nonatomic) dispatch_queue_t aQueue;
#endif

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
#if DIRECT_DECODE
    _aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
#endif
    
#if USE_HEVC
    NSLog(@"use hevc");
#endif
    
    // 파일 저장 위치
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    h264FileSavePath = [documentsDirectory stringByAppendingPathComponent:@"test.h264"];
    [fileManager removeItemAtPath:h264FileSavePath error:nil];
    [fileManager createFileAtPath:h264FileSavePath contents:nil attributes:nil];
}

#pragma mark - Decode

-(BOOL)initVTDecoder {
    if(_deocderSession) {
        return YES;
    }
    
    const uint8_t* const parameterSetPointers[2] = { _sps, _pps };
    const size_t parameterSetSizes[2] = { _spsSize, _ppsSize };
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                          2, //param count
                                                                          parameterSetPointers,
                                                                          parameterSetSizes,
                                                                          4, //nal start code size
                                                                          &_decoderFormatDescription);
    
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
    } else {
        NSLog(@"video format create failed status=%d", (int)status);
        _deocderSession = nil;
        return NO;
    }
    
    return YES;
}

-(BOOL)initVTDecoderWithPsList:(NSArray<NSData*>*)psList {
    if(_deocderSession) {
        return YES;
    }
#if USE_HEVC
    const uint8_t* const parameterSetPointers[3] = { psList[0].bytes, psList[1].bytes, psList[2].bytes };
    const size_t parameterSetSizes[3] = { psList[0].length, psList[1].length, psList[2].length };
    OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                          3, //param count
                                                                          parameterSetPointers,
                                                                          parameterSetSizes,
                                                                          4, //nal start code size
                                                                          NULL,
                                                                          &_decoderFormatDescription);
#else
    const uint8_t* const parameterSetPointers[2] = { psList[0].bytes, psList[1].bytes };
    const size_t parameterSetSizes[2] = { psList[0].length, psList[1].length };
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                          2, //param count
                                                                          parameterSetPointers,
                                                                          parameterSetSizes,
                                                                          4, //nal start code size
                                                                          &_decoderFormatDescription);
#endif
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

-(BOOL) initHEVCDecoder {
    return NO;
}

-(void)clearVTDeocder {
    if(_deocderSession) {
        VTDecompressionSessionInvalidate(_deocderSession);
        CFRelease(_deocderSession);
        _deocderSession = NULL;
    }
    
    if(_decoderFormatDescription) {
        CFRelease(_decoderFormatDescription);
        _decoderFormatDescription = NULL;
    }
    
    free(_sps);
    free(_pps);
    _spsSize = _ppsSize = 0;
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

-(void)decodeSamplebuffer:(CMSampleBufferRef)samplebuffer {
    VTDecodeFrameFlags flags = 0;
    VTDecodeInfoFlags flagOut = 0;
    OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_deocderSession,
                                                              samplebuffer,
                                                              flags,
                                                              (__bridge void *)self,
                                                              &flagOut);
    
    if(decodeStatus == kVTInvalidSessionErr) {
        NSLog(@"Invalid session, reset decoder session");
    } else if(decodeStatus == kVTVideoDecoderBadDataErr) {
        NSLog(@"decode failed status=%d(Bad data)", (int)decodeStatus);
    } else if(decodeStatus != noErr) {
        NSLog(@"decode failed status=%d", (int)decodeStatus);
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
//                NSLog(@"Nal type is IDR frame");
                if([self initVTDecoder]) {
                    pixelBuffer = [self decode:vp];
                }
                break;
            case 0x07:
//                NSLog(@"Nal type is SPS");
                _spsSize = vp.size - 4;
                _sps = malloc(_spsSize);
                memcpy(_sps, vp.buffer + 4, _spsSize);
                break;
            case 0x08:
//                NSLog(@"Nal type is PPS");
                _ppsSize = vp.size - 4;
                _pps = malloc(_ppsSize);
                memcpy(_pps, vp.buffer + 4, _ppsSize);
                break;
                
            default:
//                NSLog(@"Nal type is B/P frame");
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

- (IBAction)playerAction:(id)sender {
#if DIRECT_DECODE
#else
    if (playCalled) {
        playCalled = false;
        [_playerBtn setTitle:@"close" forState:UIControlStateNormal];

        float width = self.view.frame.size.width * WIDTH_RATIO;
        float height = width * 16.f/9.f;
        _glLayer = [[AAPLEAGLLayer alloc] initWithFrame:CGRectMake((self.view.frame.size.width-width)/2, 20, width, height)];
        [self.view.layer addSublayer:_glLayer];
        
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            [self decodeFile:@"test" fileExt:@"h264"];
        });
    } else {
        playCalled = true;
        [_playerBtn setTitle:@"play" forState:UIControlStateNormal];
        [self clearH264Deocder];
        [_glLayer removeFromSuperlayer];
    }
#endif
}

#pragma mark - 인코딩
// Called when start/stop button is pressed
- (IBAction) StartStopAction:(id)sender {
    if (startCalled)
    {
        [self startCamera];
        startCalled = false;
        [_startStopBtn setTitle:@"Stop" forState:UIControlStateNormal];
    }
    else
    {
        [_startStopBtn setTitle:@"Start" forState:UIControlStateNormal];
        startCalled = true;
        [self stopCamera];
        [vtEncoder End];
#if DIRECT_DECODE
        [self clearVTDeocder];
#endif
    }
}

- (void) startCamera
{
    // make input device
    NSError *deviceError;
    
    AVCaptureDevice *cameraDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    
    AVCaptureDeviceInput *inputDevice = [AVCaptureDeviceInput deviceInputWithDevice:cameraDevice error:&deviceError];
    
    // make output device
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
    
    // picture resolution
    [captureSession setSessionPreset:AVCaptureSessionPresetHigh];
    [captureSession setSessionPreset:[NSString stringWithString:AVCaptureSessionPreset1280x720]];
    
    connection = [outputDevice connectionWithMediaType:AVMediaTypeVideo];
    [self setRelativeVideoOrientation];
    
    NSNotificationCenter* notify = [NSNotificationCenter defaultCenter];
    
    [notify addObserver:self
               selector:@selector(statusBarOrientationDidChange:)
                   name:@"StatusBarOrientationDidChange"
                 object:nil];
    
    [captureSession commitConfiguration];
    [captureSession startRunning];
    
#if DIRECT_DECODE
    // decoded display
    float width = self.view.frame.size.width * WIDTH_RATIO;
    float height = width * 16.f/9.f;
    _glLayer = [[AAPLEAGLLayer alloc] initWithFrame:CGRectMake((self.view.frame.size.width-width)/2, 20, width, height)];
    [self.view.layer addSublayer:_glLayer];
#else
    // preview display
    AVSampleBufferDisplayLayer *sb = [[AVSampleBufferDisplayLayer alloc]init];
    sb.backgroundColor = [UIColor blackColor].CGColor;
    sbDisplayLayer = sb;
    sb.videoGravity = AVLayerVideoGravityResizeAspect;
    float width = self.view.frame.size.width * WIDTH_RATIO;
    float height = width * 16.f/9.f;
    sbDisplayLayer.frame = CGRectMake((self.view.frame.size.width-width)/2, 20, width, height);
    [self.view.layer addSublayer:sbDisplayLayer];
    
    fileHandle = [NSFileHandle fileHandleForWritingAtPath:h264FileSavePath];
#endif
    
    [vtEncoder initEncode:720 height:1280];
    vtEncoder.delegate = self;
}

- (void) statusBarOrientationDidChange:(NSNotification*)notification {
    [self setRelativeVideoOrientation];
}

- (void) setRelativeVideoOrientation {
    switch ([[UIDevice currentDevice] orientation]) {
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationUnknown:
            connection.videoOrientation = AVCaptureVideoOrientationPortrait;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            connection.videoOrientation =
            AVCaptureVideoOrientationPortraitUpsideDown;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            connection.videoOrientation = AVCaptureVideoOrientationLandscapeLeft;
            break;
        case UIInterfaceOrientationLandscapeRight:
            connection.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
            break;
        default:
            break;
    }
}

- (void) stopCamera
{
    [captureSession stopRunning];
    [previewLayer removeFromSuperlayer];

#if DIRECT_DECODE
    [_glLayer removeFromSuperlayer];
#else
    [fileHandle closeFile];
    fileHandle = NULL;
    
    [sbDisplayLayer removeFromSuperlayer];
#endif
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

-(void) captureOutput:(AVCaptureOutput*)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection*)connection {
    [sbDisplayLayer enqueueSampleBuffer:sampleBuffer];
    
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
