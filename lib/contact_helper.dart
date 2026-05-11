import 'main.dart' as main;

/// Shared helper for contact autocomplete suggestions.
/// Used by compose_screen.dart and reply_screen.dart.
class ContactHelper {
  /// Get contact suggestions for autocomplete based on query string.
  /// Searches contacts table first, falls back to emails table if no results.
  /// Returns list of formatted strings like "Name <email>" or just "email".
  static Future<List<String>> getContactSuggestions(String query, String? accountId) async {
    // Only search if query has at least 2 characters
    if (query.length < 2) return [];

    final db = await main.DatabaseHelper.instance.database;

    try {
      // Try to search contacts table first, filtering by account
      final results = await db.rawQuery(
        '''SELECT name, email, company, jobTitle FROM contacts
           WHERE (name LIKE ? OR email LIKE ? OR company LIKE ? OR jobTitle LIKE ?)
           AND accountId = ?
           ORDER BY frequency DESC, lastUsed DESC
           LIMIT 10''',
        ['%$query%', '%$query%', '%$query%', '%$query%', accountId ?? ''],
      );

      // Return as "Name <email>" with company info if available
      final contactResults = results.map<String>((row) {
        final name = row['name']?.toString() ?? '';
        final email = row['email']?.toString() ?? '';
        final company = row['company']?.toString() ?? '';
        final jobTitle = row['jobTitle']?.toString() ?? '';

        String displayName = name;
        if (company.isNotEmpty && jobTitle.isNotEmpty) {
          displayName = '$name ($jobTitle at $company)';
        } else if (company.isNotEmpty) {
          displayName = '$name ($company)';
        } else if (jobTitle.isNotEmpty) {
          displayName = '$name ($jobTitle)';
        }

        if (displayName.isNotEmpty && email.isNotEmpty && displayName != email) {
          return '$displayName <$email>';
        } else if (email.isNotEmpty) {
          return email;
        } else {
          return displayName;
        }
      }).toList();

      // If we have results from contacts table, return them
      if (contactResults.isNotEmpty) {
        return contactResults;
      }

      // If no results from contacts table, fall back to emails table
      throw Exception('No contacts found, falling back to emails');
    } catch (e) {
      // Fallback to searching sender emails from the emails table
      try {
        final results = await db.rawQuery(
          '''SELECT DISTINCT senderEmail, sender FROM emails
             WHERE (senderEmail LIKE ? OR sender LIKE ?)
             AND accountId = ?
             ORDER BY timestamp DESC LIMIT 10''',
          ['%$query%', '%$query%', accountId ?? ''],
        );
        return results.map<String>((row) {
          final name = row['sender']?.toString() ?? '';
          final email = row['senderEmail']?.toString() ?? '';
          if (name.isNotEmpty && email.isNotEmpty && name != email) {
            return '$name <$email>';
          } else if (email.isNotEmpty) {
            return email;
          } else {
            return name;
          }
        }).toList();
      } catch (e2) {
        return [];
      }
    }
  }
}
