import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'main.dart'; // For EmailAccount and DatabaseHelper
import 'package:caldav_client/caldav_client.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz;

class CalendarView extends StatefulWidget {
  final List<EmailAccount> accounts;
  
  const CalendarView({
    Key? key,
    required this.accounts,
  }) : super(key: key);

  @override
  _CalendarViewState createState() => _CalendarViewState();
}

/// SIMPLIFIED SYNC ALGORITHM IMPLEMENTATION:
/// 
/// 📤 IMMEDIATE UPLOAD (User Actions):
/// 1. User edits/adds event ✏️
/// 2. Save to local DB first 💾
/// 3. IMMEDIATELY upload to server via PUT request 🚀
/// 4. Server updates LAST-MODIFIED timestamp ⏰
/// 5. Mark local event: needs_sync = 0 ✅
/// 6. Show instant user feedback 🎉
/// 
/// 📥 BACKGROUND SYNC (Cleanup & Download):
/// 1. Fetch all server events every 5 minutes 📡
/// 2. For each UID: compare LAST-MODIFIED timestamps ⏰
/// 3. Keep newest version (server wins after immediate upload) 🏆
/// 4. Delete any local duplicates with same UID 🗑️
/// 5. Download new events from other users 📥
/// 
/// 🚀 PERFORMANCE OPTIMIZATIONS:
/// - Auto-sync every 90 seconds (was 2 minutes)
/// - Periodic sync every 5 minutes (was 10 minutes)
/// - UID-based duplicate cleanup prevents accumulation
/// - Timestamp comparison is O(1) vs complex field comparison
/// - Direct HTTP requests bypass caldav_client overhead
class _CalendarViewState extends State<CalendarView> {
  List<Map<String, dynamic>> _events = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _categoryFilter = ''; // Category filter
  Map<String, Color> _accountColors = {}; // Account colors by email address
  Timer? _syncTimer;
  DateTime _lastSyncTime = DateTime.now().subtract(const Duration(days: 1));
  
  // Predefined categories
  final List<String> _predefinedCategories = [
    'Work',
    'Personal', 
    'Meeting',
    'Appointment',
    'Birthday',
    'Holiday',
    'Travel',
    'Health',
    'Family',
    'Project'
  ];

  @override
  void initState() {
    super.initState();
    _initializeTimezone();
    _loadEvents(); // Load events (will auto-sync if > 90 seconds since last sync)
    _startPeriodicSync();
  }

  void _initializeTimezone() {
    try {
      tz.initializeTimeZones();
      print('✅ Timezone database initialized');
    } catch (e) {
      print('⚠️ Failed to initialize timezone database: $e');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _syncTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadEvents({bool forceSyncFirst = false}) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });

    try {
      print('DEBUG: Loading calendar events with search query: "$_searchQuery" (forceSyncFirst: $forceSyncFirst)');
      
      // Force sync first if requested (for manual refresh)
      if (forceSyncFirst) {
        print('🚀 Force syncing CalDAV before loading events...');
        await _syncFromCalDAV(forceSync: true);
        _lastSyncTime = DateTime.now();
        print('✅ Force sync completed, now loading events...');
      }
      
      final db = await DatabaseHelper.instance.database;
      
      // Check if calendar_events table exists first
      final tableExists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='calendar_events'"
      );
      print('DEBUG: Calendar events table exists: ${tableExists.isNotEmpty}');
      
      if (tableExists.isEmpty) {
        print('WARNING: Calendar events table does not exist, creating it now...');
        
        // Create the calendar_events table manually
        await db.execute('''
          CREATE TABLE IF NOT EXISTS calendar_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            description TEXT,
            startDateTime INTEGER NOT NULL,
            endDateTime INTEGER NOT NULL,
            location TEXT,
            accountId TEXT NOT NULL,
            isAllDay INTEGER DEFAULT 0,
            reminderMinutes INTEGER DEFAULT 15,
            hasAttachments INTEGER DEFAULT 0,
            attendees TEXT,
            recurrence TEXT,
            category TEXT DEFAULT '',
            created INTEGER DEFAULT 0,
            modified INTEGER DEFAULT 0,
            caldav_uid TEXT,
            caldav_etag TEXT,
            caldav_href TEXT,
            caldav_raw_data TEXT,
            needs_sync INTEGER DEFAULT 0
          )
        ''');
        
        // Create indexes
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_start_date ON calendar_events (startDateTime)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_account ON calendar_events (accountId)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_title ON calendar_events (title)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_category ON calendar_events (category)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_caldav_uid ON calendar_events (caldav_uid)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_needs_sync ON calendar_events (needs_sync)');
        
        // Add new columns to existing table if they don't exist
        try {
          await db.execute('ALTER TABLE calendar_events ADD COLUMN caldav_uid TEXT');
        } catch (e) {
          // Column already exists
        }
        try {
          await db.execute('ALTER TABLE calendar_events ADD COLUMN caldav_etag TEXT');
        } catch (e) {
          // Column already exists
        }
        try {
          await db.execute('ALTER TABLE calendar_events ADD COLUMN caldav_href TEXT');
        } catch (e) {
          // Column already exists
        }
        try {
          await db.execute('ALTER TABLE calendar_events ADD COLUMN caldav_raw_data TEXT');
        } catch (e) {
          // Column already exists
        }
        try {
          await db.execute('ALTER TABLE calendar_events ADD COLUMN needs_sync INTEGER DEFAULT 0');
        } catch (e) {
          // Column already exists
        }
        
        print('DEBUG: Calendar events table created successfully');
        
        setState(() {
          _events = [];
          _isLoading = false;
        });
        return;
      }
      
      String whereClause = '1=1'; // Start with always true condition
      List<dynamic> whereArgs = [];

      // Add search filter if query is not empty
      if (_searchQuery.isNotEmpty) {
        whereClause += ' AND (title LIKE ? OR description LIKE ? OR location LIKE ?)';
        final searchPattern = '%$_searchQuery%';
        whereArgs.addAll([searchPattern, searchPattern, searchPattern]);
      }
      
      // Add category filter if selected
      if (_categoryFilter.isNotEmpty) {
        whereClause += ' AND category = ?';
        whereArgs.add(_categoryFilter);
      }

      print('DEBUG: Query where clause: $whereClause');
      print('DEBUG: Query args: $whereArgs');

      final events = await db.query(
        'calendar_events',
        where: whereClause,
        whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
        orderBy: 'startDateTime ASC',
      );

      print('DEBUG: Loaded ${events.length} calendar events from database');

      setState(() {
        _events = events;
        _isLoading = false;
      });

      // Check if category column exists and add it if missing (migration)
      await _ensureCategoryColumnExists(db);
      
      // Load account colors after events are loaded
      await _loadAccountColors();
      
      // OPTIMIZED SYNC: Sync from CalDAV servers if it's been more than 90 seconds (was 2 minutes)
      if (DateTime.now().difference(_lastSyncTime).inSeconds > 90) {
        print('� OPTIMIZED AUTO-SYNC: Starting fast CalDAV sync (more than 90 seconds since last sync)');
        await _syncFromCalDAV();
        await _loadEventsFromDatabase(); // Refresh UI after sync
        _lastSyncTime = DateTime.now();
      } else {
        print('⏰ OPTIMIZED AUTO-SYNC: Skipping (last sync was ${DateTime.now().difference(_lastSyncTime).inSeconds} seconds ago)');
      }
      
