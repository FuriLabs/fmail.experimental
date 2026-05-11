import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'reply_screen.dart';
import 'main.dart' as main;

// Custom factory for handling inline images properly
class _CustomHtmlWidgetFactory extends WidgetFactory {
  @override
  Widget? buildImageWidget(BuildMetadata meta, ImageSource src) {
    final url = src.url;
    
    // Handle data URLs (base64 images)
    if (url.startsWith('data:image/')) {
      try {
        print('🔍 DEBUG: Processing data URL: ${url.substring(0, min(100, url.length))}...');
        final parts = url.split(',');
        if (parts.length < 2) {
          print('❌ ERROR: Malformed data URL - no comma found: $url');
          return Container(
            padding: const EdgeInsets.all(8),
            color: Colors.grey.shade200,
            child: const Text(
              'Malformed image data URL',
              style: TextStyle(color: Colors.red),
            ),
          );
        }
        final base64Data = parts[1];
        if (base64Data.isEmpty) {
          print('❌ ERROR: Empty base64 data in URL: $url');
          return Container(
            padding: const EdgeInsets.all(8),
            color: Colors.grey.shade200,
            child: const Text(
              'Empty image data',
              style: TextStyle(color: Colors.red),
            ),
          );
        }
        final bytes = base64Decode(base64Data);
        
        // Get original dimensions from HTML attributes if available
        double? width;
        double? height;
        
        final widthAttr = meta.element.attributes['width'];
        final heightAttr = meta.element.attributes['height'];
        final styleAttr = meta.element.attributes['style'];
        
        if (widthAttr != null) {
          width = double.tryParse(widthAttr.replaceAll('px', ''));
        }
        if (heightAttr != null) {
          height = double.tryParse(heightAttr.replaceAll('px', ''));
        }
        
        // Parse width/height from style attribute
        if (styleAttr != null) {
          final widthMatch = RegExp(r'width:\s*(\d+)px').firstMatch(styleAttr);
          final heightMatch = RegExp(r'height:\s*(\d+)px').firstMatch(styleAttr);
          
          if (widthMatch != null) {
            width = double.tryParse(widthMatch.group(1)!);
          }
          if (heightMatch != null) {
            height = double.tryParse(heightMatch.group(1)!);
          }
        }
        
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: Image.memory(
            bytes,
            width: width,
            height: height,
            fit: width != null || height != null ? BoxFit.contain : null,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                padding: const EdgeInsets.all(8),
                color: Colors.grey.shade200,
                child: const Text(
                  'Failed to load image',
                  style: TextStyle(color: Colors.red),
                ),
              );
            },
          ),
        );
      } catch (e) {
        print('Error decoding image data URL: $e');
        return Container(
          padding: const EdgeInsets.all(8),
          color: Colors.grey.shade200,
          child: const Text(
            'Invalid image data',
            style: TextStyle(color: Colors.red),
          ),
        );
      }
    }
    
    // Fallback to default behavior for other image types
    return super.buildImageWidget(meta, src);
  }
}

class EmailDetailScreen extends StatefulWidget {
  final Map<String, dynamic> email;
  final dynamic account;
  final bool alwaysShowText;

  const EmailDetailScreen({
    Key? key,
    required this.email,
    required this.account,
    this.alwaysShowText = false,
  }) : super(key: key);

  @override
  _EmailDetailScreenState createState() => _EmailDetailScreenState();
}

class _EmailDetailScreenState extends State<EmailDetailScreen> {
  bool _forceTextView = false;
  bool _isLoadingBody = false;
  String? _fetchedContent;

  @override
  void initState() {
    super.initState();
    _forceTextView = widget.alwaysShowText;
    
    // Check if body needs to be fetched
    _checkAndFetchBody();
  }
  
