import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'main.dart'; // Import for EmailAccount class
import 'dart:io' show Platform;

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  
  // Add size limits for Android cursor window compatibility
  static const int MAX_EMAIL_CONTENT_SIZE = 500000; // 500KB for email body content
  static const int MAX_ATTACHMENT_METADATA_SIZE = 100000; // 100KB for attachment metadata JSON (not files)
  static const int MAX_RAW_EMAIL_SIZE = 750000; // 750KB limit for raw email content

  DatabaseHelper._init();
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('furimail.db');
    return _database!;
  }

  // Android-specific database initialization with cursor window settings
  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 13,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
      onOpen: (db) async {
        // Android-specific optimizations
        if (Platform.isAndroid) {
          await db.execute('PRAGMA cache_size = 10000');
          await db.execute('PRAGMA temp_store = memory');
          await db.execute('PRAGMA journal_mode = WAL');
        }
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Create emails table
    await db.execute('''
      CREATE TABLE emails (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        messageId TEXT UNIQUE,
        subject TEXT,
        sender TEXT,
        recipients TEXT,
        date INTEGER,
        body TEXT,
        folder TEXT,
        accountId TEXT,
        uid INTEGER,
        flags TEXT,
        hasAttachments INTEGER DEFAULT 0,
        attachments TEXT
      )
    ''');

    // Create accounts table
    await db.execute('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        imap TEXT,
        smtp TEXT,
        username TEXT UNIQUE,
        password TEXT,
        replyFrom TEXT,
        name TEXT,
        signature TEXT,
        color TEXT,
        display TEXT,
        caldav_base_url TEXT,
        caldav_path TEXT,
        caldav_confirmed_path TEXT
      )
    ''');

    // Create calendar_events table
    await db.execute('''
      CREATE TABLE calendar_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        description TEXT,
        location TEXT,
        startDateTime INTEGER,
        endDateTime INTEGER,
        isAllDay INTEGER DEFAULT 0,
        accountId TEXT,
        category TEXT DEFAULT "",
        caldav_uid TEXT,
        caldav_etag TEXT,
        needs_sync INTEGER DEFAULT 0,
        modified INTEGER
      )
    ''');

    // Create indexes for performance
    await db.execute('CREATE INDEX idx_email_account ON emails (accountId)');
    await db.execute('CREATE INDEX idx_email_folder ON emails (folder)');
    await db.execute('CREATE INDEX idx_email_date ON emails (date)');
    await db.execute('CREATE INDEX idx_event_account ON calendar_events (accountId)');
    await db.execute('CREATE INDEX idx_event_date ON calendar_events (startDateTime)');
    await db.execute('CREATE INDEX idx_event_category ON calendar_events (category)');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    // Handle database upgrades
    if (oldVersion < 13) {
      // Add any missing columns for newer versions
      try {
        await db.execute('ALTER TABLE calendar_events ADD COLUMN needs_sync INTEGER DEFAULT 0');
      } catch (e) {
        // Column might already exist
      }
    }
  }

  Future<int> insertEmail(Map<String, dynamic> email) async {
    final db = await database;
    
    // Truncate large content to prevent cursor window errors
    final truncatedEmail = Map<String, dynamic>.from(email);
    
    // Limit email body size with null safety
    if (truncatedEmail['body'] != null) {
      final body = truncatedEmail['body'].toString();
      if (body.length > MAX_EMAIL_CONTENT_SIZE) {
        truncatedEmail['body'] = body.substring(0, MAX_EMAIL_CONTENT_SIZE) + 
          '\n\n[Content truncated due to size limits]';
        print('⚠️ Truncated email body from ${body.length} to ${MAX_EMAIL_CONTENT_SIZE} chars');
      }
    }
    
    // Limit attachment data size with null safety
      if (attachments.length > MAX_ATTACHMENT_METADATA_SIZE) {
        truncatedEmail['attachments'] = attachments.substring(0, MAX_ATTACHMENT_METADATA_SIZE) +
            '... [Attachment metadata truncated for cursor window compatibility]';
        print('⚠️ Truncated attachments from ${attachments.length} to ${MAX_ATTACHMENT_METADATA_SIZE} chars');
      }    try {
      return await db.insert('emails', truncatedEmail, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      print('❌ Failed to insert email: $e');
      // If still too big, insert minimal version
      final minimalEmail = {
        'messageId': truncatedEmail['messageId']?.toString() ?? '',
        'subject': _truncateString(truncatedEmail['subject']?.toString(), 500),
        'sender': _truncateString(truncatedEmail['sender']?.toString(), 200),
        'recipients': _truncateString(truncatedEmail['recipients']?.toString(), 500),
        'date': truncatedEmail['date'],
        'body': '[Large email content removed due to size constraints]',
        'folder': truncatedEmail['folder']?.toString() ?? '',
        'accountId': truncatedEmail['accountId']?.toString() ?? '',
        'uid': truncatedEmail['uid'],
        'flags': truncatedEmail['flags']?.toString() ?? '',
        'hasAttachments': truncatedEmail['hasAttachments'] ?? 0,
        'attachments': null,
      };
      
      print('🔄 Inserting minimal version of large email');
      return await db.insert('emails', minimalEmail, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
  
  /// Clean up oversized emails that might cause cursor window issues
  Future<void> cleanupLargeEmails() async {
    final db = await database;
    
    try {
      // Remove emails with very large content that might cause issues
      await db.execute('''
        DELETE FROM emails 
        WHERE length(body) > ? OR length(attachments) > ?
      ''', [MAX_EMAIL_CONTENT_SIZE, MAX_ATTACHMENT_METADATA_SIZE]);
      
      print('🧹 Cleaned up oversized emails from database');
    } catch (e) {
      print('❌ Error cleaning up large emails: $e');
    }
  }

  // Missing: essential CRUD methods
    // Android cursor window cleanup - call this when cursor window errors occur
  Future<void> emergencyCleanupOversizedContent() async {
    if (!Platform.isAndroid) return;
    
    try {
      final db = await database;
      print('🚨 EMERGENCY: Cleaning up oversized content for Android cursor window');
      
      // Step 1: Truncate very large content fields
      await db.execute('''
        UPDATE emails 
        SET content = SUBSTR(content, 1, ?) 
        WHERE LENGTH(content) > ?
      ''', [MAX_EMAIL_CONTENT_SIZE, MAX_EMAIL_CONTENT_SIZE]);
      
      // Step 2: Truncate large attachments
      await db.execute('''
        UPDATE emails 
        SET attachments = SUBSTR(attachments, 1, ?) 
        WHERE LENGTH(attachments) > ?
      ''', [MAX_ATTACHMENT_SIZE, MAX_ATTACHMENT_SIZE]);
      
      // Step 3: Truncate large raw email content
      await db.execute('''
        UPDATE emails 
        SET rawEmail = SUBSTR(rawEmail, 1, ?) 
        WHERE LENGTH(rawEmail) > ?
      ''', [MAX_RAW_EMAIL_SIZE, MAX_RAW_EMAIL_SIZE]);
      
      // Step 4: Remove extremely problematic emails (over 2MB total)
      await db.execute('''
        DELETE FROM emails 
        WHERE LENGTH(content) + LENGTH(IFNULL(attachments, '')) + LENGTH(IFNULL(rawEmail, '')) > 2000000
      ''');
      
      // Step 5: Vacuum to reclaim space
      await db.execute('VACUUM');
      
      print('✅ Emergency cleanup completed');
    } catch (e) {
      print('❌ Emergency cleanup failed: $e');
    }
  }

  // Android-specific safe query that limits content size in SELECT
  Future<List<Map<String, dynamic>>> getEmailsAndroidSafe({
    String? searchQuery,
    int? limit,
    int? offset,
    String? whereClause,
    List<dynamic>? whereArgs,
  }) async {
    if (!Platform.isAndroid) {
      // Use regular query on non-Android platforms
      final db = await database;
      return await db.query(
        'emails',
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit,
        offset: offset,
      );
    }
    
    try {
      final db = await database;
      
      // Android-safe query with content size limits
      final String selectClause = '''
        SELECT 
          id, messageId, accountId, subject, sender, senderEmail, timestamp,
          CASE 
            WHEN LENGTH(content) > $MAX_EMAIL_CONTENT_SIZE 
            THEN SUBSTR(content, 1, $MAX_EMAIL_CONTENT_SIZE) || '... [Content truncated for Android compatibility]'
            ELSE content 
          END as content,
          isRead, isStarred, isAnswered, isForwarded, isDraft, isDeleted, isJunk,
          folderPath, inReplyTo, "references", threadParentId, hasAttachments, hasImages,
          CASE 
            WHEN LENGTH(IFNULL(attachments, '')) > $MAX_ATTACHMENT_SIZE 
            THEN SUBSTR(IFNULL(attachments, ''), 1, $MAX_ATTACHMENT_SIZE) || '... [Attachments truncated]'
            ELSE attachments 
          END as attachments,
          CASE 
            WHEN LENGTH(IFNULL(rawEmail, '')) > $MAX_RAW_EMAIL_SIZE 
            THEN SUBSTR(IFNULL(rawEmail, ''), 1, $MAX_RAW_EMAIL_SIZE) || '... [Raw email truncated]'
            ELSE rawEmail 
          END as rawEmail,
          imapFolder
        FROM emails
      ''';
      
      String query = selectClause;
      if (whereClause != null && whereClause.isNotEmpty) {
        query += ' WHERE $whereClause';
      }
      query += ' ORDER BY timestamp DESC';
      if (limit != null) {
        query += ' LIMIT $limit';
      }
      if (offset != null) {
        query += ' OFFSET $offset';
      }
      
      return await db.rawQuery(query, whereArgs);
      
    } catch (e) {
      print('❌ Android-safe query failed, attempting emergency cleanup: $e');
      
      // If query fails, try emergency cleanup
      await emergencyCleanupOversizedContent();
      
      // Retry with basic query
      final db = await database;
      return await db.query(
        'emails',
        columns: ['id', 'messageId', 'accountId', 'subject', 'sender', 'senderEmail', 'timestamp', 'isRead'],
        where: whereClause,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit ?? 20, // Smaller limit on retry
        offset: offset,
      );
    }
  }

  Future<List<EmailAccount>> getAccounts() async {
    final db = await database;
    final maps = await db.query('accounts');
    return List.generate(maps.length, (i) {
      return EmailAccount.fromMap(maps[i]);
    });
  }

  Future<int> insertAccount(EmailAccount account) async {
    final db = await database;
    return await db.insert('accounts', account.toMap());
  }

  Future<void> updateAccount(EmailAccount account) async {
    final db = await database;
    await db.update(
      'accounts',
      account.toMap(),
      where: 'username = ?',
      whereArgs: [account.username],
    );
  }

  Future<void> deleteAccount(String username) async {
    final db = await database;
    await db.delete(
      'accounts',
      where: 'username = ?',
      whereArgs: [username],
    );
  }

  // Calendar events methods
  Future<int> insertCalendarEvent(Map<String, dynamic> event) async {
    final db = await database;
    return await db.insert('calendar_events', event);
  }

  Future<List<Map<String, dynamic>>> getCalendarEvents({String? accountId}) async {
    final db = await database;
    if (accountId != null) {
      return await db.query(
        'calendar_events',
        where: 'accountId = ?',
        whereArgs: [accountId],
        orderBy: 'startDateTime ASC',
      );
    }
    return await db.query('calendar_events', orderBy: 'startDateTime ASC');
  }

  Future<void> updateCalendarEvent(int id, Map<String, dynamic> event) async {
    final db = await database;
    await db.update(
      'calendar_events',
      event,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteCalendarEvent(int id) async {
    final db = await database;
    await db.delete(
      'calendar_events',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Utility methods
  Future<void> deleteEmail(String messageId) async {
    final db = await database;
    await db.delete(
      'emails',
      where: 'messageId = ?',
      whereArgs: [messageId],
    );
  }

  Future<void> clearEmailsForAccount(String accountId) async {
    final db = await database;
    await db.delete(
      'emails',
      where: 'accountId = ?',
      whereArgs: [accountId],
    );
  }

  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }

  /// Emergency database reset for cursor window issues
  Future<void> resetDatabase() async {
    try {
      final dbPath = await getDatabasesPath();
      final path = join(dbPath, 'furimail.db');
      
      // Close existing connection
      await close();
      
      // Delete the database file
      await deleteDatabase(path);
      
      // Reinitialize
      _database = null;
      await database; // This will recreate the database
      
      print('🔄 Database reset successfully');
    } catch (e) {
      print('❌ Error resetting database: $e');
    }
  }

  /// Clear all emails (safer than full reset)
  Future<void> clearAllEmails() async {
    final db = await database;
    try {
      await db.delete('emails');
      print('🧹 Cleared all emails from database');
    } catch (e) {
      print('❌ Error clearing emails: $e');
    }
  }

  // Helper method for safe string truncation
  String _truncateString(String? input, int maxLength) {
    if (input == null) return '';
    return input.length > maxLength ? input.substring(0, maxLength) : input;
  }

  // Android-specific query with cursor window protection
  Future<List<Map<String, dynamic>>> getEmailsAndroid({String? accountId, String? folder, int limit = 50}) async {
    final db = await database;
    String whereClause = '1=1';
    List<dynamic> whereArgs = [];
    
    if (accountId != null) {
      whereClause += ' AND accountId = ?';
      whereArgs.add(accountId);
    }
    
    if (folder != null) {
      whereClause += ' AND folder = ?';
      whereArgs.add(folder);
    }
    
    try {
      // Android-specific: Select only essential fields to avoid cursor window issues
      return await db.query(
        'emails',
        columns: ['id', 'messageId', 'subject', 'sender', 'date', 'folder', 'accountId', 'hasAttachments'], // Exclude body and attachments
        where: whereClause,
        whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
        orderBy: 'date DESC',
        limit: limit, // Much smaller limit for Android
      );
    } catch (e) {
      print('❌ Android email query failed: $e');
      // Fallback: return minimal data
      return [];
    }
  }

  // Android-specific: Get email body separately when needed
  Future<String?> getEmailBodyAndroid(String messageId) async {
    final db = await database;
    try {
      final result = await db.query(
        'emails',
        columns: ['body'],
        where: 'messageId = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      
      if (result.isNotEmpty) {
        return result.first['body'] as String?;
      }
    } catch (e) {
      print('❌ Failed to get email body for Android: $e');
    }
    return null;
  }

  // Check if folder needs more emails (Android optimization)
  Future<bool> shouldFetchMoreEmails(String accountId, String folder, int serverCount) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM emails WHERE accountId = ? AND folder = ?',
      [accountId, folder]
    );
    
    final localCount = result.first['count'] as int;
    final needsMore = localCount < serverCount && localCount < (Platform.isAndroid ? 100 : 1000);
    
    print('📊 Folder $folder: Local=$localCount, Server=$serverCount, FetchMore=$needsMore');
    return needsMore;
  }
}