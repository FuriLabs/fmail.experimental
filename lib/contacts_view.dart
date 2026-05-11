import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart'; // For EmailAccount and DatabaseHelper

class ContactsView extends StatefulWidget {
  final List<EmailAccount> accounts;
  
  const ContactsView({
    Key? key,
    required this.accounts,
  }) : super(key: key);

  @override
  _ContactsViewState createState() => _ContactsViewState();
}

class _ContactsViewState extends State<ContactsView> {
  List<Map<String, dynamic>> _contacts = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  Map<String, int> _emailCounts = {}; // Email count per contact email
  Map<String, Color> _accountColors = {}; // Account colors by email address
  Timer? _searchDebounceTimer; // Debounce timer for search

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _searchDebounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    setState(() {
      _isLoading = true;
    });

    try {
      print('DEBUG: Loading contacts with search query: "$_searchQuery"');
      final db = await DatabaseHelper.instance.database;
      
      // Check if contacts table exists first
      final tableExists = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='contacts'"
      );
      print('DEBUG: Contacts table exists: ${tableExists.isNotEmpty}');
      
      if (tableExists.isEmpty) {
        print('WARNING: Contacts table does not exist, creating it now...');
        
        // Create the contacts table manually
        await db.execute('''
          CREATE TABLE IF NOT EXISTS contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT NOT NULL,
            accountId TEXT NOT NULL,
            workPhone TEXT,
            personalPhone TEXT,
            workAddress TEXT,
            personalAddress TEXT,
            company TEXT,
            jobTitle TEXT,
            notes TEXT,
            frequency INTEGER DEFAULT 1,
            lastUsed INTEGER DEFAULT 0,
            isManual INTEGER DEFAULT 0,
            UNIQUE(email, accountId)
          )
        ''');
        
        // Create indexes
        await db.execute('CREATE INDEX IF NOT EXISTS idx_contact_email ON contacts (email)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_contact_name ON contacts (name)');
        
        print('DEBUG: Contacts table created successfully');
        
        setState(() {
          _contacts = [];
          _isLoading = false;
        });
        return;
      }
      
      String whereClause = '1=1'; // Start with always true condition
      List<dynamic> whereArgs = [];

      // Add search filter if query is not empty
      if (_searchQuery.isNotEmpty) {
        whereClause += ' AND (name LIKE ? OR email LIKE ? OR workPhone LIKE ? OR personalPhone LIKE ?)';
        final searchPattern = '%$_searchQuery%';
        whereArgs.addAll([searchPattern, searchPattern, searchPattern, searchPattern]);
      }

      print('DEBUG: Query where clause: $whereClause');
      print('DEBUG: Query args: $whereArgs');

      final contacts = await db.query(
        'contacts',
        where: whereClause,
        whereArgs: whereArgs.isNotEmpty ? whereArgs : null,
        orderBy: 'name ASC',
      );

      print('DEBUG: Loaded ${contacts.length} contacts from database');

      setState(() {
        _contacts = contacts;
        _isLoading = false;
      });

      // Load email counts and account colors after contacts are loaded
      await _loadAccountColors();
      await _loadEmailCounts();
      
