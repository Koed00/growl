//
//  GrowlPref.m
//  Growl
//
//  Created by Karl Adam on Wed Apr 21 2004.
//  Copyright 2004 The Growl Project. All rights reserved.
//
// This file is under the BSD License, refer to License.txt for details

#import "GrowlPref.h"
#import "GrowlPreferences.h"
#import "GrowlDefinesInternal.h"
#import "GrowlDefines.h"
#import "GrowlApplicationNotification.h"
#import "GrowlApplicationTicket.h"
#import "GrowlDisplayProtocol.h"
#import "GrowlPluginController.h"
#import "GrowlVersionUtilities.h"
#import "ACImageAndTextCell.h"
#import "NSGrowlAdditions.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Security/SecKeychain.h>
#import <Security/SecKeychainItem.h>

#define PING_TIMEOUT		3

static const char *keychainServiceName = "Growl";
static const char *keychainAccountName = "Growl";

@implementation GrowlPref

- (id) initWithBundle:(NSBundle *)bundle {
	if ((self = [super initWithBundle:bundle])) {
		versionCheckURL    = nil;
		downloadURL        = nil;
		pluginPrefPane     = nil;
		tickets            = nil;
		currentApplication = nil;
		startStopTimer     = nil;
		loadedPrefPanes    = [[NSMutableArray alloc] init];
		
		NSNotificationCenter *nc = [NSDistributedNotificationCenter defaultCenter];
		[nc addObserver:self selector:@selector(growlLaunched:)   name:GROWL_IS_READY object:nil];
		[nc addObserver:self selector:@selector(growlTerminated:) name:GROWL_SHUTDOWN object:nil];

		NSDictionary *defaultDefaults = [NSDictionary dictionaryWithContentsOfFile:[bundle pathForResource:@"GrowlDefaults"
																									ofType:@"plist"]];
		[[GrowlPreferences preferences] registerDefaults:defaultDefaults];
	}

	return self;
}

- (void) dealloc {
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
	[browser            release];
	[services           release];
	[pluginPrefPane     release];
	[loadedPrefPanes    release];
	[tickets            release];
	[currentApplication release];
	[startStopTimer     release];
	[images             release];
	[versionCheckURL    release];
	[downloadURL        release];
	[super dealloc];
}

#pragma mark -

- (NSString *) bundleVersion {
	return [[[self bundle] infoDictionary] objectForKey:@"CFBundleVersion"];
}

- (IBAction) checkVersion:(id)sender {
	[growlVersionProgress startAnimation:self];

	if (!versionCheckURL) {
		versionCheckURL = [[NSURL alloc] initWithString:@"http://growl.info/version.xml"];
	}
	if (!downloadURL) {
		downloadURL = [[NSURL alloc] initWithString:@"http://growl.info/"];
	}

	[self checkVersionAtURL:versionCheckURL
				displayText:NSLocalizedStringFromTableInBundle(@"A newer version of Growl is available online. Would you like to download it now?", nil, [self bundle], @"")
				downloadURL:downloadURL];

	[growlVersionProgress stopAnimation:self];
}

- (void) checkVersionAtURL:(NSURL *)url displayText:(NSString *)message downloadURL:(NSURL *)goURL {
	NSBundle *bundle = [self bundle];
	NSDictionary *infoDict = [bundle infoDictionary];
	NSString *currVersionNumber = [infoDict objectForKey:@"CFBundleVersion"];
	NSDictionary *productVersionDict = [NSDictionary dictionaryWithContentsOfURL:url];
	NSString *latestVersionNumber = [productVersionDict objectForKey:
		[infoDict objectForKey:@"CFBundleExecutable"] ];

	/*
	NSLog([[[NSBundle bundleForClass:[self class]] infoDictionary] objectForKey:@"CFBundleExecutable"] );
	NSLog(currVersionNumber);
	NSLog(latestVersionNumber);
	*/

	// do nothing--be quiet if there is no active connection or if the
	// version number could not be downloaded
	if (latestVersionNumber && (compareVersionStringsTranslating1_0To0_5(latestVersionNumber, currVersionNumber) > 0)) {
		NSBeginAlertSheet(/*title*/ NSLocalizedStringFromTableInBundle(@"Update Available", nil, bundle, @""),
						  /*defaultButton*/ nil, // use default localized button title ("OK" in English)
						  /*alternateButton*/ NSLocalizedStringFromTableInBundle(@"Cancel", nil, bundle, @""),
						  /*otherButton*/ nil,
						  /*docWindow*/ nil,
						  /*modalDelegate*/ self,
						  /*didEndSelector*/ NULL,
						  /*didDismissSelector*/ @selector(downloadSelector:returnCode:contextInfo:),
						  /*contextInfo*/ goURL,
						  /*msg*/ message);
	}
}