      // Refresh the UI
      if (mounted) {
        setState(() {});
      }
    } catch (e, stackTrace) {
      print('ERROR: Failed to load calendar events: $e');
      print('STACK TRACE: $stackTrace');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      
      // Show error to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading calendar events: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  /// Load events from database only (no sync) - for UI refresh after background sync
  Future<void> _loadEventsFromDatabase() async {
    if (!mounted) return;
    
    try {
      print('🔄 Loading events from database for UI refresh...');
      final db = await DatabaseHelper.instance.database;
      
      String whereClause = '1=1'; // Start with always true condition
      List<dynamic> whereArgs = [];

      // Add search filter if query is not empty
      if (_searchQuery.isNotEmpty) {
        whereClause += ' AND (title LIKE ? OR description LIKE ? OR location LIKE ?)';
        final searchPattern = '%$_searchQuery%';
        whereArgs.addAll([searchPattern, searchPattern, searchPattern]);
      }
      
      // Add category filter if selected
      if (_categoryFilter.isNotEmpty) {
        whereClause += ' AND category = ?';
        whereArgs.add(_categoryFilter);
      }

      final events = await db.query(
        'calendar_events',
        where: whereClause,
        whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
        orderBy: 'startDateTime ASC',
      );

      print('🔄 Loaded ${events.length} events from database for UI refresh');

      if (mounted) {
        setState(() {
          _events = events;
        });
        print('✅ UI state updated with ${events.length} events');
      }
    } catch (e) {
      print('❌ Error loading events from database: $e');
    }
  }

  Future<void> _loadAccountColors() async {
    try {
      // Map account emails to their colors
      for (var account in widget.accounts) {
        _accountColors[account.username] = account.color;
      }
    } catch (e) {
      print('ERROR: Failed to load account colors: $e');
    }
  }

  /// Get the account color for an event (used for date circle)
  Color _getAccountColor(Map<String, dynamic> event) {
    final accountId = event['accountId'] as String? ?? '';
    return _accountColors[accountId] ?? Colors.blue;
  }

  Color _getCategoryColor(String category) {
    // Define colors for each category
    const categoryColors = {
      'Work': Colors.red,
      'Personal': Colors.green,
      'Meeting': Colors.orange,
      'Appointment': Colors.purple,
      'Birthday': Colors.pink,
      'Holiday': Colors.teal,
      'Travel': Colors.indigo,
      'Health': Colors.cyan,
      'Family': Colors.amber,
      'Project': Colors.deepOrange,
    };
    
    return categoryColors[category] ?? Colors.blueGrey;
  }

  String _getEventDateDisplay(Map<String, dynamic> event) {
    final startTime = DateTime.fromMillisecondsSinceEpoch(event['startDateTime'] ?? 0);
    return DateFormat('EEE M/d').format(startTime); // e.g., "Mon 7/11"
  }

  /// ENHANCED ADD EVENT: With immediate upload functionality
  Future<void> _addEvent() async {
    final result = await _showEventDialog();
    if (result != null) {
      try {
        print('🚀 IMMEDIATE UPLOAD: Adding new calendar event with data: $result');
        final db = await DatabaseHelper.instance.database;
        
        // Check if calendar_events table exists
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='calendar_events'"
        );
        print('DEBUG: Calendar events table exists: ${tableExists.isNotEmpty}');
        if (tableExists.isEmpty) {
          print('ERROR: Calendar events table does not exist in database');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Calendar events table not found. Please restart the app.'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        
        // Generate UID for new event
        final account = widget.accounts.firstWhere(
          (a) => a.username == result['accountId'],
        );
        final eventUid = 'event-${DateTime.now().millisecondsSinceEpoch}@${account.username}';
        result['caldav_uid'] = eventUid;
        
        final insertId = await db.insert('calendar_events', result);
        print('✅ Calendar event inserted successfully with ID: $insertId');

        // Get the full event data for immediate upload
        final newEvents = await db.query(
          'calendar_events',
          where: 'id = ?',
          whereArgs: [insertId],
        );
        
        if (newEvents.isNotEmpty) {
          // 🚀 IMMEDIATE UPLOAD: Upload new event to server instantly
          print('🚀 IMMEDIATE UPLOAD: User added new event - uploading to server...');
          final uploadSuccess = await _immediateUploadEvent(newEvents.first);
          
          if (uploadSuccess) {
            print('✅ IMMEDIATE UPLOAD: New event successfully synced to server!');
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Event added and synced to server!'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 2),
              ),
            );
          } else {
            print('⚠️ IMMEDIATE UPLOAD: Failed, marked for background sync');
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('⚠️ Event added locally, will sync to server shortly'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          }
        }

        await _loadEvents();
      } catch (e, stackTrace) {
        print('❌ Failed to add calendar event: $e');
        print('STACK TRACE: $stackTrace');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error adding event: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  /// OPTIMIZED PERIODIC SYNC: Faster intervals with smart throttling
  void _startPeriodicSync() {
    // OPTIMIZED: Sync every 5 minutes for better responsiveness (was 10 minutes)
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      // Check if widget is still mounted before syncing
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      // OPTIMIZED: Only sync if it's been more than 3 minutes since last sync (was 5 minutes)
      if (DateTime.now().difference(_lastSyncTime).inMinutes > 3) {
        print('� OPTIMIZED SYNC: Starting fast periodic CalDAV sync...');
        _syncFromCalDAV().then((_) {
          _lastSyncTime = DateTime.now();
          print('✅ OPTIMIZED SYNC: Fast periodic sync completed');
          
          // 🔄 REFRESH UI after background sync
          if (mounted) {
            print('🔄 OPTIMIZED SYNC: Refreshing UI after background sync...');
            _loadEventsFromDatabase().then((_) {
              print('✅ OPTIMIZED SYNC: UI refreshed successfully');
            }).catchError((e) {
              print('❌ OPTIMIZED SYNC: UI refresh failed: $e');
            });
          }
        }).catchError((e) {
          print('❌ OPTIMIZED SYNC: Fast periodic sync failed: $e');
        });
      } else {
        print('⏰ OPTIMIZED SYNC: Skipping (last sync was ${DateTime.now().difference(_lastSyncTime).inMinutes} minutes ago)');
      }
    });
  }

  Future<void> _ensureCategoryColumnExists(dynamic db) async {
    try {
      // Check if category column exists
      final columns = await db.rawQuery("PRAGMA table_info(calendar_events)");
      final hasCategory = columns.any((column) => column['name'] == 'category');
      final hasNeedsSync = columns.any((column) => column['name'] == 'needs_sync');
      
      if (!hasCategory) {
        print('Adding category column to existing calendar_events table...');
        await db.execute('ALTER TABLE calendar_events ADD COLUMN category TEXT DEFAULT ""');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_category ON calendar_events (category)');
        print('Category column added successfully');
      }
      
      if (!hasNeedsSync) {
        print('Adding needs_sync column to existing calendar_events table...');
        await db.execute('ALTER TABLE calendar_events ADD COLUMN needs_sync INTEGER DEFAULT 0');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_event_needs_sync ON calendar_events (needs_sync)');
        print('needs_sync column added successfully');
      }
    } catch (e) {
      print('Error ensuring columns exist: $e');
    }
  }

  String _getCalDAVUrl(EmailAccount account) {
    // Use configured CalDAV base URL if provided
    if (account.caldavBaseUrl != null && account.caldavBaseUrl!.isNotEmpty) {
      return account.caldavBaseUrl!;
    }
    
    final imapHost = account.imap;
    
    // Common CalDAV URL patterns for different providers
    final Map<String, String> providerUrls = {
      'gmail.com': 'https://apidata.googleusercontent.com/caldav/v2',
      'outlook.com': 'https://outlook.office365.com',
      'hotmail.com': 'https://outlook.office365.com',
      'live.com': 'https://outlook.office365.com',
      'icloud.com': 'https://caldav.icloud.com',
      'yahoo.com': 'https://caldav.calendar.yahoo.com',
      'fastmail.com': 'https://caldav.fastmail.com',
    };
    
    // Check if it's a known provider
    for (final domain in providerUrls.keys) {
      if (account.username.toLowerCase().contains(domain)) {
        return providerUrls[domain]!;
      }
    }
    
    // Fallback: try common CalDAV patterns
    if (imapHost.startsWith('imap.')) {
      return 'https://${imapHost.replaceFirst('imap.', 'caldav.')}/';
    } else if (imapHost.startsWith('mail.')) {
      return 'https://${imapHost.replaceFirst('mail.', 'caldav.')}/';
    } else {
      return 'https://$imapHost/caldav/';
    }
  }

  /// Make a direct HTTP REPORT request (like the working Python script)
  Future<http.Response> _makeDirectCalDAVRequest(EmailAccount account, String calendarPath, DateTime startDate, DateTime endDate) async {
    final baseUrl = _getCalDAVUrl(account);
    final fullUrl = '$baseUrl$calendarPath';
    
    print('🌐 Making direct HTTP REPORT to: $fullUrl');
    print('🔑 [AUTH-DEBUG] Username: ${account.username}');
    print('🔑 [AUTH-DEBUG] Password length: ${account.password.length} chars');
    print('🔑 [AUTH-DEBUG] CalDAV base URL: $baseUrl');
    print('🔑 [AUTH-DEBUG] Calendar path: $calendarPath');
    print('📅 [DATE-RANGE] Start: ${startDate.toIso8601String()}');
    print('📅 [DATE-RANGE] End: ${endDate.toIso8601String()}');
    
    // Create exact headers like Python script (using same auth as PUT which works)
    final authString = '${account.username}:${account.password}';
    final authBytes = authString.codeUnits;
    final authBase64 = base64Encode(authBytes);
    final headers = {
      'Authorization': 'Basic $authBase64',
      'Content-Type': 'application/xml; charset=utf-8',
      'Depth': '1',
      'User-Agent': 'FMail/1.0',
    };
    
    print('🔑 [AUTH-DEBUG] Authorization header: Basic ${authBase64.substring(0, min(20, authBase64.length))}...');
    
    // Create exact REPORT body like Python script
    final startDateStr = DateFormat('yyyyMMddTHHmmssZ').format(startDate.toUtc());
    final endDateStr = DateFormat('yyyyMMddTHHmmssZ').format(endDate.toUtc());

    print('📅 [DATE-STRINGS] Start: $startDateStr');
    print('📅 [DATE-STRINGS] End: $endDateStr');
    
    final reportBody = '''<?xml version="1.0" encoding="utf-8" ?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag />
    <c:calendar-data />
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="$startDateStr" end="$endDateStr"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>''';

    print('🔧 HTTP REPORT body: ${reportBody.length} chars');
    print('📋 REPORT XML Query (full ${reportBody.length} chars):');
    // Print in chunks to avoid truncation
    for (int i = 0; i < reportBody.length; i += 200) {
      print(reportBody.substring(i, i + 200 > reportBody.length ? reportBody.length : i + 200));
    }
    print('🔧 Headers: $headers');
    
    try {
      final client = http.Client();
      final request = http.Request('REPORT', Uri.parse(fullUrl));
      request.headers.addAll(headers);
      request.body = reportBody;
      
      final streamedResponse = await client.send(request).timeout(
        const Duration(seconds: 30),
      );
      
      var response = await http.Response.fromStream(streamedResponse);
      
      // Handle 302/301 redirects
      if (response.statusCode == 302 || response.statusCode == 301) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl != null) {
          print('🔄 REPORT: Following redirect to: $redirectUrl');
          
          // Parse redirect URL - can be relative or absolute
          final redirectUri = redirectUrl.startsWith('http') 
              ? Uri.parse(redirectUrl)
              : Uri.parse('$baseUrl$redirectUrl');
          
          print('🔄 REPORT: Redirect URI: $redirectUri');
          
          // Make new REPORT request to redirected URL
          final redirectRequest = http.Request('REPORT', redirectUri);
          redirectRequest.headers.addAll(headers);
          redirectRequest.body = reportBody;
          
          final redirectStreamedResponse = await client.send(redirectRequest).timeout(
            const Duration(seconds: 30),
          );
          
          response = await http.Response.fromStream(redirectStreamedResponse);
          print('📡 REPORT after redirect status: ${response.statusCode}');
        }
      }
      
      client.close();
      
      return response;
    } catch (e) {
      print('❌ Direct HTTP REPORT failed: $e');
      rethrow;
    }
  }

  Future<CalDavClient?> _createCalDAVClient(EmailAccount account) async {
    try {
      final caldavUrl = _getCalDAVUrl(account);
      print('🌐 Attempting CalDAV connection to: $caldavUrl for ${account.username}');
      
      // Create Basic Auth header - exactly like the working Python script
      final credentials = base64Encode(utf8.encode('${account.username}:${account.password}'));
      final authHeaders = {
        'Authorization': 'Basic $credentials',
        'Content-Type': 'application/xml; charset=utf-8',
        'User-Agent': 'FuriMail-CalDAV/1.0',
        'Accept': 'application/xml, text/xml',
      };
      
      final client = CalDavClient(
        baseUrl: caldavUrl,
        headers: authHeaders,
      );
      
      print('✅ CalDAV client created successfully for ${account.username}');
      return client;
    } catch (e) {
      print('❌ Failed to create CalDAV client for ${account.username}: $e');
      return null;
    }
  }

  /// Upload local changes to CalDAV server (legacy batch method)
  Future<void> _uploadLocalChanges() async {
    print('📤 Checking for local changes to upload...');
    
    try {
      final db = await DatabaseHelper.instance.database;
      
      // Find events that need to be synced (locally modified)
      final localChanges = await db.query(
        'calendar_events',
        where: 'needs_sync = ?',
        whereArgs: [1],
      );
      
      if (localChanges.isEmpty) {
        print('✅ No local changes to upload');
        return;
      }
      
      print('📤 Found ${localChanges.length} local changes to upload');
      
      final accounts = await DatabaseHelper.instance.getAccounts();
      final accountMap = Map<String, EmailAccount>.fromIterable(
        accounts,
        key: (account) => (account as EmailAccount).username,
        value: (account) => account as EmailAccount,
      );
      
      for (final eventData in localChanges) {
        final accountId = eventData['accountId'] as String;
        final account = accountMap[accountId];
        
        if (account == null) {
          print('❌ Account not found for event: $accountId');
          continue;
        }
        
        String? uid = eventData['caldav_uid'] as String?;
        if (uid == null || uid.isEmpty) {
          // Generate UID for events that don't have one yet
          uid = 'event-${DateTime.now().millisecondsSinceEpoch}@${account.username}';
          print('📝 Generated new CalDAV UID for existing event: $uid');
          
          // Update the event in database with the new UID
          await db.update(
            'calendar_events',
            {'caldav_uid': uid},
            where: 'id = ?',
            whereArgs: [eventData['id']],
          );
          
          // Update our local eventData copy too
          eventData['caldav_uid'] = uid;
        }
        
        try {
          await _uploadEventToServer(account, eventData, uid);
          
          // Mark as synced
          await db.update(
            'calendar_events',
            {'needs_sync': 0},
            where: 'id = ?',
            whereArgs: [eventData['id']],
          );
          
          print('✅ Uploaded event: ${eventData['title']}');
        } catch (e) {
          print('❌ Failed to upload event ${eventData['title']}: $e');
        }
      }
    } catch (e) {
      print('❌ Error uploading local changes: $e');
    }
  }

  /// IMMEDIATE UPLOAD: Upload single event instantly when user saves changes
  Future<bool> _immediateUploadEvent(Map<String, dynamic> eventData) async {
    print('🚀 IMMEDIATE UPLOAD: Uploading event instantly...');
    
    try {
      final accountId = eventData['accountId'] as String;
      final accounts = await DatabaseHelper.instance.getAccounts();
      final account = accounts.firstWhere(
        (a) => a.username == accountId,
        orElse: () => throw Exception('Account not found: $accountId'),
      );
      
      // DEBUG: Show CalDAV configuration
      print('🔍 [CALENDAR-DEBUG] Account: ${account.username}');
      print('🔍 [CALENDAR-DEBUG] caldavBaseUrl: "${account.caldavBaseUrl}"');
      print('🔍 [CALENDAR-DEBUG] caldavPath: "${account.caldavPath}"');
      print('🔍 [CALENDAR-DEBUG] caldavConfirmedPath: "${account.caldavConfirmedPath}"');
      
      // Create a mutable copy of eventData to avoid read-only errors
      final mutableEventData = Map<String, dynamic>.from(eventData);
      
      final uid = mutableEventData['caldav_uid'] as String?;
      if (uid == null || uid.isEmpty) {
        // Generate new UID for new events
        final newUid = 'event-${DateTime.now().millisecondsSinceEpoch}@${account.username}';
        mutableEventData['caldav_uid'] = newUid;
        print('📝 Generated new UID for event: $newUid');
      }
      
      // Upload to server immediately
      await _uploadEventToServer(account, mutableEventData, mutableEventData['caldav_uid']);
      
      // Mark as synced in database
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'calendar_events',
        {
          'needs_sync': 0,
          'caldav_uid': mutableEventData['caldav_uid'],
          'modified': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [eventData['id']],
      );
      
      print('✅ IMMEDIATE UPLOAD: Event uploaded successfully!');
      return true;
    } catch (e) {
      print('❌ IMMEDIATE UPLOAD failed: $e');
      
      // Mark for background sync if immediate upload fails
      try {
        final db = await DatabaseHelper.instance.database;
        await db.update(
          'calendar_events',
          {'needs_sync': 1},
          where: 'id = ?',
          whereArgs: [eventData['id']],
        );
        print('📝 Marked event for background sync due to upload failure');
      } catch (dbError) {
        print('❌ Failed to mark event for sync: $dbError');
      }
      
      return false;
    }
  }
  
  /// Upload a single event to the CalDAV server
  Future<void> _uploadEventToServer(EmailAccount account, Map<String, dynamic> eventData, String uid) async {
    // Get calendar path - prefer confirmedPath if not empty, otherwise use caldavPath
    String? calendarPath = (account.caldavConfirmedPath != null && account.caldavConfirmedPath!.isNotEmpty) 
        ? account.caldavConfirmedPath 
        : account.caldavPath;
    
    print('🔍 [UPLOAD-DEBUG] Checking CalDAV paths:');
    print('   - caldavConfirmedPath: "${account.caldavConfirmedPath}"');
    print('   - caldavPath: "${account.caldavPath}"');
    print('   - Selected path: "$calendarPath"');
    
    if (calendarPath == null || calendarPath.isEmpty) {
      final errorMsg = '''
❌ CALENDAR UPLOAD FAILED: No CalDAV path configured!
   Account: ${account.username}
   caldavBaseUrl: ${account.caldavBaseUrl ?? 'NULL'}
   caldavPath: ${account.caldavPath ?? 'NULL'}
   caldavConfirmedPath: ${account.caldavConfirmedPath ?? 'NULL'}
   
   This means the calendar path discovery hasn't run or failed.
   Try syncing the calendar first to discover the correct path.
''';
      print(errorMsg);
      throw Exception('No CalDAV path configured');
    }
    
    // Generate iCalendar content
    final icalContent = _generateICalendarContent(eventData, uid);
    
    // Create PUT request to upload the event
    final url = '${account.caldavBaseUrl}$calendarPath$uid.ics';
    
    print('🌐 Uploading event to URL: $url');
    print('📝 Event UID: $uid');
    print('📄 iCal content length: ${icalContent.length} chars');
    print('📋 iCal content:');
    print(icalContent);
    print('🔑 [PUT-AUTH-DEBUG] Username: ${account.username}');
    print('🔑 [PUT-AUTH-DEBUG] Password length: ${account.password.length} chars');
    
    final authString = '${account.username}:${account.password}';
    final authBytes = authString.codeUnits;
    final authBase64 = base64Encode(authBytes);
    
    print('🔑 [PUT-AUTH-DEBUG] Authorization header: Basic ${authBase64.substring(0, min(20, authBase64.length))}...');
    
    // Create HTTP client that follows redirects
    final client = http.Client();

    // Build headers
    final headers = {
      'Authorization': 'Basic $authBase64',
      'Content-Type': 'text/calendar; charset=utf-8',
      'User-Agent': 'FMail/1.0',
    };

    // Add If-Match header with ETag if this is an update
    final etag = eventData['caldav_etag'] as String?;
    if (etag != null && etag.isNotEmpty) {
      headers['If-Match'] = etag;
      print('🏷️ [ETAG-DEBUG] Including If-Match header: $etag');
    } else {
      print('⚠️ [ETAG-DEBUG] No ETag found - this might be a new event');
    }

    try {
      var response = await client.put(
        Uri.parse(url),
        headers: headers,
        body: icalContent,
      );
      
      // Handle 302 redirect manually
      if (response.statusCode == 302 || response.statusCode == 301) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl != null) {
          print('🔄 Following redirect to: $redirectUrl');

          // Make absolute URL if redirect is relative
          final redirectUri = redirectUrl.startsWith('http')
              ? Uri.parse(redirectUrl)
              : Uri.parse('${account.caldavBaseUrl}$redirectUrl');

          response = await client.put(
            redirectUri,
            headers: headers, // Use same headers including If-Match
            body: icalContent,
          );
        }
      }
      
      print('📡 Upload response status: ${response.statusCode}');
      if (response.body.isNotEmpty) {
        print('📄 Upload response body: ${response.body.length > 200 ? response.body.substring(0, 200) + "..." : response.body}');
      }

      if (response.statusCode == 200 || response.statusCode == 201 || response.statusCode == 204) {
        print('✅ Event uploaded successfully to $url');
      } else if (response.statusCode == 412) {
        // 412 Precondition Failed - ETag mismatch
        print('⚠️ ETag mismatch (412) - event was modified on server');
        print('🔄 Retrying upload without If-Match header (force overwrite)');

        // Retry without If-Match header to force overwrite
        final headersWithoutEtag = {
          'Authorization': 'Basic $authBase64',
          'Content-Type': 'text/calendar; charset=utf-8',
          'User-Agent': 'FMail/1.0',
        };

        final retryResponse = await client.put(
          Uri.parse(url),
          headers: headersWithoutEtag,
          body: icalContent,
        );

        print('📡 Retry upload response status: ${retryResponse.statusCode}');

        if (retryResponse.statusCode == 200 || retryResponse.statusCode == 201 || retryResponse.statusCode == 204) {
          print('✅ Event uploaded successfully on retry (force overwrite)');
        } else {
          throw Exception('Retry upload failed with status ${retryResponse.statusCode}: ${retryResponse.body}');
        }
      } else {
        throw Exception('Upload failed with status ${response.statusCode}: ${response.body}');
      }
    } finally {
      client.close();
    }
  }
  
  /// Generate iCalendar content for an event
  String _generateICalendarContent(Map<String, dynamic> eventData, String uid) {
    final startDateTime = DateTime.fromMillisecondsSinceEpoch(eventData['startDateTime'] as int);
    final endDateTime = DateTime.fromMillisecondsSinceEpoch(eventData['endDateTime'] as int);
    final isAllDay = (eventData['isAllDay'] as int) == 1;
    
    final dtStart = isAllDay 
        ? 'DTSTART;VALUE=DATE:${DateFormat('yyyyMMdd').format(startDateTime)}'
        : 'DTSTART:${DateFormat('yyyyMMddTHHmmss').format(startDateTime.toUtc())}Z';
    
    final dtEnd = isAllDay 
        ? 'DTEND;VALUE=DATE:${DateFormat('yyyyMMdd').format(endDateTime)}'
        : 'DTEND:${DateFormat('yyyyMMddTHHmmss').format(endDateTime.toUtc())}Z';
    
    final now = DateFormat('yyyyMMddTHHmmss').format(DateTime.now().toUtc());
    
    final category = eventData['category'] as String? ?? '';
    final categoryLine = category.isNotEmpty ? 'CATEGORIES:$category\n' : '';
    
    return '''BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//FMail//FMail Calendar//EN
BEGIN:VEVENT
UID:$uid
DTSTAMP:${now}Z
CREATED:${now}Z
LAST-MODIFIED:${now}Z
$dtStart
$dtEnd
SUMMARY:${eventData['title']}
DESCRIPTION:${(eventData['description'] as String? ?? '').replaceAll('\n', '\\n')}
LOCATION:${eventData['location'] ?? ''}
${categoryLine}END:VEVENT
END:VCALENDAR''';
  }

  Future<void> _syncFromCalDAV({bool forceSync = false}) async {
    print('🚀 Starting bidirectional CalDAV sync... (forced: $forceSync)');
    final syncStartTime = DateTime.now();
    
    try {
      // Step 1: Upload local changes first
      print('📤 Phase 1: Uploading local changes...');
      await _uploadLocalChanges();
      
      // Step 2: Download server changes
      print('📥 Phase 2: Downloading server changes...');
      
      final accounts = await DatabaseHelper.instance.getAccounts();
      
      if (accounts.isEmpty) {
        print('❌ No accounts found to sync');
        return;
      }
      
      print('� Syncing ${accounts.length} accounts...');
      int successCount = 0;
      
      for (final account in accounts) {
        try {
          print('📧 Syncing account: ${account.username}');

          // Check if account has CalDAV configured
          if (account.caldavBaseUrl == null || account.caldavBaseUrl!.isEmpty) {
            print('⚠️ No CalDAV base URL for ${account.username}, skipping');
            continue;
          }

          // Check if account has password (required for CalDAV auth)
          if (account.password.isEmpty) {
            print('⚠️ No password configured for ${account.username}, skipping CalDAV sync');
            continue;
          }

          // Use confirmed path or configured path
          String? calendarPath = account.caldavConfirmedPath;
          if (calendarPath == null || calendarPath.isEmpty || calendarPath == "null") {
            calendarPath = account.caldavPath;
          }

          if (calendarPath == null || calendarPath.isEmpty) {
            print('⚠️ No CalDAV path for ${account.username}, skipping');
            continue;
          }
          
          // Ensure path starts with / if it's a relative path
          if (!calendarPath.startsWith('/') && !calendarPath.startsWith('http')) {
            calendarPath = '/$calendarPath';
          }
          
          print('🔧 Using calendar path: $calendarPath');
          
          // Create CalDAV client
          final client = await _createCalDAVClient(account);
          if (client == null) {
            print('❌ Failed to create CalDAV client for ${account.username}');
            continue;
          }
          
          // Get events from the last 30 days and next 365 days
          final startDate = DateTime.now().subtract(const Duration(days: 30));
          final endDate = DateTime.now().add(const Duration(days: 365));
          
          print('� Fetching events for ${account.username} from $calendarPath');
          
          // Try direct HTTP REPORT request first (exactly like Python script)
          try {
            print('🔍 Trying direct HTTP REPORT (like Python script)...');
            
            final httpResponse = await _makeDirectCalDAVRequest(account, calendarPath, startDate, endDate);
            
            print('📡 Direct HTTP REPORT status: ${httpResponse.statusCode}');
            
            if (httpResponse.statusCode == 207) {
              print('✅ Direct HTTP REPORT successful!');
              print('📄 Response length: ${httpResponse.body.length} chars');
              print('🔍 DEBUG: First 500 chars of response:');
              print(httpResponse.body.substring(0, httpResponse.body.length > 500 ? 500 : httpResponse.body.length));
              
              // Process the response with ETag support
              final eventsWithETags = _extractEventsWithETags(httpResponse.body);
              print('🎯 Found ${eventsWithETags.length} events with ETags via HTTP');
              
              if (eventsWithETags.isNotEmpty) {
                final db = await DatabaseHelper.instance.database;
                int processed = 0;
                for (final eventWithETag in eventsWithETags) {
                  try {
                    // 🚀 USE SIMPLIFIED PROCESSING with timestamp logic
                    final result = await _processCalDAVEventSimplified(db, account, eventWithETag);
                    if (result == 'imported' || result == 'updated') {
                      processed++;
                    }
                  } catch (e) {
                    print('❌ Error processing event: $e');
                  }
                }
                
                print('✅ SIMPLIFIED SYNC processed $processed events for ${account.username}');
                
                // Save the path as confirmed since it works
                if (account.caldavConfirmedPath != calendarPath) {
                  await _saveConfirmedCalDAVPath(account, calendarPath);
                }
                
                successCount++;
                continue; // Skip caldav_client methods since HTTP worked
              }
            } else {
              print('❌ Direct HTTP REPORT failed with status: ${httpResponse.statusCode}');
              if (httpResponse.body.isNotEmpty) {
                print('❌ HTTP Error response: ${httpResponse.body.length > 300 ? httpResponse.body.substring(0, 300) + "..." : httpResponse.body}');
              }
              throw Exception('HTTP REPORT failed with status ${httpResponse.statusCode}');
            }
          } catch (e) {
            print('❌ Direct HTTP REPORT failed: $e');
            print('🔄 Falling back to caldav_client methods...');
          }
          
          // If HTTP method failed, try CalDAV client methods
          dynamic response;
          try {
            print('🔍 Trying caldav_client REPORT request...');
            
            final startDateStr = DateFormat('yyyyMMddTHHmmssZ').format(startDate.toUtc());
            final endDateStr = DateFormat('yyyyMMddTHHmmssZ').format(endDate.toUtc());
            
            final reportBody = '''<?xml version="1.0" encoding="utf-8" ?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:getetag />
    <c:calendar-data />
  </d:prop>
  <c:filter>
    <c:comp-filter name="VCALENDAR">
      <c:comp-filter name="VEVENT">
        <c:time-range start="$startDateStr" end="$endDateStr"/>
      </c:comp-filter>
    </c:comp-filter>
  </c:filter>
</c:calendar-query>''';
            
            response = await client.report(calendarPath, reportBody).timeout(
              const Duration(seconds: 30),
            );
            
            print('📡 caldav_client REPORT status: ${response.statusCode}');
            
            if (response.statusCode != 207) {
              throw Exception('caldav_client REPORT failed with status ${response.statusCode}');
            }
          } catch (e) {
            print('❌ caldav_client REPORT failed: $e, trying getObjectsInTimeRange...');
            
            response = await client.getObjectsInTimeRange(calendarPath, startDate, endDate).timeout(
              const Duration(seconds: 30),
              onTimeout: () {
                print('⏰ CalDAV request timed out for ${account.username}');
                throw Exception('CalDAV request timeout');
              },
            );
          }
          
          print('📡 Response status for ${account.username}: ${response.statusCode}');
          
          if (response.statusCode == 207) {
            print('✅ CalDAV request successful for ${account.username}');
            
            // Process the response
            final db = await DatabaseHelper.instance.database;
            await _processCalDAVResponse(db, account, response);
            
            // Save the path as confirmed since it works
            if (account.caldavConfirmedPath != calendarPath) {
              await _saveConfirmedCalDAVPath(account, calendarPath);
            }
            
            successCount++;
          } else {
            print('❌ CalDAV request failed for ${account.username} with status: ${response.statusCode}');
            
            // Log detailed error information
            if (response.document != null) {
              final errorBody = response.document!.toXmlString();
              print('❌ Error response body: ${errorBody.length > 500 ? errorBody.substring(0, 500) + "..." : errorBody}');
            }
            
            // Handle specific error codes
            if (response.statusCode == 400) {
              print('🔍 HTTP 400 - Bad Request. This usually means:');
              print('   - Invalid calendar path format');
              print('   - Malformed date range in request');
              print('   - Server doesn\'t support the request format');
              print('🔧 Trying alternative calendar path discovery...');
              
              // Try to discover the correct path
              try {
                print('🔍 Attempting alternative Nextcloud path formats...');
                
                // Extract username for Nextcloud paths
                final username = account.username.split('@').first;
                
                // Try common Nextcloud calendar path variations
                final alternativePaths = [
                  '/remote.php/dav/calendars/$username/personal/',
                  '/remote.php/dav/calendars/$username/',
                  '/apps/nextcloud/remote.php/dav/calendars/$username/personal/',
                  '/nextcloud/remote.php/dav/calendars/$username/personal/',
                ];
                
                for (final altPath in alternativePaths) {
                  print('🔍 Trying alternative path: $altPath');
                  try {
                    final testResponse = await client.getObjectsInTimeRange(altPath, startDate, endDate).timeout(
                      const Duration(seconds: 15),
                    );
                    
                    if (testResponse.statusCode == 207) {
                      print('✅ Alternative path works: $altPath');
                      await _saveConfirmedCalDAVPath(account, altPath);
                      
                      // Process this successful response
                      final db = await DatabaseHelper.instance.database;
                      await _processCalDAVResponse(db, account, testResponse);
                      successCount++;
                      break; // Found working path, stop trying
                    } else {
                      print('❌ Alternative path failed: $altPath (status: ${testResponse.statusCode})');
                    }
                  } catch (e) {
                    print('❌ Alternative path error: $altPath - $e');
                  }
                }
                
                // Also try generic discovery
                final calendarPaths = await _discoverCalendarPaths(client, account);
                if (calendarPaths.isNotEmpty) {
                  print('🎯 Found alternative paths via discovery: $calendarPaths');
                  // Save the first working path
                  await _saveConfirmedCalDAVPath(account, calendarPaths.first);
                  print('💾 Saved new confirmed path: ${calendarPaths.first}');
                }
              } catch (e) {
                print('❌ Path discovery also failed: $e');
              }
            } else if (response.statusCode == 404) {
              print('🔍 HTTP 404 - Calendar path not found');
              if (account.caldavConfirmedPath == calendarPath) {
                // Clear invalid confirmed path
                await _clearConfirmedCalDAVPath(account);
                print('🧹 Cleared invalid confirmed path');
              }
            } else if (response.statusCode == 401) {
              print('🔍 HTTP 401 - Authentication failed');
              print('   - Check username/password for ${account.username}');
            } else if (response.statusCode == 403) {
              print('🔍 HTTP 403 - Access denied to calendar');
            }
          }
        } catch (e) {
          print('❌ Failed to sync account ${account.username}: $e');
          // Continue with next account
        }
      }
      
      final totalDuration = DateTime.now().difference(syncStartTime);
      print('🎉 CalDAV sync completed in ${totalDuration.inSeconds} seconds ($successCount/${accounts.length} accounts synced)');
    } catch (e) {
      final totalDuration = DateTime.now().difference(syncStartTime);
      print('❌ CalDAV sync failed after ${totalDuration.inSeconds} seconds: $e');
      rethrow;
    }
  }

  Future<List<String>> _discoverCalendarPaths(CalDavClient client, EmailAccount account) async {
    final List<String> calendarPaths = [];
    
    // Debug: Show all available paths for this account
    print('🔍 DEBUG: CalDAV paths for ${account.username}:');
    print('  - caldavConfirmedPath: "${account.caldavConfirmedPath}" (null: ${account.caldavConfirmedPath == null}, empty: ${account.caldavConfirmedPath?.isEmpty ?? true})');
    print('  - caldavPath: "${account.caldavPath}" (null: ${account.caldavPath == null}, empty: ${account.caldavPath?.isEmpty ?? true})');
    print('  - caldavBaseUrl: "${account.caldavBaseUrl}" (null: ${account.caldavBaseUrl == null}, empty: ${account.caldavBaseUrl?.isEmpty ?? true})');
    
    // First priority: try the confirmed CalDAV path if available
    // Check for actual non-null, non-empty string (not "null" string)
    if (account.caldavConfirmedPath != null && 
        account.caldavConfirmedPath!.isNotEmpty && 
        account.caldavConfirmedPath != "null" &&
        account.caldavConfirmedPath != "NULL") {
      try {
        print('✨ USING CONFIRMED PATH: ${account.caldavConfirmedPath}');
        final response = await client.initialSync(account.caldavConfirmedPath!).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            print('⏰ Confirmed path check timed out: ${account.caldavConfirmedPath}');
            throw Exception('Confirmed path timeout');
          },
        );
        
        print('📡 Confirmed path response status: ${response.statusCode}');
        if (response.statusCode == 207) {
          calendarPaths.add(account.caldavConfirmedPath!);
          print('✅ Confirmed calendar path working: ${account.caldavConfirmedPath}');
          return calendarPaths; // Use confirmed path exclusively - no discovery needed
        } else {
          print('⚠️ Confirmed path ${account.caldavConfirmedPath} returned status: ${response.statusCode}');
          // Clear the invalid confirmed path
          await _clearConfirmedCalDAVPath(account);
        }
      } catch (e) {
        print('❌ Confirmed path ${account.caldavConfirmedPath} failed: $e');
        // Clear the invalid confirmed path
        await _clearConfirmedCalDAVPath(account);
      }
    } else {
      print('⭕ Skipping confirmed path - null, empty, or string "null"');
      // Clear invalid "null" string values
      if (account.caldavConfirmedPath == "null" || account.caldavConfirmedPath == "NULL") {
        print('🧹 Clearing invalid "null" string from confirmed path');
        await _clearConfirmedCalDAVPath(account);
      }
    }
    
    // Second priority: try the configured CalDAV path if available (for manual config)
    if (account.caldavPath != null && account.caldavPath!.isNotEmpty) {
      try {
        print('🔧 Trying configured CalDAV path: ${account.caldavPath}');
        final response = await client.initialSync(account.caldavPath!).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            print('⏰ Configured path check timed out: ${account.caldavPath}');
            throw Exception('Configured path timeout');
          },
        );
        
        print('📡 Configured path response status: ${response.statusCode}');
        if (response.statusCode == 207) {
          calendarPaths.add(account.caldavPath!);
          print('✅ Found calendar at configured path: ${account.caldavPath}');
          // Save this as the confirmed path for future use
          await _saveConfirmedCalDAVPath(account, account.caldavPath!);
          print('💾 Saved configured path as confirmed: ${account.caldavPath}');
          return calendarPaths; // Use configured path exclusively if it works
        } else if (response.statusCode == 302) {
          print('🔄 Configured path returned redirect (302) - server wants different path');
        } else {
          print('❌ Configured path ${account.caldavPath} returned status: ${response.statusCode}');
        }
      } catch (e) {
        print('❌ Configured path ${account.caldavPath} failed: $e');
      }
    }
    
    // Extract username from email for NextCloud paths
    final username = account.username.split('@').first;
    final domain = account.username.split('@').last;
    
    // Fallback: Common calendar paths to try
    final pathsToTry = [
      // NextCloud paths (based on your example)
      '/remote.php/dav/calendars/$username/personal/',
      '/remote.php/dav/calendars/$username/personal',
      '/$domain/apps/nextcloud/remote.php/dav/calendars/$username/personal/',
      '/apps/nextcloud/remote.php/dav/calendars/$username/personal/',
      '/nextcloud/remote.php/dav/calendars/$username/personal/',
      '/remote.php/dav/calendars/$username/',
      '/remote.php/dav/calendars/$username',
      '/nextcloud/remote.php/dav/calendars/$username/',
      '/apps/nextcloud/remote.php/dav/calendars/$username/',
      '/$domain/apps/nextcloud/remote.php/dav/calendars/$username/',
      
      // Standard CalDAV paths
      '/caldav/v2/calendars/primary',
      '/caldav/calendars/${account.username}',
      '/calendars/${account.username}',
      '/calendar',
      '/caldav',
      '/dav/calendars/${account.username}',
      '/remote.php/dav/calendars/${account.username}',
    ];
    
    // Try all paths in parallel for faster discovery (with 5-second timeout per path)
    print('🚀 Trying ${pathsToTry.length} calendar paths in parallel...');

    final futures = pathsToTry.map((path) async {
      try {
        final response = await client.initialSync(path).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw Exception('Path check timeout');
          },
        );

        if (response.statusCode == 207) {
          print('✅ Found calendar at: $path');
          return path;
        } else if (response.statusCode == 302) {
          print('🔄 Path $path returned redirect (302)');
        } else {
          print('❌ Path $path returned status: ${response.statusCode}');
        }
        return null;
      } catch (e) {
        // Path doesn't exist or timed out
        return null;
      }
    }).toList();

    // Wait for all parallel requests to complete
    final results = await Future.wait(futures);

    // Find the first working path (maintains priority order from pathsToTry list)
    for (int i = 0; i < results.length; i++) {
      if (results[i] != null) {
        final workingPath = results[i]!;
        calendarPaths.add(workingPath);
        // Save the first working path as confirmed for future use
        await _saveConfirmedCalDAVPath(account, workingPath);
        print('💾 Saved confirmed CalDAV path: $workingPath');
        break; // Stop after finding the first (highest priority) working path
      }
    }
    
    // If no specific paths found, try to discover via PROPFIND on root
    if (calendarPaths.isEmpty) {
      try {
        print('Attempting calendar discovery via PROPFIND on root paths...');
        await _discoverCalendarsViaPropfind(client, account, calendarPaths);
      } catch (e) {
        print('PROPFIND discovery failed: $e');
      }
    }
    
    return calendarPaths;
  }

  /// Save the confirmed CalDAV path to the database for this account
  Future<void> _saveConfirmedCalDAVPath(EmailAccount account, String confirmedPath) async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'accounts',
        {'caldav_confirmed_path': confirmedPath},
        where: 'username = ?',
        whereArgs: [account.username],
      );
      print('DEBUG: Saved caldav_confirmed_path for ${account.username}: $confirmedPath');
      
      // Note: Account data will be refreshed on next sync
    } catch (e) {
      print('ERROR: Failed to save confirmed CalDAV path: $e');
    }
  }

  /// Clear the confirmed CalDAV path for this account (when it becomes invalid)
  Future<void> _clearConfirmedCalDAVPath(EmailAccount account) async {
    try {
      final db = await DatabaseHelper.instance.database;
      await db.update(
        'accounts',
        {'caldav_confirmed_path': null},
        where: 'username = ?',
        whereArgs: [account.username],
      );
      print('DEBUG: Cleared invalid caldav_confirmed_path for ${account.username}');
    } catch (e) {
      print('ERROR: Failed to clear confirmed CalDAV path: $e');
    }
  }


  Future<void> _discoverCalendarsViaPropfind(CalDavClient client, EmailAccount account, List<String> calendarPaths) async {
    final username = account.username.split('@').first;
    
    // Try PROPFIND on potential parent directories
    final parentPaths = [
      '/remote.php/dav/calendars/$username/',
      '/remote.php/dav/calendars/',
      '/apps/nextcloud/remote.php/dav/calendars/$username/',
      '/dav/calendars/$username/',
      '/caldav/',
    ];
    
    for (final parentPath in parentPaths) {
      try {
        print('🔍 PROPFIND on parent path: $parentPath');
        
        final body = '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop>
    <d:resourcetype />
    <d:displayname />
    <cs:getctag />
    <c:supported-calendar-component-set />
  </d:prop>
</d:propfind>''';
        
        final response = await client.propfind(parentPath, body, depth: 1).timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            print('⏰ PROPFIND timed out on: $parentPath');
            throw Exception('PROPFIND timeout');
          },
        );
        
        if (response.statusCode == 207) {
          print('✅ PROPFIND successful on $parentPath, parsing response...');
          String responseBody = '';
          if (response.document != null) {
            responseBody = response.document!.toXmlString();
          }
          
          // Parse the response to find calendar collections
          final foundCalendars = _parseCalendarCollections(responseBody, parentPath);
          calendarPaths.addAll(foundCalendars);
          
          if (foundCalendars.isNotEmpty) {
            print('🎯 Found ${foundCalendars.length} calendars via PROPFIND: $foundCalendars');
            // Save the first discovered path as confirmed
            await _saveConfirmedCalDAVPath(account, foundCalendars.first);
            print('💾 Saved confirmed CalDAV path from PROPFIND: ${foundCalendars.first}');
            break; // Found calendars, no need to continue
          }
        } else {
          print('❌ PROPFIND failed on $parentPath with status: ${response.statusCode}');
        }
      } catch (e) {
        print('❌ PROPFIND failed on $parentPath: $e');
        continue;
      }
    }
  }

  List<String> _parseCalendarCollections(String responseBody, String parentPath) {
    final calendars = <String>[];
    
    try {
      // Look for calendar collections in the XML response
      // This is a simplified parser - in production you'd want proper XML parsing
      final lines = responseBody.split('\n');
      String? currentHref;
      bool isCalendarCollection = false;
      
      for (final line in lines) {
        final trimmedLine = line.trim();
        
        if (trimmedLine.startsWith('<d:href>') && trimmedLine.endsWith('</d:href>')) {
          currentHref = trimmedLine
              .replaceAll('<d:href>', '')
              .replaceAll('</d:href>', '')
              .trim();
        } else if (trimmedLine.contains('<c:calendar') || 
                   trimmedLine.contains('calendar')) {
          isCalendarCollection = true;
        } else if (trimmedLine.startsWith('</d:response>') && 
                   currentHref != null && 
                   isCalendarCollection) {
          // Found a calendar collection
          if (!currentHref.endsWith('/')) {
            currentHref += '/';
          }
          calendars.add(currentHref);
          print('Found calendar collection: $currentHref');
          
          // Reset for next iteration
          currentHref = null;
          isCalendarCollection = false;
        }
      }
    } catch (e) {
      print('Error parsing calendar collections: $e');
    }
    
    return calendars;
  }

  Future<void> _processCalDAVResponse(dynamic db, EmailAccount account, dynamic response) async {
    try {
      // Parse the CalDAV response to extract events
      print('📥 Processing CalDAV response for ${account.username}');
      
      // Get XML content from document
      String responseBody = '';
      if (response.document != null) {
        responseBody = response.document!.toXmlString();
        print('📄 Response body length: ${responseBody.length} characters');
      } else {
        print('❌ No XML document in response');
        return;
      }
      
      // Look for VEVENT blocks with ETags in the response
      final eventsWithETags = _extractEventsWithETags(responseBody);
      print('🎯 Found ${eventsWithETags.length} events with ETags in CalDAV response');
      
      int importedCount = 0;
      int updatedCount = 0;
      
      for (final eventWithETag in eventsWithETags) {
        final result = await _processCalDAVEvent(db, account, eventWithETag);
        if (result == 'imported') importedCount++;
        else if (result == 'updated') updatedCount++;
      }
      
      print('✅ CalDAV sync completed for ${account.username}: $importedCount imported, $updatedCount updated');
    } catch (e) {
      print('❌ Error processing CalDAV response: $e');
    }
  }

  /// Extract events with their ETags and hrefs from CalDAV REPORT response
  List<Map<String, String>> _extractEventsWithETags(String responseBody) {
    final eventsWithMetadata = <Map<String, String>>[];
    print('🔍 DEBUG: Extracting events with metadata from CalDAV response...');

    // Count response blocks in the XML
    final responseCount = '<d:response>'.allMatches(responseBody).length;
    print('📊 DEBUG: Server XML contains $responseCount <d:response> blocks');

    // If there are multiple events, log the full response for debugging
    if (responseCount > 1) {
      print('📄 MULTI-EVENT DEBUG: Full server response:');
      print(responseBody.length > 5000 ? responseBody.substring(0, 5000) + '...[truncated]' : responseBody);
    }

    // Parse the multistatus XML response properly
    // Expected structure:
    // <d:multistatus>
    //   <d:response>
    //     <d:href>/path/to/event.ics</d:href>
    //     <d:propstat>
    //       <d:prop>
    //         <d:getetag>"etag-value"</d:getetag>
    //         <cal:calendar-data>BEGIN:VCALENDAR...</cal:calendar-data>
    //       </d:prop>
    //     </d:propstat>
    //   </d:response>
    // </d:multistatus>

    final lines = responseBody.split('\n');
    Map<String, String>? currentEvent;
    bool inResponse = false;
    bool inCalendarData = false;
    bool justStartedCalendarData = false; // Track if we just initialized buffer on this line
    String calendarDataBuffer = '';
    
    int lineNum = 0;
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      lineNum++;
      justStartedCalendarData = false; // Reset at start of each line
      
      // Debug first 20 lines
      if (lineNum <= 20) {
        print('🔍 Line $lineNum: $line');
      }
      
      // Start of a response block
      if (line.contains('<d:response>') && !line.contains('</d:response>')) {
        inResponse = true;
        currentEvent = {};
        print('📦 Found new response block at line $lineNum');
      }
      
      // Accumulate calendar data content - MUST BE FIRST!
      // (Process any pending calendar data from previous event before starting new event)
      // Skip if we just initialized the buffer on this same line
      if (inCalendarData && !justStartedCalendarData) {
        if (line.contains('</cal:calendar-data>') || line.contains('</c:calendar-data>')) {
          // Closing tag found - extract any remaining data before the tag
          print('🔍 DEBUG: Closing calendar data tag found on line $lineNum');
          print('🔍 DEBUG: inCalendarData=$inCalendarData, buffer length=${calendarDataBuffer.length}');
          
          final beforeClose = line.split('</cal:calendar-data>')[0].split('</c:calendar-data>')[0];
          if (beforeClose.isNotEmpty && beforeClose.trim().isNotEmpty) {
            calendarDataBuffer += beforeClose + '\n';
            print('🔍 DEBUG: Added ${beforeClose.length} chars before close tag');
          }
          
          if (currentEvent != null) {
            currentEvent['calendar_data'] = calendarDataBuffer.trim();
            print('📅 Found multi-line calendar data (${currentEvent['calendar_data']!.length} chars)');
          }
          inCalendarData = false;
        } else {
          // Normal line - accumulate it
          calendarDataBuffer += line + '\n';
          if (lineNum <= 20) {
            print('🔍 DEBUG: Accumulating calendar data, buffer now ${calendarDataBuffer.length} chars');
          }
        }
      }
      
      // Extract href (ICS file path) - runs AFTER calendar data processing
      if (inResponse && line.contains('<d:href>')) {
        final hrefMatch = RegExp(r'<d:href[^>]*>(.*?)</d:href>').firstMatch(line);
        if (hrefMatch != null && currentEvent != null) {
          currentEvent['href'] = hrefMatch.group(1)!.trim();
          print('🔗 Found href: ${currentEvent['href']}');
        } else {
          print('⚠️ href line matched but regex failed: $line');
        }
        
        // Also try to extract etag and calendar data from the same line
        // (XML might be all on one line)
        if (line.contains('<d:getetag>')) {
          final etagMatch = RegExp(r'<d:getetag[^>]*>(.*?)</d:getetag>').firstMatch(line);
          if (etagMatch != null && currentEvent != null) {
            final etag = etagMatch.group(1)!.replaceAll('"', '').replaceAll('&quot;', '').trim();
            currentEvent['etag'] = etag;
            print('🏷️ Found ETag (same line): $etag');
          }
        }
        
        if (line.contains('<cal:calendar-data>')) {
          final calMatch = RegExp(r'<cal:calendar-data[^>]*>(.*?)$').firstMatch(line);
          if (calMatch != null && currentEvent != null) {
            // Multi-line calendar data starts here
            inCalendarData = true;
            calendarDataBuffer = calMatch.group(1)! + '\n';
            justStartedCalendarData = true; // Don't accumulate this line again
            print('📅 Starting calendar data extraction from href line (${calendarDataBuffer.length} chars)');
          }
        }
      }
      
      // End of response block - save the event if complete
      if (line.contains('</d:response>') && inResponse) {
        if (currentEvent != null) {
          print('🔍 Event data check: href=${currentEvent.containsKey('href')}, etag=${currentEvent.containsKey('etag')}, calendar_data=${currentEvent.containsKey('calendar_data')}');
          
          if (currentEvent.containsKey('href') && 
              currentEvent.containsKey('etag') && 
              currentEvent.containsKey('calendar_data')) {
            
            // Extract UID from href (filename without .ics)
            final href = currentEvent['href']!;
            final fileName = href.split('/').last;
            final uid = fileName.endsWith('.ics') ? fileName.substring(0, fileName.length - 4) : fileName;
            currentEvent['uid'] = uid;
            
            eventsWithMetadata.add(currentEvent);
            print('✅ Added event: UID=$uid, ETag=${currentEvent['etag']}, href=$href');
          } else {
            print('⚠️ Incomplete event data found:');
            print('   - href: ${currentEvent['href'] ?? 'MISSING'}');
            print('   - etag: ${currentEvent['etag'] ?? 'MISSING'}');
            print('   - calendar_data: ${currentEvent.containsKey('calendar_data') ? 'present (${currentEvent['calendar_data']!.length} chars)' : 'MISSING'}');
          }
        }
        
        inResponse = false;
        currentEvent = null;
      }
      
      // Extract ETag
      if (inResponse && (line.contains('<d:getetag>') || line.contains('<getetag>'))) {
        final etagMatch = RegExp(r'<(?:d:)?getetag[^>]*>(.*?)</(?:d:)?getetag>').firstMatch(line);
        if (etagMatch != null && currentEvent != null) {
          final etag = etagMatch.group(1)!.replaceAll('"', '').trim();
          currentEvent['etag'] = etag;
          print('🏷️ Found ETag: $etag');
        }
      }
      
      // Start of calendar data - MUST BE AFTER accumulation check!
      // (Check for new calendar-data only after we've finished accumulating the previous one)
      if (!inCalendarData && inResponse && (line.contains('<c:calendar-data>') || line.contains('<cal:calendar-data>'))) {
        print('🔍 DEBUG: Found calendar-data start tag at line $lineNum');
        inCalendarData = true;
        calendarDataBuffer = '';
        justStartedCalendarData = true; // Don't accumulate this line
        
        // Check if calendar data is on the same line (complete)
        final dataMatch = RegExp(r'<(?:c:|cal:)?calendar-data[^>]*>(.*?)</(?:c:|cal:)?calendar-data>').firstMatch(line);
        if (dataMatch != null) {
          // Single line calendar data (complete on one line)
          if (currentEvent != null) {
            currentEvent['calendar_data'] = dataMatch.group(1)!.trim();
            print('📅 Found single-line calendar data (${currentEvent['calendar_data']!.length} chars)');
          }
          inCalendarData = false;
        } else {
          // Multi-line calendar data - extract any data after the opening tag on this line
          final afterOpenTag = line.split(RegExp(r'<(?:c:|cal:)?calendar-data[^>]*>')).last;
          if (afterOpenTag.isNotEmpty && afterOpenTag.trim().isNotEmpty) {
            calendarDataBuffer = afterOpenTag + '\n';
            print('🔍 DEBUG: Multi-line calendar data starting, buffer initialized with ${calendarDataBuffer.length} chars from line $lineNum');
          } else {
            print('🔍 DEBUG: Multi-line calendar data starting, inCalendarData=$inCalendarData');
          }
        }
      }
      
      // Handle CDATA sections
      if (inResponse && line.contains('<![CDATA[')) {
        final cdataStart = line.indexOf('<![CDATA[');

        final cdataEnd = line.indexOf(']]>');
        
        if (cdataEnd != -1) {
          // Single line CDATA
          if (currentEvent != null) {
            currentEvent['calendar_data'] = line.substring(cdataStart + 9, cdataEnd).trim();
            print('📅 Found CDATA calendar data (${currentEvent['calendar_data']!.length} chars)');
          }
        } else {
          // Multi-line CDATA
          calendarDataBuffer = line.substring(cdataStart + 9) + '\n';
          for (int j = i + 1; j < lines.length; j++) {
            if (lines[j].contains(']]>')) {
              final endIndex = lines[j].indexOf(']]>');
              calendarDataBuffer += lines[j].substring(0, endIndex);
              if (currentEvent != null) {
                currentEvent['calendar_data'] = calendarDataBuffer.trim();
                print('📅 Found multi-line CDATA calendar data (${currentEvent['calendar_data']!.length} chars)');
              }
              i = j; // Skip to end of CDATA
              break;
            } else {
              calendarDataBuffer += lines[j] + '\n';
            }
          }
        }
      }
    }
    
    print('🎯 Total events with complete metadata extracted: ${eventsWithMetadata.length}');

    // FALLBACK: If line-by-line parsing found fewer events than expected, try regex-based extraction
    if (eventsWithMetadata.length < responseCount && responseCount > 0) {
      print('⚠️ Line-by-line parsing found ${eventsWithMetadata.length} events but expected $responseCount');
      print('🔄 Attempting regex-based fallback extraction...');

      final fallbackEvents = _extractEventsWithETagsRegex(responseBody);
      if (fallbackEvents.length > eventsWithMetadata.length) {
        print('✅ Regex fallback found ${fallbackEvents.length} events - using these instead');
        return fallbackEvents;
      }
    }

    return eventsWithMetadata;
  }

  /// Fallback regex-based extraction for CalDAV responses
  List<Map<String, String>> _extractEventsWithETagsRegex(String responseBody) {
    final eventsWithMetadata = <Map<String, String>>[];

    // Match each <d:response>...</d:response> block
    final responseRegex = RegExp(r'<d:response[^>]*>(.*?)</d:response>', multiLine: true, dotAll: true);
    final responseMatches = responseRegex.allMatches(responseBody);

    print('🔍 Regex fallback found ${responseMatches.length} response blocks');

    for (final match in responseMatches) {
      final responseBlock = match.group(1) ?? '';

      // Extract href
      final hrefMatch = RegExp(r'<d:href[^>]*>(.*?)</d:href>').firstMatch(responseBlock);
      final href = hrefMatch?.group(1)?.trim();

      // Extract etag (handle various formats)
      final etagMatch = RegExp(r'<(?:d:)?getetag[^>]*>(.*?)</(?:d:)?getetag>').firstMatch(responseBlock);
      String? etag = etagMatch?.group(1)?.replaceAll('"', '').replaceAll('&quot;', '').trim();

      // Extract calendar-data (handle various namespace prefixes and CDATA)
      String? calendarData;
      final calDataMatch = RegExp(r'<(?:c:|cal:)?calendar-data[^>]*>(.*?)</(?:c:|cal:)?calendar-data>', dotAll: true).firstMatch(responseBlock);
      if (calDataMatch != null) {
        calendarData = calDataMatch.group(1)?.trim();
        // Handle CDATA
        if (calendarData != null && calendarData.contains('<![CDATA[')) {
          final cdataMatch = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true).firstMatch(calendarData);
          if (cdataMatch != null) {
            calendarData = cdataMatch.group(1)?.trim();
          }
        }
      }

      if (href != null && etag != null && calendarData != null && calendarData.isNotEmpty) {
        final fileName = href.split('/').last;
        final uid = fileName.endsWith('.ics') ? fileName.substring(0, fileName.length - 4) : fileName;

        eventsWithMetadata.add({
          'href': href,
          'etag': etag,
          'calendar_data': calendarData,
          'uid': uid,
        });
        print('✅ Regex extracted event: UID=$uid, href=$href');
      } else {
        print('⚠️ Regex could not extract complete event:');
        print('   href: ${href ?? 'MISSING'}');
        print('   etag: ${etag ?? 'MISSING'}');
        print('   calendar_data: ${calendarData != null ? '${calendarData.length} chars' : 'MISSING'}');
      }
    }

    return eventsWithMetadata;
  }

  Future<String> _processCalDAVEvent(dynamic db, EmailAccount account, Map<String, String> eventMetadata) async {
    try {
      final uid = eventMetadata['uid']!;
      final etag = eventMetadata['etag']!;
      final href = eventMetadata['href']!;
      final rawCalendarData = eventMetadata['calendar_data']!;
      
      print('📝 Processing CalDAV event: UID=$uid, ETag=$etag');
      print('📄 Raw calendar data preview: ${rawCalendarData.substring(0, rawCalendarData.length > 200 ? 200 : rawCalendarData.length)}...');
      
      // Parse the calendar data for display fields
      final lines = rawCalendarData.split('\n');
      String summary = '';
      String description = '';
      String location = '';
      String category = '';
      DateTime? dtStart;
      DateTime? dtEnd;
      bool isAllDay = false;
      
      for (final line in lines) {
        final trimmedLine = line.trim();
        if (trimmedLine.startsWith('SUMMARY:')) {
          summary = trimmedLine.substring(8).trim();
          print('📌 Found summary: $summary');
        } else if (trimmedLine.startsWith('DESCRIPTION:')) {
          description = trimmedLine.substring(12).replaceAll('\\n', '\n').trim();
        } else if (trimmedLine.startsWith('LOCATION:')) {
          location = trimmedLine.substring(9).trim();
        } else if (trimmedLine.startsWith('CATEGORIES:')) {
          category = trimmedLine.substring(11).split(',').first.trim();
        } else if (trimmedLine.startsWith('DTSTART')) {
          dtStart = _parseDateTime(trimmedLine);
          isAllDay = trimmedLine.contains('VALUE=DATE');
          print('📅 Found start date: $dtStart (all day: $isAllDay)');
        } else if (trimmedLine.startsWith('DTEND')) {
          dtEnd = _parseDateTime(trimmedLine);
          print('📅 Found end date: $dtEnd');
        }
      }
      
      if (dtStart == null || dtEnd == null || summary.isEmpty) {
        print('⚠️ Skipping incomplete event: start=$dtStart, end=$dtEnd, summary="$summary", uid="$uid"');
        return 'skipped';
      }
      
      print('✅ Event parsed successfully: "$summary" (UID: $uid) from ${dtStart} to ${dtEnd}');
      
      // Check if event already exists by UID (primary key for CalDAV sync)
      final existingEvents = await db.query(
        'calendar_events',
        where: 'accountId = ? AND caldav_uid = ?',
        whereArgs: [account.username, uid],
      );
      
      final eventData = {
        'accountId': account.username,
        'title': summary,
        'description': description,
        'location': location,
        'startDateTime': dtStart.millisecondsSinceEpoch,
        'endDateTime': dtEnd.millisecondsSinceEpoch,
        'isAllDay': isAllDay ? 1 : 0,
        'reminderMinutes': 15,
        'hasAttachments': 0,
        'attendees': '',
        'category': category,
        'modified': DateTime.now().millisecondsSinceEpoch,
        'caldav_uid': uid,
        'caldav_etag': etag,
        'caldav_href': href,
        'caldav_raw_data': rawCalendarData,
        'needs_sync': 0, // Fresh from server
      };
      
      if (existingEvents.isEmpty) {
        // Insert new event
        eventData['created'] = DateTime.now().millisecondsSinceEpoch;
        await db.insert('calendar_events', eventData);
        print('✅ Imported new event: $summary (UID: $uid) for ${account.username}');
        return 'imported';
      } else {
        // Update existing event
        final existingEvent = existingEvents.first;
        final existingId = existingEvent['id'] as int;
        final existingEtag = existingEvent['caldav_etag'] as String?;
        
        // Check if ETag has changed (server-side modification)
        bool etagChanged = existingEtag != etag;
        if (etagChanged) {
          print('🏷️ ETag changed: $existingEtag → $etag (server updated)');
        }
        
        // Check if any display field has changed
        bool hasChanges = etagChanged;
        final fieldsToCheck = ['title', 'description', 'location', 'startDateTime', 'endDateTime', 'isAllDay', 'category'];
        
        if (!hasChanges) {
          for (final field in fieldsToCheck) {
            final newValue = eventData[field];
            final oldValue = existingEvent[field];
            if (newValue != oldValue) {
              hasChanges = true;
              print('📝 Field $field changed: $oldValue → $newValue');
              break;
            }
          }
        }
        
        if (hasChanges) {
          // Check if event was locally modified but not synced
          final needsSync = existingEvent['needs_sync'] as int? ?? 0;
          if (needsSync == 1 && etagChanged) {
            print('⚠️ CONFLICT: Event was modified both locally and on server!');
            print('📤 Server version will overwrite local changes (implement conflict resolution UI)');
            // TODO: Implement conflict resolution UI
          }
          
          await db.update(
            'calendar_events',
            eventData,
            where: 'id = ?',
            whereArgs: [existingId],
          );
          print('🔄 Updated existing event: $summary (UID: $uid) for ${account.username}');
          return 'updated';
        } else {
          // No display changes but update metadata if needed
          final metadataChanged = existingEtag != etag || 
                                 existingEvent['caldav_href'] != href ||
                                 existingEvent['caldav_raw_data'] != rawCalendarData;
          
          if (metadataChanged) {
            await db.update(
              'calendar_events',
              {
                'caldav_etag': etag,
                'caldav_href': href,
                'caldav_raw_data': rawCalendarData,
              },
              where: 'id = ?',
              whereArgs: [existingId],
            );
            print('🏷️ Updated metadata for: $summary (UID: $uid)');
          }
          
          print('✓ No changes for event: $summary (UID: $uid)');
          return 'unchanged';
        }
      }
    } catch (e) {
      print('❌ Error processing CalDAV event: $e');
      print('📄 Failed event metadata: $eventMetadata');
      return 'error';
    }
  }

  DateTime? _parseDateTime(String line) {
    try {
      print('🕐 Parsing datetime line: $line');

      // Extract TZID if present
      String? tzid;
      if (line.contains(';TZID=')) {
        final tzidStart = line.indexOf('TZID=') + 5;
        final tzidEnd = line.indexOf(':', tzidStart);
        if (tzidEnd > tzidStart) {
          tzid = line.substring(tzidStart, tzidEnd);
        }
      }

      final colonIndex = line.lastIndexOf(':'); // Use lastIndexOf to get the colon before the datetime value
      if (colonIndex == -1) {
        print('❌ No colon found in datetime line');
        return null;
      }

      final dateTimeStr = line.substring(colonIndex + 1).trim();
      print('🕐 Extracted datetime string: "$dateTimeStr" (tzid: $tzid)');

      // Handle different date formats
      if (dateTimeStr.contains('T')) {
        // Full datetime
        if (dateTimeStr.endsWith('Z')) {
          // UTC time
          final parsed = DateTime.parse(dateTimeStr.replaceAll('Z', '')).toUtc();
          print('✅ Parsed UTC datetime: $parsed');
          return parsed;
        } else if (tzid != null) {
          // Has timezone specified - try to use timezone database
          try {
            // Map iCal timezone names to IANA timezone names
            final location = tz.getLocation(tzid);
            final localTime = tz.TZDateTime.parse(location, dateTimeStr);
            final utcTime = localTime.toUtc();
            print('✅ Parsed TZID datetime: $localTime in $tzid -> UTC: $utcTime (epoch: ${utcTime.millisecondsSinceEpoch})');
            return utcTime;
          } catch (e) {
            print('⚠️ Could not parse timezone $tzid, falling back to local: $e');
            // Fallback: parse as local time
            final parsed = DateTime.parse(dateTimeStr);
            print('✅ Parsed as local datetime: $parsed (epoch: ${parsed.millisecondsSinceEpoch})');
            return parsed;
          }
        } else {
          // Local time without TZID
          final parsed = DateTime.parse(dateTimeStr);
          print('✅ Parsed local datetime: $parsed');
          return parsed;
        }
      } else {
        // Date only (all day event)
        final parsed = DateTime.parse('${dateTimeStr}T00:00:00');
        print('✅ Parsed all-day date: $parsed');
        return parsed;
      }
    } catch (e) {
      print('❌ Error parsing datetime: $line, error: $e');
      return null;
    }
  }

  /// SIMPLIFIED PROCESSING: Handle CalDAV events with timestamp-based "newest wins" logic
  Future<String> _processCalDAVEventSimplified(dynamic db, EmailAccount account, Map<String, String> eventMetadata) async {
    try {
      final icalData = eventMetadata['calendar_data'];
      final serverEtag = eventMetadata['etag'];
      final serverHref = eventMetadata['href'];
      
      if (icalData == null || icalData.isEmpty) {
        return 'skipped_no_data';
      }
      
      // Extract UID and LAST-MODIFIED from iCal data
      final uid = _extractValueFromICal(icalData, 'UID');
      final lastModifiedStr = _extractValueFromICal(icalData, 'LAST-MODIFIED');
      
      if (uid == null || uid.isEmpty) {
        print('⚠️ No UID found in event, skipping');
        return 'skipped_no_uid';
      }
      
      // Parse server's LAST-MODIFIED timestamp
      DateTime? serverLastModified;
      if (lastModifiedStr != null && lastModifiedStr.isNotEmpty) {
        try {
          // Parse iCal timestamp: 20250806T124310Z
          serverLastModified = DateTime.parse(
            '${lastModifiedStr.substring(0, 4)}-${lastModifiedStr.substring(4, 6)}-${lastModifiedStr.substring(6, 8)}T${lastModifiedStr.substring(9, 11)}:${lastModifiedStr.substring(11, 13)}:${lastModifiedStr.substring(13, 15)}Z'
          );
        } catch (e) {
          print('⚠️ Failed to parse LAST-MODIFIED: $lastModifiedStr, using current time');
          serverLastModified = DateTime.now().toUtc();
        }
      } else {
        serverLastModified = DateTime.now().toUtc();
      }
      
      // Check if we already have this event locally
      final existingEvents = await db.query(
        'calendar_events',
        where: 'caldav_uid = ? AND accountId = ?',
        whereArgs: [uid, account.username],
      );
      
      if (existingEvents.isNotEmpty) {
        // SIMPLIFIED LOGIC: Compare timestamps and keep newest
        final localEvent = existingEvents.first;
        final localModified = DateTime.fromMillisecondsSinceEpoch(localEvent['modified'] ?? 0);
        
        print('🔍 UID $uid exists locally');
        print('   Server LAST-MODIFIED: ${serverLastModified.toIso8601String()}');
        print('   Local modified: ${localModified.toIso8601String()}');
        
        if (serverLastModified.isAfter(localModified)) {
          print('🏆 Server version is newer - updating local event');
          await _updateEventFromServerData(db, localEvent['id'], icalData, serverEtag, serverHref, account, serverLastModified);

          // Clean up any duplicates with same UID
          await _cleanupDuplicateUIDs(db, uid, account.username, localEvent['id']);
          return 'updated';
        } else {
          print('⏰ Local version is newer or same - keeping local event');
          // Just update metadata to ensure we have server info
          await db.update(
            'calendar_events',
            {
              'caldav_etag': serverEtag,
              'caldav_href': serverHref,
              'caldav_raw_data': icalData,
            },
            where: 'id = ?',
            whereArgs: [localEvent['id']],
          );
          return 'kept_local';
        }
      } else {
        print('📥 New event from server: $uid');
        await _importNewEventFromServer(db, icalData, serverEtag, serverHref, account);
        return 'imported';
      }
    } catch (e) {
      print('❌ Error processing CalDAV event: $e');
      return 'error';
    }
  }

  /// Clean up duplicate events with the same UID, keeping only the specified one
  Future<void> _cleanupDuplicateUIDs(dynamic db, String uid, String accountId, int keepEventId) async {
    try {
      final duplicates = await db.query(
        'calendar_events',
        where: 'caldav_uid = ? AND accountId = ? AND id != ?',
        whereArgs: [uid, accountId, keepEventId],
      );
      
      if (duplicates.isNotEmpty) {
        print('🗑️ Cleaning up ${duplicates.length} duplicate events for UID: $uid');
        
        for (final duplicate in duplicates) {
          await db.delete(
            'calendar_events',
            where: 'id = ?',
            whereArgs: [duplicate['id']],
          );
        }
        
        print('✅ Cleaned up duplicates for UID: $uid');
      }
    } catch (e) {
      print('❌ Error cleaning up duplicates: $e');
    }
  }

  /// Update existing event from server data
  Future<void> _updateEventFromServerData(dynamic db, int eventId, String icalData, String? etag, String? href, EmailAccount account, DateTime serverLastModified) async {
    try {
      final eventData = _parseICalEvent(icalData, account);

      await db.update(
        'calendar_events',
        {
          'title': eventData['title'],
          'description': eventData['description'],
          'startDateTime': eventData['startDateTime'],
          'endDateTime': eventData['endDateTime'],
          'location': eventData['location'],
          'isAllDay': eventData['isAllDay'],
          'category': eventData['category'],
          'caldav_etag': etag,
          'caldav_href': href,
          'caldav_raw_data': icalData,
          'modified': serverLastModified.millisecondsSinceEpoch, // Use server's timestamp!
          'needs_sync': 0, // Server is now the source of truth
        },
        where: 'id = ?',
        whereArgs: [eventId],
      );
    } catch (e) {
      print('❌ Error updating event from server: $e');
    }
  }

  /// Import completely new event from server
  Future<void> _importNewEventFromServer(dynamic db, String icalData, String? etag, String? href, EmailAccount account) async {
    try {
      final eventData = _parseICalEvent(icalData, account);
      
      // Add CalDAV metadata
      eventData['caldav_etag'] = etag;
      eventData['caldav_href'] = href;
      eventData['caldav_raw_data'] = icalData;
      eventData['needs_sync'] = 0;
      eventData['created'] = DateTime.now().millisecondsSinceEpoch;
      eventData['modified'] = DateTime.now().millisecondsSinceEpoch;
      
      await db.insert('calendar_events', eventData);
    } catch (e) {
      print('❌ Error importing new event: $e');
    }
  }

  /// Extract a specific value from iCal data
  String? _extractValueFromICal(String icalData, String property) {
    final lines = icalData.split('\n');
    for (final line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.startsWith('$property:')) {
        return trimmedLine.substring(property.length + 1).trim();
      }
    }
    return null;
  }

  /// Parse iCal event data into database format
  Map<String, dynamic> _parseICalEvent(String icalData, EmailAccount account) {
    final lines = icalData.split('\n');
    String title = '';
    String description = '';
    String location = '';
    String category = '';
    DateTime? dtStart;
    DateTime? dtEnd;
    bool isAllDay = false;
    String? uid;
    bool inVEvent = false;
    bool inVTimezone = false;

    for (final line in lines) {
      final trimmedLine = line.trim();

      // Track when we're inside VEVENT vs VTIMEZONE blocks
      if (trimmedLine == 'BEGIN:VEVENT') {
        inVEvent = true;
        continue;
      } else if (trimmedLine == 'END:VEVENT') {
        inVEvent = false;
        continue;
      } else if (trimmedLine == 'BEGIN:VTIMEZONE') {
        inVTimezone = true;
        continue;
      } else if (trimmedLine == 'END:VTIMEZONE') {
        inVTimezone = false;
        continue;
      }

      // Skip lines that are in VTIMEZONE blocks
      if (inVTimezone) {
        continue;
      }

      // Only parse event properties when inside VEVENT block
      if (inVEvent) {
        if (trimmedLine.startsWith('UID:')) {
          uid = trimmedLine.substring(4).trim();
        } else if (trimmedLine.startsWith('SUMMARY:')) {
          title = trimmedLine.substring(8).trim();
        } else if (trimmedLine.startsWith('DESCRIPTION:')) {
          description = trimmedLine.substring(12).trim().replaceAll('\\n', '\n');
        } else if (trimmedLine.startsWith('LOCATION:')) {
          location = trimmedLine.substring(9).trim();
        } else if (trimmedLine.startsWith('CATEGORIES:')) {
          category = trimmedLine.substring(11).trim();
        } else if (trimmedLine.startsWith('DTSTART')) {
          dtStart = _parseDateTime(trimmedLine);
          if (trimmedLine.contains('VALUE=DATE')) {
            isAllDay = true;
          }
        } else if (trimmedLine.startsWith('DTEND')) {
          dtEnd = _parseDateTime(trimmedLine);
        }
      }
    }
    
    final startEpoch = dtStart?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch;
    final endEpoch = dtEnd?.millisecondsSinceEpoch ?? DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch;
    print('📅 [PARSE-ICAL] Parsed event: $title');
    print('   dtStart DateTime: $dtStart');
    print('   startEpoch: $startEpoch');
    print('   dtEnd DateTime: $dtEnd');
    print('   endEpoch: $endEpoch');

    return {
      'title': title,
      'description': description,
      'startDateTime': startEpoch,
      'endDateTime': endEpoch,
      'location': location,
      'accountId': account.username,
      'isAllDay': isAllDay ? 1 : 0,
      'category': category,
      'caldav_uid': uid,
    };
  }

  /// ENHANCED EDIT EVENT: With immediate upload functionality 
  Future<void> _editEvent(Map<String, dynamic> event) async {
    final result = await _showEventDialog(event: event);
    if (result != null) {
      try {
        final db = await DatabaseHelper.instance.database;

        print('📝 [UPDATE-DEBUG] Data being saved to database:');
        print('   - title: ${result['title']}');
        print('   - startDateTime: ${result['startDateTime']}');
        print('   - endDateTime: ${result['endDateTime']}');
        print('   - accountId: ${result['accountId']}');

        // Update local database first
        await db.update(
          'calendar_events',
          result,
          where: 'id = ?',
          whereArgs: [event['id']],
        );
        
        // Get updated event data for immediate upload
        final updatedEvents = await db.query(
          'calendar_events',
          where: 'id = ?',
          whereArgs: [event['id']],
        );

        if (updatedEvents.isNotEmpty) {
          final updatedEvent = updatedEvents.first;
          print('📊 [DB-DEBUG] Event data from database:');
          print('   - title: ${updatedEvent['title']}');
          print('   - startDateTime: ${updatedEvent['startDateTime']}');
          print('   - endDateTime: ${updatedEvent['endDateTime']}');
          print('   - accountId: ${updatedEvent['accountId']}');
          
          // 🚀 IMMEDIATE UPLOAD: Upload changes to server instantly
          print('🚀 IMMEDIATE UPLOAD: User clicked Update - uploading to server...');
          final uploadSuccess = await _immediateUploadEvent(updatedEvent);
          
          if (uploadSuccess) {
            print('✅ IMMEDIATE UPLOAD: Successfully synced to server!');
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Event updated and synced to server!'),
                backgroundColor: Colors.green,
                duration: Duration(seconds: 2),
              ),
            );
          } else {
            print('⚠️ IMMEDIATE UPLOAD: Failed, marked for background sync');
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('⚠️ Event updated locally, will sync to server shortly'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          }
        }
        
        // Refresh UI
        await _loadEvents();
        await _loadAccountColors();
        
      } catch (e) {
        print('❌ Error updating event: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error updating event: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _deleteEvent(Map<String, dynamic> event) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Event'),
        content: Text('Are you sure you want to delete "${event['title']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final db = await DatabaseHelper.instance.database;
        await db.delete(
          'calendar_events',
          where: 'id = ?',
          whereArgs: [event['id']],
        );
        await _loadEvents();
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Event deleted successfully'),
            backgroundColor: Colors.orange,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting event: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _showEventDialog({Map<String, dynamic>? event}) async {
    final formKey = GlobalKey<FormState>();
    final isEditing = event != null;
    
    // Form controllers
    final titleController = TextEditingController(text: event?['title'] ?? '');
    final descriptionController = TextEditingController(text: event?['description'] ?? '');
    final locationController = TextEditingController(text: event?['location'] ?? '');
    final attendeesController = TextEditingController(text: event?['attendees'] ?? '');
    
    // Date/time values
    DateTime startDateTime = event != null 
        ? DateTime.fromMillisecondsSinceEpoch(event['startDateTime'])
        : DateTime.now().add(const Duration(hours: 1));
    DateTime endDateTime = event != null 
        ? DateTime.fromMillisecondsSinceEpoch(event['endDateTime'])
        : DateTime.now().add(const Duration(hours: 2));
    
    bool isAllDay = (event?['isAllDay'] ?? 0) == 1;
    int reminderMinutes = event?['reminderMinutes'] ?? 15;
    bool hasAttachments = (event?['hasAttachments'] ?? 0) == 1;
    
    // Selected account and category
    String selectedAccountId = event?['accountId'] ?? (widget.accounts.isNotEmpty ? widget.accounts.first.username : '');
    String selectedCategory = event?['category'] ?? '';

    return await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEditing ? 'Edit Event' : 'Add Event'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Account selection
                  DropdownButtonFormField<String>(
                    value: selectedAccountId.isNotEmpty ? selectedAccountId : null,
                    decoration: const InputDecoration(labelText: 'Account'),
                    items: widget.accounts
                      .fold<Map<String, EmailAccount>>({}, (map, account) {
                        map[account.username] = account;
                        return map;
                      })
                      .values
                      .map((account) => DropdownMenuItem(
                        value: account.username,
                        child: Text(account.display.isNotEmpty ? account.display : account.username),
                      ))
                      .toList(),
                    onChanged: (value) => selectedAccountId = value ?? '',
                    validator: (value) => value?.isEmpty == true ? 'Please select an account' : null,
                  ),
                  const SizedBox(height: 16),
                  
                  // Title
                  TextFormField(
                    controller: titleController,
                    decoration: const InputDecoration(labelText: 'Event Title *'),
                    validator: (value) => value?.isEmpty == true ? 'Please enter title' : null,
                  ),
                  const SizedBox(height: 16),
                  
                  // Description
                  TextFormField(
                    controller: descriptionController,
                    decoration: const InputDecoration(labelText: 'Description'),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 16),
                  
                  // Location
                  TextFormField(
                    controller: locationController,
                    decoration: const InputDecoration(labelText: 'Location'),
                  ),
                  const SizedBox(height: 16),
                  
                  // Category dropdown
                  DropdownButtonFormField<String>(
                    value: selectedCategory.isNotEmpty ? selectedCategory : null,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('No Category')),
                      ..._predefinedCategories.map((category) => DropdownMenuItem(
                        value: category,
                        child: Text(category),
                      )),
                    ],
                    onChanged: (value) => selectedCategory = value ?? '',
                  ),
                  const SizedBox(height: 16),
                  
                  // All Day toggle
                  CheckboxListTile(
                    title: const Text('All Day'),
                    value: isAllDay,
                    onChanged: (value) {
                      setDialogState(() {
                        isAllDay = value ?? false;
                      });
                    },
                  ),
                  
                  // Start Date/Time
                  ListTile(
                    title: const Text('Start'),
                    subtitle: Text(
                      isAllDay 
                          ? DateFormat('MMM d, yyyy').format(startDateTime)
                          : DateFormat('MMM d, yyyy h:mm a').format(startDateTime)
                    ),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: startDateTime,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2030),
                      );
                      if (date != null) {
                        if (!isAllDay) {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(startDateTime),
                          );
                          if (time != null) {
                            setDialogState(() {
                              startDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                            });
                          }
                        } else {
                          setDialogState(() {
                            startDateTime = DateTime(date.year, date.month, date.day);
                          });
                        }
                      }
                    },
                  ),
                  
                  // End Date/Time
                  ListTile(
                    title: const Text('End'),
                    subtitle: Text(
                      isAllDay 
                          ? DateFormat('MMM d, yyyy').format(endDateTime)
                          : DateFormat('MMM d, yyyy h:mm a').format(endDateTime)
                    ),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: endDateTime,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2030),
                      );
                      if (date != null) {
                        if (!isAllDay) {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(endDateTime),
                          );
                          if (time != null) {
                            setDialogState(() {
                              endDateTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
                            });
                          }
                        } else {
                          setDialogState(() {
                            endDateTime = DateTime(date.year, date.month, date.day);
                          });
                        }
                      }
                    },
                  ),
                  
                  // Reminder
                  DropdownButtonFormField<int>(
                    value: reminderMinutes,
                    decoration: const InputDecoration(labelText: 'Reminder'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('None')),
                      DropdownMenuItem(value: 5, child: Text('5 minutes before')),
                      DropdownMenuItem(value: 15, child: Text('15 minutes before')),
                      DropdownMenuItem(value: 30, child: Text('30 minutes before')),
                      DropdownMenuItem(value: 60, child: Text('1 hour before')),
                      DropdownMenuItem(value: 1440, child: Text('1 day before')),
                    ],
                    onChanged: (value) => reminderMinutes = value ?? 15,
                  ),
                  const SizedBox(height: 16),
                  
                  // Has Attachments toggle
                  CheckboxListTile(
                    title: const Text('Has Attachments'),
                    value: hasAttachments,
                    onChanged: (value) {
                      setDialogState(() {
                        hasAttachments = value ?? false;
                      });
                    },
                  ),
                  
                  // Attendees
                  TextFormField(
                    controller: attendeesController,
                    decoration: const InputDecoration(
                      labelText: 'Attendees (comma separated)',
                      hintText: 'email1@example.com, email2@example.com',
                    ),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (formKey.currentState!.validate()) {
                  final eventData = {
                    'accountId': selectedAccountId,
                    'title': titleController.text.trim(),
                    'description': descriptionController.text.trim(),
                    'location': locationController.text.trim(),
                    'startDateTime': startDateTime.millisecondsSinceEpoch,
                    'endDateTime': endDateTime.millisecondsSinceEpoch,
                    'isAllDay': isAllDay ? 1 : 0,
                    'reminderMinutes': reminderMinutes,
                    'hasAttachments': hasAttachments ? 1 : 0,
                    'attendees': attendeesController.text.trim(),
                    'category': selectedCategory,
                    'created': DateTime.now().millisecondsSinceEpoch,
                    'modified': DateTime.now().millisecondsSinceEpoch,
                  };
                  Navigator.of(context).pop(eventData);
                }
              },
              child: Text(isEditing ? 'Update' : 'Add'),
            ),
          ],
        ),
      ),
    );
  }

  /// Simple direct CalDAV sync without complex logic
  Future<void> _simpleCalDAVSync() async {
    print('🔄 Starting SIMPLE CalDAV sync...');
    
    try {
      final accounts = await DatabaseHelper.instance.getAccounts();
      print('🔄 Found ${accounts.length} accounts to sync');
      
      for (final account in accounts) {
        print('🔄 Syncing ${account.username}...');
        
        // Check if account has CalDAV configured
        if (account.caldavBaseUrl == null || account.caldavBaseUrl!.isEmpty) {
          print('⚠️ No CalDAV base URL for ${account.username}, skipping');
          continue;
        }
        
        if (account.caldavPath == null || account.caldavPath!.isEmpty) {
          print('⚠️ No CalDAV path for ${account.username}, skipping');
          continue;
        }
        
        print('🔧 Account: ${account.username}');
        print('🔧 CalDAV Base URL: ${account.caldavBaseUrl}');
        print('🔧 CalDAV Path: ${account.caldavPath}');
        
        try {
          // Create CalDAV client
          final client = await _createCalDAVClient(account);
          if (client == null) {
            print('❌ Failed to create CalDAV client for ${account.username}');
            continue;
          }
          
          print('✅ CalDAV client created successfully');
          
          // Test the configured path directly
          final calendarPath = account.caldavPath!;
          print('🔍 Testing path: $calendarPath');
          
          // Get events from the last 7 days and next 30 days
          final startDate = DateTime.now().subtract(const Duration(days: 7));
          final endDate = DateTime.now().add(const Duration(days: 30));
          
          print('📅 Fetching events from ${startDate.toIso8601String()} to ${endDate.toIso8601String()}');
          
          final response = await client.getObjectsInTimeRange(calendarPath, startDate, endDate).timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              print('⏰ CalDAV request timed out');
              throw Exception('CalDAV request timeout');
            },
          );
          
          print('📡 Response status: ${response.statusCode}');
          
          if (response.statusCode == 207) {
            print('✅ CalDAV request successful!');
            
            // Process the response
            if (response.document != null) {
              final responseBody = response.document!.toXmlString();
              print('📄 Response length: ${responseBody.length} characters');
              
              // Extract events with ETags
              final eventsWithETags = _extractEventsWithETags(responseBody);
              print('🎯 Found ${eventsWithETags.length} events with ETags');
              
              if (eventsWithETags.isNotEmpty) {
                print('✅ Events found! Processing...');
                
                // Process events with ETag support
                final db = await DatabaseHelper.instance.database;
                int processed = 0;
                for (final eventWithETag in eventsWithETags) {
                  try {
                    final result = await _processCalDAVEvent(db, account, eventWithETag);
                    if (result == 'imported' || result == 'updated') {
                      processed++;
                    }
                  } catch (e) {
                    print('❌ Error processing event: $e');
                  }
                }
                
                print('✅ Processed $processed events for ${account.username}');
                
                // Save the path as confirmed since it works
                await _saveConfirmedCalDAVPath(account, calendarPath);
                print('💾 Saved confirmed path: $calendarPath');
                
              } else {
                print('⚠️ No events found in calendar');
              }
            } else {
              print('❌ No document in response');
            }
          } else {
            print('❌ CalDAV request failed with status: ${response.statusCode}');
            if (response.document != null) {
              final errorBody = response.document!.toXmlString();
              print('❌ Error response: ${errorBody.length > 300 ? errorBody.substring(0, 300) + "..." : errorBody}');
            }
          }
        } catch (e) {
          print('❌ Error syncing ${account.username}: $e');
        }
      }
      
      print('🎉 Simple CalDAV sync completed');
    } catch (e) {
      print('❌ Simple CalDAV sync failed: $e');
    }
  }

  /// Debug method to test CalDAV sync step by step
  Future<void> _testCalDAVSync() async {
    print('🐛 =========================');
    print('🐛 DEBUG CALDAV SYNC TEST');
    print('🐛 =========================');
    
    try {
      // Step 1: Get accounts
      print('🐛 Step 1: Getting accounts...');
      final accounts = await DatabaseHelper.instance.getAccounts();
      print('🐛 Found ${accounts.length} accounts');
      
      if (accounts.isEmpty) {
        print('🐛 ❌ No accounts found!');
        return;
      }
      
      // Step 1.5: Fix any accounts with "null" string confirmed paths
      print('🐛 Step 1.5: Checking for invalid confirmed paths...');
      for (final account in accounts) {
        if (account.caldavConfirmedPath == "null" || account.caldavConfirmedPath == "NULL") {
          print('🐛 🧹 Clearing invalid "null" string for ${account.username}');
          await _clearConfirmedCalDAVPath(account);
        }
        
        // If account has a configured caldav-path but no confirmed path, set it
        if ((account.caldavConfirmedPath == null || 
             account.caldavConfirmedPath!.isEmpty || 
             account.caldavConfirmedPath == "null" ||
             account.caldavConfirmedPath == "NULL") &&
            account.caldavPath != null && 
            account.caldavPath!.isNotEmpty) {
          print('🐛 🔧 Setting configured path as confirmed for ${account.username}: ${account.caldavPath}');
          await _saveConfirmedCalDAVPath(account, account.caldavPath!);
        }
      }
      
      // Reload accounts after fixes
      final updatedAccounts = await DatabaseHelper.instance.getAccounts();
      
      for (int i = 0; i < updatedAccounts.length; i++) {
        final account = updatedAccounts[i];
        print('🐛 -------------------------');
        print('🐛 Testing account ${i + 1}: ${account.username}');
        
        // Step 2: Create CalDAV client
        print('🐛 Step 2: Creating CalDAV client...');
        print('🐛 Account details:');
        print('🐛   - Username: ${account.username}');
        print('🐛   - IMAP: ${account.imap}');
        print('🐛   - CalDAV Base URL: ${account.caldavBaseUrl}');
        print('🐛   - CalDAV Path: ${account.caldavPath}');
        print('🐛   - CalDAV Confirmed Path: ${account.caldavConfirmedPath}');
        
        final client = await _createCalDAVClient(account);
        if (client == null) {
          print('🐛 ❌ Failed to create CalDAV client');
          continue;
        }
        print('🐛 ✅ CalDAV client created');
        
        // Step 3: Test confirmed path if available
        if (account.caldavConfirmedPath != null && 
            account.caldavConfirmedPath!.isNotEmpty && 
            account.caldavConfirmedPath != "null" &&
            account.caldavConfirmedPath != "NULL") {
          print('🐛 Step 3: Testing confirmed path: ${account.caldavConfirmedPath}');
          try {
            final response = await client.initialSync(account.caldavConfirmedPath!).timeout(const Duration(seconds: 10));
            print('🐛 Confirmed path status: ${response.statusCode}');
            
            if (response.statusCode == 207) {
              print('🐛 ✅ Confirmed path works - testing event retrieval...');
              
              // Step 4: Test event retrieval
              final startDate = DateTime.now().subtract(const Duration(days: 7));
              final endDate = DateTime.now().add(const Duration(days: 7));
              
              final eventResponse = await client.getObjectsInTimeRange(
                account.caldavConfirmedPath!, 
                startDate, 
                endDate
              ).timeout(const Duration(seconds: 15));
              
              print('🐛 Event retrieval status: ${eventResponse.statusCode}');
              
              if (eventResponse.statusCode == 207) {
                print('🐛 ✅ Event retrieval successful');
                
                // Step 5: Test event parsing
                if (eventResponse.document != null) {
                  final responseBody = eventResponse.document!.toXmlString();
                  print('🐛 Response length: ${responseBody.length} chars');
                  print('🐛 Response preview: ${responseBody.length > 500 ? responseBody.substring(0, 500) + "..." : responseBody}');
                  
                  final eventsWithETags = _extractEventsWithETags(responseBody);
                  print('🐛 Extracted ${eventsWithETags.length} events with ETags');
                  
                  if (eventsWithETags.isNotEmpty) {
                    print('🐛 ✅ Events found and parsed successfully!');
                    
                    // Step 6: Test processing the events with ETags
                    print('🐛 Step 6: Testing event processing with ETag support...');
                    final db = await DatabaseHelper.instance.database;
                    for (int j = 0; j < eventsWithETags.length && j < 2; j++) {
                      final eventWithETag = eventsWithETags[j];
                      print('🐛 Processing event ${j + 1} with ETag: ${eventWithETag['etag']}');
                      final result = await _processCalDAVEvent(db, account, eventWithETag);
                      print('🐛 Event ${j + 1} processing result: $result');
                    }
                  } else {
                    print('🐛 ⚠️ No events found in response');
                  }
                } else {
                  print('🐛 ❌ No document in response');
                }
              } else {
                print('🐛 ❌ Event retrieval failed with status: ${eventResponse.statusCode}');
                if (eventResponse.document != null) {
                  final errorResponse = eventResponse.document!.toXmlString();
                  print('🐛 Error response: ${errorResponse.length > 300 ? errorResponse.substring(0, 300) + "..." : errorResponse}');
                }
              }
            } else {
              print('🐛 ❌ Confirmed path failed with status: ${response.statusCode}');
            }
          } catch (e) {
            print('🐛 ❌ Confirmed path test failed: $e');
          }
        } else {
          print('🐛 Step 3: No confirmed path available, would need discovery');
          
          // Step 3.5: Test the configured path directly
          if (account.caldavPath != null && account.caldavPath!.isNotEmpty) {
            print('🐛 Step 3.5: Testing configured path: ${account.caldavPath}');
            try {
              final response = await client.initialSync(account.caldavPath!).timeout(const Duration(seconds: 10));
              print('🐛 Configured path status: ${response.statusCode}');
              
              if (response.statusCode == 207) {
                print('🐛 ✅ Configured path works! Saving as confirmed...');
                await _saveConfirmedCalDAVPath(account, account.caldavPath!);
              } else {
                print('🐛 ❌ Configured path failed with status: ${response.statusCode}');
              }
            } catch (e) {
              print('🐛 ❌ Configured path test failed: $e');
            }
          }
        }
        
        // Break after first account for debugging
        break;
      }
      
    } catch (e) {
      print('🐛 ❌ Debug test failed: $e');
    }
    
    print('🐛 =========================');
    print('🐛 DEBUG TEST COMPLETED');
    print('🐛 =========================');
  }
  
  /// Update an event locally and mark for sync
  Future<void> updateEvent(Map<String, dynamic> eventData) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final eventId = eventData['id'] as int;
      
      // Update the event data
      eventData['modified'] = DateTime.now().millisecondsSinceEpoch;
      eventData['needs_sync'] = 1; // Mark for sync
      
      await db.update(
        'calendar_events',
        eventData,
        where: 'id = ?',
        whereArgs: [eventId],
      );
      
      print('✅ Updated event locally: ${eventData['title']}');
      
      // Reload events to refresh UI
      await _loadEvents();
      
      // Optionally trigger immediate sync
      if (mounted) {
        _syncFromCalDAV(forceSync: false);
      }
    } catch (e) {
      print('❌ Failed to update event: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          // Debug sync button
          PopupMenuButton<String>(
            icon: const Icon(Icons.bug_report),
            tooltip: 'Debug CalDAV Sync',
            onSelected: (value) async {
              setState(() {
                _isLoading = true;
              });
              print('🐛 DEBUG: Starting $value...');
              try {
                if (value == 'simple') {
                  await _simpleCalDAVSync();
                } else if (value == 'detailed') {
                  await _testCalDAVSync();
                }
                
                // Reload events after sync to update UI
                await _loadEvents(forceSyncFirst: false);
                
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('$value sync completed'),
                      backgroundColor: Colors.green,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              } catch (e) {
                print('🐛 DEBUG: $value failed: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('$value sync failed: ${e.toString()}'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              } finally {
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                  });
                }
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'simple',
                child: Row(
                  children: [
                    Icon(Icons.play_arrow),
                    SizedBox(width: 8),
                    Text('Simple Sync Test'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'detailed',
                child: Row(
                  children: [
                    Icon(Icons.analytics),
                    SizedBox(width: 8),
                    Text('Detailed Debug'),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: _isLoading ? 
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ) : const Icon(Icons.refresh),
            onPressed: _isLoading ? null : () async {
              setState(() {
                _isLoading = true;
              });
              try {
                print('🔄 Manual CalDAV refresh initiated (forced)');
                // Force sync regardless of timing
                await _syncFromCalDAV(forceSync: true).timeout(
                  const Duration(minutes: 2),
                  onTimeout: () {
                    print('❌ CalDAV sync timed out after 2 minutes');
                    throw Exception('CalDAV sync timed out');
                  },
                );
                _lastSyncTime = DateTime.now();
                
                // Reload events from database
                await _loadEvents(forceSyncFirst: false); // Don't sync again since we just did
                
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Calendar refreshed successfully'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
                print('✅ Manual CalDAV refresh completed');
              } catch (e) {
                print('❌ Manual CalDAV refresh failed: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Refresh failed: ${e.toString()}'),
                      backgroundColor: Colors.red,
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              } finally {
                if (mounted) {
                  setState(() {
                    _isLoading = false;
                  });
                }
              }
            },
            tooltip: 'Refresh CalDAV',
          ),
        ],
      ),
      body: Column(
        children: [
          // Search and filter bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                // Search bar
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search events...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                              });
                              _loadEvents();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                    _loadEvents();
                  },
                ),
                const SizedBox(height: 8),
                // Category filter dropdown
                Row(
                  children: [
                    const Icon(Icons.filter_list, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _categoryFilter.isNotEmpty ? _categoryFilter : null,
                        decoration: const InputDecoration(
                          labelText: 'Filter by category',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem(value: '', child: Text('All Categories')),
                          ..._predefinedCategories.map((category) => DropdownMenuItem(
                            value: category,
                            child: Text(category),
                          )),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _categoryFilter = value ?? '';
                          });
                          _loadEvents();
                        },
                      ),
                    ),
                    if (_categoryFilter.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          setState(() {
                            _categoryFilter = '';
                          });
                          _loadEvents();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          
          // Events list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _events.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.calendar_today, size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'No events found',
                              style: TextStyle(fontSize: 18, color: Colors.grey),
                            ),
                            Text(
                              'Tap + to add your first event',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _events.length,
                        itemBuilder: (context, index) {
                          final event = _events[index];
                          final title = event['title'] ?? '';
                          final description = event['description'] ?? '';
                          final location = event['location'] ?? '';
                          final startTime = DateTime.fromMillisecondsSinceEpoch(event['startDateTime'] ?? 0);
                          final endTime = DateTime.fromMillisecondsSinceEpoch(event['endDateTime'] ?? 0);
                          final isAllDay = (event['isAllDay'] ?? 0) == 1;
                          final hasAttachments = (event['hasAttachments'] ?? 0) == 1;
                          
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: _getAccountColor(event),
                                child: Text(
                                  _getEventDateDisplay(event),
                                  style: const TextStyle(
                                    color: Colors.white, 
                                    fontWeight: FontWeight.bold,
                                    fontSize: 10,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(title.isNotEmpty ? title : 'No Title'),
                                  ),
                                  // Show attachment icon if event has attachments
                                  if (hasAttachments)
                                    const Icon(Icons.attach_file, size: 16),
                                ],
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            if (location.isNotEmpty) 
                                              Text(location, style: TextStyle(color: Colors.grey[600])),
                                            if (description.isNotEmpty) 
                                              Text(
                                                description,
                                                style: TextStyle(color: Colors.grey[700]),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            // Category chip
                                            if ((event['category'] as String? ?? '').isNotEmpty)
                                              Padding(
                                                padding: const EdgeInsets.only(top: 4.0),
                                                child: Chip(
                                                  label: Text(
                                                    event['category'] as String,
                                                    style: const TextStyle(fontSize: 12, color: Colors.white),
                                                  ),
                                                  backgroundColor: _getCategoryColor(event['category'] as String),
                                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                  visualDensity: VisualDensity.compact,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      // Time on the right
                                      Text(
                                        isAllDay 
                                            ? 'All Day'
                                            : '${DateFormat('h:mm a').format(startTime)} - ${DateFormat('h:mm a').format(endTime)}',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () => _editEvent(event),
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  switch (value) {
                                    case 'edit':
                                      _editEvent(event);
                                      break;
                                    case 'delete':
                                      _deleteEvent(event);
                                      break;
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit),
                                        SizedBox(width: 8),
                                        Text('Edit'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Delete', style: TextStyle(color: Colors.red)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addEvent,
        tooltip: 'Add Event',
        child: const Icon(Icons.add),
      ),
    );
  }
}