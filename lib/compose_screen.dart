import 'package:flutter/material.dart';
import 'package:enough_mail/enough_mail.dart';
import 'main.dart' as main;
import 'contact_helper.dart';

class ComposeScreen extends StatefulWidget {
  final dynamic account;

  const ComposeScreen({
    Key? key,
    required this.account,
  }) : super(key: key);

  @override
  _ComposeScreenState createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {

  final TextEditingController _toController = TextEditingController();
  final TextEditingController _ccController = TextEditingController();
  final TextEditingController _bccController = TextEditingController();
  final TextEditingController _subjectController = TextEditingController();
  final TextEditingController _bodyController = TextEditingController();

  // FocusNodes for autocomplete fields (must be disposed)
  final FocusNode _toFocusNode = FocusNode();
  final FocusNode _ccFocusNode = FocusNode();
  final FocusNode _bccFocusNode = FocusNode();

  bool _showCc = false;
  bool _showBcc = false;

  // Account selection
  List<dynamic> _accounts = [];
  dynamic _selectedAccount;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _selectedAccount = widget.account;
  }

  Future<void> _loadAccounts() async {
    final accounts = await main.DatabaseHelper.instance.getAccounts();
    setState(() {
      _accounts = accounts;
      
      // Find the matching account from the loaded list
      if (widget.account != null && accounts.isNotEmpty) {
        // Try to find account by username/email
        final matchingAccount = accounts.where((acc) => 
          acc.username == widget.account.username || 
          acc.replyFrom == widget.account.replyFrom
        ).firstOrNull;
        
        _selectedAccount = matchingAccount ?? accounts.first;
      } else if (accounts.isNotEmpty) {
        _selectedAccount = accounts.first;
      }
    });
  }

  // Contact search using shared helper
  Future<List<String>> _getContactSuggestions(String query) async {
    return ContactHelper.getContactSuggestions(query, _selectedAccount?.username);
  }

  Future<void> _sendEmail() async {
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

      // Use the selected account for sending
      final account = _selectedAccount ?? widget.account;

      // Create SMTP client
      final smtpClient = SmtpClient('furimail');
      await smtpClient.connectToServer(account.smtp, 587, isSecure: false);
      await smtpClient.ehlo();
      await smtpClient.startTls(); // Start TLS for security
      await smtpClient.authenticate(account.username, account.password);

      // Create the email message
      final builder = MessageBuilder();
      
      // Debug log to verify account information
      print('DEBUG SMTP: Account name: "${account.name}"');
      print('DEBUG SMTP: Account replyFrom: "${account.replyFrom}"');
      
      builder.from = [MailAddress(account.name, account.replyFrom)];
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
      
      // Set message content (plain text)
      String messageBody = _bodyController.text.trim();
      
      // Add signature if account has one
      if (account.signature.isNotEmpty) {
        messageBody += '\n\n${account.signature}';
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
          await imapClient.connectToServer(_selectedAccount!.imap, 993, isSecure: true);
          await imapClient.login(_selectedAccount!.username, _selectedAccount!.password);

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
      
      String errorMessage = 'Failed to send email: $e';
      
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
    _toFocusNode.dispose();
    _ccFocusNode.dispose();
    _bccFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compose Email'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _sendEmail,
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
            // Account selection dropdown
            if (_accounts.isNotEmpty)
              DropdownButtonFormField<dynamic>(
                value: _selectedAccount,
                items: _accounts.map<DropdownMenuItem<dynamic>>((acc) {
                  return DropdownMenuItem(
                    value: acc,
                    child: Text('${acc.name} <${acc.replyFrom}>'),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedAccount = value;
                  });
                },
                decoration: const InputDecoration(
                  labelText: 'From',
                  border: OutlineInputBorder(),
                ),
              ),
            if (_accounts.isEmpty)
              Container(
                padding: const EdgeInsets.all(12.0),
                child: Text('No accounts found', style: TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),

            // To field with autocomplete
            RawAutocomplete<String>(
              textEditingController: _toController,
              focusNode: _toFocusNode,
              optionsBuilder: (TextEditingValue textEditingValue) async {
                return await _getContactSuggestions(textEditingValue.text);
              },
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'To',
                    border: OutlineInputBorder(),
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
                      height: 200.0,
                      child: ListView.builder(
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
                        height: 200.0,
                        child: ListView.builder(
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
                        height: 200.0,
                        child: ListView.builder(
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

            // Email body content field
            Expanded(
              child: TextField(
                controller: _bodyController,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                textAlignVertical: TextAlignVertical.top,
              ),
            ),

            const SizedBox(height: 24),

            // Send button
            ElevatedButton(
              onPressed: _sendEmail,
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }
}