- (void) downloadSelector:(NSWindow *)sheet returnCode:(int)returnCode contextInfo:(void *)contextInfo {
	if (returnCode == NSAlertDefaultReturn) {
		[[NSWorkspace sharedWorkspace] openURL:contextInfo];
	}
}

- (void) awakeFromNib {
	NSTableColumn *tableColumn = [growlApplications tableColumnWithIdentifier: @"application"];
	ACImageAndTextCell *imageAndTextCell = [[[ACImageAndTextCell alloc] init] autorelease];
	[imageAndTextCell setEditable: YES];
	[tableColumn setDataCell:imageAndTextCell];
	NSButtonCell *cell = [[applicationNotifications tableColumnWithIdentifier:@"sticky"] dataCell];
	[cell setAllowsMixedState:YES];

	[applicationNotifications deselectAll:NULL];
	[growlApplications deselectAll:NULL];
	[remove setEnabled:NO];

	[growlVersion setStringValue:[self bundleVersion]];

	char *password;
	UInt32 passwordLength;
	OSStatus status;
	status = SecKeychainFindGenericPassword( NULL,
											 strlen( keychainServiceName ), keychainServiceName,
											 strlen( keychainAccountName ), keychainAccountName,
											 &passwordLength, (void **)&password, NULL );

	if (status == noErr) {
		NSString *passwordString = [[NSString alloc] initWithUTF8String:password length:passwordLength];
		[networkPassword setStringValue:passwordString];
		[passwordString release];
		SecKeychainItemFreeContent( NULL, password );
	} else if (status != errSecItemNotFound) {
		NSLog( @"Failed to retrieve password from keychain. Error: %d", status );
		[networkPassword setStringValue:@""];
	}	

	browser = [[NSNetServiceBrowser alloc] init];
	services = [[NSMutableArray alloc] initWithArray:[[GrowlPreferences preferences] objectForKey:GrowlForwardDestinationsKey]];
	[browser setDelegate:self];
	[browser searchForServicesOfType:@"_growl._tcp." inDomain:@""];
}

- (void) mainViewDidLoad {
	[[NSDistributedNotificationCenter defaultCenter] addObserver:self 
														selector:@selector(appRegistered:)
															name:GROWL_APP_REGISTRATION_CONF
														  object:nil];
}

//subclassed from NSPreferencePane; called before the pane is displayed.
- (void) willSelect {
	[self reloadPreferences];
	[self checkGrowlRunning];

	[tabView setDelegate:self];
}

// copy images to avoid resizing the original image stored in the ticket
- (void) cacheImages {

	if (images) {
		[images release];
	}
	
	images = [[NSMutableArray alloc] initWithCapacity:[applications count]];
	NSEnumerator *enumerator = [applications objectEnumerator];
	id key;

	while ((key = [enumerator nextObject])) {
		NSImage *icon = [[[tickets objectForKey:key] icon] copy];
		[icon setScalesWhenResized:YES];
		[icon setSize:NSMakeSize(16.0f, 16.0f)];
		[images addObject:icon];
		[icon release];
	}
}

