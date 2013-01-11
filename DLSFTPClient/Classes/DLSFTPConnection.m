//
//  DLSFTPConnection.m
//  DLSFTPClient
//
//  Created by Dan Leehr on 8/11/12.
//  Copyright (c) 2012 Dan Leehr. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
// 
//  Redistributions of source code must retain the above copyright notice,
//  this list of conditions and the following disclaimer.
// 
//  Redistributions in binary form must reproduce the above copyright
//  notice, this list of conditions and the following disclaimer in the
//  documentation and/or other materials provided with the distribution.
// 
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
// IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
// TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
// PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
// TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
// LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
// NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#include <fcntl.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include "libssh2.h"
#include "libssh2_config.h"
#include "libssh2_sftp.h"

// keyboard-interactive response
static void response(const char *name,   int name_len, const char *instruction,   int instruction_len,   int num_prompts,   const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,   LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,   void **abstract);
static int waitsocket(int socket_fd, LIBSSH2_SESSION *session);

NSString * const SFTPClientErrorDomain = @"SFTPClientErrorDomain";
NSString * const SFTPClientUnderlyingErrorKey = @"SFTPClientUnderlyingError";

static const NSUInteger cDefaultSSHPort = 22;
static const NSTimeInterval cDefaultConnectionTimeout = 60.0;
static const size_t cBufferSize = 8192;

#import "DLSFTPConnection.h"
#import "DLSFTPFile.h"
#import "NSDictionary+SFTPFileAttributes.h"

@interface DLSFTPConnection () {

    // socket queue
    dispatch_queue_t _socketQueue;

    // file IO
    dispatch_queue_t _fileIOQueue;
}

@property (nonatomic, copy) id queuedSuccessBlock;
@property (nonatomic, copy) DLSFTPClientFailureBlock queuedFailureBlock;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *hostname;
@property (nonatomic, assign) NSUInteger port;

@property (nonatomic, assign) int socket;
@property (nonatomic, assign) LIBSSH2_SESSION *session;
@property (nonatomic, assign) LIBSSH2_SFTP *sftp;

@property (nonatomic, assign) BOOL isCancelled;
@end


@implementation DLSFTPConnection

@synthesize session=_session;
@synthesize sftp=_sftp;

#pragma mark Lifecycle

- (id)init {
    return [self initWithHostname:nil
                             port:0
                         username:nil
                         password:nil];
}

- (id)initWithHostname:(NSString *)hostname
              username:(NSString *)username
              password:(NSString *)password {
    return [self initWithHostname:hostname
                             port:cDefaultSSHPort
                         username:username
                         password:password];
}

- (id)initWithHostname:(NSString *)hostname
                  port:(NSUInteger)port
              username:(NSString *)username
              password:(NSString *)password {
    self = [super init];
    if (self) {
        self.hostname = hostname;
        self.port = port;
        self.username = username;
        self.password = password;
        self.socket = 0;
        _socketQueue = dispatch_queue_create("com.hammockdistrict.SFTPClient.socketqueue", DISPATCH_QUEUE_SERIAL);
        _fileIOQueue = dispatch_queue_create("com.hammockdistrict.SFTPClient.fileio", DISPATCH_QUEUE_SERIAL);
        _isCancelled = NO;
    }
    return self;
}

- (void)dealloc {
    self.sftp = NULL;
    self.session = NULL;
    [self disconnectSocket];
}

- (void)setSession:(LIBSSH2_SESSION *)session {
    // destroy if exists
    if (_session) {
        // check if _sftp exists
        self.sftp = NULL;
        libssh2_session_free(_session);
    }
    _session = session;
}

- (LIBSSH2_SESSION *)session {
    if (_session == NULL) {
        _session = libssh2_session_init_ex(NULL, NULL, NULL, (__bridge void *)self);
        // set non-blocking
        if (_session) {
            libssh2_session_set_blocking(_session, 0);
        }
    }
    return _session;
}

- (void)setSftp:(LIBSSH2_SFTP *)sftp {
    if (_sftp) {
        while (libssh2_sftp_shutdown(_sftp) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(self.socket, _session);
        }
    }
    _sftp = sftp;
}

// If there's an error initializing sftp, such as a non-authenticated connection, this will return NULL and we must check the session error
- (LIBSSH2_SFTP *)sftp {
    if (_sftp == NULL) {
        LIBSSH2_SESSION *session = self.session;
        // initialize sftp in non-blocking
        while (   (_sftp = libssh2_sftp_init(session)) == NULL
               && (libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN)) {
            waitsocket(self.socket, session);
        }
    }
    return _sftp;
}

#pragma mark - Private

- (void)disconnectSocket {
    close(self.socket);
    self.socket = 0;
}

