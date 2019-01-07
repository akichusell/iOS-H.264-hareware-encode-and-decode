//
//  VTHwEncoderImpl.m
//
//
//  Created by Ganvir, Manish on 3/31/15.
//  Copyright (c) 2015 Ganvir, Manish. All rights reserved.
//

#import "VTHwEncoderImpl.h"

@import VideoToolbox;
@import AVFoundation;

#define BITRATE_KBPS 5000 // 5 Mbps

@interface VTHwEncoderImpl()
@property (nonatomic) BOOL useHEVC;
@end

@implementation VTHwEncoderImpl
{
    VTCompressionSessionRef EncodingSession;
    dispatch_queue_t aQueue;
    CMFormatDescriptionRef  format;
    CMSampleTimingInfo * timingInfo;
    BOOL initialized;
    int  frameCount;
}

- (void) initWithConfiguration
{
    EncodingSession = nil;
    initialized = true;
    aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    frameCount = 0;
    
    _psList = NULL;
    _useHEVC = NO;
}

void didCompressCallback(void *outputCallbackRefCon, void *sourceFrameRefCon, OSStatus status, VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer)
{
//    NSLog(@"didCompressCallback called with status %d infoFlags %d", (int)status, (int)infoFlags);
    if (status != 0) return;
    
    if (!CMSampleBufferDataIsReady(sampleBuffer))
    {
        NSLog(@"didCompressCallback data is not ready ");
        return;
    }
    VTHwEncoderImpl* encoder = (__bridge VTHwEncoderImpl*)outputCallbackRefCon;
   
    // Check if we have got a key frame first
    bool keyframe = !CFDictionaryContainsKey( (CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true), 0)), kCMSampleAttachmentKey_NotSync);
    if (keyframe) {
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        NSMutableArray<NSData*>* pslist = [NSMutableArray array];
        size_t spsSize, count;
        const uint8_t *sps;
        if (encoder.useHEVC) {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &sps, &spsSize, &count, 0);
            [pslist addObject:[NSData dataWithBytes:sps
                                             length:spsSize]];
            for (int i=1; i<count; i++) {
                size_t size;
                const uint8_t *pps;
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &pps, &size, NULL, 0);
                [pslist addObject:[NSData dataWithBytes:pps
                                                  length:size]];
            }
            encoder.psList = pslist;
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &spsSize, &count, 0);
            [pslist addObject:[NSData dataWithBytes:sps
                                             length:spsSize]];
            for (int i=1; i<count; i++) {
                size_t size;
                const uint8_t *pps;
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &pps, &size, NULL, 0);
                [pslist addObject:[NSData dataWithBytes:pps
                                                 length:size]];
            }
            encoder.psList = pslist;
            if (encoder.delegate) {
                [encoder.delegate gotPsList:encoder.psList];
            }
        }
    }
    
#if DIRECT_DECODE
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length, totalLength;
    char *dataPointer;
    OSStatus statusCodeRet = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    if (statusCodeRet == noErr) {
        NSData* data = [[NSData alloc] initWithBytes:dataPointer length:totalLength];
        [encoder.delegate gotEncodedData:data isKeyFrame:keyframe];
    }
#else
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length, totalLength;
    char *dataPointer;
    OSStatus statusCodeRet = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    if (statusCodeRet == noErr) {
        size_t bufferOffset = 0;
        static const int AVCCHeaderLength = 4;
        while (bufferOffset < totalLength - AVCCHeaderLength) {
            // Read the NAL unit length
            uint32_t NALUnitLength = 0;
            memcpy(&NALUnitLength, dataPointer + bufferOffset, AVCCHeaderLength);
            
            // Convert the length value from Big-endian to Little-endian
            NALUnitLength = CFSwapInt32BigToHost(NALUnitLength);
            
            NSData* data = [[NSData alloc] initWithBytes:(dataPointer + bufferOffset + AVCCHeaderLength) length:NALUnitLength];
            [encoder.delegate gotEncodedData:data isKeyFrame:keyframe];
            
            // Move to the next NAL unit in the block buffer
            bufferOffset += AVCCHeaderLength + NALUnitLength;
        }
    }
#endif
}

- (void) initEncode:(int)width height:(int)height hevc:(BOOL)useHEVC {
    dispatch_sync(aQueue, ^{
        [self internalInitEncode:width height:height hevc:useHEVC];
        self.useHEVC = useHEVC;
    });
}

