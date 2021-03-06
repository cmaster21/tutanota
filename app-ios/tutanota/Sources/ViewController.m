//
//  ViewController.m
//  tutanota
//
//  Created by Tutao GmbH on 13.07.18.
//  Copyright © 2018 Tutao GmbH. All rights reserved.
//

// Sweet, sweet sugar
#import "Swiftier.h"
#import "PSPDFFastEnumeration.h"

// App classes
#import "ViewController.h"
#import "Crypto.h"
#import "TutaoFileChooser.h"
#import "TUTContactsSource.h"

// Frameworks
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>
#import <UIkit/UIkit.h>

// Runtime magic
#import <objc/message.h>

typedef void(^VoidCallback)(void);

@interface ViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property WKWebView *webView;
@property (readonly, nonnull) Crypto *crypto;
@property (readonly, nonnull) TutaoFileChooser *fileChooser;
@property (readonly, nonnull) FileUtil *fileUtil;
@property (readonly, nonnull) TUTContactsSource *contactsSource;
@property (readonly, nonnull) NSMutableArray<VoidCallback> *webviewReadyCallbacks;
@property (readonly) BOOL webViewIsready;
@property (readonly, nonnull) NSMutableDictionary<NSString *, void(^)(NSDictionary * _Nullable value)> *requests;
@property NSInteger requestId;
@property (nullable) NSString *pushToken;
@end

@implementation ViewController

- (instancetype)init
{
	self = [super init];
	if (self) {
		_crypto = [Crypto new];
		_fileChooser = [[TutaoFileChooser alloc] initWithViewController:self];
		_fileUtil = [[FileUtil alloc] initWithViewController:self];
		_contactsSource = [TUTContactsSource new];

		_webViewIsready = NO;
	}
	return self;
}

- (void)loadView {
	WKWebViewConfiguration *config = [WKWebViewConfiguration new];
	_webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
	[_webView.configuration.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
	_webView.navigationDelegate = self;
	_webView.scrollView.bounces = false;

	[config.userContentController addScriptMessageHandler:self name:@"nativeApp"];
	self.view = _webView;

	[self keyboardDisplayDoesNotRequireUserAction];
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self loadMainPageWithParams:nil];
}