- (void)startSFTPSession {
    dispatch_async(_socketQueue, ^{
        int socketFD = self.socket;
        LIBSSH2_SESSION *session = self.session;

        if (session == NULL) { // unable to access the session
            // close the socket
            [self disconnectSocket];
            // unable to initialize session
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSession
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Unable to initialize libssh2 session" }];
            if (self.queuedFailureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    self.queuedFailureBlock(error);
                    self.queuedFailureBlock = nil;
                    self.queuedSuccessBlock = nil;
                });
            }
            return;
        }
        // valid session, get the socket descriptor
        // must be called from socket's queue
        int result;
        while ((result = libssh2_session_handshake(session, socketFD) == LIBSSH2_ERROR_EAGAIN)) {
            waitsocket(socketFD, session);
        }
        if (result) {
            // handshake failed
            // free the session and close the socket
            [self disconnectSocket];

            NSString *errorDescription = [NSString stringWithFormat:@"Handshake failed with code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorHandshakeFailed
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (self.queuedFailureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    self.queuedFailureBlock(error);
                    self.queuedFailureBlock = nil;
                    self.queuedSuccessBlock = nil;
                });
            }
            return;
        }

        // handshake OK.

        // waitsocket just waits for the socket.  shouldn't use much CPU or anything and lets us be efficient about retrying a potentially blocking operation

        // get user auth methods
        char * authmethods = NULL;
        while (   (authmethods = libssh2_userauth_list(session, [self.username UTF8String], strlen([self.username UTF8String]))) == NULL
               && (libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN)) {
            waitsocket(socketFD, session);
        }

        // TODO: enable key-based authentication
        if (authmethods && strstr(authmethods, "password")) {
            while ((result = libssh2_userauth_password(session, [self.username UTF8String], [self.password UTF8String]) == LIBSSH2_ERROR_EAGAIN)) {
                waitsocket(socketFD, session);
            }
        } else if(authmethods && strstr(authmethods, "keyboard-interactive")) {
            while ((result = libssh2_userauth_keyboard_interactive(session, [_username UTF8String], response) == LIBSSH2_ERROR_EAGAIN)) {
                waitsocket(socketFD, session);
            }
        } else {
            result = LIBSSH2_ERROR_METHOD_NONE;
        }

        if (libssh2_userauth_authenticated(session) == 0) {
            // authentication failed
            // disconnect to disconnect/free the session and close the socket
            [self disconnect];
            NSString *errorDescription = [NSString stringWithFormat:@"Authentication failed with code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorAuthenticationFailed
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (self.queuedFailureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    self.queuedFailureBlock(error);
                    self.queuedFailureBlock = nil;
                    self.queuedSuccessBlock = nil;
                });
            }
            return;
        }

        // authentication succeeded
        // session is now created and we can use it
        if (self.queuedSuccessBlock) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), self.queuedSuccessBlock);
            self.queuedSuccessBlock = nil;
            self.queuedFailureBlock = nil;
        }
        return;
    });

}

#pragma mark Public

// just if the socket is connected
- (BOOL)isConnected {
    return self.socket != 0;
}

- (void)connectWithSuccessBlock:(DLSFTPClientSuccessBlock)successBlock
                   failureBlock:(DLSFTPClientFailureBlock)failureBlock {
    if (self.queuedSuccessBlock) {
        // last connection not yet connected
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorOperationInProgress
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Operation in progress" }];
        if (failureBlock) {
            failureBlock(error);
        }
    } else if (   ([self.hostname length] == 0)
               || ([self.username length] == 0)
               || ([self.password length] == 0)
               || (self.port == 0)) {
            // don't have valid arguments
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorInvalidArguments
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Invalid arguments" }];
        if (failureBlock) {
            failureBlock(error);
        }
    } else if(self.socket) {
        // already have a socket
        // last connection not yet connected
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorAlreadyConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Already connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
    } else {
        self.queuedSuccessBlock = successBlock;
        self.queuedFailureBlock = failureBlock;

        __weak DLSFTPConnection *weakSelf = self;

        // initialize and connect the socket on the socket queue
        dispatch_async(_socketQueue, ^{
            unsigned long hostaddr = inet_addr([weakSelf.hostname UTF8String]);
            weakSelf.socket = socket(AF_INET, SOCK_STREAM, 0);
            struct sockaddr_in soin;
            soin.sin_family = AF_INET;
            soin.sin_port = htons(weakSelf.port);
            soin.sin_addr.s_addr = hostaddr;
            // how to do timeouts?
            int result = connect(weakSelf.socket, (struct sockaddr*)(&soin),sizeof(struct sockaddr_in));
            if (result == 0) {
                // connected socket, start the SFTP session
                [weakSelf startSFTPSession];
            } else {
                NSString *errorDescription = [NSString stringWithFormat:@"Unable to connect: socket error: %d", result];
                NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                     code:eSFTPClientErrorUnableToConnect
                                                 userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
                // early error
                if (weakSelf.queuedFailureBlock) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        if (weakSelf.queuedFailureBlock) {
                            weakSelf.queuedFailureBlock(error);
                            weakSelf.queuedFailureBlock = nil;
                        }
                    });
                }
                // clear out queued blocks
                weakSelf.queuedSuccessBlock = nil;
            }
        });
    }
}