- (void) internalInitEncode:(int)width  height:(int)height hevc:(BOOL)useHEVC {
    CFMutableDictionaryRef sessionAttributes = CFDictionaryCreateMutable(
                                                                         NULL,
                                                                         0,
                                                                         &kCFTypeDictionaryKeyCallBacks,
                                                                         &kCFTypeDictionaryValueCallBacks);
    
    CMVideoCodecType type = (useHEVC)? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264;
    OSStatus status = VTCompressionSessionCreate(NULL, width, height, type, sessionAttributes, NULL, NULL, didCompressCallback, (__bridge void *)(self),  &EncodingSession);
    if (status != 0) {
        NSLog(@"Unable to create (%@) session", @(type));
        return ;
    }
     NSLog(@"create %@ Encoder (%d x %d)", useHEVC? @"HEVC" : @"H264", width, height);
    
    // properties
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_RealTime error %@", @(status));
    }
    
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_AllowFrameReordering error %@", @(status));
    }
    
    int32_t value = 3;
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value));
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration error %@", @(status));
    }
    
    if (useHEVC) {
        status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
        if (status != 0) {
            NSLog(@"kVTCompressionPropertyKey_ProfileLevel error %@", @(status));
        }
    } else {
        status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC);
        if (status != 0) {
            NSLog(@"kVTCompressionPropertyKey_H264EntropyMode error %@", @(status));
        }
        
        status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
        if (status != 0) {
            NSLog(@"kVTCompressionPropertyKey_ProfileLevel error %@", @(status));
        }
    }
    
    int32_t bitrateValue = BITRATE_KBPS * 1024;
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_AverageBitRate, CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitrateValue));
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_AverageBitRate error %@", @(status));
    }
    
    int64_t data_limit_bytes_per_second_value = bitrateValue * 2 / 8;
    CFNumberRef bytes_per_second = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &data_limit_bytes_per_second_value);
    int64_t one_second_value = 1;
    CFNumberRef one_second = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &one_second_value);
    const void* nums[2] = { bytes_per_second, one_second };
    CFArrayRef data_rate_limits = CFArrayCreate(nil, nums, 2, &kCFTypeArrayCallBacks);
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_DataRateLimits, data_rate_limits);
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_DataRateLimits error %@", @(status));
    }
    
    VTCompressionSessionPrepareToEncodeFrames(EncodingSession);
}

- (void) encode:(CMSampleBufferRef )sampleBuffer {
     dispatch_sync(aQueue, ^{
         [self internalEncode:sampleBuffer];
     });
}

- (void) internalEncode:(CMSampleBufferRef)sampleBuffer {
    frameCount++;
    // Get the CV Image buffer
    CVImageBufferRef imageBuffer = (CVImageBufferRef)CMSampleBufferGetImageBuffer(sampleBuffer);
    
//    CMTime presentationTimeStamp = CMTimeMake(frameCount, 1);
    CMTime presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
//    const CMTimeValue currentSec = (presentationTimeStamp.value/presentationTimeStamp.timescale);
//    NSLog(@"seil.chu // %@ [ %@ / %@ ]", @(currentSec), @(presentationTimeStamp.value), @(presentationTimeStamp.timescale));
    
    VTEncodeInfoFlags flags;
    
    // Pass it to the encoder
    OSStatus statusCode = VTCompressionSessionEncodeFrame(EncodingSession,
                                                          imageBuffer,
                                                          presentationTimeStamp,
                                                          kCMTimeInvalid,
                                                          NULL, NULL, &flags);
    // Check for error
    if (statusCode != noErr) {
        NSLog(@"VTCompressionSessionEncodeFrame failed with %d", (int)statusCode);
        
        // End the session
        VTCompressionSessionInvalidate(EncodingSession);
        CFRelease(EncodingSession);
        EncodingSession = NULL;
        return;
    }
//    NSLog(@"VTCompressionSessionEncodeFrame Success");
}

- (void) End {
    // Mark the completion
    VTCompressionSessionCompleteFrames(EncodingSession, kCMTimeInvalid);
    
    // End the session
    VTCompressionSessionInvalidate(EncodingSession);
    CFRelease(EncodingSession);
    EncodingSession = NULL;
}

@end
