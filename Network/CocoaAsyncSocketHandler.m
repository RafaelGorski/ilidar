//
//  CocoaAsyncSocketTest.m
//  iLiDAR
//
//  Created by Bo Liang on 2024/12/8.
//

#import "CocoaAsyncSocketHandler.h"
#import <GCDAsyncSocket.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

@interface CocoaAsyncSocketHandler ()<GCDAsyncSocketDelegate>

@property (strong, nonatomic) GCDAsyncSocket *socket;
@property (strong, nonatomic) NSMutableData *incomingBuffer;
@property (assign, nonatomic) BOOL isConnecting;
@property (assign, nonatomic) BOOL isReady;
@property (assign, nonatomic) uint64_t connectionID;
@property (copy, nonatomic) NSString *fingerprint;
@property (copy, nonatomic) NSString *token;

@end

@implementation CocoaAsyncSocketHandler

- (instancetype) init {
    self = [super init];
    if (self) {
        _incomingBuffer = [NSMutableData data];
        _isConnecting = NO;
    }
    return self;
}

- (void)setupSocketHost:(NSString *)host port:(NSInteger)port
           fingerprint:(NSString *)fingerprint token:(NSString *)token {
    @synchronized (self) {
        self.connectionID++;
        dispatch_queue_t networkQueue = dispatch_queue_create("com.iliDAR.network", DISPATCH_QUEUE_SERIAL);
        self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:networkQueue];
        self.fingerprint = fingerprint;
        self.token = token;
        self.isReady = NO;
        NSError *error = nil;
        self.isConnecting = YES;

        BOOL started = [self.socket connectToHost:host onPort:(uint16_t)port error:&error];
        if (!started || error) {
            NSLog(@"Fail to connect: %@", error.localizedDescription);
            self.isConnecting = NO;
            self.token = nil;
            ConnectionCallback callback = self.connectionCallback;
            if (callback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(NO);
                });
            }
        }
    }
}

- (uint64_t)currentConnectionID {
    @synchronized (self) {
        return self.isReady ? self.connectionID : 0;
    }
}

- (BOOL)sendMyData:(NSData *)data connectionID:(uint64_t)connectionID {
    @synchronized (self) {
        if (!self.isReady || connectionID == 0 || connectionID != self.connectionID || !self.socket.isConnected)
            return NO;
        [self.socket writeData:data withTimeout:-1 tag:0];
        return YES;
    }
}

- (void)disconnect {
    @synchronized (self) {
        if (self.socket) {
            self.isReady = NO;
            self.connectionID++;
            [self.socket disconnect];
            NSLog(@"Socket disconnected by user.");
        }
    }
}

#pragma mark - GCDAsyncSocketDelegate Methods

// Delegate method: Connection successful
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    if (sock != self.socket) return;
    [sock startTLS:@{GCDAsyncSocketManuallyEvaluateTrust: @YES}];
}

- (void)socket:(GCDAsyncSocket *)sock didReceiveTrust:(SecTrustRef)trust
    completionHandler:(void (^)(BOOL))completionHandler {
    @synchronized (self) {
        if (sock != self.socket) {
            completionHandler(NO);
            return;
        }
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(trust, 0);
        if (!certificate) {
            completionHandler(NO);
            return;
        }
        NSData *certificateData = CFBridgingRelease(SecCertificateCopyData(certificate));
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(certificateData.bytes, (CC_LONG)certificateData.length, digest);
        NSMutableString *actual = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
            [actual appendFormat:@"%02x", digest[i]];
        }
        completionHandler([actual isEqualToString:self.fingerprint]);
    }
}

- (void)socketDidSecure:(GCDAsyncSocket *)sock {
    @synchronized (self) {
        if (sock != self.socket) return;
        NSString *authentication = [NSString stringWithFormat:@"ILIDAR/1 %@\n", self.token];
        [sock writeData:[authentication dataUsingEncoding:NSUTF8StringEncoding] withTimeout:5 tag:1];
        [sock readDataToData:[GCDAsyncSocket LFData] withTimeout:5 maxLength:64 tag:1];
    }
}

// Delegate method: Data received (optional, can be used for simple acknowledgments)
- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    if (sock != self.socket) return;
    if (tag == 1) {
        if (![data isEqualToData:[@"OK\n" dataUsingEncoding:NSUTF8StringEncoding]]) {
            [sock disconnect];
            return;
        }
        ConnectionCallback callback;
        @synchronized (self) {
            if (sock != self.socket) return;
            self.isConnecting = NO;
            self.isReady = YES;
            self.token = nil;
            callback = self.connectionCallback;
        }
        if (callback) callback(YES);
        [sock readDataWithTimeout:-1 tag:0];
        return;
    }
    NSString *response = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"Received response: %@", response);
    
    if (self.getResponseBlock){
        self.getResponseBlock(response);
    }
    
    // Continue reading if expecting more responses
    [self.socket readDataWithTimeout:-1 tag:0];
}

// Delegate method: Connection disconnected
- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    BOOL wasReady;
    BOOL wasConnecting;
    ConnectionCallback callback;
    void (^disconnectCallback)(void);
    @synchronized (self) {
        if (sock != self.socket) return;
        wasReady = self.isReady;
        wasConnecting = self.isConnecting;
        self.isReady = NO;
        self.connectionID++;
        self.isConnecting = NO;
        self.token = nil;
        callback = self.connectionCallback;
        disconnectCallback = self.disconnectCallback;
    }
    if (err) {
        NSLog(@"Socket disconnected with error: %@", err.localizedDescription);
    } else {
        NSLog(@"Socket disconnected successfully.");
    }
    if (wasConnecting && callback) callback(NO);
    if (wasReady && disconnectCallback) disconnectCallback();
    
    // Optionally, notify about disconnection
    if (self.getResponseBlock) {
        self.getResponseBlock(@"Disconnected from server.");
    }
}

@end