- (void)userContentController:(nonnull WKUserContentController *)userContentController didReceiveScriptMessage:(nonnull WKScriptMessage *)message {
	let jsonData = [[message body] dataUsingEncoding:NSUTF8StringEncoding];
	NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
	NSLog(@"Message dict: %@", json);
	NSString *type = json[@"type"];
	NSString *requestId = json[@"id"];
	NSArray *arguments = json[@"args"];
	
	void (^sendResponseBlock)(id, NSError *) = [self responseBlockForRequestId:requestId];

	if ([@"response" isEqualToString:type]) {
		id value = json[@"value"];
		[self handleResponseWithId:requestId value:value];
	} else if ([@"init" isEqualToString:type]) {
		[self sendResponseWithId:requestId value:@"ios"];
		_webViewIsready = YES;
		foreach(callback, _webviewReadyCallbacks) {
			callback();
		}
	} else if ([@"rsaEncrypt" isEqualToString:type]) {
		[_crypto rsaEncryptWithPublicKey:arguments[0] base64Data:arguments[1] completeion:sendResponseBlock];
	} else if ([@"rsaDecrypt" isEqualToString:type]) {
		[_crypto rsaDecryptWithPrivateKey:arguments[0]
							   base64Data:arguments[1]
							   completion:sendResponseBlock];
	} else if ([@"reload" isEqualToString:type]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[self loadMainPageWithParams:arguments[0]];
		});
		[self sendResponseWithId:requestId value:[NSNull null]];
	} else if ([@"generateRsaKey" isEqualToString:type]) {
		[_crypto generateRsaKeyWithSeed:arguments[0] completion: sendResponseBlock];
	} else if ([@"openFileChooser" isEqualToString:type]) {
		[_fileChooser openWithCompletion:^(NSString *filePath, NSError *error) {
			if (error == nil) {
				if (filePath != nil) {
					[self sendResponseWithId:requestId value:@[filePath]];
				} else {
					[self sendResponseWithId:requestId value:[NSArray new]];
				}
			} else {
				[self sendErrorResponseWithId:requestId value:error];
			}
		}];
	} else if ([@"getName" isEqualToString:type]) {
		[_fileUtil getNameForPath:arguments[0] completion:sendResponseBlock];
	} else if ([@"getSize" isEqualToString:type]) {
		[_fileUtil getSizeForPath:arguments[0] completion:sendResponseBlock];
	} else if ([@"getMimeType" isEqualToString:type]) {
		[_fileUtil getMimeTypeForPath:arguments[0] completion:sendResponseBlock];
	} else if ([@"changeTheme" isEqualToString:type] || [@"closePushNotifications" isEqualToString:type]) {
		// No-op for now
		sendResponseBlock(NSNull.null, nil);
	} else if ([@"aesEncryptFile" isEqualToString:type]) {
		[_crypto aesEncryptFileWithKey:arguments[0] atPath:arguments[1] completion:sendResponseBlock];
	} else if ([@"aesDecryptFile" isEqualToString:type]) {
		[_crypto aesDecryptFileWithKey:arguments[0] atPath:arguments[1] completion:sendResponseBlock];
	} else if([@"upload" isEqualToString:type]) {
		[_fileUtil uploadFileAtPath:arguments[0] toUrl:arguments[1] withHeaders:arguments[2] completion:sendResponseBlock];
	} else if ([@"deleteFile" isEqualToString:type]) {
		[_fileUtil deleteFileAtPath:arguments[0] completion:^{
			sendResponseBlock(NSNull.null, nil);
		}];
	} else if ([@"download" isEqualToString:type]) {
		[_fileUtil downloadFileFromUrl:arguments[0]
							   forName:arguments[1]
						   withHeaders:arguments[2]
							completion:sendResponseBlock];
	} else if ([@"open" isEqualToString:type]) {
		[_fileUtil openFileAtPath:arguments[0] completion:^(NSError * _Nullable error) {
			if (error != nil) {
				[self sendErrorResponseWithId:requestId value:error];
			} else {
				[self sendResponseWithId:requestId value:NSNull.null];
			}
		}];
	} else if ([@"getPushIdentifier" isEqualToString:type]) {
		sendResponseBlock(_pushToken ? _pushToken : NSNull.null, nil);
	} else if ([@"findSuggestions" isEqualToString:type]) {
		[_contactsSource searchForContactsUsingQuery:arguments[0]
										  completion:sendResponseBlock];
	} else {
		let message = [NSString stringWithFormat:@"Unknown command: %@", type];
		NSLog(@"%@", message);
		let error = [NSError errorWithDomain:@"tutanota" code:5 userInfo:@{@"message":message}];
		[self sendErrorResponseWithId:requestId value:error];
	}
}

-(void (^)(id, NSError *))responseBlockForRequestId:(NSString *)requestId {
	return ^void(id value, NSError *error) {
		if (error == nil) {
			[self sendResponseWithId:requestId value:value];
		} else {
			[self sendErrorResponseWithId:requestId value:error];
		}
	};
}

- (void) loadMainPageWithParams:(NSString * _Nullable)params {
	_webViewIsready = NO;
	var fileUrl = [self appUrl];
	let folderUrl = [fileUrl URLByDeletingLastPathComponent];
	if (params != nil) {
		let newUrlString = [NSString stringWithFormat:@"%@%@", [fileUrl absoluteString], params];
		fileUrl = [NSURL URLWithString:newUrlString];
	}
	[_webView loadFileURL:fileUrl allowingReadAccessToURL:folderUrl];
}

- (void) sendResponseWithId:(NSString*)responseId value:(id)value {
	[self sendResponseWithId:responseId type:@"response" value:value];
}

- (void) sendErrorResponseWithId:(NSString*)responseId value:(NSError *)value {
	let errorDict = @{
					  @"name":[value domain],
					  @"message":value.userInfo[@"message"]
					  };
	[self sendResponseWithId:responseId type:@"requestError" value:errorDict];
}

