#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Frame callback. baseAddress is valid only for the duration of the call —
// copy the bytes synchronously. matrix: 0=601 1=709 2=2020. range: 0=narrow.
typedef void (^DLFrameHandler)(int width, int height, int rowBytes, BOOL isV210,
                               const void * _Nullable baseAddress, int length,
                               int matrix, int range);

@interface DLCapture : NSObject

+ (NSArray<NSString *> *)deviceNames;

- (instancetype)initWithDeviceIndex:(int)index NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, copy, nullable) DLFrameHandler frameHandler;
@property (nonatomic, copy, nullable) void (^formatHandler)(NSString *description);

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
