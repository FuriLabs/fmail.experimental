// IMAP Flags Helper for Furimail
// Handles syncing of IMAP message flags like read, replied, forwarded status

import 'package:enough_mail/enough_mail.dart';

class ImapFlagsHelper {
  
  /// Convert IMAP message flags to our database format
  static Map<String, dynamic> parseImapFlags(MimeMessage message) {
    final flags = message.flags ?? <String>[];
    
    return {
      'isRead': flags.contains(MessageFlags.seen) ? 1 : 0,
      'isStarred': flags.contains(MessageFlags.flagged) ? 1 : 0,
      'isAnswered': flags.contains(MessageFlags.answered) ? 1 : 0,
      'isDraft': flags.contains(MessageFlags.draft) ? 1 : 0,
      'isDeleted': flags.contains(MessageFlags.deleted) ? 1 : 0,
      'isForwarded': flags.contains(MessageFlags.keywordForwarded) ? 1 : 0,
      'isJunk': flags.contains(r'$Junk') ? 1 : 0,
    };
  }
  
  /// Sync local flag changes back to IMAP server
  static Future<void> syncFlagToServer({
    required ImapClient client,
    required MimeMessage message,
    required String flag,
    required bool add,
  }) async {
    try {
      if (add) {
        await client.store(MessageSequence.fromMessage(message), [flag], action: StoreAction.add);
      } else {
        await client.store(MessageSequence.fromMessage(message), [flag], action: StoreAction.remove);
      }
      print('✅ Synced flag $flag for message ${message.sequenceId}');
    } catch (e) {
      print('❌ Failed to sync flag to server: $e');
    }
  }
  
  /// Mark message as read on server
  static Future<void> markAsRead(ImapClient client, MimeMessage message) async {
    await syncFlagToServer(
      client: client,
      message: message,
      flag: MessageFlags.seen,
      add: true,
    );
  }
  
  /// Mark message as replied on server
  static Future<void> markAsReplied(ImapClient client, MimeMessage message) async {
    await syncFlagToServer(
      client: client,
      message: message,
      flag: MessageFlags.answered,
      add: true,
    );
  }
  
  /// Mark message as starred/flagged on server
  static Future<void> markAsStarred(ImapClient client, MimeMessage message, bool starred) async {
    await syncFlagToServer(
      client: client,
      message: message,
      flag: MessageFlags.flagged,
      add: starred,
    );
  }
  
  /// Mark message as forwarded (custom flag)
  static Future<void> markAsForwarded(ImapClient client, MimeMessage message) async {
    try {
      await client.store(
        MessageSequence.fromMessage(message),
        [MessageFlags.keywordForwarded],
        action: StoreAction.add,
      );
      print('✅ Marked message as forwarded');
    } catch (e) {
      print('❌ Failed to mark as forwarded: $e');
    }
  }
  
  /// Get human-readable status summary
  static String getStatusSummary(Map<String, dynamic> email) {
    final List<String> status = [];
    
    if ((email['isRead'] ?? 0) == 1) status.add('Read');
    if ((email['isAnswered'] ?? 0) == 1) status.add('Replied');
    if ((email['isForwarded'] ?? 0) == 1) status.add('Forwarded');
    if ((email['isStarred'] ?? 0) == 1) status.add('Starred');
    if ((email['isDraft'] ?? 0) == 1) status.add('Draft');
    
    return status.isEmpty ? 'Unread' : status.join(', ');
  }
}
