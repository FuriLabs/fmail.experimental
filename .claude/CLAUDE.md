# CLAUDE.md - fMail Application Context

> This file provides context for AI assistants working on this codebase.

---

## MANDATORY: Keep Documentation Up To Date

**After every code change, feature addition, or bug fix — you MUST update the following files as appropriate:**

- **[README.md](../README.md)** — User-facing docs: features, build instructions, CI, account config. Update if any of these change.
- **[.claude/docs/TODO.md](.claude/docs/TODO.md)** — Outstanding tasks. Mark fixed bugs as done, add newly discovered issues, update priorities.
- **[.claude/CLAUDE.md](.claude/CLAUDE.md)** — Architecture and patterns. Update if file structure, DB schema, key classes, or important patterns change.

**This is non-negotiable.** Stale docs cause confusion and wasted time. If you add a feature, document it. If you fix a bug on the TODO, remove it. If you change the schema, update the schema section here.

---

## Additional Documentation

Current TODO and historical investigation docs are in `.claude/docs/`:

- **[TODO.md](.claude/docs/TODO.md)** — Outstanding bugs, features, and known gotchas. **Read this first.**

Historical notes:

- [AI_EMAIL_ASSISTANT_PLAN.md](.claude/docs/AI_EMAIL_ASSISTANT_PLAN.md) - AI assistant feature planning
- [BATCH_FETCH_OPTIMIZATION_SUMMARY.md](.claude/docs/BATCH_FETCH_OPTIMIZATION_SUMMARY.md) - Batch email fetch optimization
- [CALDAV_FIX.md](.claude/docs/CALDAV_FIX.md) - CalDAV sync bug fixes
- [CALENDAR_DEBUG_PLAN.md](.claude/docs/CALENDAR_DEBUG_PLAN.md) - Calendar debugging approach
- [CALENDAR_SYNC_INVESTIGATION.md](.claude/docs/CALENDAR_SYNC_INVESTIGATION.md) - CalDAV sync investigation notes
- [CONTACT_QUOTES_FIX.md](.claude/docs/CONTACT_QUOTES_FIX.md) - Contact name quoting fix
- [DATE_PARSING_FIX_SUMMARY.md](.claude/docs/DATE_PARSING_FIX_SUMMARY.md) - Date parsing bug fixes
- [ENHANCED_EMAIL_DETAIL_SUMMARY.md](.claude/docs/ENHANCED_EMAIL_DETAIL_SUMMARY.md) - Email detail UI enhancements
- [FINAL_FIX_SUMMARY.md](.claude/docs/FINAL_FIX_SUMMARY.md) - Summary of major fixes
- [IMAP_FLAGS_INTEGRATION_SUMMARY.md](.claude/docs/IMAP_FLAGS_INTEGRATION_SUMMARY.md) - IMAP flag sync implementation
- [PARALLEL_FETCH_FIX_SUMMARY.md](.claude/docs/PARALLEL_FETCH_FIX_SUMMARY.md) - Parallel fetch bug fix
- [PERFORMANCE_FIX_SUMMARY.md](.claude/docs/PERFORMANCE_FIX_SUMMARY.md) - Performance improvements
- [RANGEERROR_AND_DATE_DEBUG_FIXES.md](.claude/docs/RANGEERROR_AND_DATE_DEBUG_FIXES.md) - RangeError and date debug fixes
- [TIMESTAMP_AND_ERROR_FIXES.md](.claude/docs/TIMESTAMP_AND_ERROR_FIXES.md) - Timestamp handling fixes
- [TODO.md](.claude/docs/TODO.md) - Outstanding tasks and ideas

---

## Project Overview

**fMail** is a cross-platform email client built with Flutter for Furi Labs. Primary targets are:

- **Linux arm64** — Furi FLX series phones (runs full Linux, not Android)
- **Linux amd64** — desktop
- **Android** — APK
- **iOS** — IPA (macOS build required)

Flutter does not support Linux cross-compilation. arm64 `.deb` must be built on an arm64 machine.

### Tech Stack

- **Framework**: Flutter/Dart (dark Material theme, `FuriMailApp` → `EmailListScreen`)
- **Email protocol**: `enough_mail` ^2.1.6 (IMAP + SMTP)
- **Database**: SQLite v14 schema via `sqflite` (Android/iOS) and `sqflite_common_ffi` (Linux)
- **Secure storage**: `flutter_secure_storage` — passwords never written to SQLite
- **Calendar**: CalDAV via `caldav_client` + direct HTTP (`package:http`) for performance-critical paths
- **HTML rendering**: `flutter_widget_from_html`
- **iCal/XML parsing**: `xml` ^6.0.0, `timezone` ^0.9.0
- **Packaging**: `flutter_distributor` (dev) — produces `.deb`, detects arch automatically

