# fMail TODO

---

## High Priority — Bugs

### Performance: Slow loading with many accounts / 10k+ emails

- Suspected causes: `_debugMode = true` permanently enabled (floods stdout), N+1 queries, unbounded caches
- First step: set `_debugMode = false` in `main.dart:2159` and measure improvement
- Also: `_threadCache`, `_threadRepliesStatus`, `_threadLatestTimestamps` maps grow unbounded — cap or clear on account switch
- `rebuildAllThreading()` is O(n×m) — slow with large mailboxes, needs optimization

### Delete email says it works but doesn't

- Investigate: check whether IMAP `\Deleted` flag is being set AND `EXPUNGE` is being called
- Local DB sets `isDeleted = 1` but email may reappear on next sync if server-side delete failed
- Check `imap_flags_helper.dart` and wherever delete is triggered in `main.dart`

### Email threading UI broken

- Thread expand icon no longer accurately shows children/parents
- `threadParentId` logic may be assigning wrong root — verify `rebuildAllThreading()` output
- UI expand state and actual thread children may be out of sync

### Filter counts don't update when new email arrives

- Counts shown in filter UI are stale after IMAP sync
- Need to trigger filter count recalculation after each sync cycle

### Email list doesn't auto-refresh in order on new email

- List may not reorder by timestamp after new email is inserted
- Evaluate: is live reordering needed or is a periodic refresh sufficient?

### HTML email rendering — replace flutter_widget_from_html with WebView

- Current `flutter_widget_from_html` has layout issues with complex HTML and images
- Replace with `webview_flutter` (already in pubspec) for full fidelity rendering
- Need to handle CID image references (inline attachments) via data URIs
- Note: WebView on Linux requires `libwebkit2gtk-4.0-dev`

---

## High Priority — New Features

### AI Email Reply Assistant

Design: settings screen stores API keys and model selection per provider.

**Providers to support:**

- OpenAI (GPT-4o, GPT-4, etc.) — `https://api.openai.com/v1/chat/completions`
- Anthropic (Claude) — `https://api.anthropic.com/v1/messages`
- Ollama (local) — `http://localhost:11434/api/chat` (no key needed, just model name)

**Settings to store in `user_settings` table:**

- `ai_provider` — `openai` | `anthropic` | `ollama`
- `ai_openai_key` — store via `flutter_secure_storage`
- `ai_anthropic_key` — store via `flutter_secure_storage`
- `ai_ollama_url` — base URL (default `http://localhost:11434`)
- `ai_model` — model name string

**UX:**

- "Draft with AI" button in reply_screen.dart
- Sends email thread context + user prompt to selected provider
- Streams response into reply body field
- User edits before sending

### Database size in Settings

- Query: `SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()`
- Or: stat the `.db` file directly via `File(dbPath).stat()`
- Display in settings as e.g. "Email cache: 142 MB — Clear"
- Add "Clear cache" button that deletes and reinitialises the DB

### Data export/import (backup & migrate) — in Settings

A user-facing backup feature accessible from Settings:

**Export:**

- Bundle `furimail.db` + accounts JSON (with passwords from secure storage) into a single `.zip`
- Encrypt the zip with a user-chosen password (AES-256)
- Save to a user-selected location via `file_picker`

**Import:**

- User selects the `.zip` file and enters password
- Decrypt and validate contents
- Restore `furimail.db` to correct location
- Re-import accounts JSON (re-enters credentials into platform keyring)
- Prompt to restart app

**Implementation notes:**

- Use `archive` package for zip creation, `encrypt` or `pointycastle` for AES
- Accounts JSON must include passwords — fetch from `flutter_secure_storage` at export time
- Warn user clearly that the zip contains credentials and should be stored securely
- On Linux: default export path `~/fmail-backup-<date>.zip`
- Consider excluding `rawEmail` content from DB export to keep file size small (emails re-sync from server)

---

## Medium Priority — Bugs

### CC and BCC missing contact autocomplete

- Compose screen has autocomplete on To field only
- Apply same `contact_helper.dart` lookup to CC and BCC fields

### New emails stopped fetching (regression)

- Verify IMAP IDLE or polling loop is still running after recent changes
- Check `lastFetchedUid` in `imap_sync_state` is being updated correctly


### contacts_view.dart:150 — wrong column names

- Query uses `fromAddress`/`toAddress` — should be `senderEmail`
- Causes email count per contact to always return 0

### calendar_view.dart:1591-1595 — debug code blocks single-event sync

- Remove or gate behind debug flag

### calendar_view.dart:1701-1720 — events silently discarded

- Events missing href/etag/calendar_data are dropped without logging
- Add warning log and graceful handling

---

## Medium Priority — Performance

### CalDAV path discovery too slow

- Currently tries 17 URLs sequentially with 10s timeout each = up to 170s
- Cache confirmed path in `caldav_confirmed_path` column (already exists) and skip discovery
- Parallelize probing if cache miss

### N+1 query in contacts_view.dart

- 1 query per contact for email count — batch into single GROUP BY query