  Future<void> _checkAndFetchBody() async {
    final bodyFetched = widget.email['bodyFetched'] as int? ?? 1;
    final content = widget.email['content']?.toString() ?? '';
    final messageId = widget.email['messageId']?.toString() ?? '';
    final subject = widget.email['subject']?.toString() ?? '';
    final uid = widget.email['uid'] as int? ?? 0;
    final folderPath = widget.email['folderPath']?.toString() ?? 'INBOX';
    
    print('🔍 EmailDetailScreen opened:');
    print('   Subject: ${subject.substring(0, min(50, subject.length))}');
    print('   MessageID: ${messageId.substring(0, min(50, messageId.length))}');
    print('   UID: $uid, Folder: $folderPath');
    print('   bodyFetched: $bodyFetched');
    print('   content preview: ${content.substring(0, min(100, content.length))}...');
    
    // If body not fetched yet, fetch it on-demand
    if (bodyFetched == 0 || content == '[Loading email body...]') {
      setState(() {
        _isLoadingBody = true;
      });
      
      print('📥 Fetching body on-demand...');
      
      try {
        final fetchedContent = await main.DatabaseHelper.fetchSingleEmailBody(
          account: widget.account,
          folderPath: folderPath,
          uid: uid,
          messageId: messageId,
        );
        
        if (fetchedContent != null && mounted) {
          print('✅ Body fetched successfully: ${fetchedContent.substring(0, min(100, fetchedContent.length))}...');
          setState(() {
            _fetchedContent = fetchedContent;
            _isLoadingBody = false;
          });
        }
      } catch (e) {
        print('Error fetching email body: $e');
        if (mounted) {
          setState(() {
            _isLoadingBody = false;
          });
        }
      }
    } else {
      print('ℹ️ Body already in database, using existing content');
    }
  }

  // Download attachment to device storage
  Future<void> _downloadAttachment(Map<String, dynamic> attachment) async {
    try {
      // Request storage permission
      if (Platform.isAndroid) {
        var status = await Permission.storage.status;
        if (!status.isGranted) {
          status = await Permission.storage.request();
          if (!status.isGranted) {
            _showErrorSnackBar('Storage permission denied');
            return;
          }
        }
      }

      // Get the downloads directory
      Directory? downloadsDirectory;
      if (Platform.isAndroid) {
        downloadsDirectory = Directory('/storage/emulated/0/Download');
        if (!await downloadsDirectory.exists()) {
          downloadsDirectory = await getExternalStorageDirectory();
        }
      } else {
        downloadsDirectory = await getApplicationDocumentsDirectory();
      }

      if (downloadsDirectory == null) {
        _showErrorSnackBar('Could not access downloads directory');
        return;
      }

      // Decode base64 data
      final String base64Data = attachment['data']?.toString() ?? '';
      if (base64Data.isEmpty) {
        _showErrorSnackBar('No attachment data found');
        return;
      }

      final Uint8List bytes = base64.decode(base64Data);
      
      // Create filename
      String filename = attachment['filename']?.toString() ?? 'attachment';
      
      // Ensure unique filename if file already exists
      String finalPath = '${downloadsDirectory.path}/$filename';
      int counter = 1;
      while (await File(finalPath).exists()) {
        final extension = filename.contains('.') ? filename.split('.').last : '';
        final name = filename.contains('.') 
            ? filename.substring(0, filename.lastIndexOf('.'))
            : filename;
        final newFilename = extension.isNotEmpty 
            ? '${name}_$counter.$extension'
            : '${name}_$counter';
        finalPath = '${downloadsDirectory.path}/$newFilename';
        counter++;
      }

      // Write file
      final File file = File(finalPath);
      await file.writeAsBytes(bytes);

      // Show success message
      _showSuccessSnackBar('Downloaded: ${file.path.split('/').last}');
      
    } catch (e) {
      print('Download error: $e');
      _showErrorSnackBar('Download failed: $e');
    }
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // Get initials from sender name/email for avatar
  String _getInitials(String sender) {
    if (sender.isEmpty) return '?';
    
    // Extract name from "Name <email>" format or use email
    String displayName = sender;
    if (sender.contains('<')) {
      displayName = sender.substring(0, sender.indexOf('<')).trim();
    }
    if (displayName.isEmpty && sender.contains('@')) {
      displayName = sender.substring(0, sender.indexOf('@'));
    }
    
    // Get initials from name
    final words = displayName.trim().split(' ');
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    } else if (words.isNotEmpty && words[0].isNotEmpty) {
      return words[0][0].toUpperCase();
    }
    return '?';
  }