### Key Dependencies

```yaml
enough_mail: ^2.1.6        # IMAP/SMTP
sqflite: ^2.3.3+1          # SQLite Android/iOS
sqflite_common_ffi: ^2.3.6 # SQLite Linux/Windows
caldav_client: ^1.1.0      # CalDAV
flutter_secure_storage: ^9.0.0
flutter_widget_from_html: ^0.16.0
provider: ^6.0.5
intl: ^0.19.0
timezone: ^0.9.0
file_picker: ^8.1.2
url_launcher: ^6.3.0
html: ^0.15.4
```

---

## File Structure

```
lib/
├── main.dart                          # App entry, FuriMailApp, EmailListScreen,
│                                      # DatabaseHelper (singleton), EmailAccount model
├── email_filter_system.dart           # FilterManager (singleton), EmailFilter, AccountFolderPair
├── email_detail_screen_enhanced.dart  # Email viewer (actively used — NOT email_detail_screen.dart)
├── compose_screen.dart                # New email composition with contact autocomplete
├── reply_screen.dart                  # Reply/forward composition
├── contacts_view.dart                 # Contact management UI
├── calendar_view.dart                 # CalDAV calendar (sync + CRUD)
├── imap_flags_helper.dart             # IMAP flag parsing and server sync
├── contact_helper.dart                # Contact DB query helpers
└── database_helper.dart              # Legacy — DO NOT USE, use DatabaseHelper in main.dart

linux/packaging/deb/
└── make_config.yaml                   # flutter_distributor .deb config

.github/workflows/
└── build.yml                          # CI: builds amd64 + arm64 .deb on push to main
```

---

## Database Schema

The app uses SQLite with these tables. **IMPORTANT**: Always use the exact column names shown below.

### `emails` Table
Primary storage for cached emails.

```typescript
interface Email {
  id: number;                    // PRIMARY KEY AUTOINCREMENT
  messageId: string;             // NOT NULL - IMAP Message-ID header
  accountId: string;             // NOT NULL - Username/email of the account
  subject: string;               // NOT NULL
  sender: string;                // NOT NULL - Display name
  senderEmail: string;           // NOT NULL - Email address
  timestamp: number;             // NOT NULL - Unix timestamp (milliseconds)
  content: string;               // NOT NULL - HTML or plain text body
  isRead: number;                // NOT NULL - 0 or 1
  isStarred: number;             // NOT NULL - 0 or 1
  isAnswered: number;            // DEFAULT 0 - Replied flag
  isForwarded: number;           // DEFAULT 0
  isDraft: number;               // DEFAULT 0
  isDeleted: number;             // DEFAULT 0
  isJunk: number;                // DEFAULT 0
  folderPath: string;            // NOT NULL - IMAP folder (e.g., "INBOX", "Sent")
  inReplyTo: string | null;      // In-Reply-To header
  references: string | null;     // References header (threading)
  attachments: string | null;    // JSON array of attachment metadata
  threadParentId: string | null; // messageId of thread root
  hasAttachments: number;        // DEFAULT 0
  hasImages: number;             // DEFAULT 0
  rawEmail: string | null;       // Full raw email content
  imapFolder: string | null;     // Alternative folder reference
  bodyFetched: number;           // DEFAULT 0 - Whether full body was fetched
  uid: number;                   // DEFAULT 0 - IMAP UID
}

// UNIQUE CONSTRAINT: (messageId, accountId, folderPath)
// INDEXES: subject, sender, content, timestamp, inReplyTo, references, threadParentId, messageId
```

### `accounts` Table
Email account credentials and settings.

```typescript
interface Account {
  id: number;                    // PRIMARY KEY AUTOINCREMENT
  imap: string;                  // NOT NULL - IMAP server (e.g., "imap.gmail.com")
  smtp: string;                  // NOT NULL - SMTP server
  username: string;              // NOT NULL - Email address/login
  password: string;              // NOT NULL - Stored encrypted via flutter_secure_storage
  replyFrom: string;             // NOT NULL - Reply-from address
  name: string;                  // NOT NULL - Display name
  signature: string;             // NOT NULL - Email signature
  color: string;                 // NOT NULL - Hex color (e.g., "#FF0000")
  display: string;               // NOT NULL - Short display text/initials for avatar
  caldav_base_url: string;       // CalDAV server base URL
  caldav_path: string;           // CalDAV calendar path
  caldav_confirmed_path: string; // Tested/confirmed CalDAV path
  last_sync_timestamp: number;   // DEFAULT 0 - Unix timestamp
  sync_settings: string | null;  // JSON settings
}
```