- (void)disconnect {
    dispatch_sync(_socketQueue, ^{
        self.sftp = NULL;
        self.session = NULL;
        [self disconnectSocket];
    });
}

// use a file descriptor to set this, like a pipe perhaps.  include it in waitsocket so waitsocket returns when cancel is set
- (void)cancelTransfer {
    dispatch_sync(_socketQueue, ^{
        self.isCancelled = YES;
    });

}

#pragma mark SFTP

// list files
- (void)listFilesInDirectory:(NSString *)directoryPath
                successBlock:(DLSFTPClientArraySuccessBlock)successBlock
                failureBlock:(DLSFTPClientFailureBlock)failureBlock {

    if ([self isConnected] == NO) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorNotConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Socket not connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    dispatch_async(_socketQueue,^{
        LIBSSH2_SESSION *session = self.session;
        LIBSSH2_SFTP *sftp = self.sftp;
        int socketFD = self.socket;

        if (sftp == NULL) {
            // unable to initialize sftp
            int lastError = libssh2_session_last_errno(session);
            char *errmsg = NULL;
            int errmsg_len = 0;
            libssh2_session_last_error(session, &errmsg, &errmsg_len, 0);
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to initialize sftp: libssh2 session error %s: %d"
                                          , errmsg
                                          , lastError];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSFTP
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // sftp is now valid
        // get a file handle for reading the directory
        LIBSSH2_SFTP_HANDLE *handle = NULL;
        while(   ((handle = libssh2_sftp_opendir(sftp, [directoryPath UTF8String])) == NULL
              && (libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN))) {
            waitsocket(socketFD, session);
        }
        if (handle == NULL) {
            // unable to open directory
            unsigned long lastError = libssh2_sftp_last_error(sftp);
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to open directory: sftp error: %ld", lastError];

            // unable to initialize session
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToOpenDirectory
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(lastError)  }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // handle is now open
        char buffer[cBufferSize];

        LIBSSH2_SFTP_ATTRIBUTES attributes;

        // opened directory, have a handle.  now read it
        // These get dupicates
        NSMutableArray *fileList = [[NSMutableArray alloc] init];
        int result = 0;

        //attempt to read
        // EAGAIN means waitsocket
        // <0 means error
        // >0 means got data
        do {
            while ((result = libssh2_sftp_readdir(handle, buffer, cBufferSize, &attributes)) == LIBSSH2SFTP_EAGAIN) {
                waitsocket(socketFD, session);
            }
            if (result > 0) {
                NSString *filename = [NSString stringWithUTF8String:buffer];
                // skip . and ..
                if ([filename isEqualToString:@"."] || [filename isEqualToString:@".."]) {
                    continue;
                }
                NSString *filepath = [directoryPath stringByAppendingPathComponent:filename];
                NSDictionary *attributesDictionary = [NSDictionary dictionaryWithAttributes:attributes];
                DLSFTPFile *file = [[DLSFTPFile alloc] initWithPath:filepath
                                                         attributes:attributesDictionary];
                [fileList addObject:file];
            }
        } while (result > 0);

        if (result < 0) {
            result = libssh2_sftp_last_error(sftp);
            while ((libssh2_sftp_closedir(handle)) == LIBSSH2SFTP_EAGAIN) {
                waitsocket(socketFD, session);
            }
            // error reading
            NSString *errorDescription = [NSString stringWithFormat:@"Read directory failed with code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToReadDirectory
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result)  }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // close the handle
        while((result = libssh2_sftp_closedir(handle)) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }
        if (result) {
            NSString *errorDescription = [NSString stringWithFormat:@"Close directory handle failed with code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToCloseDirectory
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result)  }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        [fileList sortUsingSelector:@selector(compare:)];
        if (successBlock) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                successBlock(fileList);
            });
        }
    });
}

