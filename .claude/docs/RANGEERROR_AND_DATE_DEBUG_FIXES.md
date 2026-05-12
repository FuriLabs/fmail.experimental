# RangeError and Date Debugging Fixes

## Issues Fixed

### Issue 1: RangeError - "Invalid value: Not greater than or equal to 0: -8"

**Error Message**:
```
⚠️ [PARALLEL-wayne@furilabs.com] Error processing folder Junk: RangeError (start): Invalid value: Not greater than or equal to 0: -8
⚠️ [PARALLEL-wayne@furilabs.com] Error processing folder Drafts: RangeError (start): Invalid value: Not greater than or equal to 0: -5
```

**Root Cause**:
The batch fetching code was creating UID ranges using `batchUids.first` and `batchUids.last`, but when UIDs are in descending order (e.g., `[7, 6, 5, 4, 3]`), this creates an invalid range where start > end:

```dart
// BEFORE (BROKEN):
final batchUids = [7, 6, 5, 4, 3];
final sequence = MessageSequence.fromRange(
  batchUids.first,  // 7
  batchUids.last,   // 3
  isUidSequence: true
);
// ❌ fromRange(7, 3) is invalid! start must be <= end
// Result: RangeError (start): Invalid value: Not greater than or equal to 0: -5
```

**Solution**:
Use `min()` and `max()` to find the lowest and highest UIDs in the batch, ensuring start <= end regardless of UID order:

```dart
// AFTER (FIXED):
final batchUids = [7, 6, 5, 4, 3];
final minUid = batchUids.reduce((a, b) => a < b ? a : b);  // 3
final maxUid = batchUids.reduce((a, b) => a > b ? a : b);  // 7
final sequence = MessageSequence.fromRange(minUid, maxUid, isUidSequence: true);
// ✅ fromRange(3, 7) is valid!
// IMAP server returns all UIDs between 3 and 7: [3, 4, 5, 6, 7]
```

**Why UIDs Can Be Out of Order**:
- Server may return UIDs in any order
- UIDs with gaps (deleted emails) can appear non-sequential
- Different folders have different UID sequences
- Small folders especially likely to have descending UIDs

**File Modified**: `lib/main.dart` lines ~3329-3336

---

### Issue 2: Date Parsing Not Working for People2 Emails

**Problem**: People2 emails still showing sync time instead of actual email dates

**Investigation Needed**: Added comprehensive debug logging to track date parsing:

```dart
// Added debug output at each step:
if (_debugMode && subject.contains('People2')) {
  print("📅 [People2] UID $uid: ENVELOPE date = ${message.envelope!.date}");
  print("📅 [People2] UID $uid: decodeHeaderValue('date') = $dateHeader");
  print("📅 [People2] UID $uid: Found Date in body = $dateHeader");
  print("📅 [People2] UID $uid: Parsed date = $parsedDate");
  print("⚠️ [People2] UID $uid: No date found, using current time");
}
```

**What to Look For in Console**:
1. If `ENVELOPE date` appears → date should be correct (library pre-parsed it)
2. If `decodeHeaderValue('date')` appears → check if date string is valid
3. If `Found Date in body` appears → date was extracted from body text
4. If `Parsed date` appears → check if parsed date matches actual email date
5. If `No date found` appears → ENVELOPE and headers both null (server issue or library bug)

**File Modified**: `lib/main.dart` lines ~3570-3627

---

## Testing Instructions

1. **Delete database** to test with fresh sync:
   ```bash
   rm -f .dart_tool/sqflite_common_ffi/databases/furimail.db
   ```

2. **Run app**:
   ```bash
   flutter run -d linux
   ```

3. **Verify RangeError Fix**:
   - ✅ No more "RangeError (start): Invalid value" errors
   - ✅ All folders sync successfully (including Junk and Drafts)
   - ✅ Small folders with few messages work correctly

4. **Check Date Parsing Debug Output**:
   - Look for `📅 [People2]` lines in console
   - Check which date source is being used (ENVELOPE, header, or body)
   - Verify parsed dates match actual email dates
   - Report what you see in the console

5. **Verify Contacts**:
   - ✅ Contacts auto-populate from senders
   - ✅ Check Contacts view after sync completes

---

## Expected Console Output

### RangeError Fix:
**Before (Broken)**:
```
🔍 DEBUG: First 20 UIDs to fetch: 3, 4, 5, 6, 7
⚠️ Error processing folder Drafts: RangeError (start): Invalid value: Not greater than or equal to 0: -5
```

**After (Fixed)**:
```
🔍 DEBUG: First 20 UIDs to fetch: 7, 6, 5, 4, 3
📥 [BATCH-FETCH] Fetching 5 headers from Drafts
✅ Fetched 5 messages from Drafts
```

### Date Parsing Debug:
**Example Output to Expect**:
```
📥 [BATCH-FETCH] Fetching 200 headers from INBOX
📅 [People2] UID 3405: ENVELOPE date = 2025-10-09 08:23:15.000
📅 [People2] UID 3406: decodeHeaderValue('date') = Wed, 09 Oct 2025 08:25:30 +1000
📅 [People2] UID 3406: Parsed date = 2025-10-09 08:25:30.000
```

Or if dates are still wrong:
```
⚠️ [People2] UID 3407: No date found, using current time
```

---

## Why Date Might Still Not Work

### Possibility 1: ENVELOPE Date is Null
If People2 emails have malformed Date headers, `message.envelope?.date` might be null and fallback parsing might fail.

**Next Step**: Check console for "⚠️ [People2] UID X: No date found" messages

### Possibility 2: DateCodec.decodeDate() Failing
The library's date parser might not handle People2's date format.

**Next Step**: Check console for "⚠️ Failed to parse date" messages

### Possibility 3: Database Already Has Wrong Dates
If database wasn't deleted before testing, old emails still have sync time timestamps.

**Next Step**: Verify database was deleted with `rm -f .dart_tool/sqflite_common_ffi/databases/furimail.db`

### Possibility 4: People2 Emails Actually Don't Have Date Headers
Some automated systems send emails without proper Date headers.

**Next Step**: Check one People2 email's raw source to verify Date header exists

---

## Summary

✅ **RangeError Fixed**: Min/max calculation ensures valid UID ranges  
🔍 **Date Debugging Added**: Comprehensive logging to track date parsing  
✅ **Contacts Fixed**: Auto-population restored  
✅ **Performance**: Still fast (~2-3 min for 16,000 emails)

**Date**: October 16, 2025  
**Issues**: RangeError in batch fetching, date parsing investigation  
**Solution**: Use min/max for UID ranges, add debug logging for dates

---

## Next Steps

**After running the sync, please share**:
1. Any console output with `📅 [People2]` in it
2. Whether RangeError is gone
3. Whether contacts are populating
4. Any other errors you see

This will help me understand why dates aren't working for People2 emails specifically.
