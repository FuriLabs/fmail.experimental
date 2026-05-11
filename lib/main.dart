import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:file_picker/file_picker.dart';
import 'imap_flags_helper.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'email_detail_screen_enhanced.dart'; // Import the EmailDetailScreen widget
import 'compose_screen.dart'; // Import the ComposeScreen widget
import 'email_filter_system.dart'; // Import the filter system
import 'contacts_view.dart'; // Import the ContactsView widget
import 'calendar_view.dart'; // Import the CalendarView widget

// Global error handler to prevent app crashes
void _handleFlutterError(FlutterErrorDetails details) {
  final exceptionStr = details.exception.toString();

  // Ignore known non-critical errors
  if (exceptionStr.contains('Num Lock') ||
      exceptionStr.contains('physicalKey') && exceptionStr.contains('KeyDownEvent')) {
    print('Suppressed known error: ${exceptionStr.substring(0, min(100, exceptionStr.length))}');
    return;
  }

  // Truncate exception to avoid printing massive binary data
  final truncated = exceptionStr.length > 200
      ? '${exceptionStr.substring(0, 200)}...[truncated]'
      : exceptionStr;
  print('Flutter error: $truncated');

  // Truncate stack trace safely
  final stackStr = details.stack?.toString() ?? '';
  if (stackStr.isNotEmpty) {
    print('Stack trace: ${stackStr.substring(0, min(500, stackStr.length))}...[truncated]');
  }

  // Present error to debug console but don't crash the app
  FlutterError.presentError(details);
}

void main() async {
  // Set up global error handling once at the start
  FlutterError.onError = _handleFlutterError;

  // Initialize Flutter bindings
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isLinux || Platform.isWindows) {
    try {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      print('SQLite FFI initialized successfully');
    } catch (e) {
      print('Failed to initialize SQLite FFI: $e');
      print('This may be due to missing SQLite libraries on the system.');
      // Continue without crashing - we'll handle this in DatabaseHelper
    }
  }

  try {
    await DatabaseHelper.instance.database;
    print('Database initialized successfully');
  } catch (e) {
    print('Database initialization failed: $e');
    // Continue running the app even if database fails
    // The app will show an error dialog to the user
  }
  
  runApp(const FuriMailApp());
}

class FuriMailApp extends StatelessWidget {
  const FuriMailApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'fMail',
      theme: ThemeData(
        primarySwatch: Colors.grey,
        brightness: Brightness.dark,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        dividerTheme: const DividerThemeData(
          thickness: 1.0,
          space: 1.0,
        ),
        listTileTheme: const ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(horizontal: 8.0),
        ),
      ),
      home: const EmailListScreen(),
    );
  }
}

class EmailAccount {
  final String imap;
  final String smtp;
  final String username;
  final String password;
  final String replyFrom;
  final String name;
  final String signature;
  final Color color;
  final String display;
  final String? caldavPath; // Optional CalDAV calendar path
  final String? caldavBaseUrl; // Optional CalDAV base URL (e.g., https://mail.connolly.id.au)
  final String? caldavConfirmedPath; // Confirmed CalDAV path that has been tested and works

  EmailAccount({
    required this.imap,
    required this.smtp,
    required this.username,
    required this.password,
    required this.replyFrom,
    required this.name,
    required this.signature,
    required this.color,
    required this.display,
    this.caldavPath,
    this.caldavBaseUrl,
    this.caldavConfirmedPath,
  });

  factory EmailAccount.fromJson(Map<String, dynamic> json) {
    return EmailAccount(
      imap: json['imap'],
      smtp: json['smtp'],
      username: json['username'],
      password: json['password'],
      replyFrom: json['reply-from'],
      name: json['name'],
      signature: json['signature'],
      color: Color(
          int.parse(json['color'].substring(1, 7), radix: 16) + 0xFF000000),
      display: json['display'],
      caldavPath: json['caldav-path'], // Optional field
      caldavBaseUrl: json['caldav-base-url'], // Optional field
      caldavConfirmedPath: json['caldav-confirmed-path'], // Optional field
    );
  }

