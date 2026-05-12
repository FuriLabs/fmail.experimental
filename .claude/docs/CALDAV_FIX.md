# CalDAV Event Creation Fix

## Problems Fixed

### Issue 1: Empty String vs Null Check ✅ FIXED

**Problem**: 
```dart
String? calendarPath = account.caldavConfirmedPath ?? account.caldavPath;
//                     ^^^^^^^^^^^^^^^^^^^^^^^
//                     Returns "" (empty string), not null!
```

When `caldavConfirmedPath` is an empty string `""`, the `??` operator doesn't work because it only checks for `null`, not empty strings.

**Solution**:
```dart
String? calendarPath = (account.caldavConfirmedPath != null && account.caldavConfirmedPath!.isNotEmpty) 
    ? account.caldavConfirmedPath 
    : account.caldavPath;
```

Now it properly checks if the confirmed path is **both** not null **and** not empty.

**File**: `lib/calendar_view.dart` line ~749

### Issue 2: HTTP 302 Redirect Not Followed ✅ FIXED

**Problem**: 
Server returns HTTP 302 redirect but the http.put() client doesn't follow redirects automatically:
```
Request to: https://mail.connolly.id.au/remote.php/dav/calendars/wayne/personal/event-123.ics
Redirects to: https://mail.connolly.id.au/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/event-123.ics
```

The original path in JSON was actually correct all along!

**Solution**:
```dart
// Create HTTP client and handle redirects manually
final client = http.Client();
var response = await client.put(Uri.parse(url), ...);

// Handle 302/301 redirect
if (response.statusCode == 302 || response.statusCode == 301) {
  final redirectUrl = response.headers['location'];
  if (redirectUrl != null) {
    print('🔄 Following redirect to: $redirectUrl');
    response = await client.put(redirectUri, ...);
  }
}
```

**File**: `lib/calendar_view.dart` line ~787

## Correct Configuration

Your **original** JSON configuration was correct:

```json
{
  "caldav-base-url": "https://mail.connolly.id.au",
  "caldav-path": "/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/"
}
```

The app now follows the 302 redirect from `/remote.php/...` to `/connolly.id.au/apps/nextcloud/remote.php/...` automatically.

## How to Fix Your Config

Edit `fmail_accounts.json`:

### For connolly.id.au account:
```json
{
  "imap": "monday.mxrouting.net",
  "smtp": "monday.mxrouting.net",
  "caldav-base-url": "https://mail.connolly.id.au",
  "caldav-path": "/remote.php/dav/calendars/wayne/personal/",
  "username": "wayne@connolly.id.au",
  ...
}
```

### For furilabs.com account:
```json
{
  "imap": "monday.mxrouting.net",
  "smtp": "monday.mxrouting.net",
  "caldav-base-url": "https://mail.connolly.id.au",
  "caldav-path": "/remote.php/dav/calendars/wayne/personal/",
  "username": "wayne@furilabs.com",
  ...
}
```

## Testing

1. **Update fmail_accounts.json** with correct paths

2. **Delete database** (to reload JSON):
   ```bash
   rm ~/.dart_tool/sqflite_common_ffi/databases/furimail.db*
   ```

3. **Run app**:
   ```bash
   flutter run -d linux
   ```

4. **Try creating a calendar event**

Expected console output:
```
🔍 [CALENDAR-DEBUG] caldavPath: "/remote.php/dav/calendars/wayne/personal/"
🔍 [CALENDAR-DEBUG] caldavConfirmedPath: ""
🔍 [UPLOAD-DEBUG] Checking CalDAV paths:
   - caldavConfirmedPath: ""
   - caldavPath: "/remote.php/dav/calendars/wayne/personal/"
   - Selected path: "/remote.php/dav/calendars/wayne/personal/"  ← SHOULD NOT BE EMPTY NOW!
🌐 Uploading event to URL: https://mail.connolly.id.au/remote.php/dav/calendars/wayne/personal/event-123.ics
📡 Upload response status: 201
✅ Event uploaded successfully!
```

## Alternative Paths to Try

If the above doesn't work, try these alternatives:

### Option 1: Username with @domain
```json
"caldav-path": "/remote.php/dav/calendars/wayne@connolly.id.au/personal/"
```

### Option 2: Different calendar name
```json
"caldav-path": "/remote.php/dav/calendars/wayne/calendar/"
```

### Option 3: Different base path
```json
"caldav-base-url": "https://connolly.id.au",
"caldav-path": "/apps/nextcloud/remote.php/dav/calendars/wayne/personal/"
```

## How to Find Your Correct Path

1. **Log into Nextcloud web interface**

2. **Go to Calendar app**

3. **Click on calendar settings (gear icon)**

4. **Look for "Calendar Link" or "WebDAV URL"**
   - Should look like: `https://domain.com/remote.php/dav/calendars/username/personal/`

5. **Split the URL**:
   - Base: `https://domain.com`
   - Path: `/remote.php/dav/calendars/username/personal/`

## Status

✅ **Code Fixed** - Empty string check now works properly  
⚠️ **Config Needs Update** - CalDAV path in JSON is incorrect  
📝 **Next Step** - Update JSON with correct Nextcloud path format

Once you fix the JSON config, calendar event creation should work!