- (void)makeDirectory:(NSString *)directoryPath
         successBlock:(DLSFTPClientFileMetadataSuccessBlock)successBlock
         failureBlock:(DLSFTPClientFailureBlock)failureBlock {
    if ([directoryPath length] == 0) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorInvalidArguments
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Directory name is empty" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    if ([self isConnected] == NO) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorNotConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Socket not connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    dispatch_async(_socketQueue,^{
        LIBSSH2_SESSION *session = self.session;
        LIBSSH2_SFTP *sftp = self.sftp;
        int socketFD = self.socket;

        if (sftp == NULL) {
            // unable to initialize sftp
            int lastError = libssh2_session_last_errno(session);
            char *errmsg = NULL;
            int errmsg_len = 0;
            libssh2_session_last_error(session, &errmsg, &errmsg_len, 0);
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to initialize sftp: libssh2 session error %s: %d"
                                          , errmsg
                                          , lastError];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSFTP
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // sftp is now valid
        // try to make the directory 0755
        long mode = (LIBSSH2_SFTP_S_IRWXU|
                     LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IXGRP|
                     LIBSSH2_SFTP_S_IROTH|LIBSSH2_SFTP_S_IXOTH);

        int result;
        while((result = (libssh2_sftp_mkdir(sftp, [directoryPath UTF8String], mode))) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }

        if (result) {
            // unable to make the directory
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to make directory: SFTP Status Code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToMakeDirectory
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // Directory made, stat it.
        // can use stat since we don't need a descriptor
        LIBSSH2_SFTP_ATTRIBUTES attributes;
        while ((result = libssh2_sftp_stat(sftp, [directoryPath UTF8String], &attributes)) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }
        if (result) {
            // unable to stat the directory
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to stat newly created directory: SFTP Status Code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToStatFile
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // attributes are valid
        NSDictionary *attributesDictionary = [NSDictionary dictionaryWithAttributes:attributes];
        DLSFTPFile *createdDirectory = [[DLSFTPFile alloc] initWithPath:directoryPath
                                                             attributes:attributesDictionary];

        if (successBlock) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                successBlock(createdDirectory);
            });
        }
    });
}

- (void)renameOrMoveItemAtRemotePath:(NSString *)remotePath
                         withNewPath:(NSString *)newPath
                        successBlock:(DLSFTPClientFileMetadataSuccessBlock)successBlock
                        failureBlock:(DLSFTPClientFailureBlock)failureBlock {

    if (   ([remotePath length] == 0)
        || ([newPath length] == 0)) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorInvalidArguments
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Renaming path is empty" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    if ([self isConnected] == NO) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorNotConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Socket not connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    dispatch_async(_socketQueue,^{
        LIBSSH2_SESSION *session = self.session;
        LIBSSH2_SFTP *sftp = self.sftp;
        int socketFD = self.socket;

        if (sftp == NULL) {
            // unable to initialize sftp
            int lastError = libssh2_session_last_errno(session);
            char *errmsg = NULL;
            int errmsg_len = 0;
            libssh2_session_last_error(session, &errmsg, &errmsg_len, 0);
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to initialize sftp: libssh2 session error %s: %d"
                                          , errmsg
                                          , lastError];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSFTP
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // sftp is now valid

        int result;

        // libssh2_sftp_rename includes overwrite | atomic | native
        while((result = (libssh2_sftp_rename(sftp, [remotePath UTF8String], [newPath UTF8String]))) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }

        if (result) {
            // unable to rename 
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to rename item: SFTP Status Code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToRename
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // item renamed, stat the new item
        // can use stat since we don't need a descriptor
        LIBSSH2_SFTP_ATTRIBUTES attributes;
        while ((result = libssh2_sftp_stat(sftp, [newPath UTF8String], &attributes)) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }
        if (result) {
            // unable to stat the new item
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to stat newly renamed item: SFTP Status Code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToStatFile
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // attributes are valid
        NSDictionary *attributesDictionary = [NSDictionary dictionaryWithAttributes:attributes];
        DLSFTPFile *renamedItem = [[DLSFTPFile alloc] initWithPath:newPath
                                                        attributes:attributesDictionary];

        if (successBlock) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                successBlock(renamedItem);
            });
        }
    });
}

- (void)removeFileAtPath:(NSString *)remotePath
            successBlock:(DLSFTPClientSuccessBlock)successBlock
            failureBlock:(DLSFTPClientFailureBlock)failureBlock {
    if ([remotePath length] == 0) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorInvalidArguments
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Path to remove is empty" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    if ([self isConnected] == NO) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorNotConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Socket not connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    dispatch_async(_socketQueue,^{
        LIBSSH2_SESSION *session = self.session;
        LIBSSH2_SFTP *sftp = self.sftp;
        int socketFD = self.socket;

        if (sftp == NULL) {
            // unable to initialize sftp
            int lastError = libssh2_session_last_errno(session);
            char *errmsg = NULL;
            int errmsg_len = 0;
            libssh2_session_last_error(session, &errmsg, &errmsg_len, 0);

            NSString *errorDescription = [NSString stringWithFormat:@"Unable to initialize sftp: libssh2 session error %s: %d"
                                          , errmsg
                                          , lastError];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSFTP
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // sftp is now valid

        int result;
        while((result = (libssh2_sftp_unlink(sftp, [remotePath UTF8String]))) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }

        if (result) {
            // unable to remove
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to remove file: SFTP Status Code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToRename
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // file removed
        if (successBlock) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                successBlock();
            });
        }
    });

}