### `imap_folders` Table
Cached IMAP folder structure.

```typescript
interface ImapFolder {
  id: number;                    // PRIMARY KEY AUTOINCREMENT
  accountId: string;             // NOT NULL
  folderName: string;            // NOT NULL - Display name
  folderPath: string;            // NOT NULL - Full IMAP path
  parentFolder: string | null;   // Parent folder path
  isSelectable: number;          // DEFAULT 1
  hasChildren: number;           // DEFAULT 0
  lastSynced: number;            // DEFAULT 0 - Unix timestamp
}

// UNIQUE CONSTRAINT: (accountId, folderPath)
```

### `imap_sync_state` Table
Tracks sync progress per folder.

```typescript
interface ImapSyncState {
  id: number;                    // PRIMARY KEY AUTOINCREMENT
  accountId: string;             // NOT NULL
  folderPath: string;            // NOT NULL
  lastFetchedUid: number;        // DEFAULT 0 - Last synced UID
  lastFetchedSequence: number;   // DEFAULT 0
  lastSyncTime: number;          // DEFAULT 0 - Unix timestamp
  totalMessages: number;         // DEFAULT 0
}

// UNIQUE CONSTRAINT: (accountId, folderPath)
```

### `contacts` Table
Contact book with frequency tracking.

```typescript
interface Contact {
  id: number;                    // PRIMARY KEY AUTOINCREMENT
  name: string;                  // NOT NULL
  email: string;                 // NOT NULL
  accountId: string;             // NOT NULL - Associated account
  workPhone: string | null;
  personalPhone: string | null;
  workAddress: string | null;
  personalAddress: string | null;
  company: string | null;
  jobTitle: string | null;
  notes: string | null;
  frequency: number;             // DEFAULT 1 - Usage frequency for autocomplete
  lastUsed: number;              // DEFAULT 0 - Unix timestamp
  isManual: number;              // DEFAULT 0 - 1 if manually created
}

// UNIQUE CONSTRAINT: (email, accountId)
// INDEXES: email, name, frequency DESC
```

### `calendar_events` Table
CalDAV calendar events.

```typescript
interface CalendarEvent {
  id: number;                    // PRIMARY KEY AUTOINCREMENT
  title: string;                 // NOT NULL
  description: string | null;
  startDateTime: number;         // NOT NULL - Unix timestamp
  endDateTime: number;           // NOT NULL - Unix timestamp
  location: string | null;
  accountId: string;             // NOT NULL
  isAllDay: number;              // DEFAULT 0
  reminderMinutes: number;       // DEFAULT 15
  hasAttachments: number;        // DEFAULT 0
  attendees: string | null;      // JSON array
  recurrence: string | null;     // iCal recurrence rule
  category: string;              // DEFAULT '' - e.g., "Work", "Personal"
  created: number;               // DEFAULT 0 - Unix timestamp
  modified: number;              // DEFAULT 0 - Unix timestamp
  caldav_uid: string | null;     // CalDAV UID
  caldav_etag: string | null;    // ETag for sync
  caldav_href: string | null;    // CalDAV resource URL
  caldav_raw_data: string | null; // Raw iCal data
  needs_sync: number;            // DEFAULT 0 - 1 if pending upload
}

// INDEXES: startDateTime, accountId, title, category, caldav_uid, needs_sync
```

### `user_settings` Table
Key-value settings storage.

```typescript
interface UserSetting {
  id: number;                    // PRIMARY KEY AUTOINCREMENT
  settingKey: string;            // NOT NULL UNIQUE
  settingValue: string | null;
}

// Known keys: "text_only_mode", "debug_mode", "folder_selections"
```

---

## Key Classes & Types

### `EmailAccount` (lib/main.dart)
Dart model for email accounts. Constructed from JSON import.

```dart
class EmailAccount {
  final String imap;
  final String smtp;
  final String username;          // Primary identifier
  final String password;
  final String replyFrom;
  final String name;
  final String signature;
  final Color color;              // Flutter Color object
  final String display;           // Avatar initials
  final String? caldavPath;
  final String? caldavBaseUrl;
  final String? caldavConfirmedPath;
}
```

### `EmailFilter` (lib/email_filter_system.dart)
Immutable filter state for email queries.

```dart
class EmailFilter {
  final Set<String> enabledAccounts;           // Account usernames to show
  final Set<AccountFolderPair> enabledAccountFolders; // Specific folder filters
  final String searchQuery;                    // Text search
}

class AccountFolderPair {
  final String accountId;   // Account username
  final String folderPath;  // IMAP folder path
}
```

