# Calendar Sync Debug Plan

## Current Status

✅ **CalDAV Configuration Found in JSON**:
```json
{
  "caldav-base-url": "https://mail.connolly.id.au",
  "caldav-path": "/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/"
}
```

✅ **Debug Logging Added**:
- Shows CalDAV paths when creating event
- Shows upload URL and response
- Shows detailed error if path is missing

## What to Test

### Step 1: Create a Calendar Event

1. Run the app (database has been deleted, so fresh start)
2. Let email sync complete
3. Go to Calendar tab
4. Create a new event
5. **Watch the console output carefully**

### Expected Debug Output

**If paths are configured correctly:**
```
🔍 [CALENDAR-DEBUG] Account: wayne@connolly.id.au
🔍 [CALENDAR-DEBUG] caldavBaseUrl: "https://mail.connolly.id.au"
🔍 [CALENDAR-DEBUG] caldavPath: "/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/"
🔍 [CALENDAR-DEBUG] caldavConfirmedPath: "null"  ← First time, this will be null
📝 Generated new UID for event: event-1729123456789@wayne@connolly.id.au
🔍 [UPLOAD-DEBUG] Checking CalDAV paths:
   - caldavConfirmedPath: "null"
   - caldavPath: "/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/"
   - Selected path: "/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/"
🌐 Uploading event to URL: https://mail.connolly.id.au/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/event-1729123456789@wayne@connolly.id.au.ics
📡 Upload response status: 201
✅ Event uploaded successfully!
```

**If paths are missing (the problem):**
```
🔍 [CALENDAR-DEBUG] Account: wayne@connolly.id.au
🔍 [CALENDAR-DEBUG] caldavBaseUrl: "null"  ← PROBLEM!
🔍 [CALENDAR-DEBUG] caldavPath: "null"     ← PROBLEM!
🔍 [CALENDAR-DEBUG] caldavConfirmedPath: "null"
❌ CALENDAR UPLOAD FAILED: No CalDAV path configured!
   Account: wayne@connolly.id.au
   caldavBaseUrl: NULL
   caldavPath: NULL
   caldavConfirmedPath: NULL
   
   This means the calendar path discovery hasn't run or failed.
```

**If path is wrong (404/403 error):**
```
🌐 Uploading event to URL: https://mail.connolly.id.au/wrong/path/event-123.ics
📡 Upload response status: 404
❌ IMMEDIATE UPLOAD failed: Exception: Upload failed with status 404
```

### Step 2: Check Database

After creating an event, check if CalDAV settings were saved:

```sql
SELECT username, caldav_base_url, caldav_path, caldav_confirmed_path 
FROM accounts;
```

**Expected:**
```
wayne@connolly.id.au | https://mail.connolly.id.au | /connolly.id.au/apps/nextcloud/... | NULL
wayne@furilabs.com   | https://mail.connolly.id.au | /furilabs.com/apps/nextcloud/...   | NULL
```

**If you see empty strings or NULL**, the JSON config isn't being loaded into the database properly!

### Step 3: Check Calendar Sync Log

When the calendar tab opens, it should attempt to sync:

```
📅 Syncing calendar for wayne@connolly.id.au
🔍 Trying to sync from CalDAV server...
🔧 Trying alternative calendar path discovery...
💾 Saved new confirmed path: /some/working/path/
```

## Possible Issues & Solutions

### Issue 1: Paths Not Loaded from JSON
**Symptom**: Debug shows `caldavBaseUrl: "null"`
**Cause**: Account creation/loading doesn't read caldav fields from JSON
**Solution**: Check lines 881-882 and 1297-1298 in main.dart

### Issue 2: Paths Not Saved to Database
**Symptom**: JSON has paths, but `SELECT` query shows NULL
**Cause**: Database insert/update doesn't include caldav fields
**Solution**: Check if `_saveAccountToDatabase()` includes caldav fields

### Issue 3: Wrong Path Format
**Symptom**: 404 error when uploading
**Cause**: Path in JSON is incorrect for your Nextcloud instance
**Solution**: Try different path formats:
- `/remote.php/dav/calendars/wayne@connolly.id.au/personal/`
- `/remote.php/dav/calendars/wayne/personal/`
- `/caldav/v2/wayne@connolly.id.au/calendar/`

### Issue 4: Authentication Fails
**Symptom**: 401 Unauthorized
**Cause**: Credentials wrong or need app password
**Solution**: Check if Nextcloud requires app-specific password

### Issue 5: Path Discovery Overwrites
**Symptom**: First upload works, then stops working
**Cause**: Path discovery runs and clears the configured path
**Solution**: Make sure discovery preserves manually configured paths

## Next Steps After Testing

1. **Share the console output** when creating an event
2. **Share the database query** results for accounts table
3. **Try accessing the URL manually**:
   ```bash
   curl -u "wayne@connolly.id.au:PASSWORD" \
     https://mail.connolly.id.au/connolly.id.au/apps/nextcloud/remote.php/dav/calendars/wayne/personal/
   ```
4. **Check Nextcloud calendar settings** - make sure CalDAV is enabled

Once we see the debug output, I'll know exactly what's wrong and can fix it!