  Map<String, dynamic> toJson() {
    final json = {
      'imap': imap,
      'smtp': smtp,
      'username': username,
      'password': password,
      'reply-from': replyFrom,
      'name': name,
      'signature': signature,
      'color':
          '#${color.value.toRadixString(16).substring(2, 8).toUpperCase()}',
      'display': display,
    };
    
    if (caldavPath != null) {
      json['caldav-path'] = caldavPath!;
    }
    
    if (caldavBaseUrl != null) {
      json['caldav-base-url'] = caldavBaseUrl!;
    }
    
    if (caldavConfirmedPath != null) {
      json['caldav-confirmed-path'] = caldavConfirmedPath!;
    }
    
    return json;
  }
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static bool _initializationFailed = false;
  static String? _initializationError;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_initializationFailed) {
      throw Exception('Database initialization failed: $_initializationError');
    }
    
    if (_database != null) return _database!;
    
    try {
      _database = await _initDB('furimail.db');
      return _database!;
    } catch (e) {
      _initializationFailed = true;
      _initializationError = e.toString();
      print('Database initialization error: $e');
      
      // Provide a helpful error message
      if (e.toString().contains('libsqlite3.so')) {
        _initializationError = 'SQLite library not found. Please install sqlite3 development libraries:\n'
            'sudo apt install libsqlite3-dev sqlite3';
      }
      
      rethrow;
    }
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = '$dbPath/$filePath';

    print('DEBUG: Opening database at version 14');
    return await openDatabase(
      path,
      version: 14,  // Add bodyFetched, uid columns and incremental sync support
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        print('DEBUG: Database upgrade triggered from version $oldVersion to $newVersion');
        await _onUpgrade(db, oldVersion, newVersion);
      },
    );
  }

  Future _createDB(Database db, int version) async {
    const idType = 'INTEGER PRIMARY KEY AUTOINCREMENT';
    const textType = 'TEXT NOT NULL';
    const intType = 'INTEGER NOT NULL';

    await db.execute('''
CREATE TABLE emails (
  id $idType,
  messageId $textType,
  accountId $textType,
  subject $textType,
  sender $textType,
  senderEmail $textType,
  timestamp $intType,
  content $textType,
  isRead $intType,
  isStarred $intType,
  isAnswered $intType DEFAULT 0,
  isForwarded $intType DEFAULT 0,
  isDraft $intType DEFAULT 0,
  isDeleted $intType DEFAULT 0,
  isJunk $intType DEFAULT 0,
  folderPath $textType,
  inReplyTo TEXT,
  "references" TEXT,
  attachments TEXT,
  threadParentId TEXT,
  hasAttachments $intType DEFAULT 0,
  hasImages $intType DEFAULT 0,
  rawEmail TEXT,
  imapFolder TEXT,
  bodyFetched $intType DEFAULT 0,
  uid $intType DEFAULT 0
)
''');

    await db.execute('''
CREATE TABLE accounts (
  id $idType,
  imap $textType,
  smtp $textType,
  username $textType,
  password $textType,
  replyFrom $textType,
  name $textType,
  signature $textType,
  color $textType,
  display $textType,
  caldav_base_url $textType,
  caldav_path $textType,
  caldav_confirmed_path $textType,
  last_sync_timestamp INTEGER DEFAULT 0,
  sync_settings TEXT
)
''');

    await db.execute('''
CREATE TABLE imap_folders (
  id $idType,
  accountId $textType,
  folderName $textType,
  folderPath $textType,
  parentFolder TEXT,
  isSelectable $intType DEFAULT 1,
  hasChildren $intType DEFAULT 0,
  lastSynced $intType DEFAULT 0,
  UNIQUE(accountId, folderPath)
)
''');

    await db.execute('''
CREATE TABLE imap_sync_state (
  id $idType,
  accountId $textType,
  folderPath $textType,
  lastFetchedUid $intType DEFAULT 0,
  lastFetchedSequence $intType DEFAULT 0,
  lastSyncTime $intType DEFAULT 0,
  totalMessages $intType DEFAULT 0,
  UNIQUE(accountId, folderPath)
)
''');

    await db.execute('''
CREATE TABLE contacts (
  id $idType,
  name $textType,
  email $textType,
  accountId $textType,
  workPhone TEXT,
  personalPhone TEXT,
  workAddress TEXT,
  personalAddress TEXT,
  company TEXT,
  jobTitle TEXT,
  notes TEXT,
  frequency $intType DEFAULT 1,
  lastUsed $intType DEFAULT 0,
  isManual $intType DEFAULT 0,
  UNIQUE(email, accountId)
)
''');

    await db.execute('''
CREATE TABLE user_settings (
  id $idType,
  settingKey $textType UNIQUE,
  settingValue TEXT
)
''');

    await db.execute('CREATE INDEX idx_email_subject ON emails (subject)');
    await db.execute('CREATE INDEX idx_email_sender ON emails (sender)');
    await db.execute('CREATE INDEX idx_email_content ON emails (content)');
    await db.execute('CREATE INDEX idx_email_timestamp ON emails (timestamp)');
    await db.execute('CREATE INDEX idx_email_inreplyto ON emails (inReplyTo)');
    await db
        .execute('CREATE INDEX idx_email_references ON emails ("references")');
    await db.execute(
        'CREATE INDEX idx_email_threadParentId ON emails (threadParentId)');
    
    // Create unique constraint for messageId + accountId + folderPath
    await db.execute('CREATE UNIQUE INDEX idx_email_unique_message_account_folder ON emails (messageId, accountId, folderPath)');
    
    // Create index on messageId for faster lookups (separate from unique constraint)
    await db.execute('CREATE INDEX idx_email_messageid ON emails (messageId)');
    
    // Create indexes for contacts table
    await db.execute('CREATE INDEX idx_contact_email ON contacts (email)');
    await db.execute('CREATE INDEX idx_contact_name ON contacts (name)');
    await db.execute('CREATE INDEX idx_contact_frequency ON contacts (frequency DESC)');
    
    // Create index for user_settings table
    await db.execute('CREATE INDEX idx_setting_key ON user_settings (settingKey)');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    print('DEBUG: Starting database migration from version $oldVersion to $newVersion');
    if (oldVersion < 2) {
      var tableInfo = await db.rawQuery("PRAGMA table_info(emails)");
      var columnNames = tableInfo.map((col) => col['name'] as String).toList();

      if (!columnNames.contains('inReplyTo')) {
        await db.execute('ALTER TABLE emails ADD COLUMN inReplyTo TEXT');
      }

      if (!columnNames.contains('references')) {
        await db.execute('ALTER TABLE emails ADD COLUMN "references" TEXT');
      }

      if (!columnNames.contains('attachments')) {
        await db.execute('ALTER TABLE emails ADD COLUMN attachments TEXT');
      }

      // Add missing boolean columns that should be in version 2
      if (!columnNames.contains('isAnswered')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isAnswered INTEGER DEFAULT 0');
        print('Added missing column: isAnswered');
      }

      if (!columnNames.contains('isForwarded')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isForwarded INTEGER DEFAULT 0');
        print('Added missing column: isForwarded');
      }

      if (!columnNames.contains('isDraft')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isDraft INTEGER DEFAULT 0');
        print('Added missing column: isDraft');
      }

      if (!columnNames.contains('isDeleted')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isDeleted INTEGER DEFAULT 0');
        print('Added missing column: isDeleted');
      }

      if (!columnNames.contains('isJunk')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isJunk INTEGER DEFAULT 0');
        print('Added missing column: isJunk');
      }

      try {
        await db
            .execute('CREATE INDEX idx_email_inreplyto ON emails (inReplyTo)');
      } catch (e) {
        print('Note: Index may already exist: $e');
      }

      try {
        await db.execute(
            'CREATE INDEX idx_email_references ON emails ("references")');
      } catch (e) {
        print('Note: Index may already exist: $e');
      }
    }

    if (oldVersion < 3) {
      var tableInfo = await db.rawQuery("PRAGMA table_info(emails)");
      var columnNames = tableInfo.map((col) => col['name'] as String).toList();

      if (!columnNames.contains('threadParentId')) {
        await db.execute('ALTER TABLE emails ADD COLUMN threadParentId TEXT');
        print('Added missing column: threadParentId');
      }

      if (!columnNames.contains('hasAttachments')) {
        await db.execute(
            'ALTER TABLE emails ADD COLUMN hasAttachments INTEGER DEFAULT 0');
        print('Added missing column: hasAttachments');
      }

      if (!columnNames.contains('hasImages')) {
        await db.execute(
            'ALTER TABLE emails ADD COLUMN hasImages INTEGER DEFAULT 0');
        print('Added missing column: hasImages');
      }

      if (!columnNames.contains('rawEmail')) {
        await db.execute('ALTER TABLE emails ADD COLUMN rawEmail TEXT');
        print('Added missing column: rawEmail');
      }

      try {
        await db.execute(
            'CREATE INDEX idx_email_threadParentId ON emails (threadParentId)');
      } catch (e) {
        print('Note: Index may already exist: $e');
      }
    }

    if (oldVersion < 4) {
      var tableInfo = await db.rawQuery("PRAGMA table_info(ememails)");
      var columnNames = tableInfo.map((col) => col['name'] as String).toList();

      if (!columnNames.contains('rawEmail')) {
        await db.execute('ALTER TABLE emails ADD COLUMN rawEmail TEXT');
        print('Added missing column: rawEmail');
      }
    }

    // Add a comprehensive migration to ensure all columns exist
    if (oldVersion < 5) {
      var tableInfo = await db.rawQuery("PRAGMA table_info(emails)");
      var columnNames = tableInfo.map((col) => col['name'] as String).toList();

      // Ensure all boolean columns exist (some might have been missed in previous versions)
      if (!columnNames.contains('isAnswered')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isAnswered INTEGER DEFAULT 0');
        print('Added missing column: isAnswered');
      }

      if (!columnNames.contains('isForwarded')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isForwarded INTEGER DEFAULT 0');
        print('Added missing column: isForwarded');
      }

      if (!columnNames.contains('isDraft')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isDraft INTEGER DEFAULT 0');
        print('Added missing column: isDraft');
      }

      if (!columnNames.contains('isDeleted')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isDeleted INTEGER DEFAULT 0');
        print('Added missing column: isDeleted');
      }

      if (!columnNames.contains('isJunk')) {
        await db.execute('ALTER TABLE emails ADD COLUMN isJunk INTEGER DEFAULT 0');
        print('Added missing column: isJunk');
      }
    }

    if (oldVersion < 6) {
      var tableInfo = await db.rawQuery("PRAGMA table_info(emails)");
      var columnNames = tableInfo.map((col) => col['name'] as String).toList();

      if (!columnNames.contains('customFolder')) {
        await db.execute('ALTER TABLE emails ADD COLUMN customFolder TEXT');
        print('Added missing column: customFolder');
      }
    }

    // Version 7: Final migration to ensure all columns exist
    if (oldVersion < 7) {
      print('Running database migration to version 7...');
      var tableInfo = await db.rawQuery("PRAGMA table_info(emails)");
      var columnNames = tableInfo.map((col) => col['name'] as String).toList();

      // Comprehensive check for all boolean columns that might be missing
      final requiredColumns = {
        'isAnswered': 'ALTER TABLE emails ADD COLUMN isAnswered INTEGER DEFAULT 0',
        'isForwarded': 'ALTER TABLE emails ADD COLUMN isForwarded INTEGER DEFAULT 0',
        'isDraft': 'ALTER TABLE emails ADD COLUMN isDraft INTEGER DEFAULT 0',
        'isDeleted': 'ALTER TABLE emails ADD COLUMN isDeleted INTEGER DEFAULT 0',
        'isJunk': 'ALTER TABLE emails ADD COLUMN isJunk INTEGER DEFAULT 0',
        'customFolder': 'ALTER TABLE emails ADD COLUMN customFolder TEXT',
      };

      for (final columnName in requiredColumns.keys) {
        if (!columnNames.contains(columnName)) {
          await db.execute(requiredColumns[columnName]!);
          print('Added missing column: $columnName');
        }
      }
      print('Database migration to version 7 completed.');
    }

    // Version 8: Replace customFolder with imapFolder for real IMAP folder support
    if (oldVersion < 8) {
      print('Running database migration to version 8...');
      var tableInfo = await db.rawQuery("PRAGMA table_info(emails)");
      var columnNames = tableInfo.map((col) => col['name'] as String).toList();

      // Add imapFolder column
      if (!columnNames.contains('imapFolder')) {
        await db.execute('ALTER TABLE emails ADD COLUMN imapFolder TEXT');
        print('Added missing column: imapFolder');
      }

      // Migrate existing customFolder data to imapFolder
      await db.execute('UPDATE emails SET imapFolder = customFolder WHERE customFolder IS NOT NULL');
      print('Migrated customFolder data to imapFolder');

      // Create imap_folders table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS imap_folders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          accountId TEXT NOT NULL,
          folderName TEXT NOT NULL,
          folderPath TEXT NOT NULL,
          parentFolder TEXT,
          isSelectable INTEGER DEFAULT 1,
          hasChildren INTEGER DEFAULT 0,
          lastSynced INTEGER DEFAULT 0,
          UNIQUE(accountId, folderPath)
        )
      ''');
      print('Created imap_folders table');

      // Drop customFolder column (SQLite doesn't support DROP COLUMN directly, so we leave it for now)
      // In a production app, we would create a new table and migrate data
      print('Database migration to version 8 completed.');
    }

    // Version 9: Ensure imap_folders table exists
    if (oldVersion < 9) {
      print('Running database migration to version 9...');
      
      // Create imap_folders table if it doesn't exist
      await db.execute('''
        CREATE TABLE IF NOT EXISTS imap_folders (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          accountId TEXT NOT NULL,
          folderName TEXT NOT NULL,
          folderPath TEXT NOT NULL,
          parentFolder TEXT,
          isSelectable INTEGER DEFAULT 1,
          hasChildren INTEGER DEFAULT 0,
          lastSynced INTEGER DEFAULT 0,
          UNIQUE(accountId, folderPath)
        )
      ''');
      print('Created/verified imap_folders table');
      print('Database migration to version 9 completed.');
    }
    
    if (oldVersion < 10) {
      print('Migrating database to version 10: Adding unique constraint for messageId + accountId + folderPath');
      
      // Add unique constraint for messageId + accountId + folderPath
      try {
        await db.execute('CREATE UNIQUE INDEX idx_email_unique_message_account_folder ON emails (messageId, accountId, folderPath)');
        print('Added unique constraint for messageId + accountId + folderPath');
      } catch (e) {
        print('Warning: Could not create unique constraint (may already exist): $e');
      }
      
      print('Database migration to version 10 completed.');
    }
    
    if (oldVersion < 11) {
      print('Migrating database to version 11: Adding contacts table and user settings');
      
      // Create contacts table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS contacts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          email TEXT NOT NULL,
          accountId TEXT NOT NULL,
          workPhone TEXT,
          personalPhone TEXT,
          workAddress TEXT,
          personalAddress TEXT,
          company TEXT,
          jobTitle TEXT,
          notes TEXT,
          frequency INTEGER DEFAULT 1,
          lastUsed INTEGER DEFAULT 0,
          isManual INTEGER DEFAULT 0,
          UNIQUE(email, accountId)
        )
      ''');
      
      // Create user_settings table for persistent settings
      await db.execute('''
        CREATE TABLE IF NOT EXISTS user_settings (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          settingKey TEXT NOT NULL UNIQUE,
          settingValue TEXT
        )
      ''');
      
      // Create index for faster contact searches
      await db.execute('CREATE INDEX idx_contact_email ON contacts (email)');
      await db.execute('CREATE INDEX idx_contact_name ON contacts (name)');
      await db.execute('CREATE INDEX idx_contact_frequency ON contacts (frequency DESC)');
      await db.execute('CREATE INDEX idx_setting_key ON user_settings (settingKey)');
      
      print('Database migration to version 11 completed.');
    }
    
    if (oldVersion < 12) {
      print('Migrating database to version 12: Adding CalDAV fields to accounts table');
      
      // Check if CalDAV columns already exist
      var accountsTableInfo = await db.rawQuery("PRAGMA table_info(accounts)");
      var accountColumnNames = accountsTableInfo.map((col) => col['name'] as String).toList();
      
      if (!accountColumnNames.contains('caldav_base_url')) {
        await db.execute('ALTER TABLE accounts ADD COLUMN caldav_base_url TEXT');
        print('Added caldav_base_url column to accounts table');
      }
      
      if (!accountColumnNames.contains('caldav_path')) {
        await db.execute('ALTER TABLE accounts ADD COLUMN caldav_path TEXT');
        print('Added caldav_path column to accounts table');
      }
      
      print('Database migration to version 12 completed.');
    }
    
    if (oldVersion < 13) {
      print('Migrating database to version 13: Adding CalDAV confirmed path field to accounts table');
      
      // Check if CalDAV confirmed path column already exists
      var accountsTableInfo = await db.rawQuery("PRAGMA table_info(accounts)");
      var accountColumnNames = accountsTableInfo.map((col) => col['name'] as String).toList();
      
      if (!accountColumnNames.contains('caldav_confirmed_path')) {
        await db.execute('ALTER TABLE accounts ADD COLUMN caldav_confirmed_path TEXT');
        print('Added caldav_confirmed_path column to accounts table');
      }
      
      print('Database migration to version 13 completed.');
    }
    
    if (oldVersion < 14) {
      print('Migrating database to version 14: Adding headers-first and incremental sync support');
      
      // Check emails table for new columns
      var emailsTableInfo = await db.rawQuery("PRAGMA table_info(emails)");
      var emailColumnNames = emailsTableInfo.map((col) => col['name'] as String).toList();
      
      if (!emailColumnNames.contains('bodyFetched')) {
        await db.execute('ALTER TABLE emails ADD COLUMN bodyFetched INTEGER DEFAULT 0');
        print('Added bodyFetched column to emails table');
        
        // Mark all existing emails as having their bodies fetched
        await db.execute('UPDATE emails SET bodyFetched = 1');
        print('Marked all existing emails as having bodies fetched');
      }
      
      if (!emailColumnNames.contains('uid')) {
        await db.execute('ALTER TABLE emails ADD COLUMN uid INTEGER DEFAULT 0');
        print('Added uid column to emails table');
      }
      
      // Check accounts table for new columns
      var accountsTableInfo = await db.rawQuery("PRAGMA table_info(accounts)");
      var accountColumnNames = accountsTableInfo.map((col) => col['name'] as String).toList();
      
      if (!accountColumnNames.contains('last_sync_timestamp')) {
        await db.execute('ALTER TABLE accounts ADD COLUMN last_sync_timestamp INTEGER DEFAULT 0');
        print('Added last_sync_timestamp column to accounts table');
      }
      
      if (!accountColumnNames.contains('sync_settings')) {
        await db.execute('ALTER TABLE accounts ADD COLUMN sync_settings TEXT');
        print('Added sync_settings column to accounts table');
      }
      
      // Add index on messageId for faster lookups
      try {
        await db.execute('CREATE INDEX IF NOT EXISTS idx_email_messageid ON emails (messageId)');
        print('Added index on messageId for improved query performance');
      } catch (e) {
        print('Note: messageId index may already exist: $e');
      }
      
      print('Database migration to version 14 completed - headers-first sync enabled!');
    }
  }

  Future<int> insertEmail(Map<String, dynamic> email) async {
    final db = await instance.database;

    final existingEmail = await db.query(
      'emails',
      where: 'messageId = ? AND accountId = ? AND folderPath = ?',
      whereArgs: [email['messageId'], email['accountId'], email['folderPath']],
      limit: 1,
    );

    if (existingEmail.isNotEmpty) {
      return existingEmail.first['id'] as int;
    }

    email['content'] ??= '';
    email['inReplyTo'] ??= '';
    email['references'] ??= '';
    email['attachments'] ??= '';
    email['threadParentId'] ??= email['messageId'];
    email['hasAttachments'] ??= 0;
    email['hasImages'] ??= 0;
    email['rawEmail'] ??= '';

    try {
      final insertedId = await db.insert('emails', email);
      
      // Add contact from email sender automatically
      try {
        final senderName = email['sender']?.toString() ?? '';
        final senderEmail = email['senderEmail']?.toString() ?? '';
        final accountId = email['accountId']?.toString() ?? '';
        
        if (senderEmail.isNotEmpty && accountId.isNotEmpty) {
          await addContactFromEmail(
            senderName: senderName,
            senderEmail: senderEmail,
            accountId: accountId,
          );
        }
      } catch (contactError) {
        print('Warning: Failed to add contact from email: $contactError');
        // Don't fail email insertion if contact addition fails
      }
      
      return insertedId;
    } catch (e) {
      // Don't print full exception as it may contain large attachment data
      final errorType = e.runtimeType.toString();
      final errorMsg = e.toString();
      final errorPreview = errorMsg.length > 200 ? errorMsg.substring(0, 200) + '...' : errorMsg;
      print('Error inserting email: $errorType - $errorPreview');
      
      if (e.toString().contains('no column named')) {
        print('Attempting to handle missing column...');
        await _onUpgrade(db, 2, 3);
        return await db.insert('emails', email);
      }
      rethrow;
    }
  }

  Future<void> updateThreadParent(String messageId, String newParentId) async {
    final db = await instance.database;
    await db.update(
      'emails',
      {'threadParentId': newParentId},
      where: 'threadParentId = ? OR messageId = ?',
      whereArgs: [messageId, messageId],
    );
  }

  Future<List<Map<String, dynamic>>> findThreadEmails({
    required String senderEmail,
    required String subject,
    required String accountId,
    String? inReplyTo,
    String? references,
  }) async {
    final db = await instance.database;
    final cleanSubject = subject
        .replaceAll(RegExp(r'^(Re:|Fwd:|Fw:)\s*', caseSensitive: false), '')
        .trim();
    
    // Build conditions for finding related emails in a thread
    // A thread is linked by: inReplyTo, references, or matching subject
    List<String> conditions = [];
    List<String> whereArgs = [];
    
    // Always filter by account
    conditions.add('accountId = ?');
    whereArgs.add(accountId);
    
    // Build OR conditions for thread matching
    List<String> threadConditions = [];
    
    // 1. Match by inReplyTo -> find the parent email by its messageId
    //    If this email has inReplyTo, find the email with that messageId
    if (inReplyTo != null && inReplyTo.isNotEmpty) {
      threadConditions.add('messageId = ?');
      whereArgs.add(inReplyTo);
    }
    
    // 2. Match emails that reply TO this email's messageId (if we knew it)
    //    This is handled when we also search for emails where inReplyTo matches
    
    // 3. Match by references - any messageId in the references chain
    if (references != null && references.isNotEmpty) {
      final referenceIds = references
          .split(RegExp(r'[\s,]+'))
          .where((id) => id.isNotEmpty && id.contains('@'))
          .toList();
      for (final refId in referenceIds) {
        threadConditions.add('messageId = ?');
        whereArgs.add(refId);
      }
    }
    
    // 4. Match by cleaned subject (same conversation topic) from same account
    //    But only if the subject is meaningful (not empty or generic)
    if (cleanSubject.isNotEmpty && cleanSubject.length > 3) {
      // Match emails with the same base subject (stripped of Re:/Fwd:)
      threadConditions.add("(REPLACE(REPLACE(REPLACE(LOWER(subject), 're: ', ''), 'fwd: ', ''), 'fw: ', '') LIKE ?)");
      whereArgs.add('%${cleanSubject.toLowerCase()}%');
    }
    
    // Combine: must be same account AND match any thread condition
    String whereClause;
    if (threadConditions.isNotEmpty) {
      whereClause = 'accountId = ? AND (${threadConditions.join(' OR ')})';
    } else {
      // No thread conditions - won't find anything
      return [];
    }

    print('Thread SQL Query: $whereClause');
    print('Thread SQL Args: $whereArgs');

    return await db.query(
      'emails',
      where: whereClause.isEmpty ? null : whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
    );
  }

  /// Rebuild threading for all emails in the database
  /// This fixes emails that were saved before threading logic was corrected
  Future<void> rebuildAllThreading() async {
    final db = await instance.database;
    print('🔄 Rebuilding email threading...');

    // Step 1: Reset all emails to point to themselves first (clean slate)
    await db.execute('UPDATE emails SET threadParentId = messageId');
    print('Reset all threadParentId values');

    // Step 2: Get all emails with inReplyTo set (these are replies)
    final replies = await db.query(
      'emails',
      where: "inReplyTo IS NOT NULL AND inReplyTo != ''",
      orderBy: 'timestamp ASC', // Process oldest first
    );

    print('Found ${replies.length} reply emails to process');
    int fixed = 0;

    // Build a map of messageId -> inReplyTo for fast lookups
    // This allows us to follow the inReplyTo chain instead of threadParentId
    final allEmails = await db.query('emails', columns: ['messageId', 'inReplyTo', 'accountId']);
    final Map<String, String?> inReplyToMap = {};
    for (final email in allEmails) {
      final key = '${email['accountId']}:${email['messageId']}';
      inReplyToMap[key] = email['inReplyTo'] as String?;
    }

    for (final reply in replies) {
      final inReplyTo = reply['inReplyTo'] as String?;
      final messageId = reply['messageId'] as String;
      final accountId = reply['accountId'] as String;

      if (inReplyTo == null || inReplyTo.isEmpty) continue;

      // Follow the inReplyTo chain to find the true root (email with no inReplyTo)
      String threadRoot = inReplyTo; // Default to immediate parent if chain can't be followed
      String currentId = inReplyTo;
      int depth = 0;
      final Set<String> visited = {};

      while (depth < 100 && !visited.contains(currentId)) {
        visited.add(currentId);

        final key = '$accountId:$currentId';

        // Check if this email exists in our database
        if (!inReplyToMap.containsKey(key)) {
          // Email not in database - use previous valid email as root
          break;
        }

        final parentInReplyTo = inReplyToMap[key];

        // If this email has no inReplyTo (null or empty), THIS is the thread root
        if (parentInReplyTo == null || parentInReplyTo.isEmpty) {
          threadRoot = currentId;
          break;
        }

        // Move up the chain - current email becomes potential root
        threadRoot = currentId;
        currentId = parentInReplyTo;
        depth++;
      }

      // Update this reply to point to the thread root
      await db.update(
        'emails',
        {'threadParentId': threadRoot},
        where: 'messageId = ? AND accountId = ?',
        whereArgs: [messageId, accountId],
      );
      fixed++;
    }

    print('✅ Threading rebuild complete. Fixed $fixed emails.');
  }

  Future<int> insertAccount(EmailAccount account) async {
    try {
      print('DEBUG: Inserting account ${account.username}');
      final db = await instance.database;
      const secureStorage = FlutterSecureStorage();
      await secureStorage.write(
          key: 'account_${account.username}_password', value: account.password);

      final accountData = {
        'imap': account.imap,
        'smtp': account.smtp,
        'username': account.username,
        'replyFrom': account.replyFrom,
        'name': account.name,
        'signature': account.signature,
        'color': '#${account.color.value.toRadixString(16).substring(2, 8)}',
        'display': account.display,
        'password': '',
        'caldav_base_url': account.caldavBaseUrl ?? '',
        'caldav_path': account.caldavPath ?? '',
        'caldav_confirmed_path': account.caldavConfirmedPath ?? '',
      };

      print('DEBUG: Account data to insert: ${accountData.keys.toList()}');
      final result = await db.insert('accounts', accountData);
      print('DEBUG: Account inserted successfully with ID: $result');
      return result;
    } catch (e) {
      print('ERROR: Failed to insert account ${account.username}: $e');
      rethrow;
    }
  }

  Future<int> updateAccount(EmailAccount account) async {
    try {
      print('DEBUG: Updating account ${account.username}');
      final db = await instance.database;
      const secureStorage = FlutterSecureStorage();
      
      // Update password in secure storage
      await secureStorage.write(
          key: 'account_${account.username}_password', 
          value: account.password);

      final accountData = {
        'imap': account.imap,
        'smtp': account.smtp,
        'replyFrom': account.replyFrom,
        'name': account.name,
        'signature': account.signature,
        'color': '#${account.color.value.toRadixString(16).substring(2, 8)}',
        'display': account.display,
        'caldav_base_url': account.caldavBaseUrl ?? '',
        'caldav_path': account.caldavPath ?? '',
        'caldav_confirmed_path': account.caldavConfirmedPath ?? '',
        // Note: username is not updated as it's the primary key
      };

      print('DEBUG: Account data to update: ${accountData.keys.toList()}');
      final result = await db.update(
        'accounts',
        accountData,
        where: 'username = ?',
        whereArgs: [account.username],
      );
      print('DEBUG: Account updated successfully, rows affected: $result');
      return result;
    } catch (e) {
      print('ERROR: Failed to update account ${account.username}: $e');
      rethrow;
    }
  }

  Future<int> deleteAccount(String username) async {
    final db = await instance.database;
    const secureStorage = FlutterSecureStorage();
    
    // Remove password from secure storage
    await secureStorage.delete(key: 'account_${username}_password');
    
    // Delete all emails for this account
    await db.delete(
      'emails',
      where: 'accountId = ?',
      whereArgs: [username],
    );
    
    // Delete all contacts for this account
    await db.delete(
      'contacts',
      where: 'accountId = ?',
      whereArgs: [username],
    );
    
    // Delete the account
    return await db.delete(
      'accounts',
      where: 'username = ?',
      whereArgs: [username],
    );
  }

  // Contact management methods
  Future<int> insertContact({
    required String name,
    required String email,
    required String accountId,
    String? workPhone,
    String? personalPhone,
    String? workAddress,
    String? personalAddress,
    String? company,
    String? jobTitle,
    String? notes,
    int frequency = 1,
    bool isManual = false,
  }) async {
    final db = await instance.database;
    
    final contactData = {
      'name': name,
      'email': email,
      'accountId': accountId,
      'workPhone': workPhone,
      'personalPhone': personalPhone,
      'workAddress': workAddress,
      'personalAddress': personalAddress,
      'company': company,
      'jobTitle': jobTitle,
      'notes': notes,
      'frequency': frequency,
      'lastUsed': DateTime.now().millisecondsSinceEpoch,
      'isManual': isManual ? 1 : 0,
    };
    
    try {
      return await db.insert('contacts', contactData);
    } catch (e) {
      // If contact already exists, update frequency and lastUsed
      if (e.toString().contains('UNIQUE constraint failed')) {
        return await db.update(
          'contacts',
          {
            'name': name,
            'workPhone': workPhone,
            'personalPhone': personalPhone,
            'workAddress': workAddress,
            'personalAddress': personalAddress,
            'company': company,
            'jobTitle': jobTitle,
            'notes': notes,
            'frequency': frequency + 1,
            'lastUsed': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'email = ? AND accountId = ?',
          whereArgs: [email, accountId],
        );
      }
      rethrow;
    }
  }

  Future<int> updateContact({
    required int id,
    required String name,
    required String email,
    required String accountId,
    String? workPhone,
    String? personalPhone,
    String? workAddress,
    String? personalAddress,
    String? company,
    String? jobTitle,
    String? notes,
  }) async {
    final db = await instance.database;
    
    return await db.update(
      'contacts',
      {
        'name': name,
        'email': email,
        'accountId': accountId,
        'workPhone': workPhone,
        'personalPhone': personalPhone,
        'workAddress': workAddress,
        'personalAddress': personalAddress,
        'company': company,
        'jobTitle': jobTitle,
        'notes': notes,
        'lastUsed': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteContact(int id) async {
    final db = await instance.database;
    
    return await db.delete(
      'contacts',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> getContacts({
    String? accountId,
    String? searchQuery,
    int? limit,
  }) async {
    final db = await instance.database;
    
    String whereClause = '';
    List<dynamic> whereArgs = [];
    
    if (accountId != null) {
      whereClause = 'accountId = ?';
      whereArgs.add(accountId);
    }
    
    if (searchQuery != null && searchQuery.isNotEmpty) {
      if (whereClause.isNotEmpty) {
        whereClause += ' AND ';
      }
      whereClause += '(name LIKE ? OR email LIKE ? OR company LIKE ? OR jobTitle LIKE ? OR workPhone LIKE ? OR personalPhone LIKE ?)';
      whereArgs.addAll(['%$searchQuery%', '%$searchQuery%', '%$searchQuery%', '%$searchQuery%', '%$searchQuery%', '%$searchQuery%']);
    }
    
    return await db.query(
      'contacts',
      where: whereClause.isEmpty ? null : whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'frequency DESC, lastUsed DESC',
      limit: limit,
    );
  }

  Future<void> addContactFromEmail({
    required String senderName,
    required String senderEmail,
    required String accountId,
  }) async {
    // Only add if email is valid and not empty
    if (senderEmail.isEmpty || !senderEmail.contains('@')) return;
    
    // Skip common automated email addresses
    final automatedPatterns = [
      'noreply',
      'no-reply',
      'donotreply',
      'do-not-reply',
      'support',
      'help',
      'admin',
      'system',
      'daemon',
      'mailer'
    ];
    
    final emailLower = senderEmail.toLowerCase();
    if (automatedPatterns.any((pattern) => emailLower.contains(pattern))) {
      return;
    }
    
    await insertContact(
      name: senderName.isNotEmpty ? senderName : senderEmail,
      email: senderEmail,
      accountId: accountId,
      frequency: 1,
      isManual: false,
    );
  }

  // User settings management methods
  Future<void> setSetting(String key, String value) async {
    final db = await instance.database;
    
    await db.insert(
      'user_settings',
      {
        'settingKey': key,
        'settingValue': value,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getSetting(String key) async {
    final db = await instance.database;
    
    final result = await db.query(
      'user_settings',
      where: 'settingKey = ?',
      whereArgs: [key],
      limit: 1,
    );
    
    if (result.isNotEmpty) {
      return result.first['settingValue'] as String?;
    }
    return null;
  }

  Future<void> deleteSetting(String key) async {
    final db = await instance.database;
    
    await db.delete(
      'user_settings',
      where: 'settingKey = ?',
      whereArgs: [key],
    );
  }

  Future<List<Map<String, dynamic>>> getEmails({
    String? searchQuery,
    int? limit,
    int? offset,
    EmailFilter? filter,
  }) async {
    final db = await instance.database;

    String whereClause;
    List<dynamic> whereArgs = [];

    if (filter != null) {
      // Use filter system to generate WHERE clause
      whereClause = filter.generateWhereClause();
      whereArgs = filter.generateWhereArgs();
      
      // Check for SQL parameter mismatch
      final placeholderCount = whereClause.split('?').length - 1;
      
      if (placeholderCount != whereArgs.length) {
        print('WARNING: SQL parameter mismatch, falling back to simple query');
        whereClause = 'threadParentId = messageId';
        whereArgs = [];
        // Use filter's search query, not the parameter
        final filterSearchQuery = filter.searchQuery;
        if (filterSearchQuery.isNotEmpty) {
          whereClause += ' AND (subject LIKE ? OR sender LIKE ? OR content LIKE ?)';
          whereArgs.addAll(['%$filterSearchQuery%', '%$filterSearchQuery%', '%$filterSearchQuery%']);
          print('DEBUG: Added search query to fallback: $filterSearchQuery');
        }
      }
    } else {
      // Fallback to old search system
      whereClause = 'threadParentId = messageId';

      if (searchQuery != null && searchQuery.isNotEmpty) {
        whereClause += ' AND (subject LIKE ? OR sender LIKE ? OR content LIKE ?)';
        whereArgs.addAll(['%$searchQuery%', '%$searchQuery%', '%$searchQuery%']);
      }
    }

    // Query emails
    return db.query(
      'emails',
      where: whereClause,
      whereArgs: whereArgs.isEmpty ? null : whereArgs,
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
  }

  Future<List<Map<String, dynamic>>> getThreadEmails(
      String threadParentId) async {
    final db = await instance.database;
    print('DEBUG: getThreadEmails for threadParentId: $threadParentId');

    // Get the root email first
    final rootEmails = await db.query(
      'emails',
      where: 'messageId = ?',
      whereArgs: [threadParentId],
      limit: 1,
    );

    if (rootEmails.isEmpty) {
      print('DEBUG: Thread root not found for $threadParentId');
      return [];
    }

    final root = rootEmails.first;
    final accountId = root['accountId'] as String;
    final subject = root['subject'] as String;
    final cleanSubject = subject
        .replaceAll(RegExp(r'^(Re:|Fwd:|Fw:)\s*', caseSensitive: false), '')
        .trim();

    // Find all emails in the conversation by:
    // 1. Emails with matching threadParentId
    // 2. Emails that reply to any email in the thread (inReplyTo matching)
    // 3. Emails with the same cleaned subject from the same account
    final results = await db.query(
      'emails',
      where: '''
        accountId = ? AND (
          threadParentId = ? OR
          messageId = ? OR
          inReplyTo = ? OR
          (REPLACE(REPLACE(REPLACE(LOWER(subject), 're: ', ''), 'fwd: ', ''), 'fw: ', '') = ?)
        )
      ''',
      whereArgs: [
        accountId,
        threadParentId,
        threadParentId,
        threadParentId,
        cleanSubject.toLowerCase(),
      ],
      orderBy: 'timestamp ASC',
    );

    print('DEBUG: Found ${results.length} emails in thread (including root)');
    return results;
  }

  Future<bool> hasReplies(String threadParentId) async {
    final db = await instance.database;
    final result = await db.query(
      'emails',
      where: 'threadParentId = ? AND messageId != ?',
      whereArgs: [threadParentId, threadParentId],
      limit: 1,
    );
    print('DEBUG: hasReplies($threadParentId) = ${result.isNotEmpty}');
    return result.isNotEmpty;
  }

  Future<List<EmailAccount>> getAccounts() async {
    try {
      final db = await instance.database;
      
      // Check current database version
      final version = await db.getVersion();
      print('DEBUG: Current database version: $version');
      
      // Check accounts table structure
      final tableInfo = await db.rawQuery("PRAGMA table_info(accounts)");
      final columnNames = tableInfo.map((col) => col['name'] as String).toList();
      print('DEBUG: Accounts table columns: $columnNames');
      
      print('DEBUG: Querying accounts table...');
      final accountsData = await db.query('accounts');
      print('DEBUG: Found ${accountsData.length} accounts in database');
      const secureStorage = FlutterSecureStorage();
      List<EmailAccount> accounts = [];

      for (var accountData in accountsData) {
        print('DEBUG: Processing account data: ${accountData.keys.toList()}');
        final username = accountData['username'] as String;
        String password = '';
        try {
          password = await secureStorage.read(
                key: 'account_${username}_password',
              ) ??
              '';
        } catch (e) {
          print("Error retrieving password for $username: $e");
        }

        try {
          accounts.add(EmailAccount(
        imap: accountData['imap'] as String,
        smtp: accountData['smtp'] as String,
        username: username,
        password: password,
        replyFrom: accountData['replyFrom'] as String,
        name: accountData['name'] as String,
        signature: accountData['signature'] as String,
        color: Color(int.parse((accountData['color'] as String).substring(1, 7),
                radix: 16) +
            0xFF000000),
        display: accountData['display'] as String,
            caldavBaseUrl: accountData['caldav_base_url'] as String?,
            caldavPath: accountData['caldav_path'] as String?,
            caldavConfirmedPath: accountData['caldav_confirmed_path'] as String?,
          ));
        } catch (e) {
          print('ERROR: Failed to create EmailAccount for $username: $e');
          print('Account data: $accountData');
        }
      }
      return accounts;
    } catch (e) {
      print('ERROR: Failed to get accounts from database: $e');
      return [];
    }
  }

  // IMAP Folder Management Methods
  Future<List<String>> getImapFolders(EmailAccount account) async {
    try {
      final imapClient = ImapClient();
      await imapClient.connectToServer(account.imap, 993, isSecure: true);
      await imapClient.login(account.username, account.password);
      
      final mailboxes = await imapClient.listMailboxes();
      await imapClient.logout();
      
      // Extract folder names and filter out special system folders
      final folderNames = <String>[];
      for (final mailbox in mailboxes) {
        // Check if mailbox has noSelect flag (can't select messages from it)
        if (mailbox.flags.contains(r'\Noselect')) {
          continue; // Skip this mailbox
        }
        
        if (mailbox.name.isNotEmpty) {
          folderNames.add(mailbox.name);
        }
      }
      
      print('📁 Found ${folderNames.length} IMAP folders for ${account.username}: $folderNames');
      return folderNames;
    } catch (e) {
      print('Error fetching IMAP folders for ${account.username}: $e');
      return ['INBOX']; // Return at least INBOX as fallback
    }
  }

  Future<List<Map<String, dynamic>>> getEmailsFromImapFolder({
    required EmailAccount account,
    required String folderName,
    int limit = 50,
  }) async {
    try {
      final imapClient = ImapClient();
      await imapClient.connectToServer(account.imap, 993, isSecure: true);
      await imapClient.login(account.username, account.password);
      
      // Select the specific folder/mailbox
      final Mailbox mailbox;
      if (folderName.toUpperCase() == 'INBOX') {
        mailbox = await imapClient.selectInbox();
      } else {
        // For non-inbox folders, first get the list of mailboxes to find the right one
        final mailboxes = await imapClient.listMailboxes();
        final targetMailbox = mailboxes.firstWhere(
          (mb) => mb.name == folderName,
          orElse: () => throw Exception('Mailbox $folderName not found'),
        );
        mailbox = await imapClient.selectMailbox(targetMailbox);
      }
      
      final messageCount = mailbox.messagesExists;
      
      if (messageCount == 0) {
        await imapClient.logout();
        return [];
      }
      
      // Get the last 'limit' messages
      final startIndex = messageCount > limit ? messageCount - limit + 1 : 1;
      final sequence = MessageSequence.fromRange(
        startIndex,
        messageCount,
        isUidSequence: false,
      );
      
      final fetchResult = await imapClient.fetchMessages(
        sequence,
        '(BODY[] FLAGS)',
      );
      
      final emails = <Map<String, dynamic>>[];
      for (var message in fetchResult.messages) {
        // Process message similar to existing email processing logic
        final email = await processImapMessage(message, account, folderName);
        if (email != null) {
          emails.add(email);
        }
      }
      
      await imapClient.logout();
      return emails;
    } catch (e) {
      print('Error fetching emails from folder $folderName: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> processImapMessage(
    MimeMessage message,
    EmailAccount account,
    String folderName,
  ) async {
    try {
      final String messageId = message.guid?.toString() ??
          message.uid?.toString() ??
          'msg_${DateTime.now().millisecondsSinceEpoch}';

      // Check if email already exists
      final db = await instance.database;
      final existingEmails = await db.query(
        'emails',
        where: 'messageId = ? AND accountId = ?',
        whereArgs: [messageId, account.username],
      );

      if (existingEmails.isNotEmpty) {
        return null; // Email already exists
      }

      final subject = message.decodeSubject() ?? 'No Subject';
      
      String senderName = 'Unknown';
      String senderEmail = 'unknown@unknown.com';
      
      // First try to get sender from envelope.from (the actual sender)
      if (message.envelope?.from != null &&
          message.envelope!.from!.isNotEmpty) {
        var sender = message.envelope!.from![0];
        senderName = (sender.personalName?.isNotEmpty == true) ? sender.personalName! : sender.email;
        senderEmail = sender.email;
      }
      
      // If envelope.from is not available, try parsing the From header
      if (senderEmail == 'unknown@unknown.com') {
        final fromHeader = message.getHeaderValue('from');
        if (fromHeader?.isNotEmpty ?? false) {
          try {
            var from = MailAddress.parse(fromHeader!);
            senderName = (from.personalName?.isNotEmpty == true) ? from.personalName! : from.email;
            senderEmail = from.email;
          } catch (e) {
            print("Error parsing From header: $e");
          }
        }
      }
      
      // Final fallback: try message.from if available
      if (senderEmail == 'unknown@unknown.com' && message.from?.isNotEmpty == true) {
        final from = message.from!.first;
        senderName = from.personalName ?? from.email;
        senderEmail = from.email;
      }
      
      final timestamp = message.decodeDate()?.millisecondsSinceEpoch ?? 
          DateTime.now().millisecondsSinceEpoch;

      String content = message.decodeTextHtmlPart() ?? 
          message.decodeTextPlainPart() ?? '';

      // Parse IMAP flags
      final imapFlags = ImapFlagsHelper.parseImapFlags(message);

      // Process attachments (reuse existing logic)
      final attachments = <Map<String, dynamic>>[];
      int hasAttachments = 0;
      int hasImages = 0;

      // ... attachment processing logic would go here ...

      final emailData = {
        'messageId': messageId,
        'accountId': account.username,
        'subject': subject,
        'sender': senderName,
        'senderEmail': senderEmail,
        'timestamp': timestamp,
        'content': content,
        'isRead': imapFlags['isRead'] ?? 0,
        'isStarred': imapFlags['isStarred'] ?? 0,
        'isAnswered': imapFlags['isAnswered'] ?? 0,
        'isForwarded': imapFlags['isForwarded'] ?? 0,
        'isDraft': imapFlags['isDraft'] ?? 0,
        'isDeleted': imapFlags['isDeleted'] ?? 0,
        'isJunk': imapFlags['isJunk'] ?? 0,
        'folderPath': folderName,
        'imapFolder': folderName,
        'attachments': jsonEncode(attachments),
        'hasAttachments': hasAttachments,
        'hasImages': hasImages,
        'rawEmail': message.mimeData ?? '',
      };

      await insertEmail(emailData);
      return emailData;
    } catch (e) {
      print('Error processing IMAP message: $e');
      return null;
    }
  }

  // IMAP Folder Management Operations
  
  /// Create a new IMAP folder on the server
  /// Note: Folder creation may not be supported by all IMAP servers
  Future<bool> createImapFolder(EmailAccount account, String folderName) async {
    try {
      final imapClient = ImapClient();
      await imapClient.connectToServer(account.imap, 993, isSecure: true);
      await imapClient.login(account.username, account.password);
      
      // Note: createMailbox API may require a Mailbox object in some versions
      // For now, attempt creation and handle gracefully if not supported
      try {
        await imapClient.createMailbox(folderName);
        print('✅ Created IMAP folder: $folderName for ${account.username}');
      } catch (createError) {
        print('❌ Folder creation not supported or failed: $createError');
        await imapClient.logout();
        return false;
      }
      
      await imapClient.logout();
      return true;
    } catch (e) {
      print('❌ Error creating IMAP folder $folderName for ${account.username}: $e');
      return false;
    }
  }

  /// Rename an existing IMAP folder on the server
  /// Note: Folder renaming is not supported by the enough_mail library
  Future<bool> renameImapFolder(EmailAccount account, String oldName, String newName) async {
    print('❌ IMAP folder renaming not supported by enough_mail library');
    return false;
  }

  /// Delete an IMAP folder from the server
  /// Note: Folder deletion is not supported by the enough_mail library
  Future<bool> deleteImapFolder(EmailAccount account, String folderName) async {
    print('❌ IMAP folder deletion not supported by enough_mail library');
    return false;
  }

  /// Move an email to a different IMAP folder
  /// Note: Email moving is not supported by the enough_mail library
  Future<bool> moveEmailToImapFolder({
    required EmailAccount account,
    required String messageId,
    required String targetFolder,
  }) async {
    print('❌ IMAP email moving not supported by enough_mail library');
    
    // For now, just update the local database
    try {
      final db = await instance.database;
      final result = await db.update(
        'emails',
        {'imapFolder': targetFolder},
        where: 'messageId = ? AND accountId = ?',
        whereArgs: [messageId, account.username],
      );
      
      if (result > 0) {
        print('✅ Updated local folder assignment for email $messageId to: $targetFolder');
        return true;
      } else {
        print('❌ Email not found in local database: $messageId');
        return false;
      }
    } catch (e) {
      print('❌ Error updating local folder assignment: $e');
      return false;
    }
  }

  /// Subscribe to an IMAP folder (makes it visible in folder list)
  /// Note: Folder subscription is not supported by the enough_mail library
  Future<bool> subscribeToImapFolder(EmailAccount account, String folderName) async {
    print('❌ IMAP folder subscription not supported by enough_mail library');
    return false;
  }

  /// Unsubscribe from an IMAP folder (hides it from folder list)
  /// Note: Folder subscription is not supported by the enough_mail library
  Future<bool> unsubscribeFromImapFolder(EmailAccount account, String folderName) async {
    print('❌ IMAP folder subscription not supported by enough_mail library');
    return false;
  }

  // Store IMAP folders in database
  Future<void> storeImapFolders(EmailAccount account, List<Mailbox> mailboxes) async {
    final db = await database;
    
    try {
      await db.transaction((txn) async {
        // Clear existing folders for this account
        await txn.delete('imap_folders', where: 'accountId = ?', whereArgs: [account.username]);
        
        // Insert all folders
        for (final mailbox in mailboxes) {
          await txn.insert('imap_folders', {
            'accountId': account.username,
            'folderName': mailbox.name,
            'folderPath': mailbox.name,
            'parentFolder': mailbox.name.contains(mailbox.pathSeparator) 
                ? mailbox.name.substring(0, mailbox.name.lastIndexOf(mailbox.pathSeparator))
                : null,
            'isSelectable': mailbox.flags.contains(r'\Noselect') ? 0 : 1,
            'hasChildren': mailbox.flags.contains(r'\HasChildren') ? 1 : 0,
            'lastSynced': DateTime.now().millisecondsSinceEpoch,
          });
        }
      });
      
      print('📁 Stored ${mailboxes.length} IMAP folders for ${account.username}');
    } catch (e) {
      print('Error storing IMAP folders for ${account.username}: $e');
    }
  }

  // Get cached IMAP folders from database
  Future<List<Map<String, dynamic>>> getCachedImapFolders(String accountId) async {
    final db = await database;
    return await db.query(
      'imap_folders',
      where: 'accountId = ?',
      whereArgs: [accountId],
      orderBy: 'folderPath ASC',
    );
  }

  // Get all unique folder paths from database
  Future<List<String>> getAllCachedFolderPaths() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT DISTINCT folderPath 
      FROM imap_folders 
      WHERE isSelectable = 1
      ORDER BY folderPath ASC
    ''');
    return result.map((row) => row['folderPath'] as String).toList();
  }

  // Android-specific method to check if more emails should be fetched
  Future<bool> shouldFetchMoreEmails({
    required String accountId,
    required String folderPath,
    int maxEmailsInFolder = 500,
  }) async {
    try {
      final db = await database;
      
      // Count current emails in this folder
      final result = await db.rawQuery('''
        SELECT COUNT(*) as email_count 
        FROM emails 
        WHERE accountId = ? AND folderPath = ?
      ''', [accountId, folderPath]);
      
      final currentEmailCount = result.first['email_count'] as int;
      print('Current email count in $folderPath: $currentEmailCount');
      
      // On Android, limit folder size to prevent cursor window issues
      if (Platform.isAndroid && currentEmailCount >= maxEmailsInFolder) {
        print('Skipping fetch - Android folder limit reached ($maxEmailsInFolder)');
        return false;
      }
      
      return true;
    } catch (e) {
      print('Error checking shouldFetchMoreEmails: $e');
      return true; // Default to allowing fetch
    }
  }

  // Android cursor window cleanup - call this when cursor window errors occur
  Future<void> emergencyCleanupOversizedContent() async {
    if (!Platform.isAndroid) return;
    
    try {
      final db = await database;
      print('🚨 EMERGENCY: Cleaning up oversized content for Android cursor window');
      
      // Step 1: Truncate very large content fields
      await db.execute('''
        UPDATE emails 
        SET content = SUBSTR(content, 1, 500000) 
        WHERE LENGTH(content) > 500000
      ''');
      
      // Step 2: Truncate large attachment metadata
      await db.execute('''
        UPDATE emails 
        SET attachments = SUBSTR(attachments, 1, 100000) 
        WHERE LENGTH(attachments) > 100000
      ''');
      
      // Step 3: Truncate large raw email content
      await db.execute('''
        UPDATE emails 
        SET rawEmail = SUBSTR(rawEmail, 1, 750000) 
        WHERE LENGTH(rawEmail) > 750000
      ''');
      
      // Step 4: Remove extremely problematic emails (over 2MB total)
      await db.execute('''
        DELETE FROM emails 
        WHERE LENGTH(content) + LENGTH(IFNULL(attachments, '')) + LENGTH(IFNULL(rawEmail, '')) > 2000000
      ''');
      
      print('✅ Emergency cleanup completed');
    } catch (e) {
      print('❌ Emergency cleanup failed: $e');
    }
  }

  // Fetch body for a single email on-demand (when user opens it)
  static Future<String?> fetchSingleEmailBody({
    required EmailAccount account,
    required String folderPath,
    required int uid,
    required String messageId,
  }) async {
    print('📥 Fetching body for: folder=$folderPath, messageId=${messageId.substring(0, min(30, messageId.length))}...');
    
    try {
      // Create IMAP connection
      final imapClient = ImapClient();
      await imapClient.connectToServer(account.imap, 993, isSecure: true);
      await imapClient.login(account.username, account.password);
      
      // Select folder
      if (folderPath.toUpperCase() == 'INBOX') {
        await imapClient.selectInbox();
      } else {
        final mailboxes = await imapClient.listMailboxes();
        final targetMailbox = mailboxes.firstWhere((mb) => mb.name == folderPath);
        await imapClient.selectMailbox(targetMailbox);
      }
      
      // Fetch all headers in folder to find the correct UID for this Message-ID
      print('🔍 Searching for Message-ID in folder...');
      
      // For now, fetch all headers (will optimize with SEARCH later if needed)
      // This is the safest way to ensure we find the correct message
      final headerResult = await imapClient.fetchMessages(
        MessageSequence.fromAll(),
        '(UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])',
      );
      
      int foundUid = 0;
      for (final msg in headerResult.messages) {
        final fetchedMessageId = msg.decodeHeaderValue('message-id') ?? msg.guid;
        final fetchedIdStr = fetchedMessageId?.toString() ?? '';
        
        // Compare Message-IDs (strip angle brackets if needed)
        String cleanStoredId = messageId.replaceAll(RegExp(r'^<|>$'), '');
        String cleanFetchedId = fetchedIdStr.replaceAll(RegExp(r'^<|>$'), '');
        
        if (cleanFetchedId.isNotEmpty && cleanFetchedId == cleanStoredId) {
          foundUid = msg.uid ?? 0;
          print('✅ Found Message-ID at UID $foundUid');
          print('   Stored: $messageId');
          print('   Fetched: $fetchedIdStr');
          break;
        }
      }

      if (foundUid == 0) {
        print('❌ No message found with Message-ID: $messageId in folder $folderPath');
        print('   Searched ${headerResult.messages.length} messages');
        await imapClient.logout();
        // Mark as deleted in DB
        final db = await instance.database;
        await db.update(
          'emails',
          {'bodyFetched': -1, 'content': '[This message has been deleted from the server]'},
          where: 'messageId = ?',
          whereArgs: [messageId],
        );
        return '[This message has been deleted from the server]';
      }

      // Fetch body by found UID
      final sequence = MessageSequence.fromId(foundUid, isUid: true);
      final fetchResult = await imapClient.uidFetchMessages(sequence, '(BODY.PEEK[])');
      
      if (fetchResult.messages.isEmpty) {
        print('❌ No message found with UID $foundUid in folder $folderPath');
        await imapClient.logout();
        return null;
      }
      
      final message = fetchResult.messages.first;
      
      // VERIFY: Check if the subject from server matches what we expected
      final db = await instance.database;
      final expectedEmailResult = await db.query(
        'emails',
        columns: ['subject'],
        where: 'messageId = ? AND accountId = ? AND folderPath = ?',
        whereArgs: [messageId, account.username, folderPath],
        limit: 1,
      );
      final expectedSubject = expectedEmailResult.isNotEmpty ? expectedEmailResult.first['subject'] as String : 'NOT FOUND';
      
      final fetchedSubject = message.decodeSubject() ?? message.decodeHeaderValue('subject') ?? 'Unknown';
      print('🔍 VERIFICATION:');
      print('   Expected Subject (from DB): ${expectedSubject.substring(0, min(60, expectedSubject.length))}');
      print('   Fetched Subject (from Server): ${fetchedSubject.substring(0, min(60, fetchedSubject.length))}');
      if (expectedSubject != fetchedSubject) {
        print('   ❌ MISMATCH! Server has different subject than database!');
      } else {
        print('   ✅ MATCH!');
      }
      
      // Get HTML or text content
      String htmlContent = message.decodeTextHtmlPart() ?? '';
      String textContent = message.decodeTextPlainPart() ?? '';
      String content = htmlContent.isNotEmpty ? htmlContent : textContent;
      if (content.isEmpty) content = 'No content available';
      
      // DEBUG: Show what content we're about to store
      print('📄 Fetched body for UID $foundUid (MessageID: ${messageId.substring(0, min(40, messageId.length))}):');
      print('   Content preview: ${content.substring(0, min(150, content.length))}...');
      
      // Truncate if needed
      const maxContentSize = 500000;
      if (Platform.isAndroid && content.length > maxContentSize) {
        content = content.substring(0, maxContentSize) + 
            '\n\n[Content truncated for Android compatibility]';
      }
      
      String rawEmail = message.toString();
      const maxRawSize = 750000;
      if (Platform.isAndroid && rawEmail.length > maxRawSize) {
        rawEmail = rawEmail.substring(0, maxRawSize);
      }
      
      // Update database - CRITICAL: Include folderPath to avoid updating duplicates in other folders
      final dbUpdate = await instance.database;
      await dbUpdate.update(
        'emails',
        {
          'content': content,
          'bodyFetched': 1,
          'rawEmail': rawEmail,
        },
        where: 'messageId = ? AND accountId = ? AND folderPath = ?',
        whereArgs: [messageId, account.username, folderPath],
      );
      
      await imapClient.logout();
      
      print('✅ Fetched body on-demand for email: ${messageId.substring(0, min(20, messageId.length))} in folder $folderPath');
      
      return content;
      
    } catch (e) {
      final truncated = e.toString().length > 100 ? '${e.toString().substring(0, 100)}...' : e.toString();
      print('❌ Failed to fetch email body: $truncated');
      return null;
    }
  }
  
  /// Get the last synced UID for a specific account and folder
  Future<int> getLastSyncedUid(String accountId, String folderPath) async {
    try {
      final db = await database;
      final result = await db.query(
        'imap_sync_state',
        columns: ['lastFetchedUid'],
        where: 'accountId = ? AND folderPath = ?',
        whereArgs: [accountId, folderPath],
        limit: 1,
      );
      
      if (result.isEmpty) {
        return 0;
      }
      
      return result.first['lastFetchedUid'] as int? ?? 0;
    } catch (e) {
      print('Error getting last synced UID: $e');
      return 0;
    }
  }
  
  /// Update the last synced UID for a specific account and folder
  Future<void> updateLastSyncedUid(String accountId, String folderPath, int uid, int totalMessages) async {
    try {
      final db = await database;
      final now = DateTime.now().millisecondsSinceEpoch;
      
      await db.insert(
        'imap_sync_state',
        {
          'accountId': accountId,
          'folderPath': folderPath,
          'lastFetchedUid': uid,
          'lastSyncTime': now,
          'totalMessages': totalMessages,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      
      print('✅ Updated last synced UID for $accountId/$folderPath: $uid (total: $totalMessages)');
    } catch (e) {
      print('Error updating last synced UID: $e');
    }
  }
  
  /// Get sync state for all folders of an account
  Future<Map<String, int>> getAllLastSyncedUids(String accountId) async {
    try {
      final db = await database;
      final result = await db.query(
        'imap_sync_state',
        where: 'accountId = ?',
        whereArgs: [accountId],
      );
      
      final Map<String, int> uidMap = {};
      for (var row in result) {
        final folderPath = row['folderPath'] as String;
        final uid = row['lastFetchedUid'] as int? ?? 0;
        uidMap[folderPath] = uid;
      }
      
      return uidMap;
    } catch (e) {
      print('Error getting all synced UIDs: $e');
      return {};
    }
  }
}

class HtmlStyleFilter {
  static const String _configFileName = 'html_style_filter.json';
  static final Set<String> _defaultUnsupportedAttributes = {
    'minWidth',
    'maxWidth',
  };

  static Future<String> _getConfigFilePath() async {
    final dbPath = await getDatabasesPath();
    return '$dbPath/$_configFileName';
  }

  static Future<Set<String>> loadUnsupportedAttributes() async {
    try {
      final filePath = await _getConfigFilePath();
      final file = File(filePath);
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final List<dynamic> attributes = jsonDecode(jsonString);
        return attributes.map((attr) => attr.toString()).toSet();
      } else {
        await file
            .writeAsString(jsonEncode(_defaultUnsupportedAttributes.toList()));
        return _defaultUnsupportedAttributes;
      }
    } catch (e) {
      print('Error loading HTML style filter config: $e');
      return _defaultUnsupportedAttributes;
    }
  }
}

// View modes for the main screen
enum ViewMode {
  mail,
  calendar,
  people,
}

class EmailListScreen extends StatefulWidget {
  const EmailListScreen({Key? key}) : super(key: key);

  @override
  _EmailListScreenState createState() => _EmailListScreenState();
}

class _EmailListScreenState extends State<EmailListScreen> {
  // Import accounts from a JSON file and store passwords securely

  List<Map<String, dynamic>> _emails = [];
  List<EmailAccount> _accounts = [];
  bool _isLoading = true;
  bool _isSyncing = false;
  final TextEditingController _searchController = TextEditingController();

  final ScrollController _scrollController = ScrollController();
  int _offset = 0;
  final int _limit = 50;
  bool _isLoadingMore = false;
  bool _alwaysShowText = false; // Setting for text display
  bool _debugMode = true; // Debug logging toggle - TEMPORARILY ENABLED FOR DATE DEBUGGING
  
  // Android Debug Tracking
  String _debugCurrentAccount = '';
  String _debugCurrentFolder = '';
  int _debugCurrentBatch = 0;
  int _debugTotalBatches = 0;
  int _debugEmailsProcessed = 0;
  String _debugLastError = '';
  DateTime? _debugLastActivity;
  bool _showDebugOverlay = false;
  
  // View mode management
  ViewMode _currentView = ViewMode.mail;
  
  // Threading state management
  Set<String> _expandedThreads = <String>{};
  Map<String, List<Map<String, dynamic>>> _threadCache = {};
  Map<String, bool> _threadRepliesStatus = {}; // Cache for thread replies status

  // Cache limits to prevent unbounded memory growth
  static const int _maxThreadCacheSize = 100;
  static const int _maxRepliesStatusCacheSize = 500;
  static const int _maxTimestampCacheSize = 500;

  /// Enforce cache size limits by removing oldest entries when limit exceeded
  void _enforceThreadCacheLimits() {
    // Limit thread cache (keeps most recently used threads)
    if (_threadCache.length > _maxThreadCacheSize) {
      final keysToRemove = _threadCache.keys.take(_threadCache.length - _maxThreadCacheSize).toList();
      for (final key in keysToRemove) {
        _threadCache.remove(key);
      }
    }

    // Limit replies status cache
    if (_threadRepliesStatus.length > _maxRepliesStatusCacheSize) {
      final keysToRemove = _threadRepliesStatus.keys.take(_threadRepliesStatus.length - _maxRepliesStatusCacheSize).toList();
      for (final key in keysToRemove) {
        _threadRepliesStatus.remove(key);
      }
    }

    // Limit timestamp cache
    if (_threadLatestTimestamps.length > _maxTimestampCacheSize) {
      final keysToRemove = _threadLatestTimestamps.keys.take(_threadLatestTimestamps.length - _maxTimestampCacheSize).toList();
      for (final key in keysToRemove) {
        _threadLatestTimestamps.remove(key);
      }
    }
  }
  
  // Selection mode state management
  bool _isSelectionMode = false;
  Set<String> _selectedEmailIds = <String>{};
  
  // Email polling
  Timer? _emailPollTimer;
  static const Duration _pollInterval = Duration(minutes: 1); // Check every 1 minute for faster updates

  @override
  void initState() {
    super.initState();
    _loadSettings(); // Load saved settings
    _initializeApp();
    _scrollController.addListener(_scrollListener);
    
    // Initialize filter system
    FilterManager.instance.filterNotifier.addListener(_onFilterChanged);
    
    // Initialize search controller with current filter search query
    _searchController.text = FilterManager.instance.currentFilter.searchQuery;
    
    // Test mbox processing
    _processMboxFile('image test.mbox');
    
    // Start automatic email sync (polls every 1 minute)
    _startEmailPolling();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener);
    _scrollController.dispose();
    _searchController.dispose();
    
    // Stop email polling
    _emailPollTimer?.cancel();
    
    // Remove filter listener
    FilterManager.instance.filterNotifier.removeListener(_onFilterChanged);
    
    super.dispose();
  }

  // Handle filter changes
  void _onFilterChanged() {
    // Sync search controller with filter system (avoid triggering onChanged)
    final currentFilter = FilterManager.instance.currentFilter;
    if (_searchController.text != currentFilter.searchQuery) {
      _searchController.text = currentFilter.searchQuery;
    }
    
    setState(() {
      _offset = 0;
      _emails = [];
    });
    _loadEmailsFromDb();
  }

  String _buildFilterStatusText(EmailFilter filter) {
    final List<String> parts = [];
    
    if (filter.enabledAccounts.isNotEmpty) {
      parts.add('${filter.enabledAccounts.length} account${filter.enabledAccounts.length > 1 ? 's' : ''}');
    }
    
    if (filter.enabledAccountFolders.isNotEmpty) {
      parts.add('${filter.enabledAccountFolders.length} specific folder${filter.enabledAccountFolders.length > 1 ? 's' : ''}');
    }
    
    if (filter.searchQuery.isNotEmpty) {
      parts.add('"${filter.searchQuery}"');
    }
    
    if (parts.isEmpty) {
      return 'Showing all emails from all folders';
    }
    
    return 'Filtered by: ${parts.join(' • ')}';
  }

  Future<void> _loadSettings() async {
    const secureStorage = FlutterSecureStorage();
    String? textValue = await secureStorage.read(key: 'alwaysShowText');
    String? debugValue = await secureStorage.read(key: 'debugMode');
    setState(() {
      _alwaysShowText = textValue == 'true';
      _debugMode = debugValue == 'true';
    });
    if (_debugMode) print('Text-only: $_alwaysShowText, Debug: $_debugMode');
  }

  Future<void> _saveSettings() async {
    const secureStorage = FlutterSecureStorage();
    await secureStorage.write(
        key: 'alwaysShowText', value: _alwaysShowText.toString());
    await secureStorage.write(
        key: 'debugMode', value: _debugMode.toString());
    if (_debugMode) print('Saved settings - Text-only: $_alwaysShowText, Debug: $_debugMode');
  }

  // Selection mode management methods
  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedEmailIds.clear();
      }
    });
  }

  void _toggleEmailSelection(String emailId) {
    setState(() {
      if (_selectedEmailIds.contains(emailId)) {
        _selectedEmailIds.remove(emailId);
        // Exit selection mode if no emails are selected
        if (_selectedEmailIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedEmailIds.add(emailId);
        // Enter selection mode if not already in it
        if (!_isSelectionMode) {
          _isSelectionMode = true;
        }
      }
    });
  }

  void _selectAllEmails() {
    setState(() {
      _selectedEmailIds.clear();
      for (var email in _emails) {
        _selectedEmailIds.add(email['id'].toString());
      }
      _isSelectionMode = true;
    });
  }

  void _deselectAllEmails() {
    setState(() {
      _selectedEmailIds.clear();
      _isSelectionMode = false;
    });
  }

  // AppBar builders
  AppBar _buildNormalAppBar() {
    return AppBar(
      leading: Builder(
        builder: (context) => IconButton(
          icon: const FilterIcon(color: Colors.white, size: 20.0),
          onPressed: () => Scaffold.of(context).openDrawer(),
          tooltip: 'Open Filters',
        ),
      ),
      title: Row(
        children: [
          const Text('fMail'),
          const SizedBox(width: 16),
          Expanded(
            child: Container(
              height: 36,
              child: TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Search emails...',
                  hintStyle: TextStyle(color: Colors.grey.shade300),
                  prefixIcon: Icon(Icons.search, color: Colors.grey.shade300, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, color: Colors.grey.shade300, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            final currentFilter = FilterManager.instance.currentFilter;
                            FilterManager.instance.updateFilter(
                              currentFilter.copyWith(searchQuery: ''),
                            );
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade700,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                ),
                onChanged: (query) {
                  final currentFilter = FilterManager.instance.currentFilter;
                  FilterManager.instance.updateFilter(
                    currentFilter.copyWith(searchQuery: query),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      backgroundColor: Colors.grey.shade800,
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          icon: Icon(_alwaysShowText ? Icons.text_fields : Icons.web),
          onPressed: () {
            setState(() {
              _alwaysShowText = !_alwaysShowText;
            });
            _saveSettings();
          },
          tooltip: _alwaysShowText ? 'Show Rich Content' : 'Show Text Only',
        ),
        // Sync indicator when background downloading is active
        if (_isSyncing)
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  'Syncing...',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.9),
                  ),
                ),
              ],
            ),
          ),
        IconButton(
          icon: Icon(_debugMode ? Icons.bug_report : Icons.bug_report_outlined),
          onPressed: () {
            setState(() {
              _debugMode = !_debugMode;
              // Reset debug state when toggling
              if (!_debugMode) {
                _debugCurrentAccount = '';
                _debugCurrentFolder = '';
                _debugCurrentBatch = 0;
                _debugTotalBatches = 0;
                _debugEmailsProcessed = 0;
                _debugLastError = '';
                _debugLastActivity = null;
              }
            });
            _saveSettings();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_debugMode 
                  ? 'Debug mode enabled - Android sync tracking active' 
                  : 'Debug mode disabled'),
                duration: const Duration(seconds: 3),
              ),
            );
          },
          tooltip: _debugMode ? 'Disable Android Debug Tracking' : 'Enable Android Debug Tracking',
        ),
        PopupMenuButton<String>(
          onSelected: (value) async {
            switch (value) {
              case 'add_account':
                _showAccountAddDialog();
                break;
              case 'manage_accounts':
                _showAccountManagementScreen();
                break;
              case 'import_accounts':
                _importAccounts();
                break;
              case 'export_accounts':
                _exportAccounts();
                break;
              case 'refresh':
                _refreshEmails();
                break;
              case 'rebuild_threading':
                await _rebuildThreading();
                break;
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'add_account',
              child: Text('Add Account'),
            ),
            const PopupMenuItem(
              value: 'manage_accounts',
              child: Text('Manage Accounts'),
            ),
            const PopupMenuItem(
              value: 'import_accounts',
              child: Text('Import Accounts'),
            ),
            const PopupMenuItem(
              value: 'export_accounts',
              child: Text('Export Accounts'),
            ),
            PopupMenuItem(
              value: 'refresh',
              child: Row(
                children: [
                  Icon(_isSyncing ? Icons.sync : Icons.sync, size: 18),
                  const SizedBox(width: 8),
                  Text(_isSyncing ? 'Syncing...' : 'Sync Emails'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'rebuild_threading',
              child: Row(
                children: [
                  Icon(Icons.auto_fix_high, size: 18),
                  SizedBox(width: 8),
                  Text('Rebuild Threading'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  AppBar _buildSelectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _deselectAllEmails,
        tooltip: 'Exit Selection',
      ),
      title: Text('${_selectedEmailIds.length} selected'),
      backgroundColor: Colors.blue.shade700,
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          onPressed: _selectedEmailIds.length == _emails.length ? _deselectAllEmails : _selectAllEmails,
          tooltip: _selectedEmailIds.length == _emails.length ? 'Deselect All' : 'Select All',
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          onPressed: _selectedEmailIds.isNotEmpty ? () => _showDeleteConfirmation() : null,
          tooltip: 'Delete Selected',
        ),
        IconButton(
          icon: const Icon(Icons.drive_file_move),
          onPressed: _selectedEmailIds.isNotEmpty ? () => _showMoveDialog() : null,
          tooltip: 'Move Selected',
        ),
      ],
    );
  }

  // Delete confirmation and bulk operations
  Future<void> _showDeleteConfirmation() async {
    final count = _selectedEmailIds.length;
    
    // Check if any selected emails are already in Trash
    final db = await DatabaseHelper.instance.database;
    final emailIds = _selectedEmailIds.toList();
    final emails = <Map<String, dynamic>>[];
    
    for (final emailId in emailIds) {
      final result = await db.query(
        'emails',
        where: 'id = ?',
        whereArgs: [emailId],
      );
      if (result.isNotEmpty) {
        emails.add(result.first);
      }
    }
    
    final trashEmails = emails.where((email) => 
      email['folderPath']?.toString().toLowerCase() == 'trash' ||
      email['folderPath']?.toString().toLowerCase() == 'deleted items'
    ).toList();
    
    final nonTrashEmails = emails.where((email) => 
      email['folderPath']?.toString().toLowerCase() != 'trash' &&
      email['folderPath']?.toString().toLowerCase() != 'deleted items'
    ).toList();
    
    String title;
    String content;
    
    if (trashEmails.isNotEmpty && nonTrashEmails.isEmpty) {
      // All emails are in Trash - permanent deletion
      title = 'Permanent Deletion';
      content = count == 1 
        ? 'This email is in Trash. Are you sure you want to permanently delete it?\n\nThis action cannot be undone.'
        : '$count emails are in Trash. Are you sure you want to permanently delete them?\n\nThis action cannot be undone.';
    } else if (trashEmails.isEmpty && nonTrashEmails.isNotEmpty) {
      // All emails are not in Trash - move to Trash
      title = 'Move to Trash';
      content = count == 1 
        ? 'Move this email to Trash?'
        : 'Move $count emails to Trash?';
    } else {
      // Mixed - some in Trash, some not
      title = 'Delete Emails';
      content = '${nonTrashEmails.length} email${nonTrashEmails.length > 1 ? 's' : ''} will be moved to Trash.\n'
                '${trashEmails.length} email${trashEmails.length > 1 ? 's' : ''} will be permanently deleted.\n\n'
                'Permanent deletion cannot be undone. Continue?';
    }
    
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: Text(trashEmails.isNotEmpty ? 'Delete' : 'Move to Trash'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      await _deleteSelectedEmails();
    }
  }

  Future<void> _deleteSelectedEmails() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final emailIds = _selectedEmailIds.toList();
      
      // Get the email details to check if they're already in Trash
      final emails = <Map<String, dynamic>>[];
      for (final emailId in emailIds) {
        final result = await db.query(
          'emails',
          where: 'id = ?',
          whereArgs: [emailId],
        );
        if (result.isNotEmpty) {
          emails.add(result.first);
        }
      }
      
      if (emails.isEmpty) return;
      
      // Check if any emails are already in Trash folder
      final trashEmails = emails.where((email) => 
        email['folderPath']?.toString().toLowerCase() == 'trash' ||
        email['folderPath']?.toString().toLowerCase() == 'deleted items'
      ).toList();
      
      final nonTrashEmails = emails.where((email) => 
        email['folderPath']?.toString().toLowerCase() != 'trash' &&
        email['folderPath']?.toString().toLowerCase() != 'deleted items'
      ).toList();
      
      // If any emails are in Trash, show permanent deletion confirmation
      if (trashEmails.isNotEmpty) {
        final shouldPermanentlyDelete = await _showPermanentDeleteConfirmation(trashEmails.length);
        if (!shouldPermanentlyDelete) return;
        
        // Permanently delete emails from Trash
        await _permanentlyDeleteEmails(trashEmails);
      }
      
      // Move non-Trash emails to Trash
      if (nonTrashEmails.isNotEmpty) {
        await _moveEmailsToTrash(nonTrashEmails);
      }
      
      // Update UI state
      setState(() {
        _emails.removeWhere((email) => emailIds.contains(email['id'].toString()));
        _selectedEmailIds.clear();
        _isSelectionMode = false;
      });
      
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error processing delete operation: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<bool> _showPermanentDeleteConfirmation(int count) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Permanent Deletion'),
          content: Text(
            'Are you sure you want to permanently delete $count email${count > 1 ? 's' : ''}?\n\n'
            'This action cannot be undone. The email${count > 1 ? 's' : ''} will be removed from both '
            'your device and the email server.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Permanently Delete', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _moveEmailsToTrash(List<Map<String, dynamic>> emails) async {
    try {
      final db = await DatabaseHelper.instance.database;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moving ${emails.length} email${emails.length > 1 ? 's' : ''} to Trash...'),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      // Group emails by account for IMAP operations
      final emailsByAccount = <String, List<Map<String, dynamic>>>{};
      for (final email in emails) {
        final accountId = email['accountId'] as String;
        emailsByAccount.putIfAbsent(accountId, () => []).add(email);
      }

      // Move emails on IMAP server and update database
      for (final accountId in emailsByAccount.keys) {
        final account = _accounts.firstWhere(
          (acc) => acc.username == accountId,
          orElse: () => throw Exception('Account not found: $accountId'),
        );
        
        final accountEmails = emailsByAccount[accountId]!;
        
        // Try to move emails on IMAP server
        try {
          await _moveEmailsOnImapServer(account, accountEmails, 'Trash');
        } catch (e) {
          print('Warning: Could not move emails on IMAP server: $e');
          // Continue with local move even if IMAP fails
        }
        
        // Update local database
        for (final email in accountEmails) {
          await db.update(
            'emails',
            {'folderPath': 'Trash'},
            where: 'id = ?',
            whereArgs: [email['id']],
          );
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved ${emails.length} email${emails.length > 1 ? 's' : ''} to Trash'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      print('Error moving emails to trash: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error moving emails to Trash: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _permanentlyDeleteEmails(List<Map<String, dynamic>> emails) async {
    try {
      final db = await DatabaseHelper.instance.database;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Permanently deleting ${emails.length} email${emails.length > 1 ? 's' : ''}...'),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      // Group emails by account for IMAP operations
      final emailsByAccount = <String, List<Map<String, dynamic>>>{};
      for (final email in emails) {
        final accountId = email['accountId'] as String;
        emailsByAccount.putIfAbsent(accountId, () => []).add(email);
      }

      // Delete emails from IMAP server and database
      for (final accountId in emailsByAccount.keys) {
        final account = _accounts.firstWhere(
          (acc) => acc.username == accountId,
          orElse: () => throw Exception('Account not found: $accountId'),
        );
        
        final accountEmails = emailsByAccount[accountId]!;
        
        // Try to delete emails on IMAP server
        try {
          await _deleteEmailsOnImapServer(account, accountEmails);
        } catch (e) {
          print('Warning: Could not delete emails on IMAP server: $e');
          // Continue with local deletion even if IMAP fails
        }
        
        // Delete from local database
        for (final email in accountEmails) {
          await db.delete(
            'emails',
            where: 'id = ?',
            whereArgs: [email['id']],
          );
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Permanently deleted ${emails.length} email${emails.length > 1 ? 's' : ''}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('Error permanently deleting emails: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error permanently deleting emails: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _moveEmailsOnImapServer(EmailAccount account, List<Map<String, dynamic>> emails, String targetFolder) async {
    try {
      final imapClient = ImapClient();
      await imapClient.connectToServer(account.imap, 993, isSecure: true);
      await imapClient.login(account.username, account.password);
      
      // Group emails by their current folder
      final emailsByFolder = <String, List<Map<String, dynamic>>>{};
      for (final email in emails) {
        final folderPath = email['folderPath'] as String;
        emailsByFolder.putIfAbsent(folderPath, () => []).add(email);
      }
      
      // Process each folder
      for (final folderPath in emailsByFolder.keys) {
        final folderEmails = emailsByFolder[folderPath]!;
        
        // Select the source folder
        if (folderPath.toUpperCase() == 'INBOX') {
          await imapClient.selectInbox();
        } else {
          final mailboxes = await imapClient.listMailboxes();
          final sourceMailbox = mailboxes.firstWhere(
            (mb) => mb.name == folderPath,
            orElse: () => throw Exception('Source folder $folderPath not found'),
          );
          await imapClient.selectMailbox(sourceMailbox);
        }
        
        // Find target mailbox
        final mailboxes = await imapClient.listMailboxes();
        final targetMailbox = mailboxes.firstWhere(
          (mb) => mb.name.toLowerCase() == targetFolder.toLowerCase(),
          orElse: () => throw Exception('Target folder $targetFolder not found'),
        );

        // Collect UIDs to move
        final uidsToMove = <int>[];
        for (final email in folderEmails) {
          final uid = email['uid'] as int?;
          if (uid != null && uid > 0) {
            uidsToMove.add(uid);
          }
        }

        if (uidsToMove.isNotEmpty) {
          try {
            // Create sequence from UIDs
            final sequence = MessageSequence();
            for (final uid in uidsToMove) {
              sequence.add(uid);
            }

            // Copy emails to target folder using UID COPY
            await imapClient.uidCopy(sequence, targetMailbox: targetMailbox);
            print('✅ Copied ${uidsToMove.length} emails to $targetFolder');

            // Mark original emails as deleted
            await imapClient.uidStore(sequence, [MessageFlags.deleted]);

            // Expunge to remove deleted copies
            await imapClient.expunge();
            print('✅ Moved ${uidsToMove.length} emails to $targetFolder');
          } catch (e) {
            print('❌ Failed to move emails to $targetFolder: $e');
          }
        }
      }

      await imapClient.logout();
    } catch (e) {
      print('Error in IMAP move operation: $e');
      throw e;
    }
  }

  Future<void> _deleteEmailsOnImapServer(EmailAccount account, List<Map<String, dynamic>> emails) async {
    try {
      final imapClient = ImapClient();
      await imapClient.connectToServer(account.imap, 993, isSecure: true);
      await imapClient.login(account.username, account.password);
      
      // Group emails by their current folder
      final emailsByFolder = <String, List<Map<String, dynamic>>>{};
      for (final email in emails) {
        final folderPath = email['folderPath'] as String;
        emailsByFolder.putIfAbsent(folderPath, () => []).add(email);
      }
      
      // Process each folder
      for (final folderPath in emailsByFolder.keys) {
        final folderEmails = emailsByFolder[folderPath]!;
        
        // Select the folder
        if (folderPath.toUpperCase() == 'INBOX') {
          await imapClient.selectInbox();
        } else {
          final mailboxes = await imapClient.listMailboxes();
          final sourceMailbox = mailboxes.firstWhere(
            (mb) => mb.name == folderPath,
            orElse: () => throw Exception('Folder $folderPath not found'),
          );
          await imapClient.selectMailbox(sourceMailbox);
        }
        
        // Delete each email by UID
        final uidsToDelete = <int>[];
        for (final email in folderEmails) {
          final uid = email['uid'] as int?;
          if (uid != null && uid > 0) {
            uidsToDelete.add(uid);
          }
        }

        if (uidsToDelete.isNotEmpty) {
          try {
            // Create sequence from UIDs
            final sequence = MessageSequence();
            for (final uid in uidsToDelete) {
              sequence.add(uid);
            }

            // Mark emails as deleted using UID STORE
            await imapClient.uidStore(sequence, [MessageFlags.deleted]);
            print('✅ Marked ${uidsToDelete.length} emails as deleted in $folderPath');

            // Expunge to permanently remove deleted emails
            await imapClient.expunge();
            print('✅ Expunged deleted emails from $folderPath');
          } catch (e) {
            print('❌ Failed to delete emails in $folderPath: $e');
          }
        }
      }

      await imapClient.logout();
    } catch (e) {
      print('Error in IMAP delete operation: $e');
      throw e;
    }
  }

  Future<void> _showMoveDialog() async {
    // Get list of available folders grouped by account
    final foldersByAccount = await FilterManager.instance.getFoldersGroupedByAccount();
    
    if (foldersByAccount.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No folders available for moving emails'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (BuildContext context) {
        return _FolderSelectionDialog(
          foldersByAccount: foldersByAccount,
          selectedEmailCount: _selectedEmailIds.length,
        );
      },
    );

    if (result != null) {
      final accountId = result['accountId']!;
      final folderPath = result['folderPath']!;
      await _moveSelectedEmails(accountId, folderPath);
    }
  }

  Future<void> _moveSelectedEmails(String targetAccountId, String targetFolderPath) async {
    try {
      final db = await DatabaseHelper.instance.database;
      final emailIds = _selectedEmailIds.toList();
      
      // Show loading indicator
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moving ${emailIds.length} emails to $targetFolderPath...'),
            duration: const Duration(seconds: 1),
          ),
        );
      }

      // Update emails in database
      for (final emailId in emailIds) {
        await db.update(
          'emails',
          {
            'accountId': targetAccountId,
            'folderPath': targetFolderPath,
          },
          where: 'id = ?',
          whereArgs: [emailId],
        );
      }

      // Update UI state - remove moved emails from current view
      setState(() {
        _emails.removeWhere((email) => emailIds.contains(email['id'].toString()));
        _selectedEmailIds.clear();
        _isSelectionMode = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Moved ${emailIds.length} emails to $targetFolderPath'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error moving emails: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _scrollListener() async {
    if (_scrollController.position.pixels ==
            _scrollController.position.maxScrollExtent &&
        !_isLoadingMore) {
      setState(() {
        _isLoadingMore = true;
      });
      await _loadMoreEmails();
      setState(() {
        _isLoadingMore = false;
      });
    }
  }

  Future<void> _initializeApp() async {
    try {
      await _loadAccounts();
      
      // One-time threading rebuild for existing emails (after first fix)
      await _rebuildThreadingIfNeeded();
      
      // Ensure filter has been properly initialized before loading emails
      // Add a small delay to let any async filter initialization complete
      await Future.delayed(const Duration(milliseconds: 100));
      
      await _loadEmailsFromDb();
      setState(() {
        _isLoading = false;
      });
      _syncEmailsInBackground();
    } catch (e) {
      print('App initialization failed: $e');
      setState(() {
        _isLoading = false;
      });
      
      // Show error dialog to user
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showDatabaseErrorDialog(e.toString());
      });
    }
  }
  
  Future<void> _rebuildThreadingIfNeeded() async {
    try {
      final db = await DatabaseHelper.instance.database;
      final result = await db.query(
        'user_settings',
        where: "settingKey = ?",
        whereArgs: ['threading_rebuilt_v2'],
      );
      
      if (result.isEmpty) {
        // Haven't rebuilt yet - do it now
        await DatabaseHelper.instance.rebuildAllThreading();
        
        // Mark as done
        await db.insert('user_settings', {
          'settingKey': 'threading_rebuilt_v2',
          'settingValue': DateTime.now().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (e) {
      print('Threading rebuild check failed: $e');
    }
  }

  void _showDatabaseErrorDialog(String error) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Database Error'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The app failed to initialize the database:'),
              const SizedBox(height: 8),
              Text(
                error,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 16),
              if (error.contains('libsqlite3.so')) ...[
                const Text('To fix this issue, run these commands in terminal:'),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'sudo apt update\nsudo apt install libsqlite3-dev sqlite3',
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Then restart the application.'),
              ] else ...[
                const Text('Please check the console output for more details.'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              // Exit the app since database is required
              exit(0);
            },
            child: const Text('Exit'),
          ),
          if (!error.contains('libsqlite3.so'))
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                // Try to continue without database (limited functionality)
              },
              child: const Text('Continue Anyway'),
            ),
        ],
      ),
    );
  }

  // Background sync with UI updates - NON-BLOCKING
  Future<void> _syncEmailsInBackground() async {
    if (_isSyncing) return;
    setState(() {
      _isSyncing = true;
    });
    
    // Start background fetch without awaiting
    _fetchEmailsBackground().then((_) async {
      setState(() {
        _isSyncing = false;
      });
      // Rebuild threading after sync to ensure new emails are properly threaded
      await DatabaseHelper.instance.rebuildAllThreading();
      // Refresh email list and filter counts after sync
      _loadEmailsFromDb(refresh: true);
      FilterManager.instance.refreshEmailCounts();
      print('✅ Background email sync completed');
    }).catchError((e) {
      setState(() {
        _isSyncing = false;
      });
      print('❌ Background email sync failed: $e');
    });
    
    // Load existing emails immediately (don't block UI)
    await _loadEmailsFromDb(refresh: true);
  }
  
  // Non-blocking background fetch
  Future<void> _fetchEmailsBackground() async {
    // 📧 EMAIL FETCHING - ENABLED
    print('📧 _fetchEmailsBackground() starting...');
    
    if (_accounts.isEmpty) {
      print("No accounts found to fetch emails from");
      return;
    }

    setState(() {
      _debugEmailsProcessed = 0;
      _debugLastError = '';
      _debugLastActivity = DateTime.now();
    });

    print('🚀 [PARALLEL] Starting parallel sync for ${_accounts.length} accounts...');
    
    // OPTIMIZATION: Fetch all accounts in PARALLEL instead of sequential
    await Future.wait(
      _accounts.map((account) => _fetchAccountEmailsParallel(account)),
      eagerError: false, // Don't stop if one account fails
    );
    
    setState(() {
      _debugCurrentAccount = '';
      _debugCurrentFolder = '';
      _debugLastActivity = DateTime.now();
    });
    
    print('🎉 [PARALLEL] All accounts processed. Total emails: $_debugEmailsProcessed');
  }

  // NEW: Parallel account fetching - each account syncs independently
  Future<void> _fetchAccountEmailsParallel(EmailAccount account) async {
    try {
      setState(() {
        _debugCurrentAccount = account.username;
        _debugCurrentFolder = '';
      });
      
      print("🔄 [PARALLEL-${account.username}] Starting sync");
      
      final imapClient = ImapClient();
      await imapClient.connectToServer(account.imap, 993, isSecure: true);
      await imapClient.login(account.username, account.password);
      
      // Get mailboxes
      final mailboxes = await imapClient.listMailboxes();
      print("📁 [PARALLEL-${account.username}] Found ${mailboxes.length} folders");
      
      // Store folders in database
      await DatabaseHelper.instance.storeImapFolders(account, mailboxes);
      
      // Process INBOX first for immediate content
      final inboxFolder = mailboxes.where((mb) => mb.name.toUpperCase() == 'INBOX').firstOrNull;
      if (inboxFolder != null && !inboxFolder.flags.contains(r'\Noselect')) {
        try {
          setState(() {
            _debugCurrentFolder = 'INBOX';
          });
          print("📂 [PARALLEL-${account.username}] Processing INBOX with headers-first");
          
          // Use NEW headers-first approach instead of old full-body fetch
          await _fetchEmailsFromFolder(imapClient, account, inboxFolder.name);
          
          // Update UI after INBOX (background update)
          if (mounted) {
            _loadEmailsFromDb(refresh: true).catchError((e) => print("UI update error: $e"));
          }
        } catch (folderError) {
          final errorMsg = "⚠️ [PARALLEL-${account.username}] Error processing INBOX: $folderError";
          print(errorMsg);
          setState(() {
            _debugLastError = errorMsg;
          });
        }
      }
      
      // Process other folders in background
      final otherFolders = mailboxes.where((mb) => mb.name.toUpperCase() != 'INBOX').toList();
      for (final mailboxInfo in otherFolders) {
        if (mailboxInfo.flags.contains(r'\Noselect')) {
          continue;
        }
        
        try {
          setState(() {
            _debugCurrentFolder = mailboxInfo.name;
          });
          print("📂 [PARALLEL-${account.username}] Processing folder: ${mailboxInfo.name} with headers-first");
          
          // Use NEW headers-first approach instead of old full-body fetch
          await _fetchEmailsFromFolder(imapClient, account, mailboxInfo.name);
          
          // Periodic UI updates during background processing
          if (mounted) {
            _loadEmailsFromDb(refresh: true).catchError((e) => print("UI update error: $e"));
            await Future.delayed(Duration(milliseconds: 50)); // Small yield for UI
          }
        } catch (folderError) {
          final errorMsg = "⚠️ [PARALLEL-${account.username}] Error processing folder ${mailboxInfo.name}: $folderError";
          print(errorMsg);
          setState(() {
            _debugLastError = errorMsg;
          });
        }
      }

      await imapClient.logout();
      print("✅ [PARALLEL-${account.username}] Completed sync");
    } on DatabaseException catch (dbError) {
      // Handle database cursor window errors specifically
      if (dbError.toString().contains('CursorWindow') || 
          dbError.toString().contains('Row too big')) {
        final errorMsg = "🚨 [PARALLEL-${account.username}] Cursor window error - running cleanup";
        print(errorMsg);
        setState(() {
          _debugLastError = errorMsg;
        });
        
        // Run emergency cleanup for this account
        try {
          await DatabaseHelper.instance.emergencyCleanupOversizedContent();
          print("✅ [PARALLEL-${account.username}] Cleanup completed, retrying sync");
          
          // Don't retry automatically to avoid infinite loops
          // User can manually retry if needed
        } catch (cleanupError) {
          print("❌ [PARALLEL-${account.username}] Cleanup failed: $cleanupError");
        }
      } else {
        // Truncate error message to avoid printing large attachment data
        final errorStr = dbError.toString();
        final errorPreview = errorStr.length > 300 ? errorStr.substring(0, 300) + '...[truncated]' : errorStr;
        final errorMsg = "❌ [PARALLEL-${account.username}] Database error: $errorPreview";
        print(errorMsg);
        setState(() {
          _debugLastError = errorMsg;
        });
      }
    } catch (e) {
      // Truncate error message to avoid printing large attachment data
      final errorStr = e.toString();
      final errorPreview = errorStr.length > 300 ? errorStr.substring(0, 300) + '...[truncated]' : errorStr;
      final errorMsg = "❌ [PARALLEL-${account.username}] Error: $errorPreview";
      print(errorMsg);
      setState(() {
        _debugLastError = errorMsg;
      });
    }
  }

  Future<void> _loadAccounts() async {
    _accounts = await DatabaseHelper.instance.getAccounts();
    if (_accounts.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showAccountSetupDialog();
      });
    } else {
      // Initialize filter with all accounts when accounts are loaded
      final accountUsernames = _accounts.map((acc) => acc.username).toList();
      await FilterManager.instance.initializeWithAllOptions(accountUsernames, _accounts);
    }
  }

  Future<void> _refreshEmails() async {
    // Show existing emails immediately (non-blocking)
    await _loadEmailsFromDb();

    // Start background sync without blocking UI
    _syncEmailsInBackground();
  }

  Future<void> _rebuildThreading() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rebuild Threading'),
        content: const Text(
          'This will rebuild all email threading relationships in the database.\n\n'
          'This may take a few moments depending on the number of emails.\n\n'
          'Continue?'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Rebuild'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Show progress indicator
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Rebuilding threading...'),
          ],
        ),
      ),
    );

    try {
      // Rebuild threading
      await DatabaseHelper.instance.rebuildAllThreading();

      // Reload emails to show updated threading
      await _loadEmailsFromDb(refresh: true);

      // Close progress dialog
      if (!mounted) return;
      Navigator.of(context).pop();

      // Show success message
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Threading rebuilt successfully'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      // Close progress dialog
      if (mounted) Navigator.of(context).pop();

      // Show error message
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error rebuilding threading: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _fetchEmails() async {
    if (_accounts.isEmpty) {
      print("No accounts found to fetch emails from");
      return;
    }

    for (var account in _accounts) {
      try {
        final imapClient = ImapClient();
        await imapClient.connectToServer(account.imap, 993, isSecure: true);
        await imapClient.login(account.username, account.password);
        
        // First, get list of all mailboxes/folders
        final mailboxes = await imapClient.listMailboxes();
        print("📁 Found ${mailboxes.length} folders for ${account.username}");
        
        // Store folders in database for filter drawer
        await DatabaseHelper.instance.storeImapFolders(account, mailboxes);
        
        // ANDROID OPTIMIZATION: Process INBOX first, then other folders
        final inboxFolder = mailboxes.where((mb) => mb.name.toUpperCase() == 'INBOX').firstOrNull;
        final otherFolders = mailboxes.where((mb) => mb.name.toUpperCase() != 'INBOX').toList();
        
        // Process INBOX first for immediate user content
        if (inboxFolder != null && !inboxFolder.flags.contains(r'\Noselect')) {
          try {
            print("📂 Processing folder: ${inboxFolder.name}");
            await _fetchEmailsFromFolder(imapClient, account, inboxFolder.name);
            
            // ANDROID: Load UI after INBOX to show content immediately
            if (Platform.isAndroid) {
              try {
                await _loadEmailsFromDb(refresh: true);
                await Future.delayed(Duration(milliseconds: 100)); // Let UI update
              } catch (e) {
                print("Warning: UI update after INBOX failed: $e");
              }
            }
          } catch (folderError) {
            print("⚠️ Error processing INBOX: $folderError");
          }
        }
        
        // Process other folders
        for (final mailboxInfo in otherFolders) {
          // Skip folders that can't be selected
          if (mailboxInfo.flags.contains(r'\Noselect')) {
            print("⏭️ Skipping non-selectable folder: ${mailboxInfo.name}");
            continue;
          }
          
          try {
            print("📂 Processing folder: ${mailboxInfo.name}");
            await _fetchEmailsFromFolder(imapClient, account, mailboxInfo.name);
          } catch (folderError) {
            print("⚠️ Error processing folder ${mailboxInfo.name}: $folderError");
            // Continue with other folders even if one fails
          }
        }

        await imapClient.logout();
        print("✅ Completed fetching emails for ${account.username}");
      } catch (e) {
        print("Error fetching emails for ${account.username}: $e");
      }
    }
    
    print("📧 Fetch emails operation completed");
  }

  Future<void> _fetchEmailsFromFolder(ImapClient imapClient, EmailAccount account, String folderName) async {
    // NEW HEADERS-FIRST APPROACH:
    // 1. Fetch headers only (fast) - shows email list immediately
    // 2. Fetch bodies in background - updates progressively
    await _fetchHeadersFirst(imapClient, account, folderName);
    
    // Schedule background body fetching with its own connection (non-blocking)
    _fetchBodiesInBackgroundWithNewConnection(account, folderName);
  }
  
  // PHASE 1: Fetch headers only (ENVELOPE + FLAGS + UID) - Fast!
  Future<void> _fetchHeadersFirst(ImapClient imapClient, EmailAccount account, String folderName) async {
    setState(() {
      _debugCurrentFolder = folderName;
      _debugLastActivity = DateTime.now();
    });
    
    print("📋 [HEADERS-FIRST] Fetching headers from $folderName for ${account.username}");
    
    // Select folder
    final Mailbox mailbox;
    if (folderName.toUpperCase() == 'INBOX') {
      mailbox = await imapClient.selectInbox();
    } else {
      final mailboxes = await imapClient.listMailboxes();
      final targetMailbox = mailboxes.firstWhere((mb) => mb.name == folderName);
      mailbox = await imapClient.selectMailbox(targetMailbox);
    }
    
    final messageCount = mailbox.messagesExists;
    if (messageCount == 0) {
      print("📋 [HEADERS-FIRST] No messages in $folderName");
      return;
    }
    
    // Get last synced UID for incremental sync
    final lastSyncedUid = await DatabaseHelper.instance.getLastSyncedUid(account.username, folderName);
    print("📋 [HEADERS-FIRST] Last synced UID: $lastSyncedUid, Total messages: $messageCount");
    
    // CRITICAL FIX: We need to fetch by UID, not sequence numbers!
    // Sequence numbers change when emails are deleted, UIDs are permanent
    
    // First, get all UIDs in the mailbox using UID FETCH
    print("📋 [UID-FETCH] Getting all UIDs from server using UID FETCH...");
    final allUidsSequence = MessageSequence.fromAll();
    
    // CRITICAL: Use uidFetchMessages to get actual UIDs, not sequence numbers!
    final uidFetchResult = await imapClient.uidFetchMessages(allUidsSequence, '(UID)');
    final serverUids = uidFetchResult.messages.map((m) => m.uid!).toList();
    serverUids.sort(); // Sort UIDs ascending
    
    print("📋 [UID-FETCH] Server has ${serverUids.length} messages with UIDs from ${serverUids.first} to ${serverUids.last}");
    
    // Determine which UIDs to fetch (incremental sync)
    List<int> uidsToFetch;
    if (lastSyncedUid > 0) {
      // Incremental: Only fetch UIDs > lastSyncedUid
      uidsToFetch = serverUids.where((uid) => uid > lastSyncedUid).toList();
      print("📋 [INCREMENTAL] Fetching ${uidsToFetch.length} new messages after UID $lastSyncedUid");
    } else {
      // Full sync: Fetch all
      uidsToFetch = serverUids;
      print("📋 [FULL-SYNC] Fetching ALL ${uidsToFetch.length} email headers");
    }
    
    if (uidsToFetch.isEmpty) {
      print("📋 [HEADERS-FIRST] No new messages to fetch");
      return;
    }
    
    // OPTIMIZED: Use batched UID fetching (much faster than individual requests)
    // Fetch in batches of 200 to balance speed vs correctness
    print("📋 [BATCH-UID-FETCH] Fetching ${uidsToFetch.length} messages in batches of 200");
    
    if (_debugMode) {
      print("🔍 DEBUG: First 20 UIDs to fetch: ${uidsToFetch.take(20).join(', ')}");
      if (uidsToFetch.length > 10) {
        print("🔍 DEBUG: Last 10 UIDs to fetch: ${uidsToFetch.skip(uidsToFetch.length - 10).join(', ')}");
      }
    }
    
    const batchSize = 200; // Fetch 200 messages per batch
    int fetchedCount = 0;
    
    for (int i = 0; i < uidsToFetch.length; i += batchSize) {
      final batchEnd = min(i + batchSize, uidsToFetch.length);
      final batchUids = uidsToFetch.sublist(i, batchEnd);
      
      if (_debugMode && i == 0) {
        print("🔍 DEBUG: First batch UIDs: ${batchUids.take(10).join(', ')}...");
      }
      
      // Create a UID sequence for this batch
      // CRITICAL: Use min/max to handle UIDs in any order (ascending or descending)
      final minUid = batchUids.reduce((a, b) => a < b ? a : b);
      final maxUid = batchUids.reduce((a, b) => a > b ? a : b);
      final sequence = MessageSequence.fromRange(minUid, maxUid, isUidSequence: true);
      
      // Fetch this batch with ONE request
      await _fetchHeadersBatchOptimized(imapClient, account, folderName, sequence, batchUids);
      
      fetchedCount += batchUids.length;
      
      // Update UI every 200 messages
      if (fetchedCount % 200 == 0 && mounted) {
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
  }
  
  // Fetch a single message's headers by UID (used in parallel batches)
  Future<void> _fetchSingleMessageHeader(ImapClient imapClient, EmailAccount account, String folderName, int uid) async {
    try {
      final sequence = MessageSequence.fromId(uid, isUid: true);
      
      if (_debugMode) {
        print("🔍 [FETCH-START] Requesting UID $uid from $folderName");
      }
      
      // CRITICAL: Use uidFetchMessages to fetch by UID, not sequence number!
      final fetchResult = await imapClient.uidFetchMessages(
        sequence,
        '(ENVELOPE FLAGS UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID DATE SUBJECT FROM)])',
      );
      
      if (fetchResult.messages.isEmpty) {
        if (_debugMode) print("⚠️ [FETCH-EMPTY] UID $uid returned no messages");
        return; // UID doesn't exist on server (deleted message)
      }
      
      final message = fetchResult.messages.first;
      final db = await DatabaseHelper.instance.database;
      
      // CRITICAL: Use the UID returned by the server, not the requested UID!
      // The IMAP server may return a different UID than requested
      final actualUid = message.uid ?? uid;
      
      // CRITICAL DEBUG: Verify the UID returned matches what we requested
      if (_debugMode && actualUid != uid) {
        print("🚨 [UID-MISMATCH] Requested UID $uid but got UID $actualUid! (Using $actualUid)");
      }
      
      // Extract Message-ID
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
      
      // Extract Subject
      String subject;
      final subjectHeader = message.decodeHeaderValue('subject');
      if (subjectHeader != null && subjectHeader.isNotEmpty) {
        subject = subjectHeader;
      } else {
        subject = message.decodeSubject() ?? 'No Subject';
      }
      
      // DEBUG: Print extraction for EVERY message to verify correctness
      if (_debugMode) {
        // Print first 10 messages of sync
        final count = await db.rawQuery('SELECT COUNT(*) as c FROM emails WHERE accountId = ? AND folderPath = ?', [account.username, folderName]);
        final totalStored = (count.first['c'] as int?) ?? 0;
        
        if (totalStored < 10) {
          print("📧 [SINGLE-UID-FETCH #$totalStored] UID $uid ($folderName):");
          print("   Returned UID from server: $actualUid ${actualUid == uid ? '✅' : '❌ MISMATCH!'}");
          print("   MessageID: ${messageId.substring(0, min(50, messageId.length))}...");
          print("   Subject: ${subject.substring(0, min(70, subject.length))}${subject.length > 70 ? '...' : ''}");
          print("   ---");
        }
        
        // Also print if subject contains specific keywords (but less spam now)
        if (subject.contains('People') || subject.contains('Timesheet') || 
            subject.contains('cost-effective') || subject.contains('FLX1PACK')) {
          print("📧 [KEYWORD-MATCH] Requested UID $uid → Actual UID $actualUid: ${subject.substring(0, min(50, subject.length))}");
        }
      }
      
      // Extract sender
      String senderName = 'Unknown';
      String senderEmail = 'unknown@example.com';
      
      final fromHeader = message.decodeHeaderValue('from');
      if (fromHeader != null && fromHeader.isNotEmpty) {
        final emailRegex = RegExp(r'<(.+?)>');
        final emailMatch = emailRegex.firstMatch(fromHeader);
        if (emailMatch != null) {
          senderEmail = emailMatch.group(1)!;
          senderName = fromHeader.substring(0, emailMatch.start).trim();
          
          // Remove surrounding quotes if present (double or single quotes)
          if ((senderName.startsWith('"') && senderName.endsWith('"')) ||
              (senderName.startsWith("'") && senderName.endsWith("'"))) {
            senderName = senderName.substring(1, senderName.length - 1);
          }
          
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
        timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
      }
      
      // Parse IMAP flags
      final imapFlags = ImapFlagsHelper.parseImapFlags(message);
      
      // Insert into database with the ACTUAL UID returned by server
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
        'uid': actualUid, // Use actual UID from server, not requested UID
      });
    } catch (e) {
      // Silently skip errors (deleted messages, network issues, duplicate keys, etc.)
    }
  }
  
  // Optimized: Fetch headers for a batch of messages using UID FETCH (much faster)
  Future<void> _fetchHeadersBatchOptimized(ImapClient imapClient, EmailAccount account, String folderName, MessageSequence sequence, List<int> expectedUids) async {
    try {
      if (_debugMode) {
        print("📥 [BATCH-FETCH] Fetching ${expectedUids.length} headers from $folderName");
      }
      
      // CRITICAL: Use uidFetchMessages instead of fetchMessages!
      // Include IN-REPLY-TO and REFERENCES headers for threading support
      final fetchResult = await imapClient.uidFetchMessages(
        sequence,
        '(ENVELOPE FLAGS UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID DATE SUBJECT FROM IN-REPLY-TO REFERENCES)])',
      );
      
      final db = await DatabaseHelper.instance.database;
      
      // Create a map of returned UIDs for quick lookup
      final returnedUids = <int>{};
      for (var message in fetchResult.messages) {
        if (message.uid != null) {
          returnedUids.add(message.uid!);
        }
      }
      
      // CRITICAL DEBUG: Check if we got all expected UIDs
      if (_debugMode) {
        final missing = expectedUids.where((uid) => !returnedUids.contains(uid)).toList();
        if (missing.isNotEmpty) {
          print("⚠️ [BATCH-MISSING] Expected ${expectedUids.length} messages, got ${fetchResult.messages.length}. Missing: ${missing.take(10).join(', ')}");
        }
      }
      
      for (var message in fetchResult.messages) {
        final int uid = message.uid ?? 0;
        
        // Extract Message-ID
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
        
        // Extract Subject
        String subject;
        final subjectHeader = message.decodeHeaderValue('subject');
        if (subjectHeader != null && subjectHeader.isNotEmpty) {
          subject = subjectHeader;
        } else {
          subject = message.decodeSubject() ?? 'No Subject';
        }
        
        // Extract sender
        String senderName = 'Unknown';
        String senderEmail = 'unknown@example.com';
        
        final fromHeader = message.decodeHeaderValue('from');
        if (fromHeader != null && fromHeader.isNotEmpty) {
          final emailRegex = RegExp(r'<(.+?)>');
          final emailMatch = emailRegex.firstMatch(fromHeader);
          if (emailMatch != null) {
            senderEmail = emailMatch.group(1)!;
            senderName = fromHeader.substring(0, emailMatch.start).trim();
            
            // Remove surrounding quotes if present (double or single quotes)
            if ((senderName.startsWith('"') && senderName.endsWith('"')) ||
                (senderName.startsWith("'") && senderName.endsWith("'"))) {
              senderName = senderName.substring(1, senderName.length - 1);
            }
            
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
        
        // Extract timestamp - try multiple sources
        int timestamp;
        
        // Debug: Always show envelope date status for People2
        if (_debugMode && subject.contains('People2')) {
          print("📅 [People2] UID $uid: ENVELOPE date = ${message.envelope?.date}");
          print("📅 [People2] UID $uid: ENVELOPE exists = ${message.envelope != null}");
        }
        
        if (message.envelope?.date != null) {
          timestamp = message.envelope!.date!.millisecondsSinceEpoch;
          if (_debugMode && subject.contains('People2')) {
            print("✅ [People2] UID $uid: Using ENVELOPE date successfully");
          }
        } else {
          // ENVELOPE date is null - try to extract Date from the fetched header body
          String? dateHeader;
          
          // Debug: Show raw body content for People2
          if (_debugMode && subject.contains('People2')) {
            print("📅 [People2] UID $uid: Raw body text:");
            final bodyText = message.body != null ? message.decodeTextPlainPart() : null;
            if (bodyText != null) {
              final lines = bodyText.split('\n').take(15); // First 15 lines
              for (var line in lines) {
                print("   | $line");
              }
            } else {
              print("   | (body is null)");
            }
          }
          
          // Try to get date from the explicit header fetch
          dateHeader = message.decodeHeaderValue('date');
          
          if (_debugMode && subject.contains('People2')) {
            print("📅 [People2] UID $uid: decodeHeaderValue('date') = $dateHeader");
          }
          
          // If still null, try parsing from body text
          if (dateHeader == null && message.body != null) {
            final bodyText = message.decodeTextPlainPart();
            if (bodyText != null && bodyText.contains('Date:')) {
              final lines = bodyText.split('\n');
              for (var line in lines) {
                if (line.toLowerCase().startsWith('date:')) {
                  dateHeader = line.substring(5).trim();
                  if (_debugMode && subject.contains('People2')) {
                    print("📅 [People2] UID $uid: Found Date in body = $dateHeader");
                  }
                  break;
                }
              }
            }
          }
          
          if (dateHeader != null && dateHeader.isNotEmpty) {
            try {
              // Use enough_mail's DateCodec to parse RFC 2822 date format
              final parsedDate = DateCodec.decodeDate(dateHeader);
              if (parsedDate != null) {
                timestamp = parsedDate.millisecondsSinceEpoch;
                if (_debugMode && subject.contains('People2')) {
                  print("📅 [People2] UID $uid: Parsed date = $parsedDate");
                }
              } else {
                // DateCodec failed - try INTERNALDATE as fallback
                if (message.internalDate != null) {
                  try {
                    final internalDate = DateCodec.decodeDate(message.internalDate!);
                    timestamp = internalDate?.millisecondsSinceEpoch ?? 0; // Unix epoch if all parsing fails
                    if (_debugMode) print("⚠️ DateCodec failed, using INTERNALDATE: $internalDate");
                  } catch (e) {
                    timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
                    if (_debugMode) print("⚠️ INTERNALDATE parse failed: $e - using Unix epoch");
                  }
                } else {
                  timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
                  if (_debugMode) print("⚠️ DateCodec returned null for '$dateHeader' UID $uid - using Unix epoch");
                }
              }
            } catch (e) {
              // Parse error - try INTERNALDATE as fallback
              if (message.internalDate != null) {
                try {
                  final internalDate = DateCodec.decodeDate(message.internalDate!);
                  timestamp = internalDate?.millisecondsSinceEpoch ?? 0; // Unix epoch if all parsing fails
                  if (_debugMode) print("⚠️ Date parse failed, using INTERNALDATE: $internalDate");
                } catch (e2) {
                  timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
                  if (_debugMode) print("⚠️ Failed to parse date '$dateHeader' for UID $uid: $e - using Unix epoch");
                }
              } else {
                timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
                if (_debugMode) print("⚠️ Failed to parse date '$dateHeader' for UID $uid: $e - using Unix epoch");
              }
            }
          } else {
            // No date header found - use INTERNALDATE (server received date) as fallback
            if (message.internalDate != null) {
              try {
                final internalDate = DateCodec.decodeDate(message.internalDate!);
                if (internalDate != null) {
                  timestamp = internalDate.millisecondsSinceEpoch;
                  if (_debugMode && subject.contains('People2')) {
                    print("📅 [People2] UID $uid: No date header, using INTERNALDATE: $internalDate");
                  }
                } else {
                  timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
                  if (_debugMode && subject.contains('People2')) {
                    print("⚠️ [People2] UID $uid: INTERNALDATE parse returned null - using Unix epoch");
                  }
                }
              } catch (e) {
                timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
                if (_debugMode && subject.contains('People2')) {
                  print("⚠️ [People2] UID $uid: INTERNALDATE parse failed: $e - using Unix epoch");
                }
              }
            } else {
              // Last resort: use Unix epoch (1970-01-01 00:00:00 UTC)
              timestamp = 0;
              if (_debugMode && subject.contains('People2')) {
                print("⚠️ [People2] UID $uid: No date found anywhere, using Unix epoch");
              }
            }
          }
        }
        
        // Parse IMAP flags
        final imapFlags = ImapFlagsHelper.parseImapFlags(message);
        
        // Extract threading headers
        String? inReplyTo = message.decodeHeaderValue('in-reply-to');
        String references = message.decodeHeaderValue('references') ?? '';
        
        // Clean up the headers (remove angle brackets inconsistencies)
        if (inReplyTo != null) {
          inReplyTo = inReplyTo.trim();
        }
        references = references.trim();
        
        // Determine thread parent - first check if there's a parent in the database
        String threadParentId = messageId;
        if (inReplyTo != null && inReplyTo.isNotEmpty) {
          // Check if the parent email exists
          final parentEmails = await db.query(
            'emails',
            columns: ['messageId', 'threadParentId'],
            where: 'messageId = ? AND accountId = ?',
            whereArgs: [inReplyTo, account.username],
            limit: 1,
          );
          
          if (parentEmails.isNotEmpty) {
            // Use the parent's threadParentId to maintain the chain
            threadParentId = parentEmails.first['threadParentId'] as String? ?? inReplyTo;
          }
        }
        
        // Insert into database
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
          'inReplyTo': inReplyTo ?? '',
          'references': references,
          'threadParentId': threadParentId,
          'bodyFetched': 0,
          'uid': uid,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        
        // If this email has a parent, also update the parent's thread children
        // to point to the correct thread root
        if (inReplyTo != null && inReplyTo.isNotEmpty && threadParentId != messageId) {
          // Update this email's threadParentId if we found a different root
          await db.update(
            'emails',
            {'threadParentId': threadParentId},
            where: 'messageId = ? AND accountId = ?',
            whereArgs: [messageId, account.username],
          );
        }
        
        // Add contact from email sender automatically
        try {
          if (senderEmail.isNotEmpty && account.username.isNotEmpty) {
            await DatabaseHelper.instance.addContactFromEmail(
              senderName: senderName,
              senderEmail: senderEmail,
              accountId: account.username,
            );
          }
        } catch (contactError) {
          // Don't fail email insertion if contact addition fails
          if (_debugMode) print('⚠️ Failed to add contact: $contactError');
        }
      }
    } catch (e) {
      if (_debugMode) print("❌ [BATCH-ERROR] Failed to fetch batch: $e");
    }
  }
  
  // Fetch just the headers for a batch of messages
  Future<void> _fetchHeadersBatch(ImapClient imapClient, EmailAccount account, String folderName, dynamic sequence) async {
    try {
      // Fetch headers: ENVELOPE, FLAGS, UID, INTERNALDATE, and key header fields
      // BODY.PEEK[HEADER.FIELDS (...)] fetches specific headers without marking as read
      if (_debugMode) {
        print("📥 [HEADERS] Fetching headers batch for $folderName (isUid: ${sequence.isUidSequence})");
        print("   Sequence: ${sequence.toString()}");
      }
      
      final fetchResult = await imapClient.fetchMessages(
        sequence,
        '(ENVELOPE FLAGS UID INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID DATE SUBJECT FROM)])',
      );
      
      final db = await DatabaseHelper.instance.database;
      int newHeaders = 0;
      int highestUid = 0;
      
      // CRITICAL DEBUG: Print the order of messages we're about to process
      if (_debugMode) {
        print("🔍 BATCH PROCESSING: Received ${fetchResult.messages.length} messages from IMAP");
        print("   Expected UIDs from sequence: ${sequence.toString()}");
        print("   Actual UIDs in response: ${fetchResult.messages.map((m) => m.uid).join(', ')}");
      }
      
      for (var message in fetchResult.messages) {
        final int uid = message.uid ?? 0;
        if (uid > highestUid) highestUid = uid;
        
        // CRITICAL FIX: Use actual Message-ID header, NOT UID!
        // Try multiple methods to get the Message-ID:
        // 1. decodeHeaderValue('message-id') (from explicit header fetch)
        // 2. message.guid (parsed from envelope)
        // 3. Fallback to UID-based ID
        String messageId;
        final headerValue = message.decodeHeaderValue('message-id');
        final guidValue = message.guid?.toString();
        
        if (headerValue != null && headerValue.isNotEmpty) {
          messageId = headerValue;
        } else if (guidValue != null && guidValue.isNotEmpty) {
          messageId = guidValue;
        } else {
          // Fallback: Create a pseudo Message-ID from UID (with folder to avoid collisions)
          messageId = '<uid-$uid@$folderName.${account.username}>';
        }
        
        // Parse subject - try explicit header first, then envelope
        String subject;
        final subjectHeader = message.decodeHeaderValue('subject');
        if (subjectHeader != null && subjectHeader.isNotEmpty) {
          subject = subjectHeader;
        } else {
          subject = message.decodeSubject() ?? 'No Subject';
        }
        
        // CRITICAL DEBUG: Print UID→MessageID→Subject mapping for EVERY message
        if (_debugMode && newHeaders < 20) {
          print("📧 EXTRACTING: UID=$uid");
          print("   → MessageID: ${messageId.substring(0, min(50, messageId.length))}");
          print("   → Subject: ${subject.substring(0, min(60, subject.length))}");
        }
        
        // Parse sender - try explicit header first, then envelope
        String senderName = 'Unknown';
        String senderEmail = 'unknown@example.com';
        
        final fromHeader = message.decodeHeaderValue('from');
        if (fromHeader != null && fromHeader.isNotEmpty) {
          // Parse "Name <email@domain.com>" format
          final emailRegex = RegExp(r'<(.+?)>');
          final emailMatch = emailRegex.firstMatch(fromHeader);
          if (emailMatch != null) {
            senderEmail = emailMatch.group(1)!;
            senderName = fromHeader.substring(0, emailMatch.start).trim();
            
            // Remove surrounding quotes if present (double or single quotes)
            if ((senderName.startsWith('"') && senderName.endsWith('"')) ||
                (senderName.startsWith("'") && senderName.endsWith("'"))) {
              senderName = senderName.substring(1, senderName.length - 1);
            }
            
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
        
        // CRITICAL FIX: Parse date from multiple sources
        int timestamp;
        
        // Try ENVELOPE date first (it's a DateTime object already parsed by enough_mail)
        if (message.envelope?.date != null) {
          timestamp = message.envelope!.date!.millisecondsSinceEpoch;
          if (_debugMode) print("✅ UID $uid: Using ENVELOPE date: ${message.envelope!.date}");
        } else {
          // ENVELOPE date is null - try to extract Date from the fetched header body
          String? dateHeader;
          
          // The BODY.PEEK[HEADER.FIELDS (DATE)] returns a text body part
          // Try to get it from the body text
          if (message.body != null) {
            final bodyText = message.decodeTextPlainPart();
            if (bodyText != null && bodyText.contains('Date:')) {
              // Extract date header manually
              final lines = bodyText.split('\n');
              for (var line in lines) {
                if (line.toLowerCase().startsWith('date:')) {
                  dateHeader = line.substring(5).trim(); // Remove "Date:" prefix
                  break;
                }
              }
            }
          }
          
          if (_debugMode) print("📧 UID $uid: Extracted Date header: '$dateHeader'");
          
          if (dateHeader != null && dateHeader.isNotEmpty) {
            try {
              // Use enough_mail's DateCodec to parse RFC 2822 date format
              final parsedDate = DateCodec.decodeDate(dateHeader);
              if (parsedDate != null) {
                timestamp = parsedDate.millisecondsSinceEpoch;
                if (_debugMode) print("✅ UID $uid: Parsed Date header: $parsedDate");
              } else {
                timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
                if (_debugMode) print("⚠️ DateCodec returned null for '$dateHeader' UID $uid - using Unix epoch");
              }
            } catch (e) {
              // If parsing fails, use Unix epoch
              timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
              if (_debugMode) print("⚠️ Failed to parse date '$dateHeader' for UID $uid: $e - using Unix epoch");
            }
          } else {
            timestamp = 0; // Unix epoch (1970-01-01 00:00:00 UTC)
            if (_debugMode) print("⚠️ No date header found in body for UID $uid, using Unix epoch");
          }
        }
        
        // DEBUG: Log final date
        if (_debugMode) {
          final dateStr = DateTime.fromMillisecondsSinceEpoch(timestamp).toIso8601String();
          print("📅 UID $uid: FINAL date=$dateStr, subject=${subject.substring(0, min(40, subject.length))}");
        }
        
        // Parse IMAP flags
        final imapFlags = ImapFlagsHelper.parseImapFlags(message);
        
        // Insert header-only email (bodyFetched = 0)
        // Skip manual existence check - rely on UNIQUE constraint for performance
        try {
          await db.insert('emails', {
            'messageId': messageId,
            'accountId': account.username,
            'subject': subject,
            'sender': senderName,
            'senderEmail': senderEmail,
            'timestamp': timestamp,
            'content': '[Loading email body...]', // Placeholder
            'isRead': imapFlags['isRead'] ?? 0,
            'isStarred': imapFlags['isStarred'] ?? 0,
            'isAnswered': imapFlags['isAnswered'] ?? 0,
            'isDraft': imapFlags['isDraft'] ?? 0,
            'isDeleted': imapFlags['isDeleted'] ?? 0,
            'folderPath': folderName,
            'threadParentId': messageId,
            'bodyFetched': 0, // Mark as header-only
            'uid': uid,
          });
          
          if (_debugMode && newHeaders < 20) {
            print("💾 DB INSERT: UID=$uid");
            print("   → Stored MessageID: ${messageId.substring(0, min(50, messageId.length))}");
            print("   → Stored Subject: ${subject.substring(0, min(60, subject.length))}");
          }
          
          newHeaders++;
        } catch (insertError) {
          // Skip duplicates silently, log other errors briefly
          if (!insertError.toString().contains('UNIQUE constraint')) {
            if (_debugMode) print("⚠️ Insert failed for messageId $messageId");
          }
          continue;
        }
        
        setState(() {
          _debugEmailsProcessed++;
          _debugLastActivity = DateTime.now();
        });
      }
      
      // Update last synced UID
      if (highestUid > 0) {
        await DatabaseHelper.instance.updateLastSyncedUid(
          account.username,
          folderName,
          highestUid,
          fetchResult.messages.length,
        );
      }
      
      if (newHeaders > 0) {
        print("✅ Added $newHeaders headers from $folderName");
      }
      
    } catch (e) {
      // Truncate error message to avoid printing large data
      final errorMsg = e.toString();
      final truncated = errorMsg.length > 200 ? '${errorMsg.substring(0, 200)}...' : errorMsg;
      print("❌ Error fetching headers: $truncated");
    }
  }
  
  // PHASE 2: Fetch bodies in background with its own IMAP connection (non-blocking)
  void _fetchBodiesInBackgroundWithNewConnection(EmailAccount account, String folderName) {
    // Run in background without awaiting
    Future.microtask(() async {
      try {
        // Create a new IMAP connection for background fetching
        final imapClient = ImapClient();
        await imapClient.connectToServer(account.imap, 993, isSecure: true);
        await imapClient.login(account.username, account.password);
        
        // Select the folder
        if (folderName.toUpperCase() == 'INBOX') {
          await imapClient.selectInbox();
        } else {
          final mailboxes = await imapClient.listMailboxes();
          final targetMailbox = mailboxes.firstWhere((mb) => mb.name == folderName);
          await imapClient.selectMailbox(targetMailbox);
        }
        
        final db = await DatabaseHelper.instance.database;
        
        // Get emails that don't have bodies yet
        // On Android: Only fetch bodies for recent unread emails first (priority)
        // Bodies will be fetched on-demand when user opens an email
        final emailsNeedingBodies = await db.query(
          'emails',
          where: 'accountId = ? AND folderPath = ? AND bodyFetched = 0',
          whereArgs: [account.username, folderName],
          orderBy: 'isRead ASC, timestamp DESC', // Unread first, then newest
          limit: Platform.isAndroid ? 200 : 500,
        );
        
        if (emailsNeedingBodies.isEmpty) {
          await imapClient.logout();
          return;
        }
        
        print("📦 Fetching ${emailsNeedingBodies.length} email bodies in background...");
        
        for (var email in emailsNeedingBodies) {
          try {
            final uid = email['uid'] as int? ?? 0;
            if (uid == 0) {
              if (_debugMode) print("⚠️ Skipping email with UID 0: ${email['subject']}");
              continue;
            }
            
            // Fetch full body for this message using UID FETCH
            final sequence = MessageSequence.fromId(uid, isUid: true);
            final fetchResult = await imapClient.uidFetchMessages(sequence, '(BODY.PEEK[])');
            
            if (fetchResult.messages.isNotEmpty) {
              final message = fetchResult.messages.first;
              
              // Get HTML or text content
              String htmlContent = message.decodeTextHtmlPart() ?? '';
              String textContent = message.decodeTextPlainPart() ?? '';
              String content = htmlContent.isNotEmpty ? htmlContent : textContent;
              if (content.isEmpty) content = 'No content available';
              
              // ANDROID: Truncate content to prevent cursor window errors
              const maxContentSize = 500000; // 500KB limit
              if (Platform.isAndroid && content.length > maxContentSize) {
                content = content.substring(0, maxContentSize) + 
                    '\n\n[Content truncated for Android compatibility]';
                if (_debugMode) print("⚠️ Truncated large email body");
              }
              
              String rawEmail = message.toString();
              const maxRawSize = 750000; // 750KB limit for raw email
              if (Platform.isAndroid && rawEmail.length > maxRawSize) {
                rawEmail = rawEmail.substring(0, maxRawSize) + 
                    '\n\n[Raw email truncated for Android compatibility]';
              }
              
              // Update email with body content
              await db.update(
                'emails',
                {
                  'content': content,
                  'bodyFetched': 1,
                  'rawEmail': rawEmail,
                },
                where: 'messageId = ?',
                whereArgs: [email['messageId']],
              );
              
              // Update UI periodically
              if (mounted && _debugEmailsProcessed % 10 == 0) {
                await _loadEmailsFromDb(refresh: true);
              }
            }
          } catch (e) {
            if (_debugMode) print("⚠️ Error fetching body for message: $e");
            continue;
          }
          
          // Yield control to prevent blocking
          await Future.delayed(Duration(milliseconds: 50));
        }
        
        print("✅ Background body fetch completed for $folderName");
        
        // Final UI update
        if (mounted) {
          await _loadEmailsFromDb(refresh: true);
        }
        
        // Close the connection
        await imapClient.logout();
        
      } catch (e) {
        final errorMsg = e.toString();
        final truncated = errorMsg.length > 200 ? '${errorMsg.substring(0, 200)}...' : errorMsg;
        print("❌ Background body fetch failed: $truncated");
      }
    });
  }
  
  // OLD: Fetch bodies in background (kept for reference, uses shared connection)
  void _fetchBodiesInBackground(ImapClient imapClient, EmailAccount account, String folderName) {
    // Run in background without awaiting
    Future.microtask(() async {
      try {
        final db = await DatabaseHelper.instance.database;
        
        // Get emails that don't have bodies yet
        // On Android: Only fetch bodies for recent unread emails first (priority)
        // Bodies will be fetched on-demand when user opens an email
        final emailsNeedingBodies = await db.query(
          'emails',
          where: 'accountId = ? AND folderPath = ? AND bodyFetched = 0',
          whereArgs: [account.username, folderName],
          orderBy: 'isRead ASC, timestamp DESC', // Unread first, then newest
          limit: Platform.isAndroid ? 200 : 500, // Fetch more on Android now that we have better handling
        );
        
        if (emailsNeedingBodies.isEmpty) return;
        
        print("📦 Fetching ${emailsNeedingBodies.length} email bodies in background...");
        
        for (var email in emailsNeedingBodies) {
          try {
            final uid = email['uid'] as int? ?? 0;
            if (uid == 0) {
              // Skip emails without valid UIDs (old data or sync issues)
              if (_debugMode) print("⚠️ Skipping email without UID: ${email['messageId']}");
              continue;
            }
            
            // Fetch full body for this message using UID FETCH
            final sequence = MessageSequence.fromId(uid, isUid: true);
            final fetchResult = await imapClient.uidFetchMessages(sequence, '(BODY.PEEK[])');
            
            if (fetchResult.messages.isNotEmpty) {
              final message = fetchResult.messages.first;
              
              // Get HTML or text content
              String htmlContent = message.decodeTextHtmlPart() ?? '';
              String textContent = message.decodeTextPlainPart() ?? '';
              String content = htmlContent.isNotEmpty ? htmlContent : textContent;
              if (content.isEmpty) content = 'No content available';
              
              // ANDROID: Truncate content to prevent cursor window errors
              const maxContentSize = 500000; // 500KB limit
              if (Platform.isAndroid && content.length > maxContentSize) {
                content = content.substring(0, maxContentSize) + 
                    '\n\n[Content truncated for Android compatibility]';
                if (_debugMode) print("⚠️ Truncated large email body");
              }
              
              String rawEmail = message.toString();
              const maxRawSize = 750000; // 750KB limit for raw email
              if (Platform.isAndroid && rawEmail.length > maxRawSize) {
                rawEmail = rawEmail.substring(0, maxRawSize) + 
                    '\n\n[Raw email truncated for Android compatibility]';
              }
              
              // Update email with body content
              await db.update(
                'emails',
                {
                  'content': content,
                  'bodyFetched': 1,
                  'rawEmail': rawEmail,
                },
                where: 'messageId = ?',
                whereArgs: [email['messageId']],
              );
              
              // Update UI periodically
              if (mounted && _debugEmailsProcessed % 10 == 0) {
                await _loadEmailsFromDb(refresh: true);
              }
            }
          } catch (e) {
            // Don't print full exception - it might contain binary data!
            final errorMsg = e.toString();
            final shortError = errorMsg.length > 200 ? errorMsg.substring(0, 200) + '...' : errorMsg;
            if (_debugMode) print("⚠️ Error fetching body for message: $shortError");
            continue;
          }
          
          // Yield control to prevent blocking
          await Future.delayed(Duration(milliseconds: 50));
        }
        
        print("✅ Background body fetch completed for $folderName");
        
        // Final UI update
        if (mounted) {
          await _loadEmailsFromDb(refresh: true);
        }
        
      } catch (e) {
        print("❌ Background body fetch failed: $e");
      }
    });
  }
  
  Future<void> _fetchEmailsFromFolderBackground(ImapClient imapClient, EmailAccount account, String folderName) async {
    setState(() {
      _debugCurrentFolder = folderName;
      _debugCurrentBatch = 0;
      _debugLastActivity = DateTime.now();
    });
    
    // Select the specific folder
    final Mailbox mailbox;
    if (folderName.toUpperCase() == 'INBOX') {
      mailbox = await imapClient.selectInbox();
    } else {
      // Find the mailbox by name and select it
      final mailboxes = await imapClient.listMailboxes();
      final targetMailbox = mailboxes.firstWhere(
        (mb) => mb.name == folderName,
        orElse: () => throw Exception('Mailbox $folderName not found'),
      );
      mailbox = await imapClient.selectMailbox(targetMailbox);
    }

    final messageCount = mailbox.messagesExists;
    print("� $folderName: $messageCount messages");

    if (messageCount > 0) {
      // Check if we should fetch more emails (Android optimization)
      if (Platform.isAndroid) {
        final shouldFetch = await DatabaseHelper.instance.shouldFetchMoreEmails(
          accountId: account.username, 
          folderPath: folderName,
          maxEmailsInFolder: messageCount,
        );
        if (!shouldFetch) {
          print("⏭️ [DEBUG] Skipping $folderName - sufficient emails already downloaded");
          return;
        }
      }
      
      // ANDROID OPTIMIZATION: Smaller batch size and yield points
      const batchSize = 100;
      final maxMessages = Platform.isAndroid ? 100 : messageCount; // Much smaller limit on Android
      final actualMessageCount = min(messageCount, maxMessages);

      final totalBatches = (actualMessageCount / batchSize).ceil();
      setState(() {
        _debugTotalBatches = totalBatches;
      });

      print("📦 Processing $actualMessageCount messages in $totalBatches batches (newest first)");

      // FETCH NEWEST FIRST: Start from messageCount and work backwards
      // This ensures newest emails are fetched first for better UX
      for (int batchNum = 0; batchNum < totalBatches; batchNum++) {
        // Calculate range from the end (newest) going backwards
        final batchEnd = messageCount - (batchNum * batchSize);
        final batchStart = max(batchEnd - batchSize + 1, messageCount - actualMessageCount + 1);
        final currentBatch = batchNum + 1;

        setState(() {
          _debugCurrentBatch = currentBatch;
          _debugLastActivity = DateTime.now();
        });

        // Only print batch info in verbose debug mode
        if (_debugMode) {
          print("📦 Batch $currentBatch/$totalBatches: Messages $batchStart-$batchEnd (newest first)");
        }

        // Show progress in debug mode
        if (_debugMode && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("📦 ${account.username}/$folderName: Batch $currentBatch/$totalBatches"),
              duration: Duration(milliseconds: 500),
            ),
          );
        }

        // Additional validation for sequence range
        if (batchStart < 1 || batchEnd < batchStart || batchEnd > messageCount || batchStart > messageCount) {
          final errorMsg = "❌ Invalid sequence range: $batchStart-$batchEnd (total: $messageCount), skipping batch";
          print(errorMsg);
          setState(() {
            _debugLastError = errorMsg;
          });
          continue;
        }

        // Additional safety check for empty ranges
        if (batchEnd < batchStart) {
          final errorMsg = "❌ Invalid batch range: start($batchStart) > end($batchEnd), skipping";
          print(errorMsg);
          setState(() {
            _debugLastError = errorMsg;
          });
          continue;
        }
        
        final sequence = MessageSequence.fromRange(
          batchStart,
          batchEnd,
          isUidSequence: false,
        );
        
        // Try a more conservative IMAP fetch approach with error handling
        late FetchImapResult fetchResult;
        try {
          // Use proper FETCH syntax with parentheses for multiple items
          fetchResult = await imapClient.fetchMessages(
            sequence,
            '(BODY.PEEK[] FLAGS)',
          );
        } catch (fetchError) {
          final errorStr = fetchError.toString();
          final errorPreview = errorStr.length > 150 ? errorStr.substring(0, 150) + '...' : errorStr;
          final errorMsg = "⚠️ BODY.PEEK fetch failed for messages $batchStart-$batchEnd: $errorPreview";
          print(errorMsg);
          setState(() {
            _debugLastError = errorMsg;
          });
          
          // Try alternative fetch method without BODY.PEEK
          try {
            fetchResult = await imapClient.fetchMessages(
              sequence,
              '(BODY[] FLAGS)',
            );
            if (_debugMode) print("✅ Alternative BODY fetch worked");
          } catch (altFetchError) {
            final altErrorStr = altFetchError.toString();
            final altErrorPreview = altErrorStr.length > 150 ? altErrorStr.substring(0, 150) + '...' : altErrorStr;
            print("ERROR: BODY fetch failed: $altErrorPreview");
            
            // Try just headers as last resort
            try {
              fetchResult = await imapClient.fetchMessages(
                sequence,
                '(ENVELOPE FLAGS)',
              );
              if (_debugMode) print("✅ ENVELOPE fallback worked");
            } catch (envFetchError) {
              final envErrorStr = envFetchError.toString();
              final envErrorPreview = envErrorStr.length > 150 ? envErrorStr.substring(0, 150) + '...' : envErrorStr;
              print("ERROR: All fetch methods failed: $envErrorPreview");
              continue; // Skip this batch entirely
            }
          }
        }

        final db = await DatabaseHelper.instance.database;
        final existingMessages = await db.query(
          'emails',
          columns: ['messageId'],
          where: 'accountId = ? AND folderPath = ?',
          whereArgs: [account.username, folderName],
        );
        final existingMessageIds = existingMessages
            .map((msg) => msg['messageId'] as String)
            .toSet();

        int newEmailsAdded = 0;
        for (var message in fetchResult.messages) {
          // ANDROID OPTIMIZATION: Yield control every 5 messages to prevent UI freeze and ANR
          if (Platform.isAndroid && newEmailsAdded % 5 == 0) {
            await Future.delayed(Duration(milliseconds: 10)); // Give UI thread time to breathe
          }
          
          final String messageId = message.guid?.toString() ??
              message.uid?.toString() ??
              message.sequenceId?.toString() ??
              "${account.username}_${folderName}_${DateTime.now().millisecondsSinceEpoch}_$newEmailsAdded";

          if (existingMessageIds.contains(messageId)) continue;

          String senderName = 'Unknown';
          String senderEmail = 'unknown@example.com';
          
          // First try to get sender from envelope.from (the actual sender)
          if (message.envelope?.from != null &&
              message.envelope!.from!.isNotEmpty) {
            var sender = message.envelope!.from![0];
            senderName = (sender.personalName?.isNotEmpty == true) ? sender.personalName! : sender.email;
            senderEmail = sender.email;
          }
          
          // If envelope.from is not available, try parsing the From header
          if (senderEmail == 'unknown@example.com') {
            final fromHeader = message.getHeaderValue('from');
            if (fromHeader?.isNotEmpty ?? false) {
              try {
                var from = MailAddress.parse(fromHeader!);
                senderName = (from.personalName?.isNotEmpty == true) ? from.personalName! : from.email;
                senderEmail = from.email;
              } catch (e) {
                print("Error parsing From header: $e");
              }
            }
          }

          final timestamp =
              message.envelope?.date?.millisecondsSinceEpoch ??
                  _parseEmailDate(message.getHeaderValue('date')) ??
                  DateTime.now().millisecondsSinceEpoch;

          // Prefer HTML content over plain text when available to preserve CID references
          String htmlContent = message.decodeTextHtmlPart() ?? '';
          String textContent = message.decodeTextPlainPart() ?? '';
          String content = htmlContent.isNotEmpty ? htmlContent : textContent;
          if (content.isEmpty) content = 'No content available';

          // Minimal logging for all runs
          final subjectPreview = message.decodeSubject()?.substring(0, min(50, message.decodeSubject()?.length ?? 0)) ?? 'No subject';
          final dateStr = message.envelope?.date != null ? DateFormat('MMM dd').format(message.envelope!.date!) : 'No date';
          print("📧 $dateStr | From: $senderName | $subjectPreview...");
          
          // Verbose debug logging
          if (_debugMode) {
            print("   [DEBUG] HTML: ${htmlContent.length} bytes, Text: ${textContent.length} bytes");
          }

          List<Map<String, dynamic>> attachments = [];
          int hasAttachments = 0;
          int hasImages = 0;
          
          // Process all parts including nested parts
          void processPartsRecursively(List<MimePart>? parts) {
            if (parts == null) return;
            
            for (int i = 0; i < parts.length; i++) {
              var part = parts[i];
              
              // Process nested parts first
              if (part.parts != null && part.parts!.isNotEmpty) {
                processPartsRecursively(part.parts);
              }
              
              final disposition = part.getHeaderValue('content-disposition');
              final contentType = part.getHeaderValue('content-type') ?? 'application/octet-stream';
              bool isAttachment = disposition?.toLowerCase().contains('attachment') ?? false;
              bool isInline = disposition?.toLowerCase().contains('inline') ?? false;
              bool isImage = contentType.toLowerCase().startsWith('image/');

              if (_debugMode) {
                print("DEBUG: Part $i - isAttachment: $isAttachment, isInline: $isInline, isImage: $isImage");
              }

              // Store all attachments and all images (including inline images)
              if (isAttachment || isImage || isInline) {
                final filename = part.getHeaderValue('filename') ??
                    (disposition != null && disposition.contains('filename=')
                        ? disposition.split('filename=')[1].replaceAll('"', '').trim()
                        : 'attachment_${contentType.split('/').last}');
                final data = part.decodeContentBinary();
                if (data != null) {
                  // Get Content-ID with better fallback handling
                  String? contentId = part.getHeaderValue('content-id') ?? part.getHeaderValue('Content-ID');
                  if (contentId != null) {
                    contentId = contentId.replaceAll('<', '').replaceAll('>', '');
                  }
                  
                  // Process attachment data
                  attachments.add({
                    'filename': filename,
                    'contentType': contentType,
                    'data': base64Encode(data),
                    'cid': contentId,
                    'disposition': disposition?.toLowerCase() ?? '',
                    'isInline': isInline,
                  });
                  hasAttachments = 1;
                  if (isImage) {
                    hasImages = 1;
                  }
                }
              }
            }
          }
          
          processPartsRecursively(message.parts);
          
          // Now process the HTML content to replace CID references with data URLs
          if (htmlContent.isNotEmpty && attachments.isNotEmpty) {
            content = _replaceCidReferences(htmlContent, attachments);
          }
          
          if (_debugMode) {
            print("DEBUG: Found ${attachments.length} attachments total");
          }

          String attachmentsJson = jsonEncode(attachments);

          String? inReplyTo = message.getHeaderValue('in-reply-to');
          String references = message.getHeaderValue('references') ?? '';
          String subject = message.decodeSubject() ?? '(No Subject)';

          final relatedEmails =
              await DatabaseHelper.instance.findThreadEmails(
            senderEmail: senderEmail,
            subject: subject,
            accountId: account.username,
            inReplyTo: inReplyTo,
            references: references,
          );

          String threadParentId = messageId;
          if (relatedEmails.isNotEmpty) {
            // Find the OLDEST email in the thread - that's the thread root/parent
            final oldestRelated = relatedEmails.reduce((a, b) =>
                (a['timestamp'] as int) < (b['timestamp'] as int) ? a : b);
            threadParentId = oldestRelated['messageId'] as String;
            
            if (_debugMode) {
              print('DEBUG: Threading - found ${relatedEmails.length} related emails, root: $threadParentId');
            }
          }

          // Try to get raw email content
          String rawEmailContent = '';
          try {
            // Check if the MimeMessage has methods to access raw content
            // Try toString() first, which might give us the reconstructed message
            rawEmailContent = message.toString();
            
            // If that doesn't work, try to rebuild from envelope and parts
            if (rawEmailContent.isEmpty && message.envelope != null) {
              // Build raw content from headers and parts
              final headers = <String>[];
              
              // Add major headers
              if (message.getHeaderValue('message-id') != null) {
                headers.add('Message-ID: ${message.getHeaderValue('message-id')}');
              }
              if (message.getHeaderValue('date') != null) {
                headers.add('Date: ${message.getHeaderValue('date')}');
              }
              if (message.getHeaderValue('from') != null) {
                headers.add('From: ${message.getHeaderValue('from')}');
              }
              if (message.getHeaderValue('to') != null) {
                headers.add('To: ${message.getHeaderValue('to')}');
              }
              if (message.getHeaderValue('subject') != null) {
                headers.add('Subject: ${message.getHeaderValue('subject')}');
              }
              if (message.getHeaderValue('content-type') != null) {
                headers.add('Content-Type: ${message.getHeaderValue('content-type')}');
              }
              
              rawEmailContent = headers.join('\r\n') + '\r\n\r\n' + content;
            }
          } catch (e) {
            if (_debugMode) {
              print("DEBUG: Could not get raw email content: $e");
            }
            // Fallback: just use the processed content
            rawEmailContent = content;
          }

          // Parse IMAP flags from the message
          final imapFlags = ImapFlagsHelper.parseImapFlags(message);

          try {
            await DatabaseHelper.instance.insertEmail({
              'messageId': messageId,
              'accountId': account.username,
              'subject': subject,
              'sender': senderName,
              'senderEmail': senderEmail,
              'timestamp': timestamp,
              'content': content,
              'isRead': imapFlags['isRead'] ?? 0,
              'isStarred': imapFlags['isStarred'] ?? 0,
              'isAnswered': imapFlags['isAnswered'] ?? 0,
              'isForwarded': imapFlags['isForwarded'] ?? 0,
              'isDraft': imapFlags['isDraft'] ?? 0,
              'isDeleted': imapFlags['isDeleted'] ?? 0,
              'isJunk': imapFlags['isJunk'] ?? 0,
              'folderPath': folderName, // Use the actual folder name instead of hardcoded 'INBOX'
              'inReplyTo': inReplyTo ?? '',
              'references': references,
              'attachments': attachmentsJson,
              'threadParentId': threadParentId,
              'hasAttachments': hasAttachments,
              'hasImages': hasImages,
              'rawEmail': rawEmailContent,
            });
            
            // Clean, consistent logging format
            final dateStr = DateFormat('MMM dd').format(DateTime.fromMillisecondsSinceEpoch(timestamp));
            final subjectPreview = subject.length > 50 ? subject.substring(0, 50) : subject;
            print("✅ $dateStr | From: $senderName | $subjectPreview...");
          } catch (e) {
            // Truncate error to avoid printing attachment data
            final errorStr = e.toString();
            final errorPreview = errorStr.length > 200 ? errorStr.substring(0, 200) + '...[truncated]' : errorStr;
            print("❌ ERROR: Failed to insert email - messageId: $messageId, error: $errorPreview");
            continue; // Skip this email and continue with the next one
          }

          for (var related in relatedEmails) {
            if (related['messageId'] != messageId) {
              await DatabaseHelper.instance.updateThreadParent(
                related['messageId'] as String,
                threadParentId,
              );
            }
          }

          newEmailsAdded++;
          
          // Update debug counter
          setState(() {
            _debugEmailsProcessed++;
            _debugLastActivity = DateTime.now();
          });
        }
        
        // Summarize batch
        if (newEmailsAdded > 0) {
          print("✅ Batch ${batchStart}-${batchEnd}: Added $newEmailsAdded emails from $folderName");
        }
        
        // ANDROID OPTIMIZATION: Update UI after each batch and yield control
        if (Platform.isAndroid && newEmailsAdded > 0) {
          try {
            await _loadEmailsFromDb(refresh: true); // Refresh UI
            await Future.delayed(Duration(milliseconds: 100)); // Let Android render
          } catch (e) {
            print("Warning: UI refresh failed: $e");
          }
        }
        
        // ANDROID: Additional safety - yield after every batch regardless
        if (Platform.isAndroid) {
          await Future.delayed(Duration(milliseconds: 50));
        }
      }
    }
  }

  // NEW: Optimized method for polling that only gets new emails
  Future<void> _fetchNewEmailsOnly() async {
    if (_accounts.isEmpty) {
      print("No accounts found to fetch emails from");
      return;
    }

    for (var account in _accounts) {
      try {
        print("🔄 Checking for new emails for ${account.username}...");
        final imapClient = ImapClient();
        await imapClient.connectToServer(account.imap, 993, isSecure: true);
        await imapClient.login(account.username, account.password);
        final mailbox = await imapClient.selectInbox();

        final messageCount = mailbox.messagesExists;
        
        // Get the count of existing emails for this account
        final db = await DatabaseHelper.instance.database;
        final existingCountResult = await db.rawQuery(
          'SELECT COUNT(*) as count FROM emails WHERE accountId = ?',
          [account.username]
        );
        final existingCount = existingCountResult.first['count'] as int;
        
        if (messageCount > existingCount) {
          // Only fetch the new emails
          final newEmailCount = messageCount - existingCount;
          print("📧 Found $newEmailCount new emails for ${account.username}");
          
          // Validate sequence before creating it
          final startSeq = existingCount + 1;
          final endSeq = messageCount;
          
          if (startSeq > endSeq || startSeq < 1 || endSeq < 1 || endSeq > messageCount) {
            print("ERROR: Invalid sequence range for new emails: $startSeq-$endSeq (messageCount: $messageCount)");
            await imapClient.logout();
            continue;
          }
          
          print("DEBUG: Creating sequence for new emails $startSeq-$endSeq for ${account.username}");
          
          final sequence = MessageSequence.fromRange(
            startSeq,
            endSeq,
            isUidSequence: false,
          );
          
          try {
            // Try basic FLAGS fetch first
            await imapClient.fetchMessages(sequence, '(FLAGS)');
            print("DEBUG: Basic FLAGS fetch successful for new emails");
            
            // Now try full fetch
            final fetchResult = await imapClient.fetchMessages(
              sequence,
              '(BODY.PEEK[] FLAGS)',
            );
            print("SUCCESS: Full fetch successful for ${account.username}");

            int newEmailsAdded = 0;
            for (var message in fetchResult.messages) {
              final processedEmail = await DatabaseHelper.instance.processImapMessage(message, account, 'INBOX');
              if (processedEmail != null) {
                newEmailsAdded++;
              }
            }
            
            print("📧 Added $newEmailsAdded new emails for ${account.username}");
          } catch (fetchError) {
            print("ERROR: Failed to fetch new emails for ${account.username}: $fetchError");
          }
        } else {
          print("📧 No new emails for ${account.username}");
        }

        await imapClient.logout();
      } catch (e) {
        print("Error checking new emails for ${account.username}: $e");
      }
    }
  }

  int? _parseEmailDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    try {
      final dateFormat = DateFormat('EEE, dd MMM yyyy HH:mm:ss Z');
      final date = dateFormat.parse(dateStr, true);
      return date.millisecondsSinceEpoch;
    } catch (e) {
      print("Error parsing date '$dateStr': $e");
      return null;
    }
  }

  Future<void> _loadEmailsFromDb({bool refresh = false}) async {
    final currentFilter = FilterManager.instance.currentFilter;
    
    // Debug output disabled to reduce console spam
    
    // Safety check - if no accounts are enabled, don't query (would return no results)
    if (currentFilter.enabledAccounts.isEmpty) {
      setState(() {
        if (refresh || _offset == 0) {
          _emails = [];
        }
      });
      return;
    }

    // Get thread roots (emails where threadParentId = messageId)
    final emails = await DatabaseHelper.instance.getEmails(
      searchQuery: '', // Remove old search - use filter system only
      limit: _limit * 3, // Get more emails to account for filtering
      offset: _offset,
      filter: currentFilter, // Use filter system
    );

    // Query database to get the latest timestamp for each thread
    // This is necessary because getEmails only returns thread roots, not replies
    final db = await DatabaseHelper.instance.database;
    final threadIds = emails.map((e) => e['messageId'] as String).toList();

    // Build a map of threadParentId -> latest timestamp
    Map<String, int> threadLatestTimestamps = {};
    if (threadIds.isNotEmpty) {
      final placeholders = List.filled(threadIds.length, '?').join(',');
      final result = await db.rawQuery(
        'SELECT threadParentId, MAX(timestamp) as maxTimestamp FROM emails WHERE threadParentId IN ($placeholders) GROUP BY threadParentId',
        threadIds,
      );
      for (final row in result) {
        final threadParentId = row['threadParentId'] as String;
        final maxTimestamp = row['maxTimestamp'] as int;
        threadLatestTimestamps[threadParentId] = maxTimestamp;
      }
    }

    // Add the latest thread timestamp to each email for sorting
    final threadParents = <Map<String, dynamic>>[];
    for (final email in emails) {
      final root = Map<String, dynamic>.from(email);
      final messageId = email['messageId'] as String;
      // Use the latest timestamp from the thread, or fall back to the email's own timestamp
      root['_threadLatestTimestamp'] = threadLatestTimestamps[messageId] ?? email['timestamp'] as int;
      threadParents.add(root);
    }

    // Sort threads by newest message timestamp (threads with new replies appear first)
    threadParents.sort((a, b) => (b['_threadLatestTimestamp'] as int).compareTo(a['_threadLatestTimestamp'] as int));
    final limitedThreads = threadParents.take(_limit).toList();

    setState(() {
      if (refresh || _offset == 0) {
        _emails = List<Map<String, dynamic>>.from(limitedThreads);
      } else {
        _emails.addAll(limitedThreads);
      }
      // Sort by thread's latest timestamp (if available) so threads with new replies appear first
      _emails.sort((a, b) {
        final aTime = a['_threadLatestTimestamp'] as int? ?? a['timestamp'] as int;
        final bTime = b['_threadLatestTimestamp'] as int? ?? b['timestamp'] as int;
        return bTime.compareTo(aTime);
      });
    });

    // Pre-compute thread reply status for visible emails
    await _preloadThreadRepliesStatus(limitedThreads);
  }
  
  /// Pre-load reply status for a list of thread parent emails
  Future<void> _preloadThreadRepliesStatus(List<Map<String, dynamic>> emails) async {
    final db = await DatabaseHelper.instance.database;

    // Get all thread parent IDs and their threadParentIds
    final threadChecks = <String, String>{};
    for (final email in emails) {
      final messageId = email['messageId'] as String;
      final threadParentId = email['threadParentId'] as String? ?? messageId;
      if (!_threadRepliesStatus.containsKey(messageId)) {
        threadChecks[messageId] = threadParentId;
      }
    }

    if (threadChecks.isEmpty) return;

    // For each root email, check if there are other emails in the same thread
    // and find the latest timestamp
    for (final entry in threadChecks.entries) {
      final rootMessageId = entry.key;
      final threadParentId = entry.value;

      // Get count and max timestamp in one query
      final result = await db.rawQuery('''
        SELECT COUNT(*) as count, MAX(timestamp) as maxTimestamp
        FROM emails
        WHERE threadParentId = ?
      ''', [threadParentId]);

      final count = result.first['count'] as int;
      final maxTimestamp = result.first['maxTimestamp'] as int?;

      // Has replies if count > 1 (includes the root itself)
      _threadRepliesStatus[rootMessageId] = count > 1;

      // Store the latest timestamp for this thread
      if (maxTimestamp != null) {
        _threadLatestTimestamps[rootMessageId] = maxTimestamp;
      }
    }

    // Enforce cache limits to prevent unbounded memory growth
    _enforceThreadCacheLimits();

    if (mounted) {
      setState(() {});
    }

    print('DEBUG: Preloaded reply status for ${threadChecks.length} threads');
  }

  Future<void> _loadMoreEmails() async {
    _offset += _limit;
    await _loadEmailsFromDb();
  }

  // Thread management methods
  Future<void> _toggleThread(String threadParentId) async {
    setState(() {
      if (_expandedThreads.contains(threadParentId)) {
        _expandedThreads.remove(threadParentId);
      } else {
        _expandedThreads.add(threadParentId);
      }
    });

    // Load thread emails if not cached
    if (_expandedThreads.contains(threadParentId) && !_threadCache.containsKey(threadParentId)) {
      final threadEmails = await DatabaseHelper.instance.getThreadEmails(threadParentId);
      setState(() {
        _threadCache[threadParentId] = threadEmails;
        _enforceThreadCacheLimits();
      });
    }
  }

  bool _isThreadExpanded(String threadParentId) {
    return _expandedThreads.contains(threadParentId);
  }

  List<Map<String, dynamic>> _getThreadEmails(String threadParentId) {
    return _threadCache[threadParentId] ?? [];
  }

  // Cache for latest thread timestamps
  Map<String, int> _threadLatestTimestamps = {};

  // Get the latest timestamp in a thread (for display purposes)
  // If there are replies, return the most recent reply timestamp
  // Otherwise, return the parent email's timestamp
  int _getLatestThreadTimestamp(Map<String, dynamic> email) {
    final messageId = email['messageId'] as String;
    final baseTimestamp = email['timestamp'] as int? ?? 0;

    // Check if we have a cached latest timestamp
    if (_threadLatestTimestamps.containsKey(messageId)) {
      return _threadLatestTimestamps[messageId]!;
    }

    // Otherwise return base timestamp
    return baseTimestamp;
  }

  Widget _buildThreadView(String threadParentId, EmailAccount account) {
    final threadEmails = _getThreadEmails(threadParentId);
    
    if (threadEmails.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(left: 24.0, right: 8.0, bottom: 8.0),
        child: Card(
          color: Colors.grey.shade100,
          child: const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      );
    }

    // Filter out the main email (parent) and sort by timestamp DESCENDING (newest first)
    final replyEmails = threadEmails
        .where((email) => email['messageId'] != threadParentId)
        .toList()
      ..sort((a, b) => (b['timestamp'] as int).compareTo(a['timestamp'] as int));

    return Container(
      margin: const EdgeInsets.only(left: 24.0, right: 8.0, bottom: 8.0),
      child: Column(
        children: replyEmails.map((threadEmail) {
          final bool hasImages = (threadEmail['hasImages'] ?? 0) == 1;
          final attachments = attachmentsWithoutImages(threadEmail['attachments'] ?? '[]');
          final bool hasNonImageAttachments = attachments.isNotEmpty;

          return Card(
            margin: const EdgeInsets.only(bottom: 4.0),
            // Use same card styling as parent - no special color
            child: ListTile(
              dense: true,
              leading: _isSelectionMode
                  ? Checkbox(
                      value: _selectedEmailIds.contains(threadEmail['id'].toString()),
                      onChanged: (bool? value) {
                        _toggleEmailSelection(threadEmail['id'].toString());
                      },
                    )
                  : CircleAvatar(
                      radius: 16,
                      backgroundColor: account.color,
                      child: Text(
                        account.display[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
              title: Row(
                children: [
                  const Icon(Icons.subdirectory_arrow_right, size: 16, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      threadEmail['subject'] ?? 'No Subject',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasImages) 
                    const Padding(
                      padding: EdgeInsets.only(left: 4.0),
                      child: Icon(Icons.image, size: 14, color: Colors.orange),
                    ),
                  if (hasNonImageAttachments)
                    const Padding(
                      padding: EdgeInsets.only(left: 4.0),
                      child: Icon(Icons.attach_file, size: 14, color: Colors.blue),
                    ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${threadEmail['sender']} <${threadEmail['senderEmail']}>',
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    DateFormat('MMM d, yyyy h:mm a').format(
                      DateTime.fromMillisecondsSinceEpoch(
                        threadEmail['timestamp'] ?? 0,
                      ),
                    ),
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
              onTap: () {
                if (_isSelectionMode) {
                  _toggleEmailSelection(threadEmail['id'].toString());
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => EmailDetailScreen(
                        email: threadEmail,
                        account: account,
                        alwaysShowText: _alwaysShowText,
                      ),
                    ),
                  );
                }
              },
              onLongPress: () {
                _toggleEmailSelection(threadEmail['id'].toString());
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  // Email polling methods
  void _startEmailPolling() {
    _emailPollTimer = Timer.periodic(_pollInterval, (timer) {
      _checkForNewEmails();
    });
    print('📧 Started automatic email polling every ${_pollInterval.inMinutes} minutes');
  }

  Future<void> _checkForNewEmails() async {
    if (_isSyncing) {
      print('📧 Skipping email check - sync already in progress');
      return;
    }

    print('📧 Checking for new emails...');
    try {
      // DISABLED: Old _fetchNewEmailsOnly() uses sequence numbers and causes issues
      // Use the background fetch method instead which uses UIDs properly
      print('📧 Using background sync method for email check...');
      await _fetchEmailsBackground();
      
      // Refresh email list to show new emails
      await _loadEmailsFromDb(refresh: true);
      // Refresh filter sidebar counts and badges
      FilterManager.instance.refreshEmailCounts();
      
      print('📧 Email check completed successfully');
    } catch (e) {
      print('📧 Error during automatic email check: $e');
    }
  }

  void _showAccountSetupDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('No Email Accounts'),
        content: const Text(
            'Would you like to set up an email account or import accounts from a JSON file?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _showAccountAddDialog();
            },
            child: const Text('Add Account'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _importAccounts();
            },
            child: const Text('Import Accounts'),
          ),
        ],
      ),
    );
  }

  void _showAccountAddDialog() {
    final formKey = GlobalKey<FormState>();
    String imap = '';
    String smtp = '';
    String username = '';
    String password = '';
    String replyFrom = '';
       String name = '';
    String signature = '';
    Color color = Colors.red;
    String display = '';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Email Account'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  decoration: const InputDecoration(labelText: 'IMAP Server'),
                  validator: (value) => value!.isEmpty ? 'Required' : null,
                  onSaved: (value) => imap = value!,
                ),
                TextFormField(
                  decoration: const InputDecoration(labelText: 'SMTP Server'),
                  validator: (value) => value!.isEmpty ? 'Required' : null,
                  onSaved: (value) => smtp = value!,
                ),
                TextFormField(
                  decoration:
                      const InputDecoration(labelText: 'Email Username'),
                  validator: (value) => value!.isEmpty ? 'Required' : null,
                  onSaved: (value) => username = value!,
                ),
                TextFormField(
                  decoration: const InputDecoration(labelText: 'Password'),
                  obscureText: true,
                  validator: (value) => value!.isEmpty ? 'Required' : null,
                  onSaved: (value) => password = value!,
                ),
                TextFormField(
                  decoration:
                      const InputDecoration(labelText: 'Reply-From Email'),
                  validator: (value) => value!.isEmpty ? 'Required' : null,
                  onSaved: (value) => replyFrom = value!,
                ),
                TextFormField(
                  decoration: const InputDecoration(labelText: 'Display Name'),
                  validator: (value) => value!.isEmpty ? 'Required' : null,
                  onSaved: (value) => name = value!,
                ),
                TextFormField(
                  decoration:
                      const InputDecoration(labelText: 'Email Signature'),
                  maxLines: 3,
                  onSaved: (value) => signature = value ?? '',
                ),
                TextFormField(
                  decoration:
                      const InputDecoration(labelText: 'Initials (Display)'),
                  validator: (value) => value!.isEmpty ? 'Required' : null,
                  onSaved: (value) => display = value!,
                ),
                Row(
                  children: [
                    const Text('Account Color: '),
                    const Spacer(),
                    Container(
                      width: 24,
                      height: 24,
                      color: color,
                    ),
                    IconButton(
                      icon: const Icon(Icons.color_lens),
                      onPressed: () {
                        setState(() {
                          color = Colors.accents[
                              DateTime.now().second % Colors.accents.length];
                        });
                      },
                    ),
                  ],
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
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                formKey.currentState!.save();
                final account = EmailAccount(
                  imap: imap,
                  smtp: smtp,
                  username: username,
                  password: password,
                  replyFrom: replyFrom,
                  name: name,
                  signature: signature,
                  color: color,
                  display: display,
                );
                await DatabaseHelper.instance.insertAccount(account);
                Navigator.of(context).pop();
                await _loadAccounts();
                await _fetchEmailsBackground(); // Use new parallel headers-first method
                await _loadEmailsFromDb();
                FilterManager.instance.refreshEmailCounts();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _importAccounts() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null) {
        final file = File(result.files.single.path!);
        final jsonString = await file.readAsString();
        final jsonData = jsonDecode(jsonString);

        if (jsonData['accounts'] != null && jsonData['accounts'] is List) {
          const secureStorage = FlutterSecureStorage();
          for (var accountData in jsonData['accounts']) {
            final account = EmailAccount.fromJson(accountData);
            await secureStorage.write(
                key: 'account_${account.username}_password',
                value: account.password);
            await DatabaseHelper.instance.insertAccount(account);
          }
          setState(() {
            _accounts = [];
          });
          await _loadAccounts();
          await _fetchEmailsBackground(); // Use new parallel headers-first method
          await _loadEmailsFromDb();
          FilterManager.instance.refreshEmailCounts();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Accounts imported successfully')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No valid accounts found in file')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error importing accounts: $e')),
      );
    }
  }

  Future<void> _exportAccounts() async {
    try {
      final accounts = await DatabaseHelper.instance.getAccounts();
      final jsonData = {
        'accounts': accounts.map((account) => account.toJson()).toList(),
      };
      final jsonString = jsonEncode(jsonData);
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/furimail_accounts.json');
      await file.writeAsString(jsonString);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Accounts exported to ${file.path}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error exporting accounts: $e')),
      );
    }
  }

  void _showAccountManagementScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AccountManagementScreen(
          onAccountsChanged: () async {
            await _loadAccounts();
            await _fetchEmailsBackground(); // Use new parallel headers-first method
            await _loadEmailsFromDb();
            FilterManager.instance.refreshEmailCounts();
          },
        ),
      ),
    );
  }

  // View switching method
  void _switchView(ViewMode view) {
    setState(() {
      _currentView = view;
    });
  }

  // Build content based on current view
  Widget _buildViewContent() {
    switch (_currentView) {
      case ViewMode.mail:
        return _buildEmailListView();
      case ViewMode.calendar:
        return _buildCalendarView();
      case ViewMode.people:
        return _buildPeopleView();
    }
  }

  // Build the email list view (current main content)
  Widget _buildEmailListView() {
    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : _emails.isEmpty
            ? const Center(child: Text('No emails found'))
            : ListView.builder(
                controller: _scrollController,
                itemCount: _emails.length + (_isLoadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _emails.length) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final email = _emails[index];
                  final messageId = email['messageId'] as String;
                  final threadParentId = email['threadParentId'] as String? ?? messageId;

                  // Since we now show the oldest email as the thread root,
                  // we use the email's messageId for thread operations
                  final isThreadExpanded = _isThreadExpanded(threadParentId);

                  // Find account for this email
                  final account = _accounts.firstWhere(
                    (acc) => acc.username == email['accountId'],
                    orElse: () => EmailAccount(
                      imap: '',
                      smtp: '',
                      username: email['accountId'],
                      password: '',
                      replyFrom: '',
                      name: 'Unknown',
                      signature: '',
                      color: Colors.grey,
                      display: email['accountId'].substring(0, 2).toUpperCase(),
                    ),
                  );

                  // Check if this thread has replies (using messageId since this IS the root)
                  final hasReplies = _hasReplies(messageId);

                  return Column(
                    children: [
                      Card(
                        margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: account.color,
                            child: Text(
                              account.display,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  email['subject'] ?? 'No Subject',
                                  style: TextStyle(
                                    fontWeight: (email['isRead'] ?? 0) == 0
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Icons row: attachment, image, threading (in that order)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if ((email['hasAttachments'] ?? 0) == 1)
                                    const Icon(Icons.attach_file, size: 16),
                                  if ((email['hasImages'] ?? 0) == 1)
                                    const Icon(Icons.image, size: 16),
                                  if (hasReplies)
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        // Stop event from bubbling to ListTile
                                        _toggleThread(threadParentId);
                                      },
                                      child: Padding(
                                        padding: const EdgeInsets.all(4.0),
                                        child: Icon(
                                          isThreadExpanded
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                          size: 20,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text('${email['sender']} (${email['senderEmail']})'),
                                  ),
                                  // Date on the right side of sender row
                                  // Show latest thread timestamp if there are replies
                                  Text(
                                    DateFormat('MMM d, yyyy h:mm a').format(
                                      DateTime.fromMillisecondsSinceEpoch(
                                        hasReplies ? _getLatestThreadTimestamp(email) : (email['timestamp'] ?? 0),
                                      ),
                                    ),
                                    style: TextStyle(
                                      color: Colors.grey[600],
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          onTap: () {
                            if (_isSelectionMode) {
                              _toggleEmailSelection(email['id'].toString());
                            } else {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => EmailDetailScreen(
                                    email: email,
                                    account: _accounts.firstWhere((a) => a.username == email['accountId'], orElse: () => _accounts.first),
                                    alwaysShowText: _alwaysShowText,
                                  ),
                                ),
                              );
                            }
                          },
                          onLongPress: () {
                            _toggleEmailSelection(email['id'].toString());
                          },
                          selected: _selectedEmailIds.contains(email['id'].toString()),
                          selectedTileColor: Colors.blue.withOpacity(0.1),
                        ),
                      ),
                      // Thread emails (if expanded)
                      if (isThreadExpanded && hasReplies)
                        _buildThreadView(threadParentId, _accounts.firstWhere((a) => a.username == email['accountId'], orElse: () => _accounts.first)),
                    ],
                  );
                },
              );
  }

  // Build placeholder calendar view
  Widget _buildCalendarView() {
    return CalendarView(accounts: _accounts);
  }

  // Build people/contacts view
  Widget _buildPeopleView() {
    return ContactsView(accounts: _accounts);
  }

  // Helper method to check if thread has replies
  bool _hasReplies(String threadParentId) {
    // Check preloaded status first
    if (_threadRepliesStatus.containsKey(threadParentId)) {
      return _threadRepliesStatus[threadParentId]!;
    }
    
    // Check thread cache if available
    if (_threadCache.containsKey(threadParentId)) {
      return _threadCache[threadParentId]!.where((e) => e['messageId'] != threadParentId).isNotEmpty;
    }
    
    // Not yet loaded - return false to hide arrow until we know
    // This prevents the flash/disappear behavior
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _isSelectionMode ? _buildSelectionAppBar() : _buildNormalAppBar(),
      drawer: FilterDrawer(
        accounts: _accounts,
        onFilterChanged: _onFilterChanged,
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // Filter status bar
              ValueListenableBuilder<EmailFilter>(
                valueListenable: FilterManager.instance.filterNotifier,
                builder: (context, filter, child) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8.0),
                    color: Colors.grey.shade700,
                    child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _buildFilterStatusText(filter),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (filter.hasActiveFilters)
                      TextButton(
                        onPressed: () {
                          FilterManager.instance.clearFilter();
                        },
                        child: const Text(
                          'Clear',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          
          // View content based on selected mode
          Expanded(
            child: _buildViewContent(),
          ),
        ],
      ),
      // Debug overlay for Android email downloading progress
      if (_debugMode && Platform.isAndroid && (_isSyncing || _debugCurrentAccount.isNotEmpty))
        Positioned(
          top: 10,
          right: 10,
          child: Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange, width: 1),
            ),
            constraints: BoxConstraints(maxWidth: 250),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('🔍 Android Debug', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 4),
                if (_debugCurrentAccount.isNotEmpty) ...[
                  Text('Account: $_debugCurrentAccount', style: TextStyle(color: Colors.white, fontSize: 10)),
                  if (_debugCurrentFolder.isNotEmpty)
                    Text('Folder: $_debugCurrentFolder', style: TextStyle(color: Colors.white, fontSize: 10)),
                  if (_debugCurrentBatch > 0)
                    Text('Batch: $_debugCurrentBatch/$_debugTotalBatches', style: TextStyle(color: Colors.white, fontSize: 10)),
                  Text('Emails: $_debugEmailsProcessed', style: TextStyle(color: Colors.white, fontSize: 10)),
                ],
                if (_debugLastError.isNotEmpty) ...[
                  SizedBox(height: 4),
                  Text('⚠️ Last Error:', style: TextStyle(color: Colors.red, fontSize: 10)),
                  Text(_debugLastError, style: TextStyle(color: Colors.red, fontSize: 9), maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
                if (_debugLastActivity != null) ...[
                  SizedBox(height: 4),
                  Text('Last Activity: ${DateTime.now().difference(_debugLastActivity!).inSeconds}s ago', 
                       style: TextStyle(color: Colors.grey, fontSize: 9)),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
      floatingActionButton: _currentView == ViewMode.mail
          ? FloatingActionButton(
              onPressed: () {
                if (_accounts.isNotEmpty) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ComposeScreen(
                        account: _accounts.first, // Use first account, or add account selection
                      ),
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please add an email account first')),
                  );
                }
              },
              tooltip: 'Compose Email',
              child: const Icon(Icons.edit),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentView.index,
        onTap: (index) => _switchView(ViewMode.values[index]),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.email),
            label: 'Mail',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_today),
            label: 'Calendar',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.people),
            label: 'People',
          ),
        ],
      ),
    );
  }

  List<dynamic> attachmentsWithoutImages(String attachmentsJson) {
    final attachments =
        jsonDecode(attachmentsJson.isEmpty ? '[]' : attachmentsJson);
    return attachments
        .where((a) => !a['contentType'].toString().startsWith('image/'))
        .toList();
  }

  // Test function to process mbox files directly
  Future<void> _processMboxFile(String filename) async {
    // Implementation would go here for processing mbox files
    print('Processing mbox file: $filename');
  }

  // Helper method to replace CID references with data URLs
  String _replaceCidReferences(String htmlContent, List<Map<String, dynamic>> attachments) {
    String processedContent = htmlContent;
    
    for (var attachment in attachments) {
      final cid = attachment['cid'];
      if (cid != null && cid.isNotEmpty) {
        final contentType = attachment['contentType'];
        final data = attachment['data'];
        
        if (data != null && contentType != null) {
          final dataUrl = 'data:$contentType;base64,$data';
          processedContent = processedContent.replaceAll('cid:$cid', dataUrl);
        }
      }
    }
    
    return processedContent;
  }
}

// Define ReplyScreen that's used in EmailDetailScreen
class ReplyScreen extends StatelessWidget {
  final Map<String, dynamic> email;
  final dynamic account;

  const ReplyScreen({
    Key? key,
    required this.email,
    required this.account,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final TextEditingController controller = TextEditingController();
    return Scaffold(
      appBar: AppBar(
        title: Text('Reply to ${email['subject']}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Sending functionality coming soon')),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: controller,
              maxLines: 10,
              decoration: const InputDecoration(
                hintText: 'Type your reply...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (account.signature.isNotEmpty)
              Text(
                '\n\n${account.signature}',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Comprehensive Account Management Screen
class AccountManagementScreen extends StatefulWidget {
  final VoidCallback onAccountsChanged;

  const AccountManagementScreen({
    Key? key,
    required this.onAccountsChanged,
  }) : super(key: key);

  @override
  _AccountManagementScreenState createState() => _AccountManagementScreenState();
}

class _AccountManagementScreenState extends State<AccountManagementScreen> {
  List<EmailAccount> _accounts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    setState(() {
      _isLoading = true;
    });
    _accounts = await DatabaseHelper.instance.getAccounts();
    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account Management'),
        backgroundColor: Colors.grey.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddAccountDialog,
            tooltip: 'Add Account',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _accounts.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.email_outlined,
                        size: 64,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No Email Accounts',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add your first email account to get started',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _showAddAccountDialog,
                        icon: const Icon(Icons.add),
                        label: const Text('Add Account'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _accounts.length,
                  itemBuilder: (context, index) {
                    final account = _accounts[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: account.color,
                                  child: Text(
                                    account.display.isNotEmpty ? account.display[0].toUpperCase() : '?',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        account.name,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        account.username,
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  onSelected: (value) {
                                    switch (value) {
                                      case 'edit':
                                        _showEditAccountDialog(account);
                                        break;
                                      case 'delete':
                                        _showDeleteAccountDialog(account);
                                        break;
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: Row(
                                        children: [
                                          Icon(Icons.edit, size: 18),
                                          SizedBox(width: 8),
                                          Text('Edit'),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Row(
                                        children: [
                                          Icon(Icons.delete, size: 18),
                                          SizedBox(width: 8),
                                          Text('Delete'),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _buildAccountInfo('IMAP Server', account.imap),
                            _buildAccountInfo('SMTP Server', account.smtp),
                            _buildAccountInfo('Reply From', account.replyFrom),
                            if (account.signature.isNotEmpty)
                              _buildAccountInfo('Signature', account.signature),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildAccountInfo(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddAccountDialog() {
    _showAccountDialog();
  }

  void _showEditAccountDialog(EmailAccount account) {
    _showAccountDialog(existingAccount: account);
  }

  void _showAccountDialog({EmailAccount? existingAccount}) {
    final formKey = GlobalKey<FormState>();
    final isEditing = existingAccount != null;
    
    String imap = existingAccount?.imap ?? '';
    String smtp = existingAccount?.smtp ?? '';
    String username = existingAccount?.username ?? '';
    String password = existingAccount?.password ?? '';
    String replyFrom = existingAccount?.replyFrom ?? '';
    String name = existingAccount?.name ?? '';
    String signature = existingAccount?.signature ?? '';
    Color color = existingAccount?.color ?? Colors.red;
    String display = existingAccount?.display ?? '';
    String caldavBaseUrl = existingAccount?.caldavBaseUrl ?? '';
    String caldavPath = existingAccount?.caldavPath ?? '';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(isEditing ? 'Edit Account' : 'Add Account'),
          content: Form(
            key: formKey,
            child: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Server Settings Section
                    const Text(
                      'Server Settings',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: imap,
                      decoration: const InputDecoration(
                        labelText: 'IMAP Server',
                        hintText: 'imap.example.com',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value!.isEmpty ? 'Required' : null,
                      onSaved: (value) => imap = value!,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: smtp,
                      decoration: const InputDecoration(
                        labelText: 'SMTP Server',
                        hintText: 'smtp.example.com',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value!.isEmpty ? 'Required' : null,
                      onSaved: (value) => smtp = value!,
                    ),
                    const SizedBox(height: 20),
                    
                    // Account Details Section
                    const Text(
                      'Account Details',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: username,
                      decoration: const InputDecoration(
                        labelText: 'Username/Email',
                        hintText: 'user@example.com',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value!.isEmpty ? 'Required' : null,
                      onSaved: (value) => username = value!,
                      readOnly: isEditing, // Don't allow username changes when editing
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: password,
                      decoration: const InputDecoration(
                        labelText: 'Password',
                        border: OutlineInputBorder(),
                      ),
                      obscureText: true,
                      validator: (value) => value!.isEmpty ? 'Required' : null,
                      onSaved: (value) => password = value!,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: replyFrom,
                      decoration: const InputDecoration(
                        labelText: 'Reply-From Email',
                        hintText: 'user@example.com',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value!.isEmpty ? 'Required' : null,
                      onSaved: (value) => replyFrom = value!,
                    ),
                    const SizedBox(height: 20),
                    
                    // Display Settings Section
                    const Text(
                      'Display Settings',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: name,
                      decoration: const InputDecoration(
                        labelText: 'Display Name',
                        hintText: 'John Doe',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value!.isEmpty ? 'Required' : null,
                      onSaved: (value) => name = value!,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: display,
                      decoration: const InputDecoration(
                        labelText: 'Initials (Display)',
                        hintText: 'JD',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => value!.isEmpty ? 'Required' : null,
                      onSaved: (value) => display = value!,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Account Color: '),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            setDialogState(() {
                              color = Colors.primaries[Random().nextInt(Colors.primaries.length)];
                            });
                          },
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.grey),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: () {
                            setDialogState(() {
                              color = Colors.primaries[Random().nextInt(Colors.primaries.length)];
                            });
                          },
                          child: const Text('Random'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    
                    // Signature Section
                    const Text(
                      'Signature',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: signature,
                      decoration: const InputDecoration(
                        labelText: 'Email Signature',
                        hintText: 'Best regards,\nYour Name',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      maxLines: 3,
                      onSaved: (value) => signature = value ?? '',
                    ),
                    const SizedBox(height: 20),
                    
                    // CalDAV Integration Section
                    const Text(
                      'Calendar Integration (Optional)',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: caldavBaseUrl,
                      decoration: const InputDecoration(
                        labelText: 'CalDAV Base URL',
                        hintText: 'https://mail.example.com',
                        border: OutlineInputBorder(),
                        helperText: 'Base URL for your CalDAV calendar server',
                      ),
                      onSaved: (value) => caldavBaseUrl = value ?? '',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: caldavPath,
                      decoration: const InputDecoration(
                        labelText: 'CalDAV Calendar Path',
                        hintText: '/remote.php/dav/calendars/username/personal/',
                        border: OutlineInputBorder(),
                        helperText: 'Path to your specific calendar on the server',
                      ),
                      onSaved: (value) => caldavPath = value ?? '',
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (formKey.currentState!.validate()) {
                  formKey.currentState!.save();
                  
                  final account = EmailAccount(
                    imap: imap,
                    smtp: smtp,
                    username: username,
                    password: password,
                    replyFrom: replyFrom,
                    name: name,
                    signature: signature,
                    color: color,
                    display: display,
                    caldavBaseUrl: caldavBaseUrl.isNotEmpty ? caldavBaseUrl : null,
                    caldavPath: caldavPath.isNotEmpty ? caldavPath : null,
                  );
                  
                  try {
                    if (isEditing) {
                      await DatabaseHelper.instance.updateAccount(account);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Account updated successfully')),
                      );
                    } else {
                      await DatabaseHelper.instance.insertAccount(account);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Account added successfully')),
                      );
                    }
                    
                    Navigator.of(context).pop();
                    await _loadAccounts();
                    widget.onAccountsChanged();
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error saving account: $e')),
                    );
                  }
                }
              },
              child: Text(isEditing ? 'Update' : 'Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteAccountDialog(EmailAccount account) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: Text('Are you sure you want to delete "${account.name}"?\n\nThis will remove all associated emails and cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              try {
                await DatabaseHelper.instance.deleteAccount(account.username);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Account deleted successfully')),
                );
                await _loadAccounts();
                widget.onAccountsChanged();
                Navigator.of(context).pop();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error deleting account: $e')),
                );
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// Custom Filter Icon Widget
class FilterIcon extends StatelessWidget {
  final Color color;
  final double size;

  const FilterIcon({
    Key? key,
    this.color = Colors.white,
    this.size = 24.0,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: FilterIconPainter(color: color),
    );
  }
}

class FilterIconPainter extends CustomPainter {
  final Color color;

  FilterIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final centerY = size.height / 2;
    final topY = centerY - size.height * 0.25;
    final middleY = centerY;
    final bottomY = centerY + size.height * 0.25;

    // Top line (longest)
    canvas.drawLine(
      Offset(size.width * 0.1, topY),
      Offset(size.width * 0.9, topY),
      paint,
    );

    // Middle line (medium)
    canvas.drawLine(
      Offset(size.width * 0.2, middleY),
      Offset(size.width * 0.8, middleY),
      paint,
    );

    // Bottom dot
    canvas.drawCircle(
      Offset(size.width * 0.5, bottomY),
      2.0,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Folder Selection Dialog Widget
class _FolderSelectionDialog extends StatelessWidget {
  final Map<String, List<String>> foldersByAccount;
  final int selectedEmailCount;

  const _FolderSelectionDialog({
    required this.foldersByAccount,
    required this.selectedEmailCount,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Move $selectedEmailCount emails'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: ListView.builder(
          itemCount: foldersByAccount.keys.length,
          itemBuilder: (context, accountIndex) {
            final accountId = foldersByAccount.keys.elementAt(accountIndex);
            final folders = foldersByAccount[accountId]!;
            
            return ExpansionTile(
              leading: const Icon(Icons.account_circle),
              title: Text(
                accountId,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              children: folders.map((folder) {
                return ListTile(
                  leading: const Icon(Icons.folder, size: 20),
                  title: Text(folder),
                  onTap: () {
                    Navigator.of(context).pop({
                      'accountId': accountId,
                      'folderPath': folder,
                    });
                  },
                );
              }).toList(),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
