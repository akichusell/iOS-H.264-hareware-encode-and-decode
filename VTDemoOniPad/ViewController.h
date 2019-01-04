//
//  ViewController.h
//  VTDemoOniPad
//
//  Created by AJB on 16/4/25.
//  Copyright © 2016年 AJB. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "VTHwEncoderImpl.h"
#import "AAPLEAGLLayer.h"

@interface ViewController : UIViewController<AVCaptureVideoDataOutputSampleBufferDelegate, VTHwEncoderImplDelegate>
@property (strong, nonatomic) AAPLEAGLLayer *glLayer;
@end

