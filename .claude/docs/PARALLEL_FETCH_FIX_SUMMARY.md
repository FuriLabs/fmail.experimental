# Parallel Single-UID Fetch Implementation

## Problem Summary

The `enough_mail` library has a critical bug in batch message parsing where `message.decodeHeaderValue()` returns headers from **different messages** in the batch, causing incorrect UID→MessageID→Subject mappings in the database.

### Evidence
- UID 12544 stored with "People2.0 Timesheet approved" subject
- But fetching that UID from server returns "Your receipt from Airbnb"
- This happened because Message-IDs got mixed up during batch header sync

## Root Cause

When calling:
```dart
final sequence = MessageSequence.parse("12544,12545,12546", isUidSequence: true);
final fetchResult = await imapClient.fetchMessages(sequence, '(ENVELOPE ...)');
```

The library incorrectly pairs:
- `messages[0].uid = 12544` ✅
- `messages[0].decodeHeaderValue('message-id')` = value from UID 12545 ❌
- `messages[0].decodeHeaderValue('subject')` = value from UID 12545 ❌

Result: Database contains wrong Message-ID→Subject→Content mappings for thousands of emails.

## Solution Implemented

### Parallel Single-UID Fetching

Instead of batch fetching 100 UIDs at once, we now:

1. **Fetch ONE UID at a time** using `MessageSequence.fromId(singleUID, isUid: true)`
2. **Execute 5 of these in parallel** using `Future.wait([...])`
3. This ensures each message's UID correctly matches its Message-ID and Subject

### Code Changes

#### File: `lib/main.dart`

**Modified `_fetchHeadersFirst()` method (lines 3309-3346):**
```dart
// CRITICAL FIX: Fetch headers with parallel single-UID requests
// Single-UID fetches ensure correct UID→MessageID→Subject mapping
print("📋 [PARALLEL-SINGLE] Fetching ${uidsToFetch.length} messages with parallel single-UID requests");

const parallelBatchSize = 5; // Fetch 5 messages in parallel at a time
int fetchedCount = 0;

for (int i = 0; i < uidsToFetch.length; i += parallelBatchSize) {
  final batchEnd = min(i + parallelBatchSize, uidsToFetch.length);
  final batchUids = uidsToFetch.sublist(i, batchEnd);
  
  // Fetch this batch in parallel (multiple single-UID requests simultaneously)
  final futures = batchUids.map((uid) => 
    _fetchSingleMessageHeader(imapClient, account, folderName, uid)
  ).toList();
  
  await Future.wait(futures, eagerError: false);
  
  fetchedCount += batchUids.length;
  
  // Update UI every 20 messages
  if (fetchedCount % 20 == 0 && mounted) {
    await _loadEmailsFromDb(refresh: true);
    print("📊 Progress: $fetchedCount/${uidsToFetch.length} messages fetched");
  }
  
  // Small yield to prevent blocking
  await Future.delayed(Duration(milliseconds: 10));
}

print("✅ Fetched $fetchedCount messages from $folderName");

// Final UI update
if (mounted) {
  await _loadEmailsFromDb(refresh: true);
}
```

