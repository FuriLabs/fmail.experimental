# Calendar Event Sync Issue - Investigation & Fix

## Problem Report
User creates a calendar event in the app, but it **doesn't sync to other devices or web browser calendar**.

## Root Cause Analysis

### Issue 1: Calendar Path Not Being Saved During Discovery

The calendar code has extensive path discovery/sniffing logic that tries multiple common CalDAV paths:
- `/caldav/v2/`
- `/remote.php/dav/calendars/USERNAME/personal/`
- `/principals/users/USERNAME/`
- etc.

However, there may be a disconnect between:
1. Path discovery running during sync
2. Path being saved to `caldav_confirmed_path` in database
3. Event creation using the correct path

**Code Flow**:
```dart
// During sync (calendar_view.dart):
1. _syncFromCalDAV() calls _discoverCalendarPaths()
2. Discovery finds working path
3. _saveConfirmedCalDAVPath() saves to database
4. BUT: In-memory account object still has old/null caldavConfirmedPath

// During event creation:
5. User creates event via _showAddEventDialog()
6. _immediateUploadEvent() loads account from DB (line 685-689)
7. Should get updated caldavConfirmedPath... BUT might not if:
   - Discovery hasn't run yet
   - Path discovery failed
   - Path wasn't properly saved
```

### Issue 2: Upload Function Fallback Logic

In `_uploadEventToServer()` (line 741-786):
```dart
String? calendarPath = account.caldavConfirmedPath ?? account.caldavPath;
if (calendarPath == null || calendarPath.isEmpty) {
  throw Exception('No CalDAV path configured');
}
```

This means if BOTH `caldavConfirmedPath` AND `caldavPath` are null/empty, event upload fails silently (caught by try-catch).

### Issue 3: Account CalDAV Fields Might Be Empty

