//
//  LoginViewController.m
//  DLSFTPClient
//
//  Created by Dan Leehr on 8/15/12.
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

#import "LoginViewController.h"
#import "FileBrowserViewController.h"
#import "LocalFilesViewController.h"
#import "DLSFTPConnection.h"
#import "DLDocumentsDirectoryPath.h"

enum eFieldIndex {
      eFieldIndexUsername = 1
    , eFieldIndexPassword
    , eFieldIndexHost
    , eFieldIndexPort
    , eFieldCount
    };


@interface LoginViewController () <UITextFieldDelegate> {
    UITextField *_usernameField;
    UITextField *_passwordField;
    UITextField *_hostField;
    UITextField *_portField;
}

@property (strong, nonatomic) DLSFTPConnection *connection;

@end

@implementation LoginViewController

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        self.title = @"SFTP Login";
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Login"
                                                                                  style:UIBarButtonItemStyleDone
                                                                                 target:self
                                                                                 action:@selector(loginTapped:)];
        UIBarButtonItem *localFiles = [[UIBarButtonItem alloc] initWithTitle:@"Local Files"
                                                                       style:UIBarButtonItemStyleBordered
                                                                      target:self
                                                                      action:@selector(showLocalFiles:)];
        self.toolbarItems = @[ localFiles ];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    UILabel *usernameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    usernameLabel.text = @"Username:";
    usernameLabel.textAlignment = UITextAlignmentLeft;
    usernameLabel.font = [UIFont boldSystemFontOfSize:17.0f];
    [usernameLabel sizeToFit];

    CGRect frame = usernameLabel.frame;
    frame.origin = CGPointMake(  CGRectGetMinX(self.view.bounds) + 20.0f
                               , CGRectGetMinY(self.view.bounds) + 20.0f);
    usernameLabel.frame = frame;
    
    CGFloat labelWidth = CGRectGetWidth(usernameLabel.frame);
    CGFloat labelHeight = CGRectGetHeight(usernameLabel.frame);
    CGFloat fieldHeight = 32.0f;
    
    UILabel *passwordLabel = [[UILabel alloc] initWithFrame:CGRectMake(  CGRectGetMinX(usernameLabel.frame)
                                                                       , CGRectGetMaxY(usernameLabel.frame) + 20.0f
                                                                       , labelWidth
                                                                       , labelHeight)];
    passwordLabel.text = @"Password:";
    passwordLabel.textAlignment = UITextAlignmentLeft;
    passwordLabel.font = [UIFont boldSystemFontOfSize:17.0f];

    UITextField *usernameField = [[UITextField alloc] initWithFrame:CGRectMake(  CGRectGetMaxX(usernameLabel.frame) + 20.0f
                                                                               , CGRectGetMinY(usernameLabel.frame)
                                                                               , CGRectGetMaxX(self.view.bounds) - CGRectGetMaxX(usernameLabel.frame) - 2.0f * 20.0f
                                                                               , fieldHeight)];
    usernameField.delegate = self;
    usernameField.keyboardType = UIKeyboardTypeDefault;
    usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
    usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    usernameField.borderStyle = UITextBorderStyleRoundedRect;
    usernameField.returnKeyType = UIReturnKeyNext;
    usernameField.tag = eFieldIndexUsername;
    _usernameField = usernameField;
    
    UITextField *passwordField = [[UITextField alloc] initWithFrame:CGRectMake(  CGRectGetMaxX(passwordLabel.frame) + 20.0f
                                                                               , CGRectGetMinY(passwordLabel.frame)
                                                                               , CGRectGetMaxX(self.view.bounds) - CGRectGetMaxX(passwordLabel.frame) - 2.0f * 20.0f
                                                                               , fieldHeight)];
    passwordField.delegate = self;
    passwordField.secureTextEntry = YES;
    passwordField.borderStyle = UITextBorderStyleRoundedRect;
    passwordField.returnKeyType = UIReturnKeyNext;
    passwordField.tag = eFieldIndexPassword;
    _passwordField = passwordField;

    // host
    UILabel *hostLabel = [[UILabel alloc] initWithFrame:CGRectMake(  CGRectGetMinX(passwordLabel.frame)
                                                                   , CGRectGetMaxY(passwordLabel.frame) + 20.0f
                                                                   , labelWidth
                                                                   , labelHeight)];
    hostLabel.text = @"Host:";
    hostLabel.textAlignment = UITextAlignmentLeft;
    hostLabel.font = [UIFont boldSystemFontOfSize:17.0f];

    // line

    UITextField *hostField = [[UITextField alloc] initWithFrame:CGRectMake(  CGRectGetMaxX(hostLabel.frame) + 20.0f
                                                                           , CGRectGetMinY(hostLabel.frame)
                                                                           , CGRectGetMaxX(self.view.bounds) - CGRectGetMaxX(hostLabel.frame) - 2.0f * 20.0f
                                                                           , fieldHeight)];
    hostField.delegate = self;
    hostField.borderStyle = UITextBorderStyleRoundedRect;
    hostField.keyboardType = UIKeyboardTypeURL;
    hostField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    hostField.autocorrectionType = UITextAutocorrectionTypeNo;
    hostField.returnKeyType = UIReturnKeyNext;
    hostField.tag = eFieldIndexHost;
    _hostField = hostField;

    // port
    UILabel *portLabel = [[UILabel alloc] initWithFrame:CGRectMake(  CGRectGetMinX(hostLabel.frame)
                                                                   , CGRectGetMaxY(hostLabel.frame) + 20.0f
                                                                   , labelWidth
                                                                   , labelHeight)];
    portLabel.text = @"Port:";
    portLabel.textAlignment = UITextAlignmentLeft;
    portLabel.font = [UIFont boldSystemFontOfSize:17.0f];

    UITextField *portField = [[UITextField alloc] initWithFrame:CGRectMake(  CGRectGetMaxX(portLabel.frame) + 20.0f
                                                                           , CGRectGetMinY(portLabel.frame)
                                                                           , CGRectGetMaxX(self.view.bounds) - CGRectGetMaxX(portLabel.frame) - 2.0f * 20.0f
                                                                           , fieldHeight)];
    portField.delegate = self;
    portField.keyboardType = UIKeyboardTypeNumberPad;
    portField.borderStyle = UITextBorderStyleRoundedRect;
    portField.returnKeyType = UIReturnKeyGo;
    portField.tag = eFieldIndexPort;
    _portField = portField;

    [self.view addSubview:usernameLabel];
    [self.view addSubview:passwordLabel];
    [self.view addSubview:usernameField];
    [self.view addSubview:passwordField];
    [self.view addSubview:hostLabel];
    [self.view addSubview:hostField];
    [self.view addSubview:portLabel];
    [self.view addSubview:portField];
}

