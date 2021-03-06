/* 
 * Adium is the legal property of its developers, whose names are listed in the copyright file included
 * with this source distribution.
 * 
 * This program is free software; you can redistribute it and/or modify it under the terms of the GNU
 * General Public License as published by the Free Software Foundation; either version 2 of the License,
 * or (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even
 * the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
 * Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License along with this program; if not,
 * write to the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
 */

#import "AIPurpleCertificateTrustWarningAlert.h"
#import <SecurityInterface/SFCertificateTrustPanel.h>
#import "ESPurpleJabberAccount.h"

//#define ALWAYS_SHOW_TRUST_WARNING

@interface AIPurpleCertificateTrustWarningAlert ()
- (id)initWithAccount:(AIAccount*)account
			 hostname:(NSString*)hostname
		 certificates:(CFArrayRef)certs
	   resultCallback:(void (*)(gboolean trusted, void *userdata))_query_cert_cb
			 userData:(void*)ud;
- (IBAction)showWindow:(id)sender;
- (void)runTrustPanelOnWindow:(NSWindow *)window;
- (void)certificateTrustSheetDidEnd:(SFCertificateTrustPanel *)trustpanel returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo;
@end

@implementation AIPurpleCertificateTrustWarningAlert

+ (void)displayTrustWarningAlertWithAccount:(AIAccount *)account
								   hostname:(NSString *)hostname
							   certificates:(CFArrayRef)certs
							 resultCallback:(void (*)(gboolean trusted, void *userdata))_query_cert_cb
								   userData:(void*)ud
{
	if ([hostname caseInsensitiveCompare:@"talk.google.com"] == NSOrderedSame &&
		![[account preferenceForKey:KEY_JABBER_FORCE_OLD_SSL group:GROUP_ACCOUNT_STATUS] boolValue]) {
		NSString *UID = account.UID;
		NSRange startOfDomain = [UID rangeOfString:@"@"];

		if (startOfDomain.location == NSNotFound ||
			([[UID substringFromIndex:NSMaxRange(startOfDomain)] caseInsensitiveCompare:@"gmail.com"] == NSOrderedSame)) {
			/* Google Talk accounts end up with a cert signed using gmail.com as the server.
			 * However, Google For Domains accounts are signed using talk.google.com
			 */
			hostname = @"gmail.com";
		} else if ([[UID substringFromIndex:NSMaxRange(startOfDomain)] caseInsensitiveCompare:@"googlemail.com"] == NSOrderedSame) {
			/* There are three certificates, as far as I (am) know. Maybe we should ask Sean for confirmation. */
			hostname = @"googlemail.com";
		}
	}

	AIPurpleCertificateTrustWarningAlert *alert = [[self alloc] initWithAccount:account hostname:hostname certificates:certs resultCallback:_query_cert_cb userData:ud];
	[alert showWindow:nil];
}

- (id)initWithAccount:(AIAccount*)_account
			 hostname:(NSString*)_hostname
		 certificates:(CFArrayRef)certs
	   resultCallback:(void (*)(gboolean trusted, void *userdata))_query_cert_cb
			 userData:(void*)ud
{
	if((self = [super init])) {
		query_cert_cb = _query_cert_cb;
		
		certificates = certs;
		CFRetain(certificates);
		
		account = _account;
		hostname = [_hostname copy];
		
		userdata = ud;
	}
	return self;
}

- (void)dealloc {
	CFRelease(certificates);
	if (trustRef) CFRelease(trustRef);
}

