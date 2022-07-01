#import "RNViewShot.h"
#import <AVFoundation/AVFoundation.h>
#import <React/RCTLog.h>
#import <React/UIView+React.h>
#import <React/RCTUtils.h>
#import <React/RCTConvert.h>
#import <React/RCTScrollView.h>
#import <React/RCTUIManager.h>
#if __has_include(<React/RCTUIManagerUtils.h>)
#import <React/RCTUIManagerUtils.h>
#endif
#import <React/RCTBridge.h>

@implementation RNViewShot

RCT_EXPORT_MODULE()

@synthesize bridge = _bridge;

- (dispatch_queue_t)methodQueue
{
  return RCTGetUIManagerQueue();
}

RCT_EXPORT_METHOD(captureScreen: (NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) 
{
  [self captureRef: [NSNumber numberWithInt:-1] withOptions:options resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(releaseCapture:(nonnull NSString *)uri)
{
  NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ReactNative"];
  // Ensure it's a valid file in the tmp directory
  if ([uri hasPrefix:directory] && ![uri isEqualToString:directory]) {
    NSFileManager *fileManager = [NSFileManager new];
    if ([fileManager fileExistsAtPath:uri]) {
      [fileManager removeItemAtPath:uri error:NULL];
    }
  }
}

+ (UIImage *) imageWithView:(UIView *)view
{
  UIGraphicsBeginImageContextWithOptions(view.bounds.size, view.opaque, 0.0);
  [view.layer renderInContext:UIGraphicsGetCurrentContext()];
  
  UIImage * img = UIGraphicsGetImageFromCurrentImageContext();
  
  UIGraphicsEndImageContext();
  
  return img;
}

RCT_EXPORT_METHOD(captureRef:(nonnull NSNumber *)target
                  withOptions:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
  [self.bridge.uiManager addUIBlock:^(__unused RCTUIManager *uiManager, NSDictionary<NSNumber *, UIView *> *viewRegistry) {

    // Get view
    UIView *view;

    if ([target intValue] == -1) {
      UIWindow *window = [[UIApplication sharedApplication] keyWindow];
      view = window.rootViewController.view;
    } else {
      view = viewRegistry[target];
    }

    if (!view) {
      reject(RCTErrorUnspecified, [NSString stringWithFormat:@"No view found with reactTag: %@", target], nil);
      return;
    }

    // Get options
    CGSize size = [RCTConvert CGSize:options];
    NSString *format = [RCTConvert NSString:options[@"format"]];
    NSString *result = [RCTConvert NSString:options[@"result"]];
    BOOL snapshotContentContainer = [RCTConvert BOOL:options[@"snapshotContentContainer"]];

    // Capture image
    BOOL success;

    UIView* rendered;
    UIScrollView* scrollView;
    if (snapshotContentContainer) {
      if (![view isKindOfClass:[RCTScrollView class]]) {
        reject(RCTErrorUnspecified, [NSString stringWithFormat:@"snapshotContentContainer can only be used on a RCTScrollView. instead got: %@", view], nil);
        return;
      }
      RCTScrollView* rctScrollView = view;
      scrollView = rctScrollView.scrollView;
      rendered = scrollView;
    }
    else {
      rendered = view;
    }

    double captureScale = 0; // default use screen
    
    if (size.width < 0.1 || size.height < 0.1) {
      size = snapshotContentContainer ? scrollView.contentSize : view.bounds.size;
    } else {
      captureScale = 1; // if user specifies size, use 1:1 scale or else our image is enlarged by the device screen scale factor
    }
    if (size.width < 0.1 || size.height < 0.1) {
      reject(RCTErrorUnspecified, [NSString stringWithFormat:@"The content size must not be zero or negative. Got: (%g, %g)", size.width, size.height], nil);
      return;
    }

    CGPoint savedContentOffset;
    CGRect savedFrame;
    if (snapshotContentContainer) {
      // Save scroll & frame and set it temporarily to the full content size
      savedContentOffset = scrollView.contentOffset;
      savedFrame = scrollView.frame;
      scrollView.contentOffset = CGPointZero;
      scrollView.frame = CGRectMake(0, 0, scrollView.contentSize.width, scrollView.contentSize.height);
    }

    double t1 = CACurrentMediaTime();
    
    UIGraphicsBeginImageContextWithOptions(size, NO, captureScale);
    
    success = [rendered drawViewHierarchyInRect:(CGRect){CGPointZero, size} afterScreenUpdates:YES];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
#undef printf
    
    if (!success) { // if failed try an older way (iphone6 / ipad bug:  https://stackoverflow.com/questions/25873234/snapshotviewafterscreenupdates-glitch-on-ios-8
      image = [RNViewShot imageWithView:rendered];
      if (image) success = YES;
      if (!image) printf("backup screen shot also failed, play sad wha wha wha sound\n");
    }
    if (snapshotContentContainer) {
      printf("restoring scroll and frame\n");
      // Restore scroll & frame
      scrollView.contentOffset = savedContentOffset;
      scrollView.frame = savedFrame;
    }
 
    double t2 = CACurrentMediaTime();
    printf("time to capture screen = %f\n", t2-t1);
    
    if (!success) {
      reject(RCTErrorUnspecified, @"The view cannot be captured. drawViewHierarchyInRect was not successful. This is a potential technical or security limitation.", nil);
      return;
    }

    if (!image) {
      reject(RCTErrorUnspecified, @"Failed to capture view snapshot. UIGraphicsGetImageFromCurrentImageContext() returned nil!", nil);
      return;
    }

    // Convert image to data (on a background thread)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{

      NSData *data;
      if ([format isEqualToString:@"jpg"]) {
        CGFloat quality = [RCTConvert CGFloat:options[@"quality"]];
        data = UIImageJPEGRepresentation(image, quality);
      }
      else {
        data = UIImagePNGRepresentation(image);
      }

      NSError *error = nil;
      NSString *res = nil;
      if ([result isEqualToString:@"base64"]) {
        // Return as a base64 raw string
        res = [data base64EncodedStringWithOptions: NSDataBase64Encoding64CharacterLineLength];
      }
      else if ([result isEqualToString:@"data-uri"]) {
        // Return as a base64 data uri string
        NSString *base64 = [data base64EncodedStringWithOptions: NSDataBase64Encoding64CharacterLineLength];
        NSString *imageFormat = ([format isEqualToString:@"jpg"]) ? @"jpeg" : format;
        res = [NSString stringWithFormat:@"data:image/%@;base64,%@", imageFormat, base64];
      }
      else {
        // Save to a temp file
        NSString *path = RCTTempFilePath(format, &error);
        if (path && !error) {
          if ([data writeToFile:path options:(NSDataWritingOptions)0 error:&error]) {
            res = path;
          }
        }
      }

      if (res && !error) {
        resolve(res);
        return;
      }

      // If we reached here, something went wrong
      if (error) reject(RCTErrorUnspecified, error.localizedDescription, error);
      else reject(RCTErrorUnspecified, @"viewshot unknown error", nil);
    });
  }];
}


@end