### Email list firstWhere() on every render

- O(n×m) — use a Map lookup instead

### SMTP blocks main thread

- Wrap SMTP send in `compute()` or `Isolate.run()` in `compose_screen.dart` and `reply_screen.dart`

---

## Medium Priority — Code Quality

### `_debugMode = true` permanently on (main.dart:2159)

- Set to `false` for release; wire to `user_settings` `debug_mode` key

### FlutterError.onError set 4 times in main.dart

- Only last assignment takes effect — consolidate into the one in `main()`

### Duplicated code to extract

- Sender parsing — duplicated in 5+ places → extract to `contact_helper.dart`
- Date parsing (200+ lines) — duplicated → extract to shared utility
- SMTP logic — 90% identical in `compose_screen.dart` and `reply_screen.dart` → extract service
- `PRAGMA table_info` pattern — repeated 10+ times → extract helper

### Reply screen missing contact autocomplete

- `compose_screen.dart` has it; apply same pattern to `reply_screen.dart`

### No debounce on contact search

- Fires a DB query on every keystroke — add 300ms debounce

---

## Tests

### Current state

```text
test/
├── widget_test.dart                     ← BROKEN — default Flutter counter template, delete or replace
├── helpers/test_database.dart           ← Good in-memory DB helper with full schema
└── unit/
    ├── email/threading_test.dart        ← Works
    ├── filter/filter_manager_test.dart  ← Works
    └── calendar/ical_parsing_test.dart  ← Works
```

Run the working tests:

```bash
flutter test test/unit/
```

Do NOT run `test/widget_test.dart` — it will fail immediately.

### Tests to add

- `test/unit/email/delete_test.dart` — verify IMAP `\Deleted` flag + EXPUNGE behaviour
- `test/unit/email/imap_flags_test.dart` — test `ImapFlagsHelper.parseImapFlags()`
- `test/unit/contacts/autocomplete_test.dart` — frequency ranking, 2-char trigger
- `test/unit/contacts/contact_helper_test.dart` — test `contact_helper.dart` queries
- `test/unit/calendar/caldav_sync_test.dart` — timestamp-based newest-wins logic
- Integration tests for SMTP send (mocked)

### Playwright / web UI testing (suggestion)

Flutter web (`flutter run -d chrome`) renders the full UI locally.
Playwright could drive the web build for end-to-end UI tests (navigation, compose screen,
filter interactions) without any email server — good option for CI.

---

## Lower Priority — Missing Features

### Email Forwarding

- Forward button missing from email detail view
- `reply_screen.dart` likely needs a `isForward` mode (similar to reply) that pre-fills subject with `Fwd:` and quotes the original body
- Set `isForwarded = 1` on the original email after sending and sync `$Forwarded` IMAP flag

### Unsubscribe Button

- When opening an email, detect `List-Unsubscribe` header or unsubscribe links in the body
- Show a prominent "Unsubscribe" button in the email detail view that opens the link
- Bonus: add an inbox filter ("Has unsubscribe link") to show all such emails — makes bulk unsubscribing easy
- Detection: check `List-Unsubscribe` header first (reliable), then fall back to regex on body for "unsubscribe" links

### Email Sort Options

- Currently sorted by date descending only
- Add sort options: date (newest/oldest), sender name (A-Z / Z-A)
- Store preference in `user_settings` table under a `sort_order` key

### Notifications (local, no server required)

No push server needed — the app already has the data. Use `flutter_local_notifications` to trigger OS-level notifications directly from within the app.

**New email notifications:**

- Trigger when IMAP sync detects new UIDs higher than `lastFetchedUid`
- Show sender, subject, account colour
- On Android: use `workmanager` for periodic background sync when app is not in foreground
- On Linux/FLX: app can run as background service; libnotify → GNOME notifications via `flutter_local_notifications`
- On iOS: trigger during foreground sync; background fetch (~15 min intervals) via `background_fetch`

**Calendar reminders:**

- Pre-schedule a local notification at `startDateTime - reminderMinutes` whenever an event is saved or synced
- No background process needed — notifications are registered with the OS at sync time and fire even if the app is closed
- `reminderMinutes` is already stored per-event in the `calendar_events` table

**Implementation:**

- Add `flutter_local_notifications` to `pubspec.yaml`
- On Android: add `workmanager` for background email sync
- Request notification permission on first launch (required iOS/Android 13+)
- Add notification toggle in Settings per account and for calendar reminders

### Attachment handling

- Incomplete — referenced in schema but not fully implemented in UI

---

## Known Gotchas (do not forget)

- `references` is a reserved SQL word — always quote it: `"references"`
- `email_detail_screen.dart` is the old file — **use `email_detail_screen_enhanced.dart`**
- `database_helper.dart` is legacy — **use `DatabaseHelper` in `main.dart`**
- CalDAV servers use `cal:`, `c:`, or no namespace prefix — handle all variants
- Emails without a date header get `timestamp = 0` (Unix epoch) — filter these in UI
- Account dropdown must deduplicate with `.fold()` to avoid duplicate entries