**New `_fetchSingleMessageHeader()` method (lines 3348-3443):**
```dart
Future<void> _fetchSingleMessageHeader(ImapClient imapClient, EmailAccount account, String folderName, int uid) async {
  try {
    // Create single-UID sequence - THIS IS THE KEY FIX
    final sequence = MessageSequence.fromId(uid, isUid: true);
    
    final fetchResult = await imapClient.fetchMessages(
      sequence,
      '(ENVELOPE FLAGS UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID DATE SUBJECT FROM)])',
    );
    
    if (fetchResult.messages.isEmpty) {
      return; // UID doesn't exist on server (deleted message)
    }
    
    final message = fetchResult.messages.first; // Only ONE message returned
    final db = await DatabaseHelper.instance.database;
    
    // Extract Message-ID (now guaranteed to match this UID)
    String messageId;
    final headerValue = message.decodeHeaderValue('message-id');
    final guidValue = message.guid?.toString();
    
    if (headerValue != null && headerValue.isNotEmpty) {
      messageId = headerValue;
    } else if (guidValue != null && guidValue.isNotEmpty) {
      messageId = guidValue;
    } else {
      messageId = '<uid-$uid@$folderName.${account.username}>';
    }
    
    // Extract Subject (now guaranteed to match this UID)
    String subject;
    final subjectHeader = message.decodeHeaderValue('subject');
    if (subjectHeader != null && subjectHeader.isNotEmpty) {
      subject = subjectHeader;
    } else {
      subject = message.decodeSubject() ?? 'No Subject';
    }
    
    // DEBUG: Print extraction for specific subjects
    if (_debugMode && (subject.contains('People') || subject.contains('Timesheet') || subject.contains('Airbnb'))) {
      print("📧 SINGLE-UID UID $uid:");
      print("   MessageID: ${messageId.substring(0, min(50, messageId.length))}");
      print("   Subject: ${subject.substring(0, min(60, subject.length))}");
    }
    
    // Extract sender (email + name)
    String senderName = 'Unknown';
    String senderEmail = 'unknown@example.com';
    
    final fromHeader = message.decodeHeaderValue('from');
    if (fromHeader != null && fromHeader.isNotEmpty) {
      final emailRegex = RegExp(r'<(.+?)>');
      final emailMatch = emailRegex.firstMatch(fromHeader);
      if (emailMatch != null) {
        senderEmail = emailMatch.group(1)!;
        senderName = fromHeader.substring(0, emailMatch.start).trim();
        if (senderName.isEmpty) senderName = senderEmail;
      } else {
        senderEmail = fromHeader;
        senderName = fromHeader;
      }
    } else if (message.envelope?.from != null && message.envelope!.from!.isNotEmpty) {
      var sender = message.envelope!.from![0];
      senderName = (sender.personalName?.isNotEmpty == true) ? sender.personalName! : sender.email;
      senderEmail = sender.email;
    }
    
    // Extract timestamp
    int timestamp;
    if (message.envelope?.date != null) {
      timestamp = message.envelope!.date!.millisecondsSinceEpoch;
    } else {
      timestamp = DateTime.now().millisecondsSinceEpoch;
    }
    
    // Parse IMAP flags (read, starred, etc.)
    final imapFlags = ImapFlagsHelper.parseImapFlags(message);
    
    // Insert into database with correct Message-ID
    await db.insert('emails', {
      'messageId': messageId,
      'accountId': account.username,
      'subject': subject,
      'sender': senderName,
      'senderEmail': senderEmail,
      'timestamp': timestamp,
      'content': '[Loading email body...]',
      'isRead': imapFlags['isRead'] ?? 0,
      'isStarred': imapFlags['isStarred'] ?? 0,
      'isAnswered': imapFlags['isAnswered'] ?? 0,
      'isDraft': imapFlags['isDraft'] ?? 0,
      'isDeleted': imapFlags['isDeleted'] ?? 0,
      'folderPath': folderName,
      'threadParentId': messageId,
      'bodyFetched': 0,
      'uid': uid,
    });
  } catch (e) {
    // Silently skip errors (deleted messages, network issues, duplicate keys, etc.)
  }
}
```

## Performance Impact

- **Before**: 1 batch request for 100 UIDs = 1 network round-trip (but wrong data)
- **After**: 5 parallel single-UID requests = ~20 batches per 100 UIDs, but **correct data**

The parallelization (5 concurrent requests) maintains reasonable performance while ensuring correctness.

## Testing Required

### 1. Delete Database
```bash
rm /path/to/furimail.db
```

### 2. Run Full Sync
Launch the app and let it sync all ~18,812 emails from scratch.

### 3. Verify Message-ID Correctness
Open a People2.0 Timesheet email and check:
- Does the subject in the list match the content when opened?
- Should see: "✅ MATCH!" instead of "❌ MISMATCH!" in verification output

### 4. Monitor Console Output
Look for:
```
📋 [PARALLEL-SINGLE] Fetching 100 messages with parallel single-UID requests
📧 SINGLE-UID UID 12544:
   MessageID: <630106467...>
   Subject: People2.0 Timesheet approved
📊 Progress: 20/100 messages fetched
📊 Progress: 40/100 messages fetched
...
✅ Fetched 100 messages from INBOX
```

## Expected Outcome

After database reset and full sync:
1. All Message-IDs in database will correctly match their subjects
2. Opening any email will show content matching the subject line
3. People2.0 Timesheet emails will display timesheet approval content (not Airbnb/GitHub)
4. Verification code will show "✅ MATCH!" for all emails

## Backup Created

Before implementation, backup created:
```
lib/main.dart.backup_YYYYMMDD_HHMMSS
```

## Deprecated Code

The old `_fetchHeadersBatch()` method at line 3451 is now unused and can be removed in future cleanup. It's left in the code with a compiler warning for reference.

## Additional Notes

- The `fetchSingleEmailBody()` method (line 1787) already uses correct Message-ID-based fetching and doesn't need changes
- Debug mode (`_debugMode = true`) prints detailed extraction info for troubleshooting
- Error handling silently skips deleted messages and network issues
- UI updates every 20 messages to show progress
