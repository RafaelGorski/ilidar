//
//  CocoaAsyncSocketTest.h
//  iLiDAR
//
//  Created by Bo Liang on 2024/12/8.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ResponseBlock)(NSString *response);
typedef void (^ConnectionCallback)(BOOL success);

@interface CocoaAsyncSocketHandler : NSObject

@property (nonatomic, copy) ResponseBlock getResponseBlock;
@property (nonatomic, copy) ConnectionCallback connectionCallback;
@property (nonatomic, copy) void (^disconnectCallback)(void);

// Setup connection with host and port
- (void)setupSocketHost:(NSString *)host port:(NSInteger)port
           fingerprint:(NSString *)fingerprint token:(NSString *)token;

// Send only while the original authenticated connection is still active.
- (uint64_t)currentConnectionID;
- (BOOL)sendMyData:(NSData *)data connectionID:(uint64_t)connectionID;

// Disconnect the socket
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
