import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:enough_mail/enough_mail.dart';
import 'main.dart' as main;
import 'contact_helper.dart';

enum ReplyType {
  reply,
  replyAll,
}

class ReplyScreen extends StatefulWidget {
  final Map<String, dynamic> email;
  final dynamic account;
  final ReplyType replyType;

  const ReplyScreen({
    Key? key,
    required this.email,
    required this.account,
    required this.replyType,
  }) : super(key: key);

  @override
  _ReplyScreenState createState() => _ReplyScreenState();
}

class _ReplyScreenState extends State<ReplyScreen> {
  final TextEditingController _toController = TextEditingController();
  final TextEditingController _ccController = TextEditingController();
  final TextEditingController _bccController = TextEditingController();
  final TextEditingController _subjectController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();

  // FocusNodes for autocomplete fields (must be disposed)
  final FocusNode _ccFocusNode = FocusNode();
  final FocusNode _bccFocusNode = FocusNode();

  bool _showCc = false;
  bool _showBcc = false;

  // Contact search using shared helper
  Future<List<String>> _getContactSuggestions(String query) async {
    return ContactHelper.getContactSuggestions(query, widget.account?.username);
  }

  @override
  void initState() {
    super.initState();
    _initializeReplyFields();
  }

  void _initializeReplyFields() {
    final originalSender = widget.email['senderEmail']?.toString() ?? '';
    final originalSubject = widget.email['subject']?.toString() ?? '';
    final originalContent = widget.email['content']?.toString() ?? '';
    final timestamp = widget.email['timestamp'] as int? ?? 0;
    final formattedDate = DateFormat('MMM dd, yyyy \'at\' hh:mm a')
        .format(DateTime.fromMillisecondsSinceEpoch(timestamp));

    // Set recipient(s)
    if (widget.replyType == ReplyType.reply) {
      _toController.text = originalSender;
    } else if (widget.replyType == ReplyType.replyAll) {
      _toController.text = originalSender;

      // Parse original To and CC from raw email to populate CC field
      final rawEmail = widget.email['rawEmail']?.toString() ?? '';
      final myEmail = widget.account?.replyFrom ?? widget.account?.username ?? '';

      final ccRecipients = _parseReplyAllRecipients(rawEmail, originalSender, myEmail);
      if (ccRecipients.isNotEmpty) {
        _ccController.text = ccRecipients.join(', ');
      }
      _showCc = true;
    }

    // Set subject (Re: prefix is same for both reply and reply all)
    _subjectController.text = originalSubject.startsWith('Re: ')
        ? originalSubject
        : 'Re: $originalSubject';

    // Set quoted content
    final quotedContent = _createQuotedContent(originalContent, originalSender, formattedDate);
    _bodyController.text = '\n\n$quotedContent';
    
    // Position cursor at beginning for user to start typing
    _bodyController.selection = const TextSelection.collapsed(offset: 0);
  }

  /// Parse To and CC recipients from raw email headers for Reply All
  /// Returns list of email addresses excluding the original sender and current user
  List<String> _parseReplyAllRecipients(String rawEmail, String originalSender, String myEmail) {
    final recipients = <String>{};

    if (rawEmail.isEmpty) return [];

    // Normalize emails for comparison (lowercase, trim)
    final senderNorm = originalSender.toLowerCase().trim();
    final myEmailNorm = myEmail.toLowerCase().trim();

    // Parse headers from raw email (headers end at first blank line)
    final headerEndIndex = rawEmail.indexOf('\r\n\r\n');
    final headers = headerEndIndex > 0 ? rawEmail.substring(0, headerEndIndex) : rawEmail;

    // Unfold headers (continuation lines start with whitespace)
    final unfoldedHeaders = headers.replaceAll(RegExp(r'\r\n[ \t]+'), ' ');

    // Extract To header
    final toMatch = RegExp(r'^To:\s*(.+?)(?=\r?\n[^\s]|\r?\n$|$)', multiLine: true, caseSensitive: false)
        .firstMatch(unfoldedHeaders);
    if (toMatch != null) {
      _extractEmailAddresses(toMatch.group(1) ?? '', recipients);
    }

    // Extract CC header
    final ccMatch = RegExp(r'^Cc:\s*(.+?)(?=\r?\n[^\s]|\r?\n$|$)', multiLine: true, caseSensitive: false)
        .firstMatch(unfoldedHeaders);
    if (ccMatch != null) {
      _extractEmailAddresses(ccMatch.group(1) ?? '', recipients);
    }

    // Remove the original sender and current user from recipients
    recipients.removeWhere((email) {
      final emailNorm = email.toLowerCase().trim();
      return emailNorm == senderNorm || emailNorm == myEmailNorm || emailNorm.isEmpty;
    });

    return recipients.toList();
  }

