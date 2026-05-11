import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iCal DateTime Parsing', () {
    test('should parse UTC datetime correctly', () {
      const icalDateStr = '20250115T143000Z';

      // Parse iCal format: YYYYMMDDTHHmmssZ
      final parsed = DateTime.parse(
        '${icalDateStr.substring(0, 4)}-${icalDateStr.substring(4, 6)}-${icalDateStr.substring(6, 8)}T${icalDateStr.substring(9, 11)}:${icalDateStr.substring(11, 13)}:${icalDateStr.substring(13, 15)}Z',
      );

      expect(parsed.year, equals(2025));
      expect(parsed.month, equals(1));
      expect(parsed.day, equals(15));
      expect(parsed.hour, equals(14));
      expect(parsed.minute, equals(30));
      expect(parsed.second, equals(0));
      expect(parsed.isUtc, isTrue);
    });

    test('should parse local datetime correctly', () {
      const icalDateStr = '20250115T143000';

      // Parse iCal format without Z: YYYYMMDDTHHmmss
      final parsed = DateTime.parse(
        '${icalDateStr.substring(0, 4)}-${icalDateStr.substring(4, 6)}-${icalDateStr.substring(6, 8)}T${icalDateStr.substring(9, 11)}:${icalDateStr.substring(11, 13)}:${icalDateStr.substring(13, 15)}',
      );

      expect(parsed.year, equals(2025));
      expect(parsed.month, equals(1));
      expect(parsed.day, equals(15));
      expect(parsed.hour, equals(14));
      expect(parsed.minute, equals(30));
    });

    test('should parse all-day date correctly', () {
      const icalDateStr = '20250115';

      // Parse iCal all-day format: YYYYMMDD
      final parsed = DateTime.parse(
        '${icalDateStr.substring(0, 4)}-${icalDateStr.substring(4, 6)}-${icalDateStr.substring(6, 8)}T00:00:00',
      );

      expect(parsed.year, equals(2025));
      expect(parsed.month, equals(1));
      expect(parsed.day, equals(15));
      expect(parsed.hour, equals(0));
      expect(parsed.minute, equals(0));
    });
  });

  group('iCal Property Extraction', () {
    test('should extract SUMMARY from iCal data', () {
      const icalData = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
DTSTART:20250115T100000Z
DTEND:20250115T110000Z
SUMMARY:Team Meeting
DESCRIPTION:Weekly sync
UID:test-event-123
END:VEVENT
END:VCALENDAR''';

      final summaryMatch = RegExp(r'SUMMARY:(.*)').firstMatch(icalData);
      expect(summaryMatch, isNotNull);
      expect(summaryMatch!.group(1)?.trim(), equals('Team Meeting'));
    });

    test('should extract UID from iCal data', () {
      const icalData = '''BEGIN:VEVENT
UID:unique-event-id-456
SUMMARY:Test Event
END:VEVENT''';

      final uidMatch = RegExp(r'UID:(.*)').firstMatch(icalData);
      expect(uidMatch, isNotNull);
      expect(uidMatch!.group(1)?.trim(), equals('unique-event-id-456'));
    });

    test('should extract DTSTART with TZID', () {
      const line = 'DTSTART;TZID=America/New_York:20250115T100000';

      // Extract TZID
      final tzidMatch = RegExp(r'TZID=([^:;]+)').firstMatch(line);
      expect(tzidMatch, isNotNull);
      expect(tzidMatch!.group(1), equals('America/New_York'));

      // Extract datetime
      final colonIndex = line.lastIndexOf(':');
      final dateTimeStr = line.substring(colonIndex + 1).trim();
      expect(dateTimeStr, equals('20250115T100000'));
    });

    test('should handle DESCRIPTION with line continuations', () {
      const icalData = '''DESCRIPTION:This is a long description that continues
  on the next line with a leading space
  and another continuation here
SUMMARY:Event Title''';

      // iCal line continuations start with space or tab
      final unfoldedData = icalData.replaceAll(RegExp(r'\r?\n[ \t]'), '');
      final descMatch = RegExp(r'DESCRIPTION:(.*)').firstMatch(unfoldedData);

      expect(descMatch, isNotNull);
      // Note: line continuation folding preserves a single space at join points
      expect(
        descMatch!.group(1)?.trim(),
        equals('This is a long description that continues on the next line with a leading space and another continuation here'),
      );
    });
  });

  group('iCal VEVENT vs VTIMEZONE Parsing', () {
    test('should only extract data from VEVENT block, not VTIMEZONE', () {
      const icalData = '''BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VTIMEZONE
TZID:America/New_York
BEGIN:STANDARD
DTSTART:19700101T000000
RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
END:STANDARD
END:VTIMEZONE
BEGIN:VEVENT
DTSTART;TZID=America/New_York:20250115T100000
DTEND;TZID=America/New_York:20250115T110000
SUMMARY:Real Event
UID:real-event-123
END:VEVENT
END:VCALENDAR''';

      // Simulate the parser logic - only parse within VEVENT blocks
      final lines = icalData.split('\n');
      bool inVEvent = false;
      bool inVTimezone = false;
      String? dtstart;
      String? summary;

      for (final line in lines) {
        final trimmed = line.trim();

        if (trimmed == 'BEGIN:VEVENT') {
          inVEvent = true;
          continue;
        } else if (trimmed == 'END:VEVENT') {
          inVEvent = false;
          continue;
        } else if (trimmed == 'BEGIN:VTIMEZONE') {
          inVTimezone = true;
          continue;
        } else if (trimmed == 'END:VTIMEZONE') {
          inVTimezone = false;
          continue;
        }

        // Skip VTIMEZONE content
        if (inVTimezone) continue;

        // Only parse VEVENT content
        if (inVEvent) {
          if (trimmed.startsWith('DTSTART')) {
            dtstart = trimmed;
          } else if (trimmed.startsWith('SUMMARY:')) {
            summary = trimmed.substring(8);
          }
        }
      }

      // Should have parsed the VEVENT data, not the VTIMEZONE DTSTART
      expect(dtstart, equals('DTSTART;TZID=America/New_York:20250115T100000'));
      expect(summary, equals('Real Event'));

      // The VTIMEZONE DTSTART (19700101T000000) should not be used
      expect(dtstart!.contains('19700101'), isFalse);
    });
  });

  group('CalDAV XML Response Parsing', () {
    test('should extract multiple events from multistatus response', () {
      const xmlResponse = '''<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>/calendars/user/default/event1.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-1"</d:getetag>
        <cal:calendar-data>BEGIN:VEVENT
UID:event-1
SUMMARY:Event 1
END:VEVENT</cal:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/calendars/user/default/event2.ics</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"etag-2"</d:getetag>
        <cal:calendar-data>BEGIN:VEVENT
UID:event-2
SUMMARY:Event 2
END:VEVENT</cal:calendar-data>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>''';

      // Count response blocks
      final responseCount = '<d:response>'.allMatches(xmlResponse).length;
      expect(responseCount, equals(2));

      // Extract events using regex
      final responseRegex = RegExp(
        r'<d:response[^>]*>(.*?)</d:response>',
        multiLine: true,
        dotAll: true,
      );
      final matches = responseRegex.allMatches(xmlResponse);

      expect(matches.length, equals(2));

      final events = <Map<String, String>>[];
      for (final match in matches) {
        final block = match.group(1) ?? '';

        final hrefMatch = RegExp(r'<d:href[^>]*>(.*?)</d:href>').firstMatch(block);
        final etagMatch = RegExp(r'<d:getetag[^>]*>(.*?)</d:getetag>').firstMatch(block);
        final dataMatch = RegExp(
          r'<cal:calendar-data[^>]*>(.*?)</cal:calendar-data>',
          dotAll: true,
        ).firstMatch(block);

        if (hrefMatch != null && etagMatch != null && dataMatch != null) {
          events.add({
            'href': hrefMatch.group(1)!.trim(),
            'etag': etagMatch.group(1)!.replaceAll('"', '').trim(),
            'calendar_data': dataMatch.group(1)!.trim(),
          });
        }
      }

      expect(events.length, equals(2));
      expect(events[0]['href'], equals('/calendars/user/default/event1.ics'));
      expect(events[0]['etag'], equals('etag-1'));
      expect(events[1]['href'], equals('/calendars/user/default/event2.ics'));
      expect(events[1]['etag'], equals('etag-2'));
    });
  });
}
