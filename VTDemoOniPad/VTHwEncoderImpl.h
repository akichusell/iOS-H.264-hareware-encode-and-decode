//
//  H264HwEncoderImpl.h
//  h264v1
//
//  Created by Ganvir, Manish on 3/31/15.
//  Copyright (c) 2015 Ganvir, Manish. All rights reserved.
//

#import <Foundation/Foundation.h>
@import AVFoundation;
@protocol VTHwEncoderImplDelegate <NSObject>

- (void)gotSpsPps:(NSData*)sps pps:(NSData*)pps;
- (void)gotEncodedData:(NSData*)data isKeyFrame:(BOOL)isKeyFrame;
- (void)gotEncodedSamplebuffer:(CMSampleBufferRef)sampleBuffer isKeyFrame:(BOOL)isKeyFrame;

@end

@interface VTHwEncoderImpl : NSObject 

- (void) initWithConfiguration;
- (void) initEncode:(int)width  height:(int)height;
- (void) encode:(CMSampleBufferRef )sampleBuffer; 
- (void) End;

@property (weak, nonatomic) NSString *error;
@property (weak, nonatomic) id<VTHwEncoderImplDelegate> delegate;

@property (strong, nonatomic) NSData *sps;
@property (strong, nonatomic) NSData *pps;
@property (nonatomic) NSUInteger spsSize;
@property (nonatomic) NSUInteger ppsSize;


@end