  /// Extract email addresses from a header value like "Name <email>, other@email.com"
  void _extractEmailAddresses(String headerValue, Set<String> results) {
    // Match email addresses: either in angle brackets or standalone
    final emailPattern = RegExp(r'(?:<([^>]+)>|([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}))');

    for (final match in emailPattern.allMatches(headerValue)) {
      final email = match.group(1) ?? match.group(2);
      if (email != null && email.contains('@')) {
        results.add(email.trim());
      }
    }
  }

  String _createQuotedContent(String originalContent, String sender, String date) {
    final quotedHeader = 'On $date, $sender wrote:';
    final quotedLines = originalContent
        .split('\n')
        .map((line) => '> $line')
        .join('\n');

    return '$quotedHeader\n$quotedLines';
  }

  Future<void> _sendReply() async {
    // Validate required fields
    if (_toController.text.trim().isEmpty) {
      _showErrorSnackBar('Please enter a recipient');
      return;
    }

    if (_subjectController.text.trim().isEmpty) {
      _showErrorSnackBar('Please enter a subject');
      return;
    }

    try {
      // Show loading state
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 16),
              Text('Sending email...'),
            ],
          ),
          duration: Duration(seconds: 30),
          backgroundColor: Colors.blue,
        ),
      );

      // Create SMTP client
      final smtpClient = SmtpClient('furimail');
      await smtpClient.connectToServer(widget.account.smtp, 587, isSecure: false);
      await smtpClient.ehlo();
      await smtpClient.startTls(); // Start TLS for security
      await smtpClient.authenticate(widget.account.username, widget.account.password);

      // Create the email message
      final builder = MessageBuilder();
      
      // Debug log to verify account information
      print('DEBUG SMTP: Account name: "${widget.account.name}"');
      print('DEBUG SMTP: Account replyFrom: "${widget.account.replyFrom}"');
      
      builder.from = [MailAddress(widget.account.name, widget.account.replyFrom)];
      builder.to = [MailAddress('', _toController.text.trim())];
      
      // Add CC if provided
      if (_showCc && _ccController.text.trim().isNotEmpty) {
        final ccAddresses = _ccController.text.split(',')
            .map((email) => MailAddress('', email.trim()))
            .toList();
        builder.cc = ccAddresses;
      }
      
      // Add BCC if provided
      if (_showBcc && _bccController.text.trim().isNotEmpty) {
        final bccAddresses = _bccController.text.split(',')
            .map((email) => MailAddress('', email.trim()))
            .toList();
        builder.bcc = bccAddresses;
      }
      
      builder.subject = _subjectController.text.trim();
      
      // Set message ID and threading headers for proper reply threading
      final originalMessageId = widget.email['messageId']?.toString();
      if (originalMessageId != null && originalMessageId.isNotEmpty) {
        builder.setHeader('In-Reply-To', originalMessageId);
        
        // Build References header
        final originalReferences = widget.email['references']?.toString() ?? '';
        final references = originalReferences.isNotEmpty 
            ? '$originalReferences $originalMessageId'
            : originalMessageId;
        builder.setHeader('References', references);
      }
      
      // Set message content (plain text)
      String messageBody = _bodyController.text.trim();
      
      // Add signature if account has one
      if (widget.account.signature.isNotEmpty) {
        messageBody += '\n\n${widget.account.signature}';
      }
      
      builder.text = messageBody;
      
      final mimeMessage = builder.buildMimeMessage();
      
      // Send the email
      final sendResponse = await smtpClient.sendMessage(mimeMessage);
      await smtpClient.quit();

      // Clear any existing snackbars
      ScaffoldMessenger.of(context).clearSnackBars();

      if (sendResponse.isOkStatus) {
        // Save to IMAP Sent folder
        try {
          final imapClient = ImapClient(isLogEnabled: false);
          await imapClient.connectToServer(widget.account.imap, 993, isSecure: true);
          await imapClient.login(widget.account.username, widget.account.password);

          // Find the Sent folder (try common names)
          final mailboxes = await imapClient.listMailboxes();
          String? sentFolder;
          for (final name in ['Sent', 'INBOX.Sent', 'Sent Items', 'Sent Messages', '[Gmail]/Sent Mail']) {
            if (mailboxes.any((mb) => mb.name == name || mb.path == name)) {
              sentFolder = mailboxes.firstWhere((mb) => mb.name == name || mb.path == name).path;
              break;
            }
          }

          if (sentFolder != null) {
            await imapClient.appendMessage(mimeMessage, targetMailboxPath: sentFolder, flags: [MessageFlags.seen]);
            print('✅ Saved sent email to IMAP $sentFolder folder');
          } else {
            print('⚠️ Could not find Sent folder in IMAP');
          }

          await imapClient.logout();
        } catch (e) {
          print('❌ Failed to save to IMAP Sent folder: $e');
          // Don't fail the whole operation if IMAP save fails
        }

        // Mark the original email as replied in the database
        try {
          final db = await main.DatabaseHelper.instance.database;
          await db.update(
            'emails',
            {'isAnswered': 1},
            where: 'messageId = ?',
            whereArgs: [widget.email['messageId']],
          );
          print('✅ Marked original email as replied in database');
        } catch (e) {
          print('❌ Failed to mark email as replied in database: $e');
        }

        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Email sent successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );

        // Navigate back after a short delay
        await Future.delayed(const Duration(seconds: 1));
        Navigator.of(context).pop();
      } else {
        throw Exception('SMTP send failed: ${sendResponse.message}');
      }
      
    } catch (e) {
      // Clear any existing snackbars
      ScaffoldMessenger.of(context).clearSnackBars();
      
      String errorMessage = 'Failed to send reply: $e';
      
      // Provide more specific error messages
      if (e.toString().contains('authentication')) {
        errorMessage = 'Authentication failed. Please check your email credentials.';
      } else if (e.toString().contains('connection')) {
        errorMessage = 'Connection failed. Please check your SMTP server settings.';
      } else if (e.toString().contains('TLS')) {
        errorMessage = 'Secure connection failed. Please check your SMTP server supports TLS.';
      }
      
      _showErrorSnackBar(errorMessage);
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  void dispose() {
    _toController.dispose();
    _ccController.dispose();
    _bccController.dispose();
    _subjectController.dispose();
    _bodyController.dispose();
    _ccFocusNode.dispose();
    _bccFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final replyTitle = widget.replyType == ReplyType.reply ? 'Reply' : 'Reply All';
    
    return Scaffold(
      appBar: AppBar(
        title: Text(replyTitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _sendReply,
            child: const Text(
              'Send',
              style: TextStyle(
                color: Colors.blue,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // To field
            TextField(
              controller: _toController,
              decoration: const InputDecoration(
                labelText: 'To',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            
            // CC/BCC toggle buttons
            Row(
              children: [
                if (!_showCc)
                  TextButton(
                    onPressed: () => setState(() => _showCc = true),
                    child: const Text('Cc'),
                  ),
                if (!_showBcc)
                  TextButton(
                    onPressed: () => setState(() => _showBcc = true),
                    child: const Text('Bcc'),
                  ),
              ],
            ),

            // CC field with autocomplete
            if (_showCc) ...[
              const SizedBox(height: 12),
              RawAutocomplete<String>(
                textEditingController: _ccController,
                focusNode: _ccFocusNode,
                optionsBuilder: (TextEditingValue textEditingValue) async {
                  return await _getContactSuggestions(textEditingValue.text);
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: 'Cc',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _showCc = false;
                          _ccController.clear();
                        }),
                      ),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4.0,
                      child: SizedBox(
                        width: MediaQuery.of(context).size.width - 32,
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options.elementAt(index);
                            return ListTile(
                              title: Text(option),
                              onTap: () => onSelected(option),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],

            // BCC field with autocomplete
            if (_showBcc) ...[
              const SizedBox(height: 12),
              RawAutocomplete<String>(
                textEditingController: _bccController,
                focusNode: _bccFocusNode,
                optionsBuilder: (TextEditingValue textEditingValue) async {
                  return await _getContactSuggestions(textEditingValue.text);
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: 'Bcc',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() {
                          _showBcc = false;
                          _bccController.clear();
                        }),
                      ),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  );
                },
                optionsViewBuilder: (context, onSelected, options) {
                  return Align(
                    alignment: Alignment.topLeft,
                    child: Material(
                      elevation: 4.0,
                      child: SizedBox(
                        width: MediaQuery.of(context).size.width - 32,
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          shrinkWrap: true,
                          itemCount: options.length,
                          itemBuilder: (context, index) {
                            final option = options.elementAt(index);
                            return ListTile(
                              title: Text(option),
                              onTap: () => onSelected(option),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],

            const SizedBox(height: 12),

            // Subject field
            TextField(
              controller: _subjectController,
              decoration: const InputDecoration(
                labelText: 'Subject',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),

            // Body field
            Expanded(
              child: TextField(
                controller: _bodyController,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
