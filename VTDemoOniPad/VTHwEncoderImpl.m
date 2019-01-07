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

@implementation VTHwEncoderImpl
{
    VTCompressionSessionRef EncodingSession;
    dispatch_queue_t aQueue;
    CMFormatDescriptionRef  format;
    CMSampleTimingInfo * timingInfo;
    BOOL initialized;
    int  frameCount;
}
@synthesize error;

- (void) initWithConfiguration
{
    EncodingSession = nil;
    initialized = true;
    aQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    frameCount = 0;
    
    _sps = NULL;
    _spsSize = 0;
    _pps = NULL;
    _ppsSize = 0;
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
#if USE_HEVC
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        size_t sparameterSetSize, sparameterSetCount;
        const uint8_t *sparameterSet;
        OSStatus statusCode = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0 );
        if (statusCode == noErr) {
            // Found sps and now check for pps
            size_t pparameterSetSize, pparameterSetCount;
            const uint8_t *pparameterSet;
            OSStatus statusCode = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 1, &pparameterSet, &pparameterSetSize, &pparameterSetCount, 0 );
            if (statusCode == noErr)
            {
                // Found pps
                encoder.sps = [NSData dataWithBytes:sparameterSet length:sparameterSetSize];
                encoder.spsSize = sparameterSetSize;
                
                encoder.pps = [NSData dataWithBytes:pparameterSet length:pparameterSetSize];
                encoder.ppsSize = pparameterSetSize;
                
                if (encoder.delegate) {
                    [encoder.delegate gotSpsPps:encoder.sps pps:encoder.pps];
                }
            }
        }
#else
        CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        // CFDictionaryRef extensionDict = CMFormatDescriptionGetExtensions(format);
        // Get the extensions
        // From the extensions get the dictionary with key "SampleDescriptionExtensionAtoms"
        // From the dict, get the value for the key "avcC"
        size_t sparameterSetSize, sparameterSetCount;
        const uint8_t *sparameterSet;
        OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sparameterSet, &sparameterSetSize, &sparameterSetCount, 0 );
        if (statusCode == noErr) {
            // Found sps and now check for pps
            size_t pparameterSetSize, pparameterSetCount;
            const uint8_t *pparameterSet;
            OSStatus statusCode = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pparameterSet, &pparameterSetSize, &pparameterSetCount, 0 );
            if (statusCode == noErr)
            {
                // Found pps
                encoder.sps = [NSData dataWithBytes:sparameterSet length:sparameterSetSize];
                encoder.spsSize = sparameterSetSize;
                
                encoder.pps = [NSData dataWithBytes:pparameterSet length:pparameterSetSize];
                encoder.ppsSize = pparameterSetSize;
                
                if (encoder.delegate) {
                    [encoder.delegate gotSpsPps:encoder.sps pps:encoder.pps];
                }
            }
        }
#endif
    }
    
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t length, totalLength;
    char *dataPointer;
    OSStatus statusCodeRet = CMBlockBufferGetDataPointer(dataBuffer, 0, &length, &totalLength, &dataPointer);
    if (statusCodeRet == noErr) {
#if SPLIT_NALUNIT
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
#else
        NSData* data = [[NSData alloc] initWithBytes:dataPointer length:totalLength];
        [encoder.delegate gotEncodedData:data isKeyFrame:keyframe];
#endif
    }
}

- (void) initEncode:(int)width  height:(int)height {
    dispatch_sync(aQueue, ^{
        [self internalInitEncode:width height:height];
    });
}

- (void) internalInitEncode:(int)width  height:(int)height {
    CFMutableDictionaryRef sessionAttributes = CFDictionaryCreateMutable(
                                                                         NULL,
                                                                         0,
                                                                         &kCFTypeDictionaryKeyCallBacks,
                                                                         &kCFTypeDictionaryValueCallBacks);
#if USE_HEVC
    CMVideoCodecType type = kCMVideoCodecType_HEVC;
#else
    CMVideoCodecType type = kCMVideoCodecType_H264;
#endif
    OSStatus status = VTCompressionSessionCreate(NULL, width, height, type, sessionAttributes, NULL, NULL, didCompressCallback, (__bridge void *)(self),  &EncodingSession);
    NSLog(@"VTCompressionSessionCreate %d", (int)status);
    if (status != 0)
    {
        NSLog(@"Unable to create (%@) session", @(type));
        return ;
    }
    
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
    
#if USE_HEVC
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_ProfileLevel error %@", @(status));
    }
#else
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC);
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_H264EntropyMode error %@", @(status));
    }
    
    status = VTSessionSetProperty(EncodingSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    if (status != 0) {
        NSLog(@"kVTCompressionPropertyKey_ProfileLevel error %@", @(status));
    }
#endif
    
    int32_t bitrateValue = 5000 * 1024; // 5 Mbps
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
        error = NULL;
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
    error = NULL;
}

@end