  // Build action button widget
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    Color? color,
  }) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: color ?? Colors.blue,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color ?? Colors.blue,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Email action handlers
  void _handleReply(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReplyScreen(
          email: widget.email,
          account: widget.account,
          replyType: ReplyType.reply,
        ),
      ),
    );
  }

  void _handleReplyAll(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ReplyScreen(
          email: widget.email,
          account: widget.account,
          replyType: ReplyType.replyAll,
        ),
      ),
    );
  }

  void _handleMarkAsJunk(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Mark as Junk'),
          content: const Text('Are you sure you want to mark this email as junk?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  // TODO: Implement actual junk filtering
                  // For now, we'll move to a "junk" folder and mark as read
                  await _markEmailAsJunk();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Email marked as junk'),
                      backgroundColor: Colors.orange,
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to mark as junk: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: const Text('Mark as Junk'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _markEmailAsJunk() async {
    try {
      // Get database instance using the imported DatabaseHelper
      final db = await main.DatabaseHelper.instance.database;
      
      // Update the email to mark it as junk
      await db.update(
        'emails',
        {
          'folderPath': 'JUNK',
          'isRead': 1, // Mark as read when moving to junk
        },
        where: 'messageId = ?',
        whereArgs: [widget.email['messageId']],
      );
      
      print('Successfully marked email ${widget.email['messageId']} as junk');
      
      // TODO: Additional junk handling could include:
      // 1. Adding sender to blocklist
      // 2. Training spam filter
      // 3. Moving to dedicated junk folder on IMAP server
      
    } catch (e) {
      print('Error marking email as junk: $e');
      rethrow;
    }
  }

  void _handleUnsubscribe(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Unsubscribe'),
          content: const Text('Do you want to unsubscribe from this sender?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  await _handleUnsubscribeAction();
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Unsubscribe failed: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: const Text('Unsubscribe'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleUnsubscribeAction() async {
    final rawEmail = widget.email['rawEmail']?.toString() ?? '';
    
    // Look for List-Unsubscribe header in raw email
    String? unsubscribeUrl = _extractUnsubscribeUrl(rawEmail);
    
    if (unsubscribeUrl != null) {
      await _launchUnsubscribeUrl(unsubscribeUrl);
    } else {
      // Look for unsubscribe links in email content
      unsubscribeUrl = _findUnsubscribeLinkInContent();
      
      if (unsubscribeUrl != null) {
        await _launchUnsubscribeUrl(unsubscribeUrl);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No unsubscribe link found in this email'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  Future<void> _launchUnsubscribeUrl(String url) async {
    try {
      // Clean up the URL if needed
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://$url';
      }

      final Uri uri = Uri.parse(url);
      
      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Opening unsubscribe link: $url'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cannot open unsubscribe link: $url'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening unsubscribe link: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String? _extractUnsubscribeUrl(String rawEmail) {
    // Look for List-Unsubscribe header
    final listUnsubscribeRegex = RegExp(r'List-Unsubscribe:\s*<([^>]+)>', caseSensitive: false);
    final match = listUnsubscribeRegex.firstMatch(rawEmail);
    
    if (match != null) {
      return match.group(1);
    }
    
    return null;
  }

  String? _findUnsubscribeLinkInContent() {
    final content = widget.email['content']?.toString() ?? '';
    
    // Look for unsubscribe links in the content
    final unsubscribeRegex = RegExp(
      r'''href=["']([^"']*(?:unsubscribe|opt-out|optout)[^"']*)["']''',
      caseSensitive: false,
    );
    
    final match = unsubscribeRegex.firstMatch(content);
    if (match != null) {
      return match.group(1);
    }
    
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final subject = widget.email['subject']?.toString() ?? 'No Subject';
    // Fix: Use correct database fields for sender information
    final senderName = widget.email['sender']?.toString() ?? 'Unknown Sender';
    final senderEmail = widget.email['senderEmail']?.toString() ?? '';
    final from = senderEmail.isNotEmpty ? '$senderName <$senderEmail>' : senderName;
    
    // Fix: Use timestamp field and convert from milliseconds since epoch
    final timestamp = widget.email['timestamp'] as int? ?? 0;
    
    // CRITICAL DEBUG: Print what content we're actually going to display
    print('🎨 EmailDetailScreen RENDERING:');
    print('   Subject from widget: ${subject.substring(0, min(50, subject.length))}');
    print('   MessageID from widget: ${(widget.email['messageId']?.toString() ?? 'null').substring(0, min(50, (widget.email['messageId']?.toString() ?? 'null').length))}');
    
    // Use fetched content if available, otherwise use widget content
    final String content;
    if (_fetchedContent != null) {
      content = _fetchedContent!;
      print('   Using _fetchedContent (${content.substring(0, min(100, content.length))})...');
    } else {
      content = (widget.email['content'] ?? '').toString();
      print('   Using widget.email content (${content.substring(0, min(100, content.length))})...');
    }
    
    final attachments = jsonDecode(widget.email['attachments'] ?? '[]');
    
    // Parse timestamp for formatting
    DateTime parsedDate = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final formattedDate = DateFormat('MMM dd, yyyy \'at\' hh:mm a').format(parsedDate);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          subject.length > 30 ? '${subject.substring(0, 30)}...' : subject,
          style: const TextStyle(fontSize: 16),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(_forceTextView ? Icons.code : Icons.text_fields),
            onPressed: () {
              setState(() {
                _forceTextView = !_forceTextView;
              });
            },
            tooltip: _forceTextView ? 'Show Rich Content' : 'Show Plain Text',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Email Header
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Subject
                    Text(
                      subject,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Sender Info
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Colors.blue.shade100,
                          child: Text(
                            _getInitials(from),
                            style: TextStyle(
                              color: Colors.blue.shade700,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                from,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                formattedDate,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Action Buttons
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildActionButton(
                          icon: Icons.reply,
                          label: 'Reply',
                          onPressed: () => _handleReply(context),
                        ),
                        _buildActionButton(
                          icon: Icons.reply_all,
                          label: 'Reply All',
                          onPressed: () => _handleReplyAll(context),
                        ),
                        _buildActionButton(
                          icon: Icons.block,
                          label: 'Junk',
                          color: Colors.orange,
                          onPressed: () => _handleMarkAsJunk(context),
                        ),
                        _buildActionButton(
                          icon: Icons.unsubscribe,
                          label: 'Unsub',
                          color: Colors.red,
                          onPressed: () => _handleUnsubscribe(context),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),

            // Email Content with Hybrid Image Display
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Content',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_isLoadingBody)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20.0),
                          child: Column(
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text('Loading email body...'),
                            ],
                          ),
                        ),
                      )
                    else if (content.isNotEmpty)
                      _buildContentDisplay(content, attachments)
                    else
                      const Text(
                        'No content available',
                        style: TextStyle(fontStyle: FontStyle.italic),
                      ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            
            // File Attachments (non-inline only)
            if (attachments.isNotEmpty) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'File Attachments',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...attachments
                          .where((attachment) => 
                              attachment is Map && 
                              attachment['isInline'] != true)
                          .map<Widget>((attachment) {
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.attach_file),
                            title: Text(attachment['filename']?.toString() ?? 'Unknown file'),
                            subtitle: Text(attachment['contentType']?.toString() ?? 'Unknown type'),
                            trailing: IconButton(
                              icon: const Icon(Icons.download),
                              onPressed: () => _downloadAttachment(attachment),
                            ),
                          ),
                        );
                      }).toList(),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildContentDisplay(String content, List<dynamic> attachments) {
    if (_forceTextView) {
      final plainText = _htmlToPlainText(content);
      return SelectableText(
        plainText,
        style: const TextStyle(
          height: 1.5,
          fontSize: 14,
          fontFamily: 'monospace', // Use monospace to better preserve formatting
        ),
      );
    }
    
    return FutureBuilder<Map<String, dynamic>>(
      future: _processEmailContent(content, attachments),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        
        if (snapshot.hasError) {
          print('Error processing content: ${snapshot.error}');
          final plainText = _htmlToPlainText(content);
          return SelectableText(
            plainText,
            style: const TextStyle(
              height: 1.5,
              fontSize: 14,
              fontFamily: 'monospace',
            ),
          );
        }
        
        final result = snapshot.data!;
        final processedContent = result['content'] as String;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Display content using HtmlWidget with inline images
            Container(
              constraints: const BoxConstraints(minHeight: 200),
              child: HtmlWidget(
                processedContent,
                textStyle: const TextStyle(
                  fontSize: 14, 
                  height: 1.5,
                  color: Colors.white,
                ),
                // Custom factory to handle images properly
                factoryBuilder: () => _CustomHtmlWidgetFactory(),
              ),
            ),
          ],
        );
      },
    );
  }

  // Process email content and handle inline images properly
  Future<Map<String, dynamic>> _processEmailContent(String content, List<dynamic> attachments) async {
    try {
      print('🖼️ Processing email content for inline display...');
      
      // Replace CID references with data URLs and keep them in HTML
      String processedContent = _replaceCidReferences(content, attachments);
      
      // For HtmlWidget, we'll use a custom WidgetFactory to handle images properly
      // No need to extract images separately anymore - they stay in their HTML positions
      
      return {
        'content': processedContent,
        'images': <String>[], // Empty since we're keeping images inline
      };
    } catch (e) {
      print('🖼️ Error processing content: $e');
      return {
        'content': content,
        'images': <String>[],
      };
    }
  }

  // Replace CID references in HTML content with data URLs
  String _replaceCidReferences(String htmlContent, List<dynamic> attachments) {
    print('🔍 DEBUG: Original HTML content preview: ${htmlContent.substring(0, min(400, htmlContent.length))}...');
    
    // Check for existing data URLs in the content
    if (htmlContent.contains('data:')) {
      print('❌ WARNING: HTML already contains data: URLs before CID replacement!');
      final dataUrls = RegExp(r'data:[^"\s]*').allMatches(htmlContent);
      for (final match in dataUrls) {
        print('❌ Found existing data URL: ${match.group(0)}');
      }
    }
    
    String processedContent = htmlContent;
    
    // Fix malformed data URLs that have filename parameters before base64
    processedContent = processedContent.replaceAllMapped(
      RegExp(r'src="(data:image/[^;]+);\s*name="[^"]*";(base64,[^"]*)"'),
      (match) {
        final mimeType = match.group(1)!;
        final base64Data = match.group(2)!;
        final fixedUrl = '$mimeType;$base64Data';
        print('🔧 Fixed malformed data URL: ${mimeType}; name=... -> $mimeType;base64,...');
        return 'src="$fixedUrl"';
      }
    );
    
    // Create a mapping of Content-IDs to data URLs
    Map<String, String> cidToDataUrl = {};
    
    for (var attachment in attachments) {
      if (attachment is! Map) continue;
      
      final contentId = attachment['cid']?.toString();
      final contentType = attachment['contentType']?.toString() ?? '';
      final base64Data = attachment['data']?.toString() ?? '';
      final isImage = contentType.startsWith('image/');
      
      if (contentId != null && contentId.isNotEmpty && isImage && base64Data.isNotEmpty) {
        // Extract just the media type from content-type (remove parameters like name="...")
        final mediaType = contentType.split(';')[0].trim();
        final dataUrl = 'data:$mediaType;base64,$base64Data';
        
        // Store multiple formats for better matching
        cidToDataUrl[contentId] = dataUrl;
        
        // Also store without angle brackets if present
        final cleanCid = contentId.replaceAll(RegExp(r'[<>]'), '');
        if (cleanCid != contentId) {
          cidToDataUrl[cleanCid] = dataUrl;
        }
        
        print("🔄 Mapped CID '$contentId' to data URL (${dataUrl.length} chars)");
      }
    }
    
    // Replace CID references with data URLs
    for (var entry in cidToDataUrl.entries) {
      final cid = entry.key;
      final dataUrl = entry.value;
      
      // Replace various CID reference formats
      processedContent = processedContent.replaceAll('src="cid:$cid"', 'src="$dataUrl"');
      processedContent = processedContent.replaceAll("src='cid:$cid'", "src='$dataUrl'");
      processedContent = processedContent.replaceAll('cid:$cid', dataUrl);
    }
    
    print("🔄 CID replacement complete. Content size: ${processedContent.length}");
    return processedContent;
  }

  String _htmlToPlainText(String htmlContent) {
    // Balanced HTML to plain text conversion
    String text = htmlContent;
    
    // Remove style blocks (CSS)
    text = text.replaceAll(RegExp(r'<style[^>]*>.*?</style>', caseSensitive: false, dotAll: true), '');
    
    // Remove script blocks (JavaScript)
    text = text.replaceAll(RegExp(r'<script[^>]*>.*?</script>', caseSensitive: false, dotAll: true), '');
    
    // Remove comments
    text = text.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    
    // Handle block elements that should create line breaks
    // Headers - add line break before and after
    text = text.replaceAll(RegExp(r'<h[1-6][^>]*>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'</h[1-6]>', caseSensitive: false), '\n\n');
    
    // Paragraphs - add line break before and after
    text = text.replaceAll(RegExp(r'<p[^>]*>', caseSensitive: false), '\n\n');
    text = text.replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n');
    
    // Divs - add line break (many emails use divs as paragraphs)
    text = text.replaceAll(RegExp(r'<div[^>]*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</div>', caseSensitive: false), '\n');
    
    // Line breaks
    text = text.replaceAll(RegExp(r'<br[^>]*/?>', caseSensitive: false), '\n');
    
    // List items - add line break and bullet
    text = text.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ');
    text = text.replaceAll(RegExp(r'</li>', caseSensitive: false), '');
    
    // Table rows - add line breaks for each row
    text = text.replaceAll(RegExp(r'<tr[^>]*>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'</tr>', caseSensitive: false), '');
    
    // Table cells - add space between cells
    text = text.replaceAll(RegExp(r'<t[hd][^>]*>', caseSensitive: false), ' ');
    text = text.replaceAll(RegExp(r'</t[hd]>', caseSensitive: false), ' ');
    
    // Remove all remaining HTML tags
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');
    
    // Decode HTML entities
    text = text.replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAll('&#x2F;', '/')
        .replaceAll('&#x3D;', '=')
        .replaceAll('&apos;', "'")
        .replaceAll('&copy;', '©')
        .replaceAll('&reg;', '®')
        .replaceAll('&trade;', '™');
    
    // Clean up whitespace while preserving meaningful line breaks
    // First, normalize multiple spaces to single spaces
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    
    // Then handle line breaks more carefully
    // Replace sequences of newlines + spaces + newlines with just double newlines
    text = text.replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n');
    
    // Replace single newlines that have only spaces around them with single newlines
    text = text.replaceAll(RegExp(r'\n[ \t]*\n'), '\n\n');
    
    // Remove leading/trailing spaces on each line
    text = text.split('\n').map((line) => line.trim()).join('\n');
    
    // Remove excessive empty lines (more than 2 consecutive)
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    
    // Remove empty lines at start and end
    text = text.trim();
    
    return text;
  }
}