- (void) sendResponseWithId:(NSString *)responseId type:(NSString *)type value:(id)value {
	let response = @{
					 @"id":responseId,
					 @"type":type,
					 @"value":value
					 };

	[self postMessage:response];
}

- (void) postMessage:(NSDictionary *)message {
	let jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
	let jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
	dispatch_async(dispatch_get_main_queue(), ^{
		let escapted = [jsonString stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
		let js = [NSString stringWithFormat:@"tutao.nativeApp.handleMessageFromNative('%@')", escapted];
		[self->_webView evaluateJavaScript:js completionHandler:nil];
	});
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
	// We need to implement this bridging from native because we don't know if we are an iOS app before the init event
	[_webView evaluateJavaScript:@"window.nativeApp = {invoke: (message) => window.webkit.messageHandlers.nativeApp.postMessage(message)}"
			   completionHandler:nil];
}

- (nonnull NSURL *)appUrl {
	let path = [[NSBundle mainBundle] pathForResource:@"build/app" ofType:@"html"];
	return [NSURL fileURLWithPath:path];
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
	if ([[navigationAction.request.URL absoluteString] hasPrefix:[self appUrl].absoluteString]) {
		decisionHandler(WKNavigationActionPolicyAllow);
	} else {
		decisionHandler(WKNavigationActionPolicyCancel);
		[self presentViewController:[[SFSafariViewController alloc] initWithURL:navigationAction.request.URL]
						   animated:YES
						 completion:nil];
	}
}

- (void)didRegisterForRemoteNotificationsWithToken:(NSData *)deviceToken {
	[self doWhenReady:^{
		let stringToken = [[deviceToken description] stringByTrimmingCharactersInSet:
						   [NSCharacterSet characterSetWithCharactersInString:@"<> "]];
		[self sendRequestWithType:@"updatePushIdentifier" args:@[stringToken] completion:nil];
	}];
}

-(void)doWhenReady:(VoidCallback)callback {
	if (_webViewIsready) {
		callback();
	} else {
		[_webviewReadyCallbacks addObject:callback];
	}
}

-(void)sendRequestWithType:(NSString * _Nonnull)type
					  args:(NSArray<id> * _Nonnull)args
				completion:(void(^ _Nullable)(NSDictionary * _Nullable value))completion {
	let requestId = [NSString stringWithFormat:@"app%ld", (long) _requestId++];
	if (completion) {
		_requests[requestId] = completion;
	}
	let json = @{
				 @"id": requestId,
				 @"type": type,
				 @"args": args
				 };
	[self postMessage:json];
}

-(void)handleResponseWithId:(NSString *)requestId value:(id)value {
	let request = _requests[requestId];
	if (request) {
		[_requests removeObjectForKey:requestId];
	}
	request(value);
}

// Swizzling WebKit to be show keyboard when we call focus() on fields
// Work quite slowly so forms should not be focused at the time of animation
// https://github.com/Telerik-Verified-Plugins/WKWebView/commit/04e8296adeb61f289f9c698045c19b62d080c7e3#L609-L620
- (void) keyboardDisplayDoesNotRequireUserAction {
   Class class = NSClassFromString(@"WKContentView");
    NSOperatingSystemVersion iOS_11_3_0 = (NSOperatingSystemVersion){11, 3, 0};

    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: iOS_11_3_0]) {
        SEL selector = sel_getUid("_startAssistingNode:userIsInteracting:blurPreviousNode:changingActivityState:userObject:");
        Method method = class_getInstanceMethod(class, selector);
        IMP original = method_getImplementation(method);
        IMP override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, BOOL arg3, id arg4) {
            ((void (*)(id, SEL, void*, BOOL, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3, arg4);
        });
        method_setImplementation(method, override);
    } else {
        SEL selector = sel_getUid("_startAssistingNode:userIsInteracting:blurPreviousNode:userObject:");
        Method method = class_getInstanceMethod(class, selector);
        IMP original = method_getImplementation(method);
        IMP override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, id arg3) {
            ((void (*)(id, SEL, void*, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3);
        });
        method_setImplementation(method, override);
    }
}

@end