- (void)showLocalFiles:(id)sender {
    UIViewController *viewController = [[LocalFilesViewController alloc] initWithPath:DLDocumentsDirectoryPath()];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:viewController];

    [self.navigationController presentViewController:navigationController
                                            animated:YES
                                          completion:nil];
}


- (void)loginTapped:(id)sender {
    NSString *username = [_usernameField.text copy];
    NSString *password = [_passwordField.text copy];
    NSInteger port = [_portField.text integerValue];
    NSString *host = [_hostField.text copy];

    UIBarButtonItem *loginButton = self.navigationItem.rightBarButtonItem;
    loginButton.enabled = NO;

    __weak LoginViewController *weakSelf = self;

    // make a connection object and attempt to connect
    DLSFTPConnection *connection = [[DLSFTPConnection alloc] initWithHostname:host
                                                                                   port:port
                                                                               username:username
                                                                               password:password];
    self.connection = connection;
    DLSFTPClientSuccessBlock successBlock = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // login successful
            FileBrowserViewController *viewController = [[FileBrowserViewController alloc] initWithSFTPConnection:connection];
            [weakSelf.navigationController pushViewController:viewController animated:YES];
        });
    };

    DLSFTPClientFailureBlock failureBlock = ^(NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.connection = nil;
            loginButton.enabled = YES;
            // login failure
            NSString *title = [NSString stringWithFormat:@"%@ Error: %d", error.domain, error.code];
            UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:title
                                                                message:[error localizedDescription]
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
            [alertView show];
        });
    };

    [connection connectWithSuccessBlock:successBlock
                           failureBlock:failureBlock];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.navigationItem.rightBarButtonItem.enabled = YES;
}

#pragma mark UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    NSInteger tag = textField.tag + 1;
    UITextField *nextField = (UITextField *)[self.view viewWithTag:tag];
    if (nextField) {
        [nextField becomeFirstResponder];
    } else {
        [textField resignFirstResponder];
        [self loginTapped:nil];
    }
    return YES;
}

@end