- (void) reloadPreferences {
	if (tickets) {
		[tickets release];
	}
	tickets = [[GrowlApplicationTicket allSavedTickets] mutableCopy];
	applications = [[[tickets allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] mutableCopy];

	[self cacheImages];

	[self loadViewForDisplay:nil];

	[growlApplications reloadData];

	GrowlPreferences *preferences = [GrowlPreferences preferences];
	[allDisplayPlugins removeAllItems];
	[allDisplayPlugins addItemsWithTitles:[[GrowlPluginController controller] allDisplayPlugins]];
	[allDisplayPlugins selectItemWithTitle:[preferences objectForKey:GrowlDisplayPluginKey]];
	[displayPlugins reloadData];

	if ([[preferences objectForKey:GrowlStartServerKey] boolValue]) {
		[startGrowlServer setState:NSOnState];
		[allowRemoteRegistration setEnabled:YES];
	} else {
		[startGrowlServer setState:NSOffState];
		[allowRemoteRegistration setEnabled:NO];
	}

	if ([[preferences objectForKey:GrowlRemoteRegistrationKey] boolValue]) {
		[allowRemoteRegistration setState:NSOnState];
	} else {
		[allowRemoteRegistration setState:NSOffState];
	}

	if ([preferences startGrowlAtLogin]) {
		[startGrowlAtLogin setState:NSOnState];
	} else {
		[startGrowlAtLogin setState:NSOffState];
	}

	if ([[preferences objectForKey:GrowlEnableForwardKey] boolValue]) {
		[enableForward setState:NSOnState];
		[growlServiceList setEnabled:YES];
	} else {
		[enableForward setState:NSOffState];
		[growlServiceList setEnabled:NO];
	}

	if ([[preferences objectForKey:GrowlUpdateCheckKey] boolValue]) {
		[backgroundUpdateCheck setState:NSOnState];
	} else {
		[backgroundUpdateCheck setState:NSOffState];
	}
	
	// If Growl is enabled, ensure the helper app is launched
	if ([[preferences objectForKey:GrowlEnabledKey] boolValue]) {
		[[GrowlPreferences preferences] launchGrowl];
	}

	[self buildMenus];
	
	[self reloadAppTab];
	[self reloadDisplayTab];
}

- (void) buildMenus {
	// Building Menu for the drop down one time.  It's cached from here on out.  If we want to add new display types
	// we'll have to call this method after the controller knows about it.
	NSEnumerator * enumerator;
	
	if (applicationDisplayPluginsMenu) {
		[applicationDisplayPluginsMenu release];
	}

	applicationDisplayPluginsMenu = [[NSMenu alloc] initWithTitle:@"DisplayPlugins"];
	enumerator = [[[GrowlPluginController controller] allDisplayPlugins] objectEnumerator];
	id title;
	[applicationDisplayPluginsMenu addItemWithTitle:NSLocalizedStringFromTableInBundle(@"Default",nil,[self bundle],@"") action:nil keyEquivalent:@""];
	[applicationDisplayPluginsMenu addItem:[NSMenuItem separatorItem]];
	
	while ((title = [enumerator nextObject])) {
		[applicationDisplayPluginsMenu addItemWithTitle:title action:nil keyEquivalent:@""];
	}

	[[[growlApplications tableColumnWithIdentifier:@"display"] dataCell] setMenu:applicationDisplayPluginsMenu];
	[[[applicationNotifications tableColumnWithIdentifier:@"priority"] dataCell] setMenu:notificationPriorityMenu];
	[[[applicationNotifications tableColumnWithIdentifier:@"display"] dataCell] setMenu:applicationDisplayPluginsMenu];
}

- (void) updateRunningStatus {
	[startStopTimer invalidate];
	startStopTimer = nil;
	[startStopGrowl setEnabled:YES];
	NSBundle *bundle = [self bundle];
	[startStopGrowl setTitle:
		growlIsRunning ? NSLocalizedStringFromTableInBundle(@"Stop Growl",nil,bundle,@"")
					   : NSLocalizedStringFromTableInBundle(@"Start Growl",nil,bundle,@"")];
	[growlRunningStatus setStringValue:
		growlIsRunning ? NSLocalizedStringFromTableInBundle(@"Growl is running.",nil,bundle,@"")
					   : NSLocalizedStringFromTableInBundle(@"Growl is stopped.",nil,bundle,@"")];
	[growlRunningProgress stopAnimation:self];
}

- (void) reloadAppTab {
	[currentApplication release];
	currentApplication = nil;
//	currentApplication = [[growlApplications titleOfSelectedItem] retain];
	unsigned numApplications = [applications count];
	int row = [growlApplications selectedRow];
	if (numApplications) {
		if (row > -1)
			currentApplication = [[applications objectAtIndex:row] retain];
	} 

	[remove setEnabled:NO];
	appTicket = [tickets objectForKey:currentApplication];

//	[applicationEnabled setState:[appTicket ticketEnabled]];
//	[applicationEnabled setTitle:[NSString stringWithFormat:@"Enable notifications for %@",currentApplication]];

	[[[applicationNotifications tableColumnWithIdentifier:@"enable"] dataCell] setEnabled:[appTicket ticketEnabled]];

	[applicationNotifications reloadData];
	
	[growlApplications reloadData];
}

- (void) reloadDisplayTab {
	if (currentPlugin) {
		[currentPlugin release];
	}
	
	NSArray *plugins = [[GrowlPluginController controller] allDisplayPlugins];
	unsigned numPlugins = [plugins count];
	
	if (([displayPlugins selectedRow] < 0) && (numPlugins > 0U)) {
		[displayPlugins selectRow:0 byExtendingSelection:NO];
	}

	if (numPlugins > 0U) {
		currentPlugin = [[plugins objectAtIndex:[displayPlugins selectedRow]] retain];
	}

	currentPluginController = [[GrowlPluginController controller] displayPluginNamed:currentPlugin];
	[self loadViewForDisplay:currentPlugin];
	NSDictionary *info = [currentPluginController pluginInfo];
	[displayAuthor setStringValue:[info objectForKey:@"Author"]];
	[displayVersion setStringValue:[info objectForKey:@"Version"]];
}

- (void) writeForwardDestinations {
	NSMutableArray *destinations = [NSMutableArray arrayWithCapacity:[services count]];
	NSEnumerator *enumerator = [services objectEnumerator];
	NSMutableDictionary *entry;
	while ( (entry = [enumerator nextObject]) ) {
		if ( ![entry objectForKey:@"netservice"] ) {
			[destinations addObject:entry];
		}
	}
	[[GrowlPreferences preferences] setObject:destinations forKey:GrowlForwardDestinationsKey];
}

#pragma mark -
#pragma mark Growl running state

- (void) launchGrowl {
	// Don't allow the button to be clicked while we update
	[startStopGrowl setEnabled:NO];
	[growlRunningProgress startAnimation:self];
	
	// Update our status visible to the user
	[growlRunningStatus setStringValue:NSLocalizedStringFromTableInBundle(@"Launching Growl...",nil,[self bundle],@"")];
	
	[[GrowlPreferences preferences] setGrowlRunning:YES];
	
	// After 4 seconds force a status update, in case Growl didn't start/stop
	[self performSelector:@selector(checkGrowlRunning)
			   withObject:nil
			   afterDelay:4.0];	
}

- (void) terminateGrowl {
	// Don't allow the button to be clicked while we update
	[startStopGrowl setEnabled:NO];
	[growlRunningProgress startAnimation:self];
	
	// Update our status visible to the user
	[growlRunningStatus setStringValue:NSLocalizedStringFromTableInBundle(@"Terminating Growl...",nil,[self bundle],@"")];
	
	// Ask the Growl Helper App to shutdown
	[[GrowlPreferences preferences] setGrowlRunning:NO];
	
	// After 4 seconds force a status update, in case growl didn't start/stop
	[self performSelector:@selector(checkGrowlRunning)
			   withObject:nil
			   afterDelay:4.0];	
}

#pragma mark "General" tab pane

- (IBAction) startStopGrowl:(id) sender {
	// Make sure growlIsRunning is correct
	if (growlIsRunning != [[GrowlPreferences preferences] isGrowlRunning]) {
		// Nope - lets just flip it and update status
		growlIsRunning = !growlIsRunning;
		[self updateRunningStatus];
		return;
	}

	// Our desired state is a toggle of the current state;
	if (growlIsRunning) {
		[self terminateGrowl];
	} else {
		[self launchGrowl];
	}
}

- (IBAction) startGrowlAtLogin:(id) sender {
	[[GrowlPreferences preferences] setStartGrowlAtLogin:([sender state] == NSOnState)];
}

- (IBAction) backgroundUpdateCheck:(id) sender {
	[[GrowlPreferences preferences] setObject:[NSNumber numberWithBool:([sender state] == NSOnState)]
									   forKey:GrowlUpdateCheckKey];
}

- (IBAction) selectDisplayPlugin:(id)sender {
	[[GrowlPreferences preferences] setObject:[sender titleOfSelectedItem] forKey:GrowlDisplayPluginKey];
}

- (IBAction)deleteTicket:(id)sender {
	int row = [growlApplications selectedRow];
	id key = [applications objectAtIndex:row];
	NSString *path = [[tickets objectForKey:key] path];

	if ( [[NSFileManager defaultManager] removeFileAtPath:path handler:nil] ) {
		[[NSDistributedNotificationCenter defaultCenter] postNotificationName:GrowlPreferencesChanged
																	   object:@"GrowlTicketDeleted"
																	 userInfo:[NSDictionary dictionaryWithObject:key forKey:@"TicketName"]];
		[tickets removeObjectForKey:key];
		[images removeObjectAtIndex:row];
		[applications removeObjectAtIndex:row];
		[growlApplications deselectAll:NULL];
		[self reloadAppTab];
	}
}

#pragma mark "Network" tab pane

- (IBAction) startGrowlServer:(id)sender {
	BOOL enabled = ([sender state] == NSOnState);
	[[GrowlPreferences preferences] setObject:[NSNumber numberWithBool:enabled] forKey:GrowlStartServerKey];
	[allowRemoteRegistration setEnabled:enabled];
}

- (IBAction) allowRemoteRegistration:(id)sender {
	NSNumber *state = [NSNumber numberWithBool:([sender state] == NSOnState)];
	[[GrowlPreferences preferences] setObject:state forKey:GrowlRemoteRegistrationKey];
}

- (IBAction) setRemotePassword:(id)sender {
	const char *password = [[sender stringValue] UTF8String];
	unsigned length = strlen( password );
	OSStatus status;
	SecKeychainItemRef itemRef = nil;
	status = SecKeychainFindGenericPassword( NULL,
											 strlen( keychainServiceName ), keychainServiceName,
											 strlen( keychainAccountName ), keychainAccountName,
											 NULL, NULL, &itemRef );
	if ( status == errSecItemNotFound ) {
		// add new item
		status = SecKeychainAddGenericPassword( NULL,
												strlen( keychainServiceName ), keychainServiceName,
												strlen( keychainAccountName ), keychainAccountName,
												length, password, NULL );
		if ( status ) {
			NSLog( @"Failed to add password to keychain." );
		}
	} else {
		// change existing password
		SecKeychainAttribute attrs[] = {
		{ kSecAccountItemAttr, strlen( keychainAccountName ), (char *)keychainAccountName },
		{ kSecServiceItemAttr, strlen( keychainServiceName ), (char *)keychainServiceName }
		};
		const SecKeychainAttributeList attributes = { sizeof(attrs) / sizeof(attrs[0]), attrs };
		status = SecKeychainItemModifyAttributesAndData( itemRef,		// the item reference
														 &attributes,	// no change to attributes
														 length,		// length of password
														 password		// pointer to password data
														 );
		if ( itemRef ) {
			CFRelease( itemRef );
		}
		if ( status ) {
			NSLog( @"Failed to change password in keychain." );
		}
	}
}

- (IBAction) setEnableForward:(id)sender {
	BOOL enabled = [sender state] == NSOnState;
	[growlServiceList setEnabled:enabled];
	[[GrowlPreferences preferences] setObject:[NSNumber numberWithBool:enabled] forKey:GrowlEnableForwardKey];
}

#pragma mark "Display Options" tab pane

- (IBAction) showPreview:(id) sender {
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:GrowlPreview object:currentPlugin];
}

