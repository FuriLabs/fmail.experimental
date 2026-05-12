# Contact Display Quote Fix

## Problem

Contacts list showing double quotes around names and shortcodes:
```
"C
"Tracey Coors"
email@domain.com
```

## Root Cause

When emails have senders in RFC 2822 format with quoted names:
```
"Tracey Coors" <email@domain.com>
```

The code extracts the name by finding everything before the `<` symbol:
```dart
senderName = fromHeader.substring(0, emailMatch.start).trim();
// Result: "Tracey Coors"  ← Still has quotes!
```

These quotes were then:
1. Stored in the database in the `contacts` table
2. Displayed in the UI with quotes
3. Used to generate initials (first letter was `"` instead of `T`)

## Solution

### Code Fix (3 locations in main.dart)

Added quote-stripping logic after extracting the sender name:

```dart
senderName = fromHeader.substring(0, emailMatch.start).trim();

// Remove surrounding quotes if present (e.g., "John Doe" <email@...>)
if (senderName.startsWith('"') && senderName.endsWith('"')) {
  senderName = senderName.substring(1, senderName.length - 1);
}

if (senderName.isEmpty) senderName = senderEmail;
```

**Fixed in:**
- Line ~3447 (`_fetchSingleMessageHeader`) - Old single-message fetch
- Line ~3560 (`_fetchHeadersBatchOptimized`) - New batch fetch (primary)
- Line ~3830 (`_fetchHeadersBatch`) - Legacy batch fetch

### Database Cleanup

For existing contacts with quotes, run this SQL:

```sql
UPDATE contacts 
SET name = TRIM(name, '"')
WHERE name LIKE '"%"';
```

Or delete the database and re-sync:
```bash
rm ~/.dart_tool/sqflite_common_ffi/databases/furimail.db*
```

## Testing

### Before Fix
```
Contact entry:
  name: "Tracey Coors"
  initials: "" (first char is quote)
  display: "C  ← wrong shortcode
           "Tracey Coors"
```

### After Fix
```
Contact entry:
  name: Tracey Coors
  initials: TC
  display: TC
           Tracey Coors
```

## How to Verify

1. Delete database and re-sync (fresh data):
   ```bash
   rm ~/.dart_tool/sqflite_common_ffi/databases/furimail.db*
   flutter run -d linux
   ```

2. Wait for sync to complete

3. Go to Contacts tab

4. Check contacts - names should have no quotes:
   - ✅ `TC` instead of `"C`
   - ✅ `Tracey Coors` instead of `"Tracey Coors"`

5. Or query database directly:
   ```bash
   sqlite3 ~/.dart_tool/sqflite_common_ffi/databases/furimail.db \
     "SELECT name, email FROM contacts LIMIT 10;"
   ```
   
   Should show clean names without quotes.

## Additional Notes

- This affects all contacts auto-populated from email senders
- Manually added contacts wouldn't have this issue
- The fix prevents future contacts from having quotes
- Old contacts in existing databases need SQL cleanup or re-sync

## Related Files

- `lib/main.dart` - Email parsing and contact extraction (3 fixes)
- `lib/contacts_view.dart` - Contact display (no changes needed)
- `lib/database_helper.dart` - Contact insertion (no changes needed)
- `fix_contact_quotes.sql` - Database cleanup script

## Status

✅ **FIXED** - All 3 locations where sender names are extracted now strip surrounding quotes.

New syncs will create contacts without quotes. Existing contacts can be fixed with SQL UPDATE or by deleting and re-syncing the database.