      // Refresh the UI
      setState(() {});
    } catch (e, stackTrace) {
      print('ERROR: Failed to load contacts: $e');
      print('STACK TRACE: $stackTrace');
      setState(() {
        _isLoading = false;
      });
      
      // Show error to user
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading contacts: ${e.toString()}'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _loadEmailCounts() async {
    try {
      final db = await DatabaseHelper.instance.database;

      // Collect all contact emails for batch query
      final contactEmails = _contacts
          .map((c) => c['email'] as String?)
          .where((e) => e != null && e.isNotEmpty)
          .toSet()
          .toList();

      if (contactEmails.isEmpty) {
        setState(() {
          _emailCounts = {};
        });
        return;
      }

      // Build single batch query with GROUP BY instead of N+1 queries
      final placeholders = List.filled(contactEmails.length, '?').join(',');
      final result = await db.rawQuery(
        'SELECT senderEmail, COUNT(*) as count FROM emails WHERE senderEmail IN ($placeholders) GROUP BY senderEmail',
        contactEmails,
      );

      // Convert results to map
      Map<String, int> counts = {};
      for (final row in result) {
        final email = row['senderEmail'] as String;
        final count = row['count'] as int;
        counts[email] = count;
      }

      setState(() {
        _emailCounts = counts;
      });
    } catch (e) {
      print('ERROR: Failed to load email counts: $e');
    }
  }

  Future<void> _loadAccountColors() async {
    try {
      // Map account emails to their colors
      for (var account in widget.accounts) {
        _accountColors[account.username] = account.color;
      }
    } catch (e) {
      print('ERROR: Failed to load account colors: $e');
    }
  }

  Color _getContactColor(Map<String, dynamic> contact) {
    final accountId = contact['accountId'] as String? ?? '';
    return _accountColors[accountId] ?? Colors.blue;
  }

  Future<void> _addContact() async {
    final result = await _showContactDialog();
    if (result != null) {
      try {
        print('DEBUG: Attempting to add contact with data: $result');
        final db = await DatabaseHelper.instance.database;
        
        // Check if contacts table exists
        final tableExists = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='contacts'"
        );
        print('DEBUG: Contacts table exists: ${tableExists.isNotEmpty}');
        
        if (tableExists.isEmpty) {
          print('ERROR: Contacts table does not exist in database');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Contacts table not found. Please restart the app.'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        
        // Check what columns actually exist in the contacts table
        final tableInfo = await db.rawQuery("PRAGMA table_info(contacts)");
        print('DEBUG: Contacts table structure: $tableInfo');
        final columnNames = tableInfo.map((col) => col['name']).toList();
        print('DEBUG: Available columns: $columnNames');
        
        final insertId = await db.insert('contacts', result);
        print('DEBUG: Contact inserted successfully with ID: $insertId');
        
        await _loadContacts();
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact added successfully'),
            backgroundColor: Colors.green,
          ),
        );
      } catch (e, stackTrace) {
        print('ERROR: Failed to add contact: $e');
        print('STACK TRACE: $stackTrace');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error adding contact: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _editContact(Map<String, dynamic> contact) async {
    final result = await _showContactDialog(contact: contact);
    if (result != null) {
      try {
        final db = await DatabaseHelper.instance.database;
        await db.update(
          'contacts',
          result,
          where: 'id = ?',
          whereArgs: [contact['id']],
        );
        await _loadContacts();
        
        // Force reload account colors to ensure color updates
        await _loadAccountColors();
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact updated successfully'),
            backgroundColor: Colors.green,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating contact: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteContact(Map<String, dynamic> contact) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Contact'),
        content: Text('Are you sure you want to delete ${contact['name']}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        final db = await DatabaseHelper.instance.database;
        await db.delete(
          'contacts',
          where: 'id = ?',
          whereArgs: [contact['id']],
        );
        await _loadContacts();
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact deleted successfully'),
            backgroundColor: Colors.orange,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting contact: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _showContactDialog({Map<String, dynamic>? contact}) async {
    final formKey = GlobalKey<FormState>();
    final isEditing = contact != null;
    
    // Form controllers - using correct column names
    final nameController = TextEditingController(text: contact?['name'] ?? '');
    final emailController = TextEditingController(text: contact?['email'] ?? '');
    final workPhoneController = TextEditingController(text: contact?['workPhone'] ?? '');
    final personalPhoneController = TextEditingController(text: contact?['personalPhone'] ?? '');
    final workAddressController = TextEditingController(text: contact?['workAddress'] ?? '');
    final personalAddressController = TextEditingController(text: contact?['personalAddress'] ?? '');
    final companyController = TextEditingController(text: contact?['company'] ?? '');
    final jobTitleController = TextEditingController(text: contact?['jobTitle'] ?? '');
    final notesController = TextEditingController(text: contact?['notes'] ?? '');
    
    // Selected account
    String selectedAccountId = contact?['accountId'] ?? (widget.accounts.isNotEmpty ? widget.accounts.first.username : '');

    return await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEditing ? 'Edit Contact' : 'Add Contact'),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Account selection
                DropdownButtonFormField<String>(
                  value: selectedAccountId.isNotEmpty ? selectedAccountId : null,
                  decoration: const InputDecoration(labelText: 'Account'),
                  items: widget.accounts.map((account) => DropdownMenuItem(
                    value: account.username,
                    child: Text(account.display.isNotEmpty ? account.display : account.username),
                  )).toList(),
                  onChanged: (value) => selectedAccountId = value ?? '',
                  validator: (value) => value?.isEmpty == true ? 'Please select an account' : null,
                ),
                const SizedBox(height: 16),
                
                // Name field (single field now)
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Full Name *'),
                  validator: (value) => value?.isEmpty == true ? 'Please enter name' : null,
                ),
                const SizedBox(height: 16),
                
                // Email
                TextFormField(
                  controller: emailController,
                  decoration: const InputDecoration(labelText: 'Email *'),
                  keyboardType: TextInputType.emailAddress,
                  validator: (value) {
                    if (value?.isEmpty == true) return 'Please enter email';
                    if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value!)) {
                      return 'Please enter a valid email';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                
                // Company
                TextFormField(
                  controller: companyController,
                  decoration: const InputDecoration(labelText: 'Company'),
                ),
                const SizedBox(height: 16),
                
                // Job Title
                TextFormField(
                  controller: jobTitleController,
                  decoration: const InputDecoration(labelText: 'Job Title'),
                ),
                const SizedBox(height: 16),
                
                // Phone numbers (using correct column names)
                TextFormField(
                  controller: workPhoneController,
                  decoration: const InputDecoration(labelText: 'Work Phone'),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),
                
                TextFormField(
                  controller: personalPhoneController,
                  decoration: const InputDecoration(labelText: 'Personal Phone'),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),
                
                // Addresses
                TextFormField(
                  controller: workAddressController,
                  decoration: const InputDecoration(labelText: 'Work Address'),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                
                TextFormField(
                  controller: personalAddressController,
                  decoration: const InputDecoration(labelText: 'Personal Address'),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                
                // Notes
                TextFormField(
                  controller: notesController,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: 3,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                final contactData = {
                  'accountId': selectedAccountId,
                  'name': nameController.text.trim(),
                  'email': emailController.text.trim(),
                  'company': companyController.text.trim(),
                  'jobTitle': jobTitleController.text.trim(),
                  'workPhone': workPhoneController.text.trim(),
                  'personalPhone': personalPhoneController.text.trim(),
                  'workAddress': workAddressController.text.trim(),
                  'personalAddress': personalAddressController.text.trim(),
                  'notes': notesController.text.trim(),
                  'lastUsed': DateTime.now().millisecondsSinceEpoch,
                  'isManual': 1, // Mark as manually added
                };
                Navigator.of(context).pop(contactData);
              }
            },
            child: Text(isEditing ? 'Update' : 'Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search contacts...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                          _loadContacts();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
                // Debounce search to avoid excessive database queries
                _searchDebounceTimer?.cancel();
                _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
                  _loadContacts();
                });
              },
            ),
          ),
          
          // Contacts list
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _contacts.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.people_outline, size: 64, color: Colors.grey),
                            SizedBox(height: 16),
                            Text(
                              'No contacts found',
                              style: TextStyle(fontSize: 18, color: Colors.grey),
                            ),
                            Text(
                              'Tap + to add your first contact',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _contacts.length,
                        itemBuilder: (context, index) {
                          final contact = _contacts[index];
                          final name = contact['name'] ?? '';
                          final email = contact['email'] ?? '';
                          final company = contact['company'] ?? '';
                          
                          // Extract initials from name
                          String initials = '';
                          final nameParts = name.split(' ');
                          if (nameParts.isNotEmpty) {
                            initials = nameParts.first.isNotEmpty ? nameParts.first[0].toUpperCase() : '';
                            if (nameParts.length > 1 && nameParts.last.isNotEmpty) {
                              initials += nameParts.last[0].toUpperCase();
                            }
                          }
                          
                          return Card(
                            margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: _getContactColor(contact),
                                child: Text(
                                  initials.isNotEmpty ? initials : '?',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                ),
                              ),
                              title: Text(name.isNotEmpty ? name : 'No Name'),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (email.isNotEmpty) Text(email),
                                  if (company.isNotEmpty) Text(company, style: TextStyle(color: Colors.grey[600])),
                                  if (_emailCounts.containsKey(email) && _emailCounts[email]! > 0)
                                    Text(
                                      '${_emailCounts[email]} email${_emailCounts[email] == 1 ? '' : 's'}',
                                      style: TextStyle(color: Colors.grey[500], fontSize: 12),
                                    ),
                                ],
                              ),
                              onTap: () => _editContact(contact),
                              trailing: PopupMenuButton<String>(
                                onSelected: (value) {
                                  switch (value) {
                                    case 'edit':
                                      _editContact(contact);
                                      break;
                                    case 'delete':
                                      _deleteContact(contact);
                                      break;
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit),
                                        SizedBox(width: 8),
                                        Text('Edit'),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete, color: Colors.red),
                                        SizedBox(width: 8),
                                        Text('Delete', style: TextStyle(color: Colors.red)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addContact,
        tooltip: 'Add Contact',
        child: const Icon(Icons.add),
      ),
    );
  }
}