//This is the frame of the preference view that we should get back.
#define DISPLAY_PREF_FRAME NSMakeRect(165.0f, 42.0f, 354.0f, 289.0f)
- (void)loadViewForDisplay:(NSString*)displayName {
	NSView *newView = nil;
	NSPreferencePane *prefPane = nil, *oldPrefPane = nil;

	if (pluginPrefPane) {
		oldPrefPane = pluginPrefPane;
	}

	if (displayName) {
		// Old plugins won't support the new protocol. Check first
		if ([currentPluginController respondsToSelector:@selector(preferencePane)]) {
			prefPane = [currentPluginController preferencePane];
		}

		if (prefPane == pluginPrefPane) {
			// Don't bother swapping anything
			return;
		} else {
			[pluginPrefPane release];
			pluginPrefPane = [prefPane retain];
			[oldPrefPane willUnselect];
		}
		if (pluginPrefPane) {
			if ([loadedPrefPanes containsObject:pluginPrefPane]) {
				newView = [pluginPrefPane mainView];
			} else {
				newView = [pluginPrefPane loadMainView];
				[loadedPrefPanes addObject:pluginPrefPane];
			}
			[pluginPrefPane willSelect];
		}
	} else {
		[pluginPrefPane release];
		pluginPrefPane = nil;
	}
	if (!newView) {
		newView = displayDefaultPrefView;
	}
	if (displayPrefView != newView) {
		// Make sure the new view is framed correctly
		[newView setFrame:DISPLAY_PREF_FRAME];
		[[displayPrefView superview] replaceSubview:displayPrefView with:newView];
		displayPrefView = newView;
		
		if (pluginPrefPane) {
			[pluginPrefPane didSelect];
			// Hook up key view chain
			[displayPlugins setNextKeyView:[pluginPrefPane firstKeyView]];
			[[pluginPrefPane lastKeyView] setNextKeyView:tabView];
			//[[displayPlugins window] makeFirstResponder:[pluginPrefPane initialKeyView]];
		} else {
			[displayPlugins setNextKeyView:tabView];
		}
		
		if (oldPrefPane) {
			[oldPrefPane didUnselect];
		}
	}
}