The `EmailAccount` class has three CalDAV fields:
- `caldavBaseUrl` - Base URL (e.g., https://mail.connolly.id.au)
- `caldavPath` - Initial guess at calendar path
- `caldavConfirmedPath` - Tested and confirmed working path

**If these are not properly configured during account setup**, calendar sync will fail.

## Verification Steps

### Step 1: Check Account CalDAV Configuration

Run this query to see what's stored:
```sql
SELECT username, caldav_base_url, caldav_path, caldav_confirmed_path 
FROM accounts;
```

**Expected Result**:
```
wayne@connolly.id.au | https://mail.connolly.id.au | /caldav/v2/wayne@connolly.id.au/calendar/ | /remote.php/dav/calendars/wayne@connolly.id.au/personal/
```

**If you see NULL values**, that's the problem!

### Step 2: Check Console Output When Creating Event

When you create a calendar event, look for these messages:
```
🚀 IMMEDIATE UPLOAD: Uploading event instantly...
📝 Generated new UID for event: event-1729123456789@wayne@connolly.id.au
🌐 Uploading event to URL: https://mail.connolly.id.au/remote.php/dav/calendars/wayne@connolly.id.au/personal/event-1729123456789@wayne@connolly.id.au.ics
📡 Upload response status: 201
✅ IMMEDIATE UPLOAD: Event uploaded successfully!
```

**If you see**:
```
❌ IMMEDIATE UPLOAD failed: Exception: No CalDAV path configured
📝 Marked event for background sync due to upload failure
```

Then `caldavConfirmedPath` AND `caldavPath` are both null/empty!

### Step 3: Manual Path Discovery Test

The app should automatically discover paths during first sync. To test:
1. Delete database
2. Re-add account
3. Go to Calendar tab
4. Watch console for path discovery messages:
```
🔧 Trying alternative calendar path discovery...
🎯 Found alternative paths via discovery: [/remote.php/dav/calendars/wayne@connolly.id.au/personal/]
💾 Saved new confirmed path: /remote.php/dav/calendars/wayne@connolly.id.au/personal/
```

## Potential Fixes

### Fix 1: Add Debug Output to Track CalDAV Fields

Add this to `_immediateUploadEvent()` to see what's happening:

```dart
Future<bool> _immediateUploadEvent(Map<String, dynamic> eventData) async {
  print('🚀 IMMEDIATE UPLOAD: Uploading event instantly...');
  
  try {
    final accountId = eventData['accountId'] as String;
    final accounts = await DatabaseHelper.instance.getAccounts();
    final account = accounts.firstWhere(
      (a) => a.username == accountId,
      orElse: () => throw Exception('Account not found: $accountId'),
    );
    
    // ADD THIS DEBUG OUTPUT:
    print('🔍 [DEBUG] Account CalDAV config:');
    print('   - caldavBaseUrl: ${account.caldavBaseUrl}');
    print('   - caldavPath: ${account.caldavPath}');
    print('   - caldavConfirmedPath: ${account.caldavConfirmedPath}');
    
    // ... rest of function
```

### Fix 2: Force Path Discovery Before First Upload

If paths are empty, trigger discovery before attempting upload:

```dart
Future<bool> _immediateUploadEvent(Map<String, dynamic> eventData) async {
  print('🚀 IMMEDIATE UPLOAD: Uploading event instantly...');
  
  try {
    final accountId = eventData['accountId'] as String;
    final accounts = await DatabaseHelper.instance.getAccounts();
    final account = accounts.firstWhere(
      (a) => a.username == accountId,
      orElse: () => throw Exception('Account not found: $accountId'),
    );
    
    // CHECK IF CALDAV IS CONFIGURED
    if ((account.caldavConfirmedPath == null || account.caldavConfirmedPath!.isEmpty) &&
        (account.caldavPath == null || account.caldavPath!.isEmpty)) {
      print('⚠️ No CalDAV path configured, attempting discovery...');
      
      // Force a sync to discover paths
      await _syncFromCalDAV(forceSync: true);
      
      // Reload account to get updated paths
      final updatedAccounts = await DatabaseHelper.instance.getAccounts();
      final updatedAccount = updatedAccounts.firstWhere((a) => a.username == accountId);
      
      if ((updatedAccount.caldavConfirmedPath == null || updatedAccount.caldavConfirmedPath!.isEmpty) &&
          (updatedAccount.caldavPath == null || updatedAccount.caldavPath!.isEmpty)) {
        throw Exception('Failed to discover CalDAV path for ${account.username}');
      }
      
      // Use updated account for upload
      account = updatedAccount;
    }
    
    // ... rest of function
```

### Fix 3: Better Error Messages

Change the error handling to be more informative:

```dart
Future<void> _uploadEventToServer(EmailAccount account, Map<String, dynamic> eventData, String uid) async {
  // Get calendar path
  String? calendarPath = account.caldavConfirmedPath ?? account.caldavPath;
  if (calendarPath == null || calendarPath.isEmpty) {
    final errorMsg = '''
❌ No CalDAV path configured for ${account.username}!
   caldavBaseUrl: ${account.caldavBaseUrl ?? 'NULL'}
   caldavPath: ${account.caldavPath ?? 'NULL'}
   caldavConfirmedPath: ${account.caldavConfirmedPath ?? 'NULL'}
   
Please check account configuration or wait for automatic path discovery.
''';
    print(errorMsg);
    throw Exception('No CalDAV path configured');
  }
  
  // ... rest of function
```

## What to Do Next

### Immediate Steps:

1. **Check database** - Run SQL query to see CalDAV fields
2. **Enable debug mode** - Add debug output to see what's happening
3. **Create a test event** - Watch console output carefully
4. **Share console output** - Send me any error messages or debug output

### Questions to Answer:

1. **Do you see path discovery messages** when first opening Calendar tab?
2. **What's in the database** for caldav_base_url, caldav_path, caldav_confirmed_path?
3. **What error appears** in console when creating an event?
4. **Does caldav-path exist in account JSON file** (fmail_accounts.json)?

### Manual Workaround (if needed):

If automatic discovery isn't working, you can manually set paths in `fmail_accounts.json`:

```json
{
  "accounts": [
    {
      "username": "wayne@connolly.id.au",
      "password": "...",
      "imap": "mail.connolly.id.au",
      "smtp": "mail.connolly.id.au",
      "caldav-base-url": "https://mail.connolly.id.au",
      "caldav-path": "/remote.php/dav/calendars/wayne@connolly.id.au/personal/",
      "caldav-confirmed-path": ""
    }
  ]
}
```

Common CalDAV paths for different servers:
- **Nextcloud/ownCloud**: `/remote.php/dav/calendars/USERNAME/personal/`
- **Google**: Not directly supported (needs OAuth2, different API)
- **iCloud**: `/[NUMBER]/calendars/`
- **Generic**: `/caldav/`, `/calendars/`, `/dav/`

## Summary

The calendar functionality is present and should work, but there are three potential issues:

1. ❌ CalDAV paths not being saved during account setup
2. ❌ Path discovery not running or failing silently
3. ❌ Event upload trying to use null/empty paths

**Need from you**: 
- Console output when creating an event
- Database query results for account CalDAV fields
- Whether you see path discovery messages in console

Once we know which issue it is, I can provide a targeted fix!
