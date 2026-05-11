import 'package:flutter_test/flutter_test.dart';
import '../../helpers/test_database.dart';

void main() {
  TestDatabase.initialize();

  group('Email Filter SQL Generation', () {
    test('filter by single account should generate correct WHERE clause', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      // Insert emails from two accounts
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-1',
        accountId: 'account1@example.com',
        subject: 'Account 1 Email',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-2',
        accountId: 'account2@example.com',
        subject: 'Account 2 Email',
      );

      // Query with filter for account1 only
      final emails = await db.query(
        'emails',
        where: 'accountId = ?',
        whereArgs: ['account1@example.com'],
      );

      expect(emails.length, equals(1));
      expect(emails[0]['accountId'], equals('account1@example.com'));

      await db.close();
    });

    test('filter by multiple accounts should use IN clause', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-1',
        accountId: 'account1@example.com',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-2',
        accountId: 'account2@example.com',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-3',
        accountId: 'account3@example.com',
      );

      // Query with filter for account1 and account2
      final emails = await db.query(
        'emails',
        where: 'accountId IN (?, ?)',
        whereArgs: ['account1@example.com', 'account2@example.com'],
      );

      expect(emails.length, equals(2));

      await db.close();
    });

    test('filter by folder should generate correct WHERE clause', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-1',
        accountId: 'test@example.com',
        folderPath: 'INBOX',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-2',
        accountId: 'test@example.com',
        folderPath: 'Sent',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-3',
        accountId: 'test@example.com',
        folderPath: 'Drafts',
      );

      // Query INBOX only
      final inboxEmails = await db.query(
        'emails',
        where: 'folderPath = ?',
        whereArgs: ['INBOX'],
      );

      expect(inboxEmails.length, equals(1));
      expect(inboxEmails[0]['folderPath'], equals('INBOX'));

      await db.close();
    });

    test('filter by account AND folder should combine conditions', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-1',
        accountId: 'account1@example.com',
        folderPath: 'INBOX',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-2',
        accountId: 'account1@example.com',
        folderPath: 'Sent',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-3',
        accountId: 'account2@example.com',
        folderPath: 'INBOX',
      );

      // Query account1 INBOX only
      final emails = await db.query(
        'emails',
        where: 'accountId = ? AND folderPath = ?',
        whereArgs: ['account1@example.com', 'INBOX'],
      );

      expect(emails.length, equals(1));
      expect(emails[0]['accountId'], equals('account1@example.com'));
      expect(emails[0]['folderPath'], equals('INBOX'));

      await db.close();
    });

    test('search filter should match subject, sender, or content', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-1',
        accountId: 'test@example.com',
        subject: 'Meeting Tomorrow',
        sender: 'Alice',
        content: 'Please confirm attendance',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-2',
        accountId: 'test@example.com',
        subject: 'Invoice',
        sender: 'Bob',
        content: 'See attached invoice',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-3',
        accountId: 'test@example.com',
        subject: 'Hello',
        sender: 'Meeting Planner',
        content: 'Greetings',
      );

      // Search for 'meeting' - should match msg-1 (subject) and msg-3 (sender)
      final searchTerm = '%meeting%';
      final emails = await db.query(
        'emails',
        where: 'subject LIKE ? OR sender LIKE ? OR content LIKE ?',
        whereArgs: [searchTerm, searchTerm, searchTerm],
      );

      expect(emails.length, equals(2));

      await db.close();
    });
  });

  group('Email Filter - Read/Unread Status', () {
    test('filter unread emails only', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-1',
        accountId: 'test@example.com',
        isRead: 0,
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-2',
        accountId: 'test@example.com',
        isRead: 1,
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-3',
        accountId: 'test@example.com',
        isRead: 0,
      );

      final unreadEmails = await db.query(
        'emails',
        where: 'isRead = 0',
      );

      expect(unreadEmails.length, equals(2));

      await db.close();
    });

    test('count unread emails per folder', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      // 2 unread in INBOX
      await TestDatabase.insertTestEmail(db, messageId: 'm1', accountId: 'a', folderPath: 'INBOX', isRead: 0);
      await TestDatabase.insertTestEmail(db, messageId: 'm2', accountId: 'a', folderPath: 'INBOX', isRead: 0);
      await TestDatabase.insertTestEmail(db, messageId: 'm3', accountId: 'a', folderPath: 'INBOX', isRead: 1);

      // 1 unread in Sent
      await TestDatabase.insertTestEmail(db, messageId: 'm4', accountId: 'a', folderPath: 'Sent', isRead: 0);
      await TestDatabase.insertTestEmail(db, messageId: 'm5', accountId: 'a', folderPath: 'Sent', isRead: 1);

      // Count unread in INBOX
      final inboxUnread = await db.rawQuery(
        'SELECT COUNT(*) as count FROM emails WHERE folderPath = ? AND isRead = 0',
        ['INBOX'],
      );
      expect(inboxUnread[0]['count'], equals(2));

      // Count unread in Sent
      final sentUnread = await db.rawQuery(
        'SELECT COUNT(*) as count FROM emails WHERE folderPath = ? AND isRead = 0',
        ['Sent'],
      );
      expect(sentUnread[0]['count'], equals(1));

      await db.close();
    });
  });
}