#pragma mark Notification, Application and Service table view data source methods

- (int) numberOfRowsInTableView:(NSTableView *)tableView {
	int returnValue = 0;

	if (tableView == growlApplications) {
		returnValue = [applications count];
	} else if (tableView == applicationNotifications) {
		returnValue = [[appTicket allNotifications] count];
	} else if (tableView == displayPlugins) {
		returnValue = [[[GrowlPluginController controller] allDisplayPlugins] count];
	} else if (tableView == growlServiceList) {
		returnValue = [services count];
	}
	
	return returnValue;
}

- (id) tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(int)row {
	id returnObject = nil;
	id identifier;
	
	if (tableView == growlApplications) 	{
		identifier = [column identifier];
		if ([identifier isEqualTo:@"enable"]) {
			returnObject = [NSNumber numberWithBool:[[tickets objectForKey: [applications objectAtIndex:row]] ticketEnabled]];
		} else if ([identifier isEqualTo:@"application"]) {
			returnObject = [applications objectAtIndex:row];
		} 
	} else if (tableView == applicationNotifications) {
		NSString * note = [[appTicket allNotifications] objectAtIndex:row];
		identifier = [column identifier];
		
		if ([identifier isEqualTo:@"enable"]) {
			returnObject = [NSNumber numberWithBool:[appTicket isNotificationEnabled:note]];
		} else if ([identifier isEqualTo:@"notification"]) {
			returnObject = note;
		} else if ([identifier isEqualTo:@"sticky"]) {
			returnObject = [NSNumber numberWithInt:[appTicket stickyForNotification:note]];
		}
	} else if (tableView == displayPlugins) {
		// only one column, but for the sake of cleanliness
		identifier = [column identifier];
		if ([identifier isEqualTo:@"plugins"]) {
			returnObject = [[[GrowlPluginController controller] allDisplayPlugins] objectAtIndex:row];
		}
	} else if (tableView == growlServiceList) {
		identifier = [column identifier];
		returnObject = [[services objectAtIndex:row] objectForKey:identifier];
	}

	return returnObject;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(int)row {
	id identifier;

	if (tableView == growlApplications) {
		NSString *application = [[[tickets allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] objectAtIndex:row];
		GrowlApplicationTicket *ticket = [tickets objectForKey:application];
		identifier = [column identifier];

		if ([identifier isEqualTo:@"enable"]) {
			[ticket setEnabled:[value boolValue]];
			[GrowlPref saveTicket:ticket];
		} else if ([identifier isEqualTo:@"display"])	{
			int index = [value intValue];
			if (index == 0) {
				if ([ticket displayPlugin]) {
					[ticket setDisplayPluginNamed:nil];
					[GrowlPref saveTicket:ticket];
				}
			} else {
				NSString *pluginName = [[applicationDisplayPluginsMenu itemAtIndex:index] title];
				if (![pluginName isEqualTo:[[[tickets objectForKey:application] displayPlugin] name]]) {
					[ticket setDisplayPluginNamed:pluginName];
					[GrowlPref saveTicket:ticket];
				}
			}
		}
		[self reloadAppTab];
	} else if (tableView == applicationNotifications) {
		NSString *note = [[appTicket allNotifications] objectAtIndex:row];
		identifier = [column identifier];

		if ([identifier isEqualTo:@"enable"]) {
			if ([value boolValue]) {
				[appTicket setNotificationEnabled:note];
			} else {
				[appTicket setNotificationDisabled:note];
			}
			[GrowlPref saveTicket:appTicket];
		} else if ([identifier isEqualTo:@"display"]) {
			int index = [value intValue];
			if (index == 0) {
				if ([appTicket displayPluginForNotification:note]) {
					[appTicket setDisplayPluginNamed:nil forNotification:note];
					[GrowlPref saveTicket:appTicket];
				}
			} else {
				NSString *pluginName = [[applicationDisplayPluginsMenu itemAtIndex:index] title];
				if (![pluginName isEqualTo:[[appTicket displayPluginForNotification:note] name]]) {
					[appTicket setDisplayPluginNamed:pluginName forNotification:note];
					[GrowlPref saveTicket:appTicket];
				}
			}
		} else if ([identifier isEqualTo:@"priority"]) {
			int index = [value intValue];
			
			if (index == 0) {
				if ([appTicket priorityForNotification:note] != GP_unset) {
					[appTicket resetPriorityForNotification:note];
					[GrowlPref saveTicket:appTicket];
				}
			} else if ([appTicket priorityForNotification:note] != (index-4)) {
				[appTicket setPriority:(index-4) forNotification:note];
				[GrowlPref saveTicket:appTicket];
			}
		} else if ([identifier isEqualTo:@"sticky"]) {
			[appTicket setSticky:[value intValue] forNotification:note];
			[GrowlPref saveTicket:appTicket];
		}
	} else if (tableView == growlServiceList) {
		identifier = [column identifier];
		if ([identifier isEqualTo:@"use"]) {
			NSMutableDictionary *entry = [services objectAtIndex:row];
			if ([value boolValue]) {
				NSNetService *serviceToResolve = [entry objectForKey:@"netservice"];
				if (serviceToResolve) {
					// Make sure to cancel any previous resolves.
					if (serviceBeingResolved) {
						[serviceBeingResolved stop];
						[serviceBeingResolved release];
						serviceBeingResolved = nil;
					}

					currentServiceIndex = row;
					serviceBeingResolved = serviceToResolve;
					[serviceBeingResolved retain];
					[serviceBeingResolved setDelegate:self];
					[serviceBeingResolved resolve];
				}
			}

			[entry setObject:value forKey:identifier];
			[self writeForwardDestinations];
		}
	}
}

#pragma mark TableView delegate methods

- (void) tableViewSelectionDidChange:(NSNotification *)theNote {
	if ([theNote object] == growlApplications) {
		[self reloadAppTab];
		if ([[theNote object] selectedRow] > -1) {
			[remove setEnabled:YES]; 
		} else {
			[remove setEnabled:NO];
		}
		[applicationNotifications reloadData];
	} else if ([theNote object] == displayPlugins) {
		[self reloadDisplayTab];
		[remove setEnabled:NO];
	} else if ([theNote object] == applicationNotifications) {
		[self reloadAppTab];
		//[remove setEnabled:NO];
	}
}

- (void) tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(int)row {
	NSString *identifier = [column identifier];
	if (tableView == growlApplications) {
		if ([identifier isEqualTo:@"display"]) {
			id <GrowlDisplayPlugin> displayPlugin = [[tickets objectForKey:[applications objectAtIndex:row]] displayPlugin];
			if (!displayPlugin) {
				[cell selectItemAtIndex:0]; // Default
			} else {
				[cell selectItemWithTitle:[displayPlugin name]];
			}
		} else if ([identifier isEqualTo:@"application"]) {
			[(ACImageAndTextCell *)cell setImage:[images objectAtIndex:row]];
		}
	} else if (tableView == applicationNotifications) {
		id notif = [[appTicket allNotifications] objectAtIndex:row];
		if ([identifier isEqualTo:@"priority"]) {
			int priority = [appTicket priorityForNotification:notif];
			if (priority != GP_unset) {
				[cell selectItemAtIndex:priority+4];
			} else {
				[cell selectItemAtIndex:0];
			}
		} else if ([identifier isEqualTo:@"display"]) {
			id <GrowlDisplayPlugin> displayPlugin = [appTicket displayPluginForNotification:notif];
			if (!displayPlugin) {
				[cell selectItemAtIndex:0]; // Default
			} else {
				[cell selectItemWithTitle:[displayPlugin name]];
			}
		}
	}
}

-(void) tableViewDidClickInBody:(NSTableView*)tableView {
	if ((tableView == growlApplications) && ([tableView selectedRow] > -1)) {
		[remove setEnabled:YES];
	} else {
		[remove setEnabled:NO];
	}
}

#pragma mark NSNetServiceBrowser Delegate Methods

- (void) netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didFindService:(NSNetService *)aNetService moreComing:(BOOL)moreComing {
	// check if a computer with this name has already been added
	NSString *name = [aNetService name];
	NSEnumerator *enumerator = [services objectEnumerator];
	NSMutableDictionary *entry;
	while ((entry = [enumerator nextObject])) {
		if ([[entry objectForKey:@"computer"] isEqualToString:name]) {
			return;
		}
	}

	// add a new entry at the end
	entry = [[NSMutableDictionary alloc] initWithObjectsAndKeys:
		aNetService, @"netservice",
		name, @"computer",
		[NSNumber numberWithBool:FALSE], @"use",
		nil];
	[services addObject:entry];
	[entry release];

	if (!moreComing) {
		[growlServiceList reloadData];
		[self writeForwardDestinations];
	}
}

- (void) netServiceBrowser:(NSNetServiceBrowser *)aNetServiceBrowser didRemoveService:(NSNetService *)aNetService moreComing:(BOOL)moreComing {
	// This case is slightly more complicated. We need to find the object in the list and remove it.
	unsigned count = [services count];
	NSDictionary *currentEntry;

	for( unsigned i = 0; i < count; ++i ) {
		currentEntry = [services objectAtIndex:i];
		if ([[currentEntry objectForKey:@"netservice"] isEqual:aNetService]) {
			[services removeObjectAtIndex:i];
			break;
		}
	}

	if (serviceBeingResolved && [serviceBeingResolved isEqual:aNetService]) {
		[serviceBeingResolved stop];
		[serviceBeingResolved release];
		serviceBeingResolved = nil;
	}

	if (!moreComing) {
		[growlServiceList reloadData];
		[self writeForwardDestinations];
	}
}

- (void) netServiceDidResolveAddress:(NSNetService *)sender {
	NSArray *addresses = [sender addresses];
	if ([addresses count] > 0U) {
		NSData *address = [addresses objectAtIndex:0U];
		NSMutableDictionary *entry = [services objectAtIndex:currentServiceIndex];
		[entry setObject:address forKey:@"address"];
		[entry removeObjectForKey:@"netservice"];
		[self writeForwardDestinations];
	}
}

#pragma mark Growl Tab View Delegate Methods

- (void) tabView:(NSTabView*)tab willSelectTabViewItem:(NSTabViewItem*)tabViewItem {
	//NSLog(@"%s %@\n", __FUNCTION__, [tabViewItem label]);
	if ([[tabViewItem identifier] isEqual:@"2"]) {
		[[tab window] makeFirstResponder: growlApplications];
	}			
}

#pragma mark -

+ (void)saveTicket:(GrowlApplicationTicket *)ticket {
	[ticket saveTicket];
	[[NSDistributedNotificationCenter defaultCenter] postNotificationName:GrowlPreferencesChanged
																   object:@"GrowlTicketChanged"
																 userInfo:[NSDictionary dictionaryWithObject:[ticket applicationName] forKey:@"TicketName"]];
}

#pragma mark Detecting Growl

- (void)checkGrowlRunning {
	growlIsRunning = [[GrowlPreferences preferences] isGrowlRunning];
	[self updateRunningStatus];
}

#pragma mark -

// Refresh preferences when a new application registers with Growl
- (void)appRegistered: (NSNotification *) note {
	NSString *app = [note object];
	GrowlApplicationTicket *ticket = [[GrowlApplicationTicket alloc] initTicketForApplication:app];

/*	if (![tickets objectForKey:app])
		[growlApplications addItemWithTitle:app];*/

	[tickets setObject:ticket forKey:app];
	[ticket release];
	[applications release];
	applications = [[[tickets allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] mutableCopy];
	[self cacheImages];
	[growlApplications reloadData];

	if ([currentApplication isEqualToString:app]) {
		[self reloadPreferences];
	}
}

- (void)growlLaunched:(NSNotification *)note {
	growlIsRunning = YES;
	[self updateRunningStatus];
}

- (void)growlTerminated:(NSNotification *)note {
	growlIsRunning = NO;
	[self updateRunningStatus];
}

@end
