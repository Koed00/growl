//
//  GrowlLogPrefs.m
//  Growl
//
//  Created by Olivier Bonnet on 13/12/04.
//  Copyright 2004 Olivier Bonnet. All rights reserved.
//

#import "GrowlLogPrefs.h"
#import "GrowlLogDefines.h"
#import "GrowlDefines.h"

@implementation GrowlLogPrefs
- (NSString *) mainNibName
{
	return @"GrowlLogPrefs";
}

- (void) dealloc
{
	[customHistArray release];
	[super dealloc];
}

- (void) awakeFromNib
{
	int		typePref = 0;
	NSString	*s;
	customHistArray = [[NSMutableArray alloc] init];
	READ_GROWL_PREF_VALUE(customHistKey1, LogPrefDomain, NSString * , &s);
//	NSLog(@"hist1 = %@", s);
	if (s) {
		[customHistArray addObject:s];
		//NSLog(@"hist1 = %@", s);
	}
	READ_GROWL_PREF_VALUE(customHistKey2, LogPrefDomain, NSString *, &s);
	if (s) {
		[customHistArray addObject:s];
		//NSLog(@"hist2 = %@", s);
	}
	READ_GROWL_PREF_VALUE(customHistKey3, LogPrefDomain, NSString *, &s);
	if (s) {
		[customHistArray addObject:s];
		//NSLog(@"hist3 = %@", s);
	}
	
	[self updatePopupMenu];
		
	READ_GROWL_PREF_INT(logTypeKey, LogPrefDomain, &typePref);
	[fileType selectCellAtRow:typePref column:0];
	if (typePref == 0) {
		[customMenuButton setEnabled:NO];
	} else [customMenuButton setEnabled:YES];
}

- (IBAction) typeChanged:(id)sender {
	int		typePref;
	
	if (sender == fileType) {
		typePref = [fileType selectedRow];
		WRITE_GROWL_PREF_INT(logTypeKey, typePref, LogPrefDomain);
		if (typePref == 0) {
			[customMenuButton setEnabled:NO];
		} else [customMenuButton setEnabled:YES];
		UPDATE_GROWL_PREFS();
	}
}

- (IBAction) openConsoleApp:(id)sender {
	[[NSWorkspace sharedWorkspace] launchApplication:@"Console"];
}


- (IBAction) customFileChoosen:(id)sender {
	if (sender == customMenuButton) {
		int selected = [customMenuButton indexOfSelectedItem];
		//NSLog(@"custom %d", selected);
		if (selected == [customMenuButton numberOfItems] - 1) {
			NSSavePanel *sp;
			int runResult;
			sp = [NSSavePanel savePanel];
			[sp setRequiredFileType:@"log"];
			runResult = [sp runModalForDirectory:NSHomeDirectory() file:@""];
			if (runResult == NSOKButton) {
				int index = NSNotFound;
				unsigned i = 0;
				for(i = 0; i < [customHistArray count]; i++) {
					if([[customHistArray objectAtIndex:i] isEqual:[sp filename]])
						index = i;
				}
				if (index == NSNotFound) {
					if ([customHistArray count] == 3)
						[customHistArray removeLastObject];
				} else {
					[customHistArray removeObjectAtIndex:index];
				}	
			[customHistArray insertObject:[NSString stringWithString:[sp filename]] atIndex:0];
			
			}
		} else {
			NSString *temp = [[customHistArray objectAtIndex:selected] retain];
			[customHistArray removeObjectAtIndex:selected];
			[customHistArray insertObject:temp atIndex:0];
			[temp release];
		}
		
		NSString *s;
		//NSLog(@"CustomHistArray = %@", customHistArray);
		s = [customHistArray objectAtIndex:0];
		if (s) {		
			WRITE_GROWL_PREF_VALUE(customHistKey1, s, LogPrefDomain);
			//NSLog(@"Writing %@ as hist1", s);
			SYNCHRONIZE_GROWL_PREFS();
		}
		
		if(([customHistArray count] > 1) && (s = [customHistArray objectAtIndex:1])) {
				WRITE_GROWL_PREF_VALUE(customHistKey2, s, LogPrefDomain);
				//NSLog(@"Writing %@ as hist2", s);
				SYNCHRONIZE_GROWL_PREFS();
		}
		
		if(([customHistArray count] > 2) && (s = [customHistArray objectAtIndex:2])) {
			WRITE_GROWL_PREF_VALUE(customHistKey3, s, LogPrefDomain);
			//NSLog(@"Writing %@ as hist3", s);
		}
		SYNCHRONIZE_GROWL_PREFS();
		UPDATE_GROWL_PREFS();

		[self updatePopupMenu];
	}
}

- (void) updatePopupMenu {
	unsigned i = 0;
	
	[customMenuButton removeAllItems];
	
	for(i = 0; i < [customHistArray count]; i++) {
		NSArray *pathComponentry = [[[customHistArray objectAtIndex:i] stringByAbbreviatingWithTildeInPath] pathComponents];
		if([pathComponentry count] > 2) {
			NSMutableString *arg = [[NSMutableString alloc] init];
			unichar ellipse = 0x2026;
			[arg setString:[NSMutableString stringWithCharacters:&ellipse length:1]];
			[arg appendString:@"/"];
			[arg appendString:[pathComponentry objectAtIndex:([pathComponentry count] - 2)]];
			[arg appendString:@"/"];
			[arg appendString:[pathComponentry objectAtIndex:([pathComponentry count] - 1)]];
			[customMenuButton insertItemWithTitle:arg atIndex:i];
		} else {
			[customMenuButton insertItemWithTitle:[[customHistArray objectAtIndex:i] stringByAbbreviatingWithTildeInPath] atIndex:i];
		}
	}
	[[customMenuButton menu] addItem:[NSMenuItem separatorItem]];
	[customMenuButton addItemWithTitle:@"Browse..."];
	[customMenuButton selectItemAtIndex:0];

}

- (void) didSelect {
	SYNCHRONIZE_GROWL_PREFS();
}

@end