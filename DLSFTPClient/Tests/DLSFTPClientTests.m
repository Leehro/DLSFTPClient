//
//  DLSFTPClientTests.m
//  DLSFTPClientTests
//
//  Created by Dan Leehr on 1/6/13.
//  Copyright (c) 2013 Dan Leehr. All rights reserved.
//

#import "DLSFTPClientTests.h"
#import "DLSFTPConnection.h"
#import "DLSFTPFile.h"
#import "NSDictionary+SFTPFileAttributes.h"

@interface DLSFTPClientTests ()

@property (strong, nonatomic) NSDictionary *connectionInfo;
@property (strong, nonatomic) DLSFTPConnection *connection;

@end


@implementation DLSFTPClientTests

- (void)setUp {
    [super setUp];
    NSString *connectionInfoPath = [[NSBundle bundleWithIdentifier:@"com.hammockdistrict.DLSFTPClientTests"] pathForResource:@"ConnectionInfo"
                                                                                                                      ofType:@"plist"];
    self.connectionInfo = [NSDictionary dictionaryWithContentsOfFile:connectionInfoPath];
    DLSFTPConnection *connection = [[DLSFTPConnection alloc] initWithHostname:self.connectionInfo[@"hostname"]
                                                                         port:[self.connectionInfo[@"port"] integerValue]
                                                                     username:self.connectionInfo[@"username"]
                                                                     password:self.connectionInfo[@"password"]];
    self.connection = connection;
    STAssertNotNil(self.connection, @"Connection is nil");

}

- (void)tearDown
{
    [self.connection disconnect];
    STAssertFalse([self.connection isConnected], @"Disconnection unsuccessful");
    // Tear-down code here.
    [super tearDown];
}

- (void)testConnect {
    __block NSError *localError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [self.connection connectWithSuccessBlock:^{
        dispatch_semaphore_signal(semaphore);
    } failureBlock:^(NSError *error) {
        localError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    STAssertNil(localError, localError.localizedDescription);
    STAssertTrue([self.connection isConnected], @"Connection unsuccessful");
}

- (void)testList {
    [self testConnect];
    STAssertTrue([self.connection isConnected], @"Not connected");
    __block NSError *localError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    static NSString *directoryPath = @"/Users/testuser/sftp-test";
    [self.connection listFilesInDirectory:directoryPath
                             successBlock:^(NSArray *array) {
                                 dispatch_semaphore_signal(semaphore);
                             }
                             failureBlock:^(NSError *error) {
                                 localError = error;
                                 dispatch_semaphore_signal(semaphore);
    }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    STAssertNil(localError, localError.localizedDescription);
}


- (void)testMkDir {
    [self testConnect];
    STAssertTrue([self.connection isConnected], @"Not connected");
    __block NSError *localError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSString *basePath = self.connectionInfo[@"basePath"];
    NSString *directoryName = self.connectionInfo[@"directoryName"];
    NSString *fullPath = [basePath stringByAppendingPathComponent:directoryName];
    [self.connection makeDirectory:fullPath
                      successBlock:^(DLSFTPFile *fileOrDirectory) {
                          STAssertEqualObjects(fileOrDirectory.filename, directoryName, @"File name does not match");
                          dispatch_semaphore_signal(semaphore);
                      } failureBlock:^(NSError *error) {
                          localError = error;
                          dispatch_semaphore_signal(semaphore);
                      }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    STAssertNil(localError, localError.localizedDescription);

    // make sure the directory appears in the list
    semaphore = dispatch_semaphore_create(0);
    [self.connection listFilesInDirectory:basePath
                             successBlock:^(NSArray *array) {
                                 __block BOOL foundDirectory = NO;
                                 [array enumerateObjectsUsingBlock:^(DLSFTPFile *file, NSUInteger idx, BOOL *stop) {
                                     if ([file.filename isEqualToString:directoryName]) {
                                         *stop = foundDirectory = YES;
                                     }
                                 }];
                                 STAssertTrue(foundDirectory, @"Created directory was not found in listing");
                                 dispatch_semaphore_signal(semaphore);
                             } failureBlock:^(NSError *error) {
                                 localError = error;
                                 dispatch_semaphore_signal(semaphore);
                             }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    STAssertNil(localError, localError.localizedDescription);
}

- (void)testRmDir {
    [self testConnect];
    STAssertTrue([self.connection isConnected], @"Not connected");
    __block NSError *localError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSString *basePath = self.connectionInfo[@"basePath"];
    NSString *directoryName = self.connectionInfo[@"directoryName"];
    NSString *fullPath = [basePath stringByAppendingPathComponent:directoryName];
    [self.connection removeDirectoryAtPath:fullPath
                         successBlock:^{
                             dispatch_semaphore_signal(semaphore);
                         } failureBlock:^(NSError *error) {
                             localError = error;
                             dispatch_semaphore_signal(semaphore);
                         }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    STAssertNil(localError, localError.localizedDescription);

    // make sure the directory is removed
    semaphore = dispatch_semaphore_create(0);
    [self.connection listFilesInDirectory:basePath
                             successBlock:^(NSArray *array) {
                                 __block BOOL foundDirectory = NO;
                                 [array enumerateObjectsUsingBlock:^(DLSFTPFile *file, NSUInteger idx, BOOL *stop) {
                                     if ([file.filename isEqualToString:directoryName]) {
                                         *stop = foundDirectory = YES;
                                     }
                                 }];
                                 STAssertFalse(foundDirectory, @"Removed directory was found in listing");
                                 dispatch_semaphore_signal(semaphore);
                             } failureBlock:^(NSError *error) {
                                 localError = error;
                                 dispatch_semaphore_signal(semaphore);
                             }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    STAssertNil(localError, localError.localizedDescription);
}


/*
 
- (void)testRename {
 
}


- (void)testDownload {
    STFail(@"Not yet implemented");    
}

- (void)testUpload {
    STFail(@"Not yet implemented");
}

- (void)testUploadAndDownload {
    STFail(@"Not yet implemented");
}
*/
// what else to test.  Concurrency - download and list


@end