- (void)removeDirectoryAtPath:(NSString *)remotePath
                 successBlock:(DLSFTPClientSuccessBlock)successBlock
                 failureBlock:(DLSFTPClientFailureBlock)failureBlock {
    if ([remotePath length] == 0) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorInvalidArguments
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Path to remove is empty" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    if ([self isConnected] == NO) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorNotConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Socket not connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    dispatch_async(_socketQueue,^{
        LIBSSH2_SESSION *session = self.session;
        LIBSSH2_SFTP *sftp = self.sftp;
        int socketFD = self.socket;

        if (sftp == NULL) {
            // unable to initialize sftp
            int lastError = libssh2_session_last_errno(session);
            char *errmsg = NULL;
            int errmsg_len = 0;
            libssh2_session_last_error(session, &errmsg, &errmsg_len, 0);

            NSString *errorDescription = [NSString stringWithFormat:@"Unable to initialize sftp: libssh2 session error %s: %d"
                                          , errmsg
                                          , lastError];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSFTP
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // sftp is now valid

        int result;
        while((result = (libssh2_sftp_rmdir(sftp, [remotePath UTF8String]))) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }

        if (result) {
            // unable to remove
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to remove directory: SFTP Status Code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToRename
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // directory removed
        if (successBlock) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                successBlock();
            });
        }
    });
    
}