### `FilterManager` (lib/email_filter_system.dart)
Singleton managing filter state with `ValueNotifier` for reactivity.

```dart
FilterManager.instance.currentFilter;     // Get current filter
FilterManager.instance.updateFilter(f);   // Apply new filter
FilterManager.instance.filterNotifier;    // Listen for changes
```

### `DatabaseHelper` (lib/main.dart)
Singleton for database access.

```dart
await DatabaseHelper.instance.database;   // Get Database instance
await DatabaseHelper.instance.getAccounts(); // Get List<EmailAccount>
```

---

## View Modes

The main screen switches between three views:

```dart
enum ViewMode {
  mail,      // EmailListScreen - main inbox
  calendar,  // CalendarView - CalDAV events
  people,    // ContactsView - address book
}
```

---

## Threading Model

Emails are threaded by `messageId` and `threadParentId`:

- **`threadParentId`**: Points to the root email's `messageId` in a thread
- **`inReplyTo`**: Direct parent message ID
- **`references`**: Full chain of message IDs

To show only thread roots in inbox:
```sql
WHERE threadParentId = messageId
```

---

## IMAP Flag Mapping

Synced via `ImapFlagsHelper`:

| IMAP Flag | Database Column |
|-----------|-----------------|
| `\Seen` | `isRead` |
| `\Flagged` | `isStarred` |
| `\Answered` | `isAnswered` |
| `\Draft` | `isDraft` |
| `\Deleted` | `isDeleted` |
| `$Forwarded` | `isForwarded` |
| `$Junk` | `isJunk` |

---

## Common Patterns

### Loading Emails from DB
```dart
final db = await DatabaseHelper.instance.database;
final emails = await db.query(
  'emails',
  where: filter.generateWhereClause(),
  whereArgs: filter.generateWhereArgs(),
  orderBy: 'timestamp DESC',
  limit: 50,
  offset: 0,
);
```

### Saving an Email
```dart
await db.insert('emails', {
  'messageId': messageId,
  'accountId': account.username,  // Use username as account ID
  'subject': subject,
  'sender': senderName,
  'senderEmail': senderEmail,
  'timestamp': DateTime.now().millisecondsSinceEpoch,
  'content': htmlContent,
  'isRead': 0,
  'isStarred': 0,
  'folderPath': 'INBOX',
  'threadParentId': messageId,  // Self-reference if no thread
}, conflictAlgorithm: ConflictAlgorithm.replace);
```

### Account JSON Format (import/export)
```json
{
  "accounts": [
    {
      "imap": "imap.example.com",
      "smtp": "smtp.example.com",
      "username": "user@example.com",
      "password": "your_password",
      "reply-from": "user@example.com",
      "name": "Display Name",
      "signature": "Best regards,\nName",
      "color": "#FF0000",
      "display": "DN",
      "caldav-base-url": "https://caldav.example.com",
      "caldav-path": "/calendars/user/default"
    }
  ]
}
```

---

## Important Notes

1. **Account ID**: Always use `account.username` (the email address) as `accountId` in database queries.

2. **Timestamps**: Store as Unix milliseconds (`DateTime.now().millisecondsSinceEpoch`). Emails without dates fallback to `0` (Unix epoch).

3. **Unique Emails**: The constraint `(messageId, accountId, folderPath)` prevents duplicates. Same email in different folders is allowed.

4. **Passwords**: Never stored directly in SQLite. Use `flutter_secure_storage` for actual password storage; the `password` column in `accounts` table is legacy.

5. **CalDAV Sync**: Uses `needs_sync` flag. Set to `1` when local changes need upload, cleared after successful sync.

6. **Debug Mode**: Toggle `_debugMode` in `_EmailListScreenState` for verbose logging.

---

## Running the App

```bash
# Install dependencies
flutter pub get

# Run on Linux
flutter run -d linux

# Run on Android
flutter run -d android

# Build release
flutter build linux --release
```

---

## Database Location

- **Linux**: `<project_root>/.dart_tool/sqflite_common_ffi/databases/furimail.db`
- **Android/iOS**: App internal storage (use `adb shell` or Files app to access)

To reset and force a full re-sync from IMAP, delete the database file and restart the app.
- **iOS**: App documents directory

To reset the database and re-sync from IMAP:
```bash
rm ~/Documents/code/fmail/.dart_tool/sqflite_common_ffi/databases/furimail.db
```

---

## Headers-First Sync Strategy

Email sync uses a two-phase approach for performance:

1. **Phase 1 - Headers Only**: Fetch email headers (subject, sender, date) quickly
   - Sets `bodyFetched = 0` in database
   - Allows UI to display email list immediately