- (IBAction)showWindow:(id)sender {
	OSStatus err;
	SecPolicyRef policyRef;
	
	NSAssert( UINT_MAX > [hostname length],
					 @"More string data than libpurple can handle.  Abort." );
	
	policyRef = SecPolicyCreateSSL(YES, (__bridge CFStringRef)hostname);
	err = SecTrustCreateWithCertificates(certificates, policyRef, &trustRef);

	if(err != noErr) {
		CFRelease(policyRef);
		NSBeep();
		return;
	}
	
	// test whether we aren't already trusting this certificate
	SecTrustResultType result;
	err = SecTrustEvaluate(trustRef, &result);
	if(err == noErr) {
		// with help from http://lists.apple.com/archives/Apple-cdsa/2006/Apr/msg00013.html
		switch(result) {
			case kSecTrustResultProceed: // trust ok, go right ahead
			case kSecTrustResultUnspecified: // trust ok, user has no particular opinion about this
#ifndef ALWAYS_SHOW_TRUST_WARNING
				query_cert_cb(true, userdata);
				break;
#endif
			case kSecTrustResultConfirm: // trust ok, but user asked (earlier) that you check with him before proceeding
			case kSecTrustResultDeny: // trust ok, but user previously said not to trust it anyway
			case kSecTrustResultRecoverableTrustFailure: // trust broken, perhaps argue with the user
			case kSecTrustResultOtherError: // failure other than trust evaluation; e.g., internal failure of the SecTrustEvaluate function. We'll let the user decide where to go from here.
			{
				
#if 1
				//Show on an independent window.
#define TRUST_PANEL_WIDTH 535
				NSWindow *fakeWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, TRUST_PANEL_WIDTH, 1)
																	styleMask:(NSTitledWindowMask | NSMiniaturizableWindowMask)
																	  backing:NSBackingStoreBuffered
																		defer:NO];
				[fakeWindow center];
				[fakeWindow setTitle:AILocalizedString(@"Verify Certificate", nil)];

				[self runTrustPanelOnWindow:fakeWindow];
				[fakeWindow makeKeyAndOrderFront:nil];
#else
				//Show as a sheet on the account's preferences
				[adium.accountController editAccount:account onWindow:nil notifyingTarget:self];
#endif
				break;
			}
			default:
				/*
				 * kSecTrustResultFatalTrustFailure -> trust broken, user can't fix it
				 * kSecTrustResultInvalid -> logic error; fix your program (SecTrust was used incorrectly)
				 */
				query_cert_cb(false, userdata);
				break;
		}
	} else {
		query_cert_cb(false, userdata);
	}

	CFRelease(policyRef);
}

- (void)runTrustPanelOnWindow:(NSWindow *)window
{
	SFCertificateTrustPanel *trustPanel = [[SFCertificateTrustPanel alloc] init];
	
	// this could probably be used for a more detailed message:
	//	CFArrayRef certChain;
	//	CSSM_TP_APPLE_EVIDENCE_INFO *statusChain;
	//	err = SecTrustGetResult(trustRef, &result, &certChain, &statusChain);
	
	NSString *title = [NSString stringWithFormat:AILocalizedString(@"Adium can't verify the identity of \"%@\".", nil), hostname];
	
	NSString *informativeText = [NSString stringWithFormat:AILocalizedString(@"The certificate of the server %@ is not trusted, which means that the server's identity cannot be automatically verified. Do you want to continue connecting?\n\nFor more information, click \"Show Certificate\".",nil), hostname];
	[trustPanel setInformativeText:informativeText];

	[trustPanel setAlternateButtonTitle:AILocalizedString(@"Cancel",nil)];
	[trustPanel setShowsHelp:YES];

	SecPolicyRef sslPolicy = SecPolicyCreateSSL(TRUE, (__bridge CFStringRef)hostname);
	if (sslPolicy) {
		[trustPanel setPolicies:(__bridge id)sslPolicy];
		CFRelease(sslPolicy);
	}

	[trustPanel beginSheetForWindow:window
					  modalDelegate:self
					 didEndSelector:@selector(certificateTrustSheetDidEnd:returnCode:contextInfo:)
						contextInfo:(__bridge void *)window
							  trust:trustRef
							message:title];
}


- (void)editAccountWindow:(NSWindow *)window didOpenForAccount:(AIAccount *)inAccount
{
	[self runTrustPanelOnWindow:window];	
}

- (void)certificateTrustSheetDidEnd:(SFCertificateTrustPanel *)trustpanel returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
	BOOL didTrustCerficate = (returnCode == NSOKButton);
	NSWindow *parentWindow = (__bridge NSWindow *)contextInfo;

	query_cert_cb(didTrustCerficate, userdata);

	[parentWindow performClose:nil];
}

@end