- (void)downloadFileAtRemotePath:(NSString *)remotePath
                     toLocalPath:(NSString *)localPath
                   progressBlock:(DLSFTPClientProgressBlock)progressBlock
                    successBlock:(DLSFTPClientFileTransferSuccessBlock)successBlock
                    failureBlock:(DLSFTPClientFailureBlock)failureBlock {
    if ([self isConnected] == NO) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorNotConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Not connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }

    dispatch_async(_socketQueue, ^{
        // create file if it does not exist
        if ([[NSFileManager defaultManager] fileExistsAtPath:localPath] == NO) {
            [[NSFileManager defaultManager] createFileAtPath:localPath
                                                    contents:nil
                                                  attributes:nil];
        }

        if ([[NSFileManager defaultManager] isWritableFileAtPath:localPath] == NO) {
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToOpenLocalFileForWriting
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Local file is not writable" }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        LIBSSH2_SESSION *session = self.session;
        LIBSSH2_SFTP *sftp = self.sftp;
        int socketFD = self.socket;
        if (sftp == NULL) {
            // unable to initialize sftp
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSFTP
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Unable to initialize sftp" }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // sftp is now valid
        // get a file handle for the file to download
        // TODO: resumable downloads
        LIBSSH2_SFTP_HANDLE *handle = NULL;
        while (   (handle = libssh2_sftp_open(sftp, [remotePath UTF8String], LIBSSH2_FXF_READ, 0)) == NULL
               && (libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN)) {
            waitsocket(socketFD, session);
        }
        if (handle == NULL) {
            // unable to open file
            // get last error
            unsigned long lastError = libssh2_sftp_last_error(sftp);
            // TODO: enumerate the errors instead of just printing code

            NSString *errorDescription = [NSString stringWithFormat:@"Unable to open file for reading: SFTP Status Code %ld", lastError];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToOpenFile
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(lastError) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }
        // should be able to cancel any of these

        // file handle is now open
        LIBSSH2_SFTP_ATTRIBUTES attributes;
        int result;
        while ((result = libssh2_sftp_fstat(handle, &attributes)) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }
        // can also check permissions/types
        if (result) {
            // unable to stat the file
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to stat file: SFTP Status Code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToStatFile
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        dispatch_group_t downloadGroup = dispatch_group_create();

        // join the group from the socket queue
        dispatch_group_enter(downloadGroup);
        // join the group from the fileIOQueue
        dispatch_async(_fileIOQueue, ^{
            dispatch_group_enter(downloadGroup);
        });

        /* Begin dispatch io */

        dispatch_io_t channel = dispatch_io_create_with_path(  DISPATCH_IO_STREAM
                                                             , [localPath UTF8String]
                                                             , (O_WRONLY | O_CREAT | O_TRUNC)
                                                             , 0
                                                             , _fileIOQueue
                                                             , ^(int error) {
                                                                 // when the channel is cleaned up, leave the group
                                                                 dispatch_group_leave(downloadGroup);
                                                                 if (error) {
                                                                     printf("error in dispatch io: %d\n", error);
                                                                 }
                                                             });
        if (channel == NULL) {
            // Error creating the channel
            NSString *errorDescription = [NSString stringWithFormat:@"Unable to create a chhannel for writing to %@", localPath];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToCreateChannel
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription } ];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // dispatch source to invoke progress handler block
        __block BOOL shouldContinue = YES; // user has not cancelled

        dispatch_source_t progressSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
        __block unsigned long long bytesReceived = 0ull;
        unsigned long long filesize = attributes.filesize;
        dispatch_source_set_event_handler(progressSource, ^{
                bytesReceived += dispatch_source_get_data(progressSource);
            if (progressBlock) {
                shouldContinue = progressBlock(bytesReceived, filesize);
            }
        });

        char buffer[cBufferSize];

        int bytesRead = 0;
        dispatch_resume(progressSource);

        NSDate *startTime = [NSDate date];

        do {
            // first read data from libssh2
            bytesRead = 0;
            while (   shouldContinue
                   && (bytesRead = libssh2_sftp_read(handle, buffer, cBufferSize)) == LIBSSH2SFTP_EAGAIN) {
                // Consider making shouldContinue a file descriptor source so we can monitor it like we do waitsocket
                waitsocket(socketFD, session);
            }
            if (shouldContinue == NO) {
                break;
            }
            // after data has been read, write it to the channel
            if (bytesRead > 0) {
                dispatch_source_merge_data(progressSource, bytesRead);
                dispatch_data_t data = dispatch_data_create(buffer, bytesRead, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
                dispatch_io_write(  channel
                                  , 0
                                  , data
                                  , _fileIOQueue // just for reporting the below block
                                  , ^(bool done, dispatch_data_t data, int error) {
                                      // done refers to the chunk of data written
                                      // TODO: consider moving progress reporting here
                                      if (error) {
                                          printf("error in dispatch_io_write %d\n", error);
                                      }
                                  });
            } // if bytesRead is 0 or less than 0, reading is finished
        } while (shouldContinue && (bytesRead > 0));

        NSDate *finishTime = [NSDate date];
        dispatch_source_cancel(progressSource);
        dispatch_io_close(channel, 0);
        channel = NULL;

        /* End dispatch_io */

        dispatch_group_leave(downloadGroup);
        dispatch_group_wait(downloadGroup, DISPATCH_TIME_FOREVER);

        if (shouldContinue == NO) {
            // cancelled by user
            while(libssh2_sftp_close_handle(handle) == LIBSSH2SFTP_EAGAIN) {
                waitsocket(socketFD, session);
            }

            // delete the file
            NSError __autoreleasing *deleteError = nil;
            if([[NSFileManager defaultManager] removeItemAtPath:localPath error:&deleteError] == NO) {
                NSLog(@"Unable to delete unfinished file: %@", deleteError);
            }

            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorCancelledByUser
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Cancelled by user." }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        if (bytesRead < 0) {
            // get the error before closing the file
            int result = libssh2_sftp_last_error(sftp);
            while(libssh2_sftp_close_handle(handle) == LIBSSH2SFTP_EAGAIN) {
                waitsocket(socketFD, session);
            }
            // error reading
            NSString *errorDescription = [NSString stringWithFormat:@"Read file failed with code %d.", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToReadFile
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // now close the remote handle
        while((result = libssh2_sftp_close_handle(handle)) == LIBSSH2SFTP_EAGAIN) {
            waitsocket(socketFD, session);
        }
        if (result) {
            NSString *errorDescription = [NSString stringWithFormat:@"Close file handle failed with code %d", result];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToCloseFile
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }
        NSDictionary *attributesDictionary = [NSDictionary dictionaryWithAttributes:attributes];
        DLSFTPFile *file = [[DLSFTPFile alloc] initWithPath:remotePath
                                                 attributes:attributesDictionary];

        if (successBlock) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                successBlock(file, startTime, finishTime);

            });
        }
    });
}

- (void)uploadFileToRemotePath:(NSString *)remotePath
                 fromLocalPath:(NSString *)localPath
                 progressBlock:(DLSFTPClientProgressBlock)progressBlock
                  successBlock:(DLSFTPClientFileTransferSuccessBlock)successBlock
                  failureBlock:(DLSFTPClientFailureBlock)failureBlock {
    if ([self isConnected] == NO) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorNotConnected
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Not connected" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }
    if (remotePath == nil) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorInvalidArguments
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Remote path not specified" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }
    if (localPath == nil) {
        NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                             code:eSFTPClientErrorInvalidArguments
                                         userInfo:@{ NSLocalizedDescriptionKey : @"Local path not specified" }];
        if (failureBlock) {
            failureBlock(error);
        }
        return;
    }


    dispatch_async(_socketQueue, ^{
        // verify local file is readable prior to upload
        if ([[NSFileManager defaultManager] isReadableFileAtPath:localPath] == NO) {
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToOpenLocalFileForReading
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Local file is not readable" }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        NSError __autoreleasing *attributesError = nil;
        NSDictionary *localFileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:localPath
                                                                                             error:&attributesError];
        if (localFileAttributes == nil) {
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToOpenLocalFileForReading
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Unable to get attributes of Local file", NSUnderlyingErrorKey : attributesError }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        LIBSSH2_SESSION *session = self.session;
        LIBSSH2_SFTP *sftp = self.sftp;
        int socketFD = self.socket;
        if (sftp == NULL) {
            // unable to initialize sftp
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToInitializeSFTP
                                             userInfo:@{ NSLocalizedDescriptionKey : @"Unable to initialize sftp" }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // sftp is now valid
        // get a file handle for the file to upload
        // write, create, or truncate.  There's also append and excl
        // permissions 644 (can customize later)
        // TODO: customize permissions later or base them on local file?
        // TODO: resume uploads?  first stat the remote file if it exists
        LIBSSH2_SFTP_HANDLE *handle = NULL;
                     while (   (handle = libssh2_sftp_open(  sftp
                                                           , [remotePath UTF8String]
                                                           , LIBSSH2_FXF_WRITE|LIBSSH2_FXF_CREAT|LIBSSH2_FXF_READ
                                                           , LIBSSH2_SFTP_S_IRUSR|LIBSSH2_SFTP_S_IWUSR|
                                                             LIBSSH2_SFTP_S_IRGRP|LIBSSH2_SFTP_S_IROTH)) == NULL
                            && (libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN)) {
            waitsocket(socketFD, session);
        }
        
        if (handle == NULL) {
            // unable to open file handle
            // get last error
            unsigned long lastError = libssh2_sftp_last_error(sftp);
            // TODO: enumerate the errors instead of just printing code

            NSString *errorDescription = [NSString stringWithFormat:@"Unable to open file for writing: SFTP Status Code %ld", lastError];
            NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                 code:eSFTPClientErrorUnableToOpenFile
                                             userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(lastError) }];
            if (failureBlock) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    failureBlock(error);
                });
            }
            return;
        }

        // jump to the file IO queue
        dispatch_async(_fileIOQueue, ^{
            void(^cleanup_handler)(int) = ^(int error) {
            };

            dispatch_io_t channel = dispatch_io_create_with_path(  DISPATCH_IO_STREAM
                                                                 , [localPath UTF8String]
                                                                 , O_RDONLY
                                                                 , 0
                                                                 , _fileIOQueue
                                                                 , cleanup_handler
                                                                 );

            // dispatch source to invoke progress handler block
            __block BOOL shouldContinue = YES;

            dispatch_source_t progressSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
            __block unsigned long long totalBytesSent = 0ull;
            unsigned long long filesize = [localFileAttributes fileSize];
            dispatch_source_set_event_handler(progressSource, ^{
                totalBytesSent += dispatch_source_get_data(progressSource);
                if (progressBlock) {
                    shouldContinue = progressBlock(totalBytesSent, filesize);
                }
            });

            dispatch_resume(progressSource);

            NSDate *startTime = [NSDate date];
            __block int sftp_result = 0;
            __block int read_error = 0;

            // this block gets dispatched on the socket queue
            dispatch_block_t read_finished_block = ^{
                NSDate *finishTime = [NSDate date];
                if (shouldContinue == NO) {
                    // Cancelled by user
                    while(libssh2_sftp_close_handle(handle) == LIBSSH2SFTP_EAGAIN) {
                        waitsocket(socketFD, session);
                    }

                    // delete remote file on cancel?
                    NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                         code:eSFTPClientErrorCancelledByUser
                                                     userInfo:@{ NSLocalizedDescriptionKey : @"Cancelled by user." }];
                    if (failureBlock) {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                            failureBlock(error);
                        });
                    }
                    return;
                }

                if (read_error != 0) {
                    // error reading file
                    NSString *errorDescription = [NSString stringWithFormat:@"Read local file failed with code %d", read_error];
                    NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                         code:eSFTPClientErrorUnableToReadFile
                                                     userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(read_error) }];
                    if (failureBlock) {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                            failureBlock(error);
                        });
                    }
                    return;
                }

                if (sftp_result < 0) { // error on last call to upload
                    // get the error before closing the file
                    int result = libssh2_sftp_last_error(sftp);
                    while(libssh2_sftp_close_handle(handle) == LIBSSH2SFTP_EAGAIN) {
                        waitsocket(socketFD, session);
                    }
                    // error writing
                    NSString *errorDescription = [NSString stringWithFormat:@"Write file failed with code %d.", result];
                    NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                         code:eSFTPClientErrorUnableToWriteFile
                                                     userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
                    if (failureBlock) {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                            failureBlock(error);
                        });
                    }
                    return;
                }

                int result;
                // stat the remote file after uploading
                LIBSSH2_SFTP_ATTRIBUTES attributes;
                while ((result = libssh2_sftp_fstat(handle, &attributes)) == LIBSSH2SFTP_EAGAIN) {
                    waitsocket(socketFD, session);
                }
                if (result) {
                    // unable to stat the file
                    NSString *errorDescription = [NSString stringWithFormat:@"Unable to stat file: SFTP Status Code %d", result];
                    NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                         code:eSFTPClientErrorUnableToStatFile
                                                     userInfo:@{ NSLocalizedDescriptionKey : errorDescription, SFTPClientUnderlyingErrorKey : @(result) }];
                    if (failureBlock) {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                            failureBlock(error);
                        });
                    }
                    return;
                }

                // now close the remote handle
                while((result = libssh2_sftp_close_handle(handle)) == LIBSSH2SFTP_EAGAIN) {
                    waitsocket(socketFD, session);
                }
                if (result) {
                    NSString *errorDescription = [NSString stringWithFormat:@"Close file handle failed with code %d", result];
                    NSError *error = [NSError errorWithDomain:SFTPClientErrorDomain
                                                         code:eSFTPClientErrorUnableToCloseFile
                                                     userInfo:@{ NSLocalizedDescriptionKey : errorDescription }];
                    if (failureBlock) {
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                            failureBlock(error);
                        });
                    }
                    return;
                }

                NSDictionary *attributesDictionary = [NSDictionary dictionaryWithAttributes:attributes];
                DLSFTPFile *file = [[DLSFTPFile alloc] initWithPath:remotePath
                                                         attributes:attributesDictionary];

                if (successBlock) {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        successBlock(file, startTime, finishTime);
                    });
                }
            }; // end of read_finished_block

            // dispatch this block on file io queue
            dispatch_block_t channel_cleanup_block = ^{
                dispatch_source_cancel(progressSource);
                dispatch_io_close(channel, DISPATCH_IO_STOP);
                dispatch_async(_socketQueue, read_finished_block);
            }; // end channel cleanup block

            dispatch_io_read(  channel
                             , 0 // for stream, offset is ignored
                             , SIZE_MAX
                             , _socketQueue // blocks with data queued on the socket queue
                             , ^(bool done, dispatch_data_t data, int error) {
                                 // data has been read into dispatch_data_t data
                                 // this will be executed on _socketQueue
                                 // now loop over the data in sizes smaller than the buffer
                                 size_t buffered_chunk_size = MIN(cBufferSize, dispatch_data_get_size(data));
                                 size_t offset = 0;
                                 const void *buffer;
                                 while (   (buffered_chunk_size > 0)
                                        && (offset < dispatch_data_get_size(data))
                                        && shouldContinue) {
                                     dispatch_data_t buffered_chunk_subrange = dispatch_data_create_subrange(data, offset, buffered_chunk_size);
                                     size_t bytes_read = 0;
                                     // map the subrange to make sure we have a contiguous buffer
                                     dispatch_data_t mapped_buffered_chunk_subrange = dispatch_data_create_map(buffered_chunk_subrange, &buffer, &bytes_read);

                                     // send the buffer
                                     while (   shouldContinue
                                            && (sftp_result = libssh2_sftp_write(handle, buffer, bytes_read)) == LIBSSH2SFTP_EAGAIN) {
                                         // update shouldcontinue into the waitsocket file desctiptor
                                         waitsocket(socketFD, session);
                                     }
                                     mapped_buffered_chunk_subrange = NULL;
                                     
                                     offset += bytes_read;

                                     if (sftp_result > 0) {
                                         dispatch_source_merge_data(progressSource, sftp_result);
                                     } else {
                                         // error in SFTP write
                                         dispatch_async(_fileIOQueue, channel_cleanup_block);
                                     }
                                 }
                                 // end of reading while loop in dispatch_io_handler
                                 read_error = error;
                                 if (done) {
                                     dispatch_async(_fileIOQueue, channel_cleanup_block);
                                 }
                             }); // end of dispatch_io_read
        }); // end of _fileIOQueue
    }); // end of socketQueue

}


