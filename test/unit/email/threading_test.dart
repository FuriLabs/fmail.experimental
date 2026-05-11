import 'package:flutter_test/flutter_test.dart';
import '../../helpers/test_database.dart';

void main() {
  TestDatabase.initialize();

  group('Email Threading', () {
    test('emails with same threadParentId should be grouped together', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      // Create a thread with 3 emails
      final threadRootId = 'thread-root-123';
      final accountId = 'test@example.com';

      // Insert root email
      await TestDatabase.insertTestEmail(
        db,
        messageId: threadRootId,
        accountId: accountId,
        subject: 'Original Message',
        threadParentId: threadRootId,
        timestamp: DateTime(2025, 1, 1, 10, 0).millisecondsSinceEpoch,
      );

      // Insert reply 1
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'reply-1',
        accountId: accountId,
        subject: 'Re: Original Message',
        inReplyTo: threadRootId,
        threadParentId: threadRootId,
        timestamp: DateTime(2025, 1, 1, 11, 0).millisecondsSinceEpoch,
      );

      // Insert reply 2
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'reply-2',
        accountId: accountId,
        subject: 'Re: Original Message',
        inReplyTo: 'reply-1',
        references: '$threadRootId reply-1',
        threadParentId: threadRootId,
        timestamp: DateTime(2025, 1, 1, 12, 0).millisecondsSinceEpoch,
      );

      // Query thread emails
      final threadEmails = await db.query(
        'emails',
        where: 'threadParentId = ? AND accountId = ?',
        whereArgs: [threadRootId, accountId],
        orderBy: 'timestamp ASC',
      );

      expect(threadEmails.length, equals(3));
      expect(threadEmails[0]['messageId'], equals(threadRootId));
      expect(threadEmails[1]['messageId'], equals('reply-1'));
      expect(threadEmails[2]['messageId'], equals('reply-2'));

      await db.close();
    });

    test('thread root should have threadParentId equal to messageId', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      final messageId = 'standalone-email';
      await TestDatabase.insertTestEmail(
        db,
        messageId: messageId,
        accountId: 'test@example.com',
        subject: 'Standalone Email',
        threadParentId: messageId,
      );

      final email = await db.query(
        'emails',
        where: 'messageId = ?',
        whereArgs: [messageId],
      );

      expect(email.length, equals(1));
      expect(email[0]['threadParentId'], equals(messageId));

      await db.close();
    });

    test('querying only thread roots returns unique threads', () async {
      final db = await TestDatabase.createInMemoryDatabase();
      final accountId = 'test@example.com';

      // Thread 1 with 2 emails
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'thread1-root',
        accountId: accountId,
        subject: 'Thread 1',
        threadParentId: 'thread1-root',
      );
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'thread1-reply',
        accountId: accountId,
        subject: 'Re: Thread 1',
        threadParentId: 'thread1-root',
      );

      // Thread 2 with 1 email
      await TestDatabase.insertTestEmail(
        db,
        messageId: 'thread2-root',
        accountId: accountId,
        subject: 'Thread 2',
        threadParentId: 'thread2-root',
      );

      // Query only thread roots (where threadParentId == messageId)
      final threadRoots = await db.query(
        'emails',
        where: 'threadParentId = messageId AND accountId = ?',
        whereArgs: [accountId],
      );

      expect(threadRoots.length, equals(2));

      await db.close();
    });
  });

  group('Email Threading - References Parsing', () {
    test('references header should contain full thread chain', () async {
      final db = await TestDatabase.createInMemoryDatabase();

      await TestDatabase.insertTestEmail(
        db,
        messageId: 'msg-3',
        accountId: 'test@example.com',
        subject: 'Re: Re: Original',
        inReplyTo: 'msg-2',
        references: 'msg-1 msg-2',
        threadParentId: 'msg-1',
      );

      final email = await db.query(
        'emails',
        where: 'messageId = ?',
        whereArgs: ['msg-3'],
      );

      expect(email[0]['references'], equals('msg-1 msg-2'));
      expect(email[0]['inReplyTo'], equals('msg-2'));
      expect(email[0]['threadParentId'], equals('msg-1'));

      await db.close();
    });
  });
}