2. **Phase 2 - Body Fetch**: Fetch full body content on-demand or in background
   - Sets `bodyFetched = 1` after fetching
   - Triggered when user opens an email or during background sync

```dart
// Check if body needs fetching
if (email['bodyFetched'] == 0) {
  await _fetchFullEmailBody(email);
}
```

---

## Threading Algorithm

The `rebuildAllThreading()` function rebuilds thread relationships:

1. Queries all emails ordered by timestamp
2. For each email, checks `inReplyTo` and `references` headers
3. Finds the oldest message in the thread chain (thread root)
4. Updates `threadParentId` to point to the root's `messageId`

```dart
// Thread root: threadParentId == messageId
// Thread child: threadParentId == root's messageId
```

**Note**: Thread rebuilding is O(n*m) where n=emails and m=thread chain length. Consider optimizations for large mailboxes.

---

## CalDAV Sync Algorithm

Calendar sync uses timestamp-based "newest wins" logic:

1. **Server → Local**:
   - REPORT request fetches events with ETags
   - Compare server `LAST-MODIFIED` with local `modified` timestamp
   - Server wins if newer, otherwise keep local

2. **Local → Server**:
   - Events with `needs_sync = 1` are uploaded via PUT
   - Include `If-Match: <etag>` header for updates
   - On 412 Precondition Failed, retry without If-Match (force overwrite)

3. **Path Discovery**:
   - Try `caldav_confirmed_path` first if available
   - Fall back to discovering paths from CalDAV principal

```dart
// Mark event for upload
await db.update('calendar_events', {'needs_sync': 1}, where: 'id = ?', whereArgs: [id]);

// Clear after successful upload
await db.update('calendar_events', {'needs_sync': 0, 'caldav_etag': newEtag}, ...);
```

---

## Contact Autocomplete

Compose screen provides contact autocomplete after 2 characters:

1. Search `contacts` table by name or email (case-insensitive LIKE)
2. Results ordered by `frequency DESC` (most-used first)
3. Update `frequency` and `lastUsed` when contact is selected

```dart
final contacts = await db.query(
  'contacts',
  where: '(name LIKE ? OR email LIKE ?) AND accountId = ?',
  whereArgs: ['%$query%', '%$query%', accountId],
  orderBy: 'frequency DESC',
  limit: 10,
);
```

---

## Error Handling Patterns

Global error handler in `main()` suppresses known non-critical errors:

```dart
void _handleFlutterError(FlutterErrorDetails details) {
  // Suppress known Flutter/Linux keyboard issues
  if (exceptionStr.contains('Num Lock') ||
      exceptionStr.contains('physicalKey')) {
    return; // Don't crash
  }
  FlutterError.presentError(details);
}
```

**Principle**: Log errors but don't crash the app for non-fatal issues.

---

## Known Issues & Gotchas

1. **SQLite `references` Column**: `references` is a reserved word - use quotes in raw SQL: `"references"`

2. **Account Dropdown Duplicates**: Use `.fold()` to deduplicate when building dropdown items from account list

3. **VTIMEZONE Parsing**: When parsing iCal, skip DTSTART in VTIMEZONE blocks - only parse within VEVENT blocks

4. **CalDAV Namespace Prefixes**: Different servers use `cal:`, `c:`, or no prefix for calendar-data - handle all variants

5. **Empty Timestamps**: Emails without valid dates get `timestamp = 0` (Unix epoch)

---

## Testing

Run tests with:

```bash
# All unit tests
flutter test test/unit/

# Specific test file
flutter test test/unit/calendar/ical_parsing_test.dart

# With coverage
flutter test --coverage
```

Test database helper creates in-memory SQLite instances for isolated testing.

---

## Dependencies (Full List)

```yaml
dependencies:
  enough_mail: ^2.1.6        # IMAP/SMTP
  sqflite: ^2.3.3+1          # SQLite (Android/iOS)
  sqflite_common_ffi: ^2.3.6 # SQLite (Linux/Windows)
  caldav_client: ^1.1.0      # CalDAV sync
  flutter_secure_storage: ^9.0.0  # Secure credential storage
  flutter_widget_from_html: ^0.16.0  # HTML email rendering
  provider: ^6.0.5           # State management
  intl: ^0.19.0              # Date formatting
  timezone: ^0.9.0           # Timezone handling for CalDAV
  url_launcher: ^6.3.0       # Open links in browser
  file_picker: ^8.1.2        # Attachment file selection
  path_provider: ^2.1.4      # App directory paths
  html: ^0.15.4              # HTML parsing
```