@end

// waitsocket from http://www.libssh2.org/examples/

static int waitsocket(int socket_fd, LIBSSH2_SESSION *session) {
    struct timeval timeout;
    int rc;
    fd_set fd;
    fd_set *writefd = NULL;
    fd_set *readfd = NULL;
    int dir;

    timeout.tv_sec = 10;
    timeout.tv_usec = 0;

    FD_ZERO(&fd);

    FD_SET(socket_fd, &fd);

    /* now make sure we wait in the correct direction */
    dir = libssh2_session_block_directions(session);

    if(dir & LIBSSH2_SESSION_BLOCK_INBOUND)
        readfd = &fd;

    if(dir & LIBSSH2_SESSION_BLOCK_OUTBOUND)
        writefd = &fd;

    rc = select(socket_fd + 1, readfd, writefd, NULL, &timeout);

    return rc;
}


// callback function for keyboard-interactive authentication
static void response(const char *name,
                     int name_len,
                     const char *instruction,
                     int instruction_len,
                     int num_prompts,
                     const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                     LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,
                     void **abstract) {
    DLSFTPConnection *connection = (__bridge DLSFTPConnection *)*abstract;

    if (num_prompts > 0) {
        // check if prompt is password
        // assume responses matches prompts
        // according to documentation, string values will be free'd
        const char *password = [connection.password UTF8String];
        responses[0].text = malloc(strlen(password) * sizeof(char) + 1);
        strcpy(responses[0].text, password);
        responses[0].length = strlen(password);
    }
}

