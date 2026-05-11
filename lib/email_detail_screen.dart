import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:intl/intl.dart';

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

  @override
  void initState() {
    super.initState();
    // FlutterError.onError is set once in main() - don't override it here
  }

  String _htmlToPlainText(String htmlContent) {
    final document = html_parser.parse(htmlContent);
    String text = document.body?.text.trim() ?? htmlContent;

    // Process line by line to clean up whitespace and blank lines
    List<String> lines = text.split('\n');
    List<String> processedLines = [];
    bool lastLineWasEmpty = false;

    for (String line in lines) {
      String trimmedLine = line.trim();
      
      if (trimmedLine.isEmpty) {
        if (!lastLineWasEmpty) {
          processedLines.add('');
          lastLineWasEmpty = true;
        }
      } else {
        processedLines.add(trimmedLine);
        lastLineWasEmpty = false;
      }
    }

    return processedLines.join('\n').trim();
  }

  @override
  Widget build(BuildContext context) {
    try {
      final subject = widget.email['subject']?.toString() ?? 'No Subject';
      final from = widget.email['from']?.toString() ?? 'Unknown Sender';
      final date = widget.email['date']?.toString() ?? '';
      
      // Parse date for formatting
      DateTime? parsedDate;
      try {
        if (date.isNotEmpty) {
          parsedDate = DateTime.parse(date);
        }
      } catch (e) {
        // If parsing fails, leave parsedDate as null
      }
      
      final formattedDate = parsedDate != null
          ? DateFormat('MMM dd, yyyy \'at\' hh:mm a').format(parsedDate)
          : date;

      // Get content - prioritize HTML over plain text
      final content = (widget.email['content'] ?? '').toString();
      final attachments = jsonDecode(widget.email['attachments'] ?? '[]');

      return Scaffold(
        appBar: AppBar(
          title: Text('Email Details'),
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
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        subject,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'From: $from',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.blue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Date: $formattedDate',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 16),

              // Email Content
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
                      if (content.isNotEmpty)
                        _forceTextView || widget.alwaysShowText
                            ? SelectableText(
                                _htmlToPlainText(content),
                                style: const TextStyle(height: 1.5),
                              )
                            : _buildHybridContentDisplay(content, attachments)
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
                          try {
                            return Card(
                              child: ListTile(
                                leading: const Icon(Icons.attach_file),
                                title: Text(attachment['filename']?.toString() ?? 'Unknown file'),
                                subtitle: Text(attachment['contentType']?.toString() ?? 'Unknown type'),
                                trailing: IconButton(
                                  icon: const Icon(Icons.download),
                                  onPressed: () {
                                    // TODO: Implement attachment download
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Download not yet implemented')),
                                    );
                                  },
                                ),
                              ),
                            );
                          } catch (e) {
                            print('Error rendering attachment: $e');
                            return Card(
                              color: Colors.red.withOpacity(0.1),
                              child: ListTile(
                                leading: const Icon(Icons.error, color: Colors.red),
                                title: Text(attachment['filename']?.toString() ?? 'Unknown file'),
                                subtitle: Text('Error loading attachment: $e'),
                              ),
                            );
                          }
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
    } catch (e, stack) {
      print('Critical error in build: $e');
      print(stack);
      return Scaffold(
        appBar: AppBar(
          title: const Text('Error'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: const Center(child: Text('Unable to display email')),
      );
    }
  }

  // Build hybrid display with native images and WebView text
  Widget _buildHybridContentDisplay(String htmlContent, List<dynamic> attachments) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _processEmailContent(htmlContent, attachments),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        
        if (snapshot.hasError) {
          print('Error processing content: ${snapshot.error}');
          return SelectableText(
            _htmlToPlainText(htmlContent),
            style: const TextStyle(height: 1.5),
          );
        }
        
        final result = snapshot.data!;
        final processedContent = result['content'] as String;
        final inlineImages = result['images'] as List<String>;
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Display inline images natively first
            if (inlineImages.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '📷 Email Images (${inlineImages.length})',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...inlineImages.asMap().entries.map((entry) {
                      final index = entry.key;
                      final dataUrl = entry.value;
                      return _buildNativeImage(dataUrl, index + 1);
                    }).toList(),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // Display text content
            Container(
              constraints: const BoxConstraints(minHeight: 200),
              child: _buildWebViewContent(processedContent),
            ),
          ],
        );
      },
    );
  }

  // Process email content and extract inline images
  Future<Map<String, dynamic>> _processEmailContent(String content, List<dynamic> attachments) async {
    try {
      print('🖼️ Processing email content...');
      
      // Replace CID references with data URLs first
      String processedContent = _replaceCidReferences(content, attachments);
      
      // Extract data URLs from the processed content
      final List<String> imageDataUrls = [];
      final RegExp dataUrlRegex = RegExp(r'data:image/[^;]+;base64,([A-Za-z0-9+/=]+)', multiLine: true);
      final matches = dataUrlRegex.allMatches(processedContent);
      
      for (final match in matches) {
        final fullDataUrl = match.group(0)!;
        imageDataUrls.add(fullDataUrl);
        print('🖼️ Found embedded image: ${fullDataUrl.substring(0, 50)}...');
      }
      
      // Create content without data URLs for WebView (replace with placeholders)
      String webViewContent = processedContent;
      for (int i = 0; i < imageDataUrls.length; i++) {
        webViewContent = webViewContent.replaceFirst(
          imageDataUrls[i], 
          '<div style="padding: 10px; background: #f0f0f0; text-align: center; border-radius: 4px; margin: 8px 0;">[Image ${i + 1} displayed above]</div>'
        );
      }
      
      return {
        'content': webViewContent,
        'images': imageDataUrls,
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
    String processedContent = htmlContent;
    
    // Create a mapping of Content-IDs to data URLs
    Map<String, String> cidToDataUrl = {};
    
    for (var attachment in attachments) {
      if (attachment is! Map) continue;
      
      final contentId = attachment['cid']?.toString();
      final contentType = attachment['contentType']?.toString() ?? '';
      final base64Data = attachment['data']?.toString() ?? '';
      final isImage = contentType.startsWith('image/');
      
      print('🔍 DEBUG: Processing attachment - CID: $contentId, Type: $contentType, IsImage: $isImage, DataLength: ${base64Data.length}');
      
      if (contentId != null && contentId.isNotEmpty && isImage) {
        if (base64Data.isEmpty) {
          print('❌ ERROR: Empty base64Data for CID $contentId');
          continue;
        }
        
        // Extract just the media type from content-type (remove parameters like name="...")
        final mediaType = contentType.split(';')[0].trim();
        
        print('🔍 DEBUG: Extracted mediaType: "$mediaType" from contentType: "$contentType"');
        
        final dataUrl = 'data:$mediaType;base64,$base64Data';
        
        print('🔍 DEBUG: Created data URL for CID $contentId: ${dataUrl.substring(0, min(80, dataUrl.length))}...');
        
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
      
      // Handle quoted-printable encoded CID references (=XX format)
      final quotedPrintableCid = 'cid:$cid'.replaceAllMapped(
        RegExp(r'([=:@.-])'),
        (match) {
          final char = match.group(1)!;
          final hex = char.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(2, '0');
          return '=$hex';
        },
      );
      processedContent = processedContent.replaceAll(quotedPrintableCid, dataUrl);
    }
    
    print("🔄 CID replacement complete. Content size: ${processedContent.length}");
    return processedContent;
  }

  // Build native Flutter image widget from data URL
  Widget _buildNativeImage(String dataUrl, int imageNumber) {
    try {
      print('🔍 DEBUG: Building image widget with dataUrl: ${dataUrl.substring(0, min(100, dataUrl.length))}...');
      
      // Extract base64 content from data URL
      final base64Start = dataUrl.indexOf('base64,');
      if (base64Start == -1) {
        print('❌ ERROR: No base64 data found in dataUrl: $dataUrl');
        return Container(
          padding: const EdgeInsets.all(16),
          child: const Text('Invalid image data', style: TextStyle(color: Colors.red)),
        );
      }
      
      final base64Content = dataUrl.substring(base64Start + 7);
      final imageBytes = base64Decode(base64Content);
      
      print('🖼️ Creating native image widget $imageNumber (${imageBytes.length} bytes)');
      
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Image $imageNumber',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.blue,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.memory(
                imageBytes,
                fit: BoxFit.contain,
                width: double.infinity,
                errorBuilder: (context, error, stackTrace) {
                  print('🖼️ Error loading image: $error');
                  return Container(
                    padding: const EdgeInsets.all(20),
                    color: Colors.red.withOpacity(0.1),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.broken_image, color: Colors.red),
                        SizedBox(width: 8),
                        Text('Failed to load image', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      print('🖼️ Error building native image: $e');
      return Container(
        padding: const EdgeInsets.all(16),
        child: Text('Error loading image: $e', style: const TextStyle(color: Colors.red)),
      );
    }
  }

  // Build WebView content with fallback to HTML widget
  Widget _buildWebViewContent(String content) {
    try {
      // Use HtmlWidget which handles the content better than WebView for inline images
      return Container(
        constraints: const BoxConstraints(minHeight: 200),
        child: HtmlWidget(
          content,
          textStyle: const TextStyle(fontSize: 14, height: 1.5),
          customStylesBuilder: (element) {
            if (element.localName == 'body') {
              return {
                'font-family': '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
                'line-height': '1.6',
                'margin': '0',
                'padding': '16px',
                'color': '#333',
                'background-color': '#fff',
              };
            }
            if (element.localName == 'img') {
              return {
                'max-width': '100%',
                'height': 'auto',
              };
            }
            if (element.localName == 'table') {
              return {
                'width': '100%',
                'border-collapse': 'collapse',
              };
            }
            if (element.localName == 'td' || element.localName == 'th') {
              return {
                'padding': '8px',
                'text-align': 'left',
              };
            }
            return null;
          },
        ),
      );
    } catch (e) {
      print('HtmlWidget error, falling back to plain text: $e');
      // Final fallback to plain text
      return Container(
        constraints: const BoxConstraints(minHeight: 200),
        child: SelectableText(
          _htmlToPlainText(content),
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
      );
    }
  }
}
