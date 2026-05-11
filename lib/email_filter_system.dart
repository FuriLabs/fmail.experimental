// Email Filtering System for Furimail
// Provides account filtering and IMAP folder management

import 'dart:convert';
import 'package:flutter/material.dart';
import 'main.dart';

class AccountFolderPair {
  final String accountId;
  final String folderPath;

  const AccountFolderPair({required this.accountId, required this.folderPath});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountFolderPair &&
          runtimeType == other.runtimeType &&
          accountId == other.accountId &&
          folderPath == other.folderPath;

  @override
  int get hashCode => accountId.hashCode ^ folderPath.hashCode;

  @override
  String toString() => '$accountId:$folderPath';
}

class EmailFilter {
  final Set<String> enabledAccounts;
  final Set<AccountFolderPair> enabledAccountFolders;
  final String searchQuery;

  const EmailFilter({
    required this.enabledAccounts,
    required this.enabledAccountFolders,
    this.searchQuery = '',
  });

  EmailFilter copyWith({
    Set<String>? enabledAccounts,
    Set<AccountFolderPair>? enabledAccountFolders,
    String? searchQuery,
  }) {
    return EmailFilter(
      enabledAccounts: enabledAccounts ?? this.enabledAccounts,
      enabledAccountFolders: enabledAccountFolders ?? this.enabledAccountFolders,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }

  // Check if any filters are active (beyond the default "show all accounts, all folders" state)
  bool get hasActiveFilters {
    // If there's a search query, filters are active
    if (searchQuery.isNotEmpty) return true;
    
    // If specific account-folder pairs are enabled, filters are active
    if (enabledAccountFolders.isNotEmpty) return true;
    
    // At this point, we have all accounts, all folders, no search
    // This is considered the "default" state, so no active filters
    return false;
  }

  // Generate SQL WHERE clause based on active filters
  String generateWhereClause() {
    final List<String> conditions = [];
    
    // Account filtering - must be enabled first
    if (enabledAccounts.isEmpty) {
      conditions.add('1 = 0');
      return conditions.join(' AND ');
    }
    
    // Add account filter
    final accountList = enabledAccounts.map((acc) => "'$acc'").join(', ');
    conditions.add('accountId IN ($accountList)');
    
    // Folder filtering - if specific account-folder pairs are enabled, filter by them
    // If no specific pairs are specified (enabledAccountFolders is empty), show ALL folders for enabled accounts
    if (enabledAccountFolders.isNotEmpty) {
      final List<String> accountFolderConditions = [];
      final List<String> specialFolders = ['Trash', 'Deleted Items', 'Sent', 'Drafts'];
      bool hasSpecialFolders = false;
      
      for (final pair in enabledAccountFolders) {
        accountFolderConditions.add("(accountId = '${pair.accountId}' AND folderPath = '${pair.folderPath}')");
        if (specialFolders.any((folder) => folder.toLowerCase() == pair.folderPath.toLowerCase())) {
          hasSpecialFolders = true;
        }
      }
      
      // Base condition for thread parent - but allow all emails in special folders
      if (hasSpecialFolders) {
        // For special folders (Trash, Sent, etc.), show all emails, not just thread parents
        final folderCondition = '(${accountFolderConditions.join(' OR ')})';
        conditions.add(folderCondition);
      } else {
        // For regular folders (INBOX), only show thread parents
        conditions.add('threadParentId = messageId');
        final folderCondition = '(${accountFolderConditions.join(' OR ')})';
        conditions.add(folderCondition);
      }
      
    } else {
      // No specific folder pairs selected - show ALL folders for enabled accounts
      // Only show thread parents (main email list view)
      conditions.add('threadParentId = messageId');
    }
    
    // Search query - use placeholder for parameterized query
    if (searchQuery.isNotEmpty) {
      conditions.add('(subject LIKE ? OR sender LIKE ? OR content LIKE ?)');
    }
    
    final finalClause = conditions.join(' AND ');
    return finalClause;
  }

  List<String> generateWhereArgs() {
    final List<String> args = [];
    
    // Add search arguments if search query is present
    if (searchQuery.isNotEmpty) {
      final searchPattern = '%$searchQuery%';
      args.addAll([searchPattern, searchPattern, searchPattern]);
    }
    
    return args;
  }
}

class FilterManager {
  static FilterManager? _instance;
  static FilterManager get instance => _instance ??= FilterManager._();
  FilterManager._();

  EmailFilter _currentFilter = const EmailFilter(
    enabledAccounts: {},
    enabledAccountFolders: {},
  );

  EmailFilter get currentFilter => _currentFilter;

  final ValueNotifier<EmailFilter> filterNotifier = ValueNotifier(
    const EmailFilter(
      enabledAccounts: {},
      enabledAccountFolders: {},
    ),
  );

  // Add a notifier for when email counts should be refreshed
  final ValueNotifier<DateTime> countsRefreshNotifier = ValueNotifier(DateTime.now());

  // Method to trigger email count refresh
  void refreshEmailCounts() {
    countsRefreshNotifier.value = DateTime.now();
    print('DEBUG: Triggered email counts refresh at ${countsRefreshNotifier.value}');
  }

  // Initialize filter with all available accounts
  Future<void> initializeWithAllOptions(List<String> accountUsernames, List<EmailAccount> accounts) async {
    // Start with all accounts enabled and no folder restrictions
    // This shows all emails from all folders for all accounts by default
    
    final initialFilter = EmailFilter(
      enabledAccounts: Set<String>.from(accountUsernames),
      enabledAccountFolders: const {}, // Start with no folder restrictions - show all folders
      searchQuery: '',
    );
    
    // Try to restore previous folder selections
    final restoredFilter = await _restoreFolderSelections(initialFilter);
    
    _currentFilter = restoredFilter;
    filterNotifier.value = restoredFilter;
  }

  void updateFilter(EmailFilter newFilter) {
    _currentFilter = newFilter;
    filterNotifier.value = newFilter;
    
    // Save folder selections to persistent storage
    _saveFolderSelections(newFilter);
  }

  void clearFilter() {
    // Reset to show all accounts and all folders with no search query
    final allAccounts = Set<String>.from(_currentFilter.enabledAccounts);
    
    // If no accounts are currently enabled, we can't determine what accounts to show
    // In this case, keep the current state (don't clear anything)
    if (allAccounts.isEmpty) {
      return;
    }
    
    final clearedFilter = EmailFilter(
      enabledAccounts: allAccounts, // Keep all current accounts
      enabledAccountFolders: const {}, // Clear folder restrictions - show all folders
      searchQuery: '', // Clear search
    );
    updateFilter(clearedFilter);
  }

  // Save folder selections to database
  Future<void> _saveFolderSelections(EmailFilter filter) async {
    try {
      final folderSelections = filter.enabledAccountFolders.map((folder) => 
        '${folder.accountId}:${folder.folderPath}'
      ).toList();
      
      final selectionsJson = jsonEncode(folderSelections);
      await DatabaseHelper.instance.setSetting('folder_selections', selectionsJson);
      print('DEBUG: Saved folder selections: $selectionsJson');
    } catch (e) {
      print('Warning: Failed to save folder selections: $e');
    }
  }

  // Restore folder selections from database
  Future<EmailFilter> _restoreFolderSelections(EmailFilter baseFilter) async {
    try {
      final selectionsJson = await DatabaseHelper.instance.getSetting('folder_selections');
      if (selectionsJson == null || selectionsJson.isEmpty) {
        return baseFilter;
      }
      
      final List<dynamic> folderList = jsonDecode(selectionsJson);
      final Set<AccountFolderPair> restoredFolders = {};
      
      for (final folderString in folderList) {
        if (folderString is String && folderString.contains(':')) {
          final parts = folderString.split(':');
          if (parts.length == 2) {
            restoredFolders.add(AccountFolderPair(
              accountId: parts[0],
              folderPath: parts[1],
            ));
          }
        }
      }
      
      print('DEBUG: Restored folder selections: $restoredFolders');
      
      return EmailFilter(
        enabledAccounts: baseFilter.enabledAccounts,
        enabledAccountFolders: restoredFolders,
        searchQuery: baseFilter.searchQuery,
      );
    } catch (e) {
      print('Warning: Failed to restore folder selections: $e');
      return baseFilter;
    }
  }

  // Get folders grouped by account
  Future<Map<String, List<String>>> getFoldersGroupedByAccount() async {
    final Map<String, List<String>> foldersByAccount = {};
    
    try {
      final db = await DatabaseHelper.instance.database;
      
      // First, try to get folders from imap_folders table if it exists
      final tables = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='imap_folders'");
      
      if (tables.isNotEmpty) {
        // imap_folders table exists, use it
        final result = await db.rawQuery('''
          SELECT accountId, folderPath 
          FROM imap_folders 
          WHERE isSelectable = 1
          ORDER BY accountId, folderPath ASC
        ''');
        
        for (final row in result) {
          final accountId = row['accountId'] as String;
          final folderPath = row['folderPath'] as String;
          
          if (!foldersByAccount.containsKey(accountId)) {
            foldersByAccount[accountId] = [];
          }
          foldersByAccount[accountId]!.add(folderPath);
        }
        
        print('DEBUG: Folders from imap_folders table: $foldersByAccount');
      } else {
        print('DEBUG: imap_folders table does not exist, using fallback');
      }
      
      // If no folders found, try fallback to emails table
      if (foldersByAccount.isEmpty) {
        final result = await db.rawQuery('''
          SELECT DISTINCT accountId, folderPath 
          FROM emails 
          WHERE folderPath IS NOT NULL AND folderPath != ""
          ORDER BY accountId, folderPath ASC
        ''');
        
        for (final row in result) {
          final accountId = row['accountId'] as String;
          final folderPath = row['folderPath'] as String;
          
          if (!foldersByAccount.containsKey(accountId)) {
            foldersByAccount[accountId] = [];
          }
          if (!foldersByAccount[accountId]!.contains(folderPath)) {
            foldersByAccount[accountId]!.add(folderPath);
          }
        }
        
        print('DEBUG: Folders from emails table: $foldersByAccount');
      }
      
      // Ensure all accounts have standard folders, adding missing ones
      final accounts = await db.rawQuery('SELECT username FROM accounts');
      final standardFolders = ['INBOX', 'Sent', 'Drafts', 'Trash'];
      
      for (final account in accounts) {
        final username = account['username'] as String;
        
        if (!foldersByAccount.containsKey(username)) {
          // No folders found for this account, add all standard folders
          foldersByAccount[username] = [...standardFolders];
          print('DEBUG: Added default folders for account $username');
        } else {
          // Account has some folders, ensure all standard folders are present
          for (final folder in standardFolders) {
            if (!foldersByAccount[username]!.contains(folder)) {
              foldersByAccount[username]!.add(folder);
            }
          }
          // Sort folders with INBOX first
          foldersByAccount[username]!.sort((a, b) {
            if (a == 'INBOX') return -1;
            if (b == 'INBOX') return 1;
            return a.compareTo(b);
          });
          print('DEBUG: Ensured standard folders for account $username: ${foldersByAccount[username]}');
        }
      }
      
      print('DEBUG: Final folders by account: $foldersByAccount');
      
    } catch (e) {
      print('DEBUG: Error getting folders grouped by account: $e');
      // Return safe fallback
      return {};
    }
    
    return foldersByAccount;
  }
}

class FilterDrawer extends StatefulWidget {
  final List<EmailAccount> accounts;
  final VoidCallback onFilterChanged;

  const FilterDrawer({
    super.key,
    required this.accounts,
    required this.onFilterChanged,
  });

  @override
  State<FilterDrawer> createState() => _FilterDrawerState();
}

class _FilterDrawerState extends State<FilterDrawer> {
  EmailFilter _currentFilter = const EmailFilter(
    enabledAccounts: {},
    enabledAccountFolders: {},
  );
  
  Map<String, List<String>> _accountFolders = {};
  // Cache for email counts per account-folder
  Map<String, int> _emailCounts = {};
  
  // Add these caches to prevent unnecessary rebuilds
  bool _isLoadingFolders = false;
  bool _isLoadingCounts = false;
  DateTime? _lastCountsUpdate;
  
  // Cache the Future builders to prevent flicker
  Map<String, Future<int>> _countFutures = {};
  Map<String, Future<int>> _unreadFutures = {};

  @override
  void initState() {
    super.initState();
    _currentFilter = FilterManager.instance.currentFilter;

    // Listen for count refresh notifications
    FilterManager.instance.countsRefreshNotifier.addListener(_onCountsRefreshRequested);

    // Load IMAP folders from database cache - only once
    _loadImapFoldersOnce();
  }

  @override
  void dispose() {
    // Remove the listener to prevent memory leaks
    FilterManager.instance.countsRefreshNotifier.removeListener(_onCountsRefreshRequested);
    super.dispose();
  }

  // Handle count refresh requests
  void _onCountsRefreshRequested() {
    print('DEBUG: Received count refresh request, forcing reload...');
    // Force reload of email counts by clearing the cache
    _lastCountsUpdate = null;
    _loadEmailCounts().then((_) {
      if (mounted) {
        setState(() {
          // Trigger UI rebuild with new counts
        });
      }
    });
  }

  // Load folders and counts only once, not every time the drawer opens
  void _loadImapFoldersOnce() {
    if (_isLoadingFolders) return;
    _isLoadingFolders = true;
    
    print('DEBUG: Loading IMAP folders once from database...');
    
    // Load email counts first (only if not loaded recently)
    final now = DateTime.now();
    final shouldRefreshCounts = _lastCountsUpdate == null || 
        now.difference(_lastCountsUpdate!).inMinutes > 5; // Refresh every 5 minutes
    
    Future<void> loadCounts = shouldRefreshCounts ? _loadEmailCounts() : Future.value();
    
    loadCounts.then((_) {
      return FilterManager.instance.getFoldersGroupedByAccount();
    }).then((accountFoldersMap) {
      print('DEBUG: Loaded folders by account: $accountFoldersMap');
      
      if (mounted) {
        setState(() {
          _accountFolders = accountFoldersMap;
          _isLoadingFolders = false;
        });
        
        // Re-initialize filter after folders are loaded
        _initializeFilterWithAllOptions();
      }
    }).catchError((e) {
      print('DEBUG: Error loading IMAP folders: $e');
      if (mounted) {
        setState(() {
          _isLoadingFolders = false;
          // Ensure each account has at least default folders
          _accountFolders = {};
          for (final account in widget.accounts) {
            _accountFolders[account.username] = ['INBOX', 'Sent', 'Drafts', 'Trash'];
          }
        });
        
        // Re-initialize filter after folders are loaded
        _initializeFilterWithAllOptions();
      }
    });
  }

  // Load all email counts for efficiency
  Future<void> _loadEmailCounts() async {
    if (_isLoadingCounts) return;
    _isLoadingCounts = true;
    
    try {
      final db = await DatabaseHelper.instance.database;
      
      // Define special folders that show all emails (not just thread parents)
      final specialFolders = ['Trash', 'Deleted Items', 'Sent', 'Drafts'];
      
      // Load total counts with the same logic as display:
      // - Special folders: count all emails
      // - Regular folders: count only thread parents
      final totalResult = await db.rawQuery('''
        SELECT 
          accountId, 
          folderPath, 
          COUNT(*) as total_count,
          COUNT(CASE WHEN threadParentId = messageId THEN 1 END) as parent_count
        FROM emails 
        GROUP BY accountId, folderPath
      ''');
      
      // Load unread counts with the same logic
      final unreadResult = await db.rawQuery('''
        SELECT 
          accountId, 
          folderPath, 
          COUNT(*) as total_count,
          COUNT(CASE WHEN threadParentId = messageId THEN 1 END) as parent_count
        FROM emails 
        WHERE isRead = 0
        GROUP BY accountId, folderPath
      ''');
      
      _emailCounts.clear();
      _countFutures.clear();
      _unreadFutures.clear();
      
      // Store total counts (use appropriate count based on folder type)
      for (final row in totalResult) {
        final accountId = row['accountId'] as String;
        final folderPath = row['folderPath'] as String;
        final totalCount = row['total_count'] as int;
        final parentCount = row['parent_count'] as int;
        
        // Use total count for special folders, parent count for regular folders
        final isSpecialFolder = specialFolders.any((folder) => 
          folder.toLowerCase() == folderPath.toLowerCase());
        final displayCount = isSpecialFolder ? totalCount : parentCount;
        
        _emailCounts['$accountId:$folderPath'] = displayCount;
        print('DEBUG: $accountId:$folderPath - Total: $totalCount, Parents: $parentCount, Display: $displayCount (Special: $isSpecialFolder)');
      }
      
      // Store unread counts (use appropriate count based on folder type)
      for (final row in unreadResult) {
        final accountId = row['accountId'] as String;
        final folderPath = row['folderPath'] as String;
        final totalCount = row['total_count'] as int;
        final parentCount = row['parent_count'] as int;
        
        // Use total count for special folders, parent count for regular folders
        final isSpecialFolder = specialFolders.any((folder) => 
          folder.toLowerCase() == folderPath.toLowerCase());
        final displayCount = isSpecialFolder ? totalCount : parentCount;
        
        _emailCounts['unread_$accountId:$folderPath'] = displayCount;
      }
      
      _lastCountsUpdate = DateTime.now();
      print('Loaded email counts: $_emailCounts');
    } catch (e) {
      print('Error loading email counts: $e');
    } finally {
      _isLoadingCounts = false;
    }
  }

  void _initializeFilterWithAllOptions() {
    if (widget.accounts.isNotEmpty) {
      final allAccountUsernames = widget.accounts.map((acc) => acc.username).toSet();
      
      // Check if this is the first initialization (no accounts enabled)
      if (_currentFilter.enabledAccounts.isEmpty) {
        // First initialization: enable all accounts
        final newFilter = EmailFilter(
          enabledAccounts: allAccountUsernames,
          enabledAccountFolders: const {}, // Empty set means all folders
          searchQuery: _currentFilter.searchQuery,
        );
        
        setState(() {
          _currentFilter = newFilter;
        });
        
        // Update the global filter manager
        WidgetsBinding.instance.addPostFrameCallback((_) {
          FilterManager.instance.updateFilter(_currentFilter);
        });
        print('DEBUG: Initialized filter: accounts=$allAccountUsernames, folders=${newFilter.enabledAccountFolders}');
      }
    }
  }

  void _updateFilter() {
    FilterManager.instance.updateFilter(_currentFilter);
    widget.onFilterChanged();
  }

  // Build email count badge without FutureBuilder to prevent flicker
  Widget _buildEmailCountBadge(String accountId, String folderPath) {
    final key = '$accountId:$folderPath';
    final count = _emailCounts[key] ?? 0;
    
    if (count == 0) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.only(left: 4.0),
      padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 2.0),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count',
        style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
      ),
    );
  }

  // Build unread badge without FutureBuilder to prevent flicker
  Widget _buildUnreadBadge(String accountId, String folderPath) {
    final key = 'unread_$accountId:$folderPath';
    final unreadCount = _emailCounts[key] ?? 0;
    
    if (unreadCount == 0) return const SizedBox.shrink();
    
    return Container(
      margin: const EdgeInsets.only(left: 4.0),
      padding: const EdgeInsets.all(4.0),
      decoration: const BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
      ),
      child: Text(
        '$unreadCount',
        style: const TextStyle(
          fontSize: 9, 
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          // Header with dark theme colors
          Container(
            height: 90,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade800,
            ),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Email Filters',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Filter by account and folders',
                  style: TextStyle(
                    color: Colors.grey.shade300,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Accounts (with nested IMAP folders)
                  _buildAccountsSection(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Accounts & Folders',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              onPressed: () {
                // Force refresh by clearing cache and reloading
                setState(() {
                  _emailCounts.clear();
                  _countFutures.clear();
                  _unreadFutures.clear();
                  _lastCountsUpdate = null;
                  _isLoadingFolders = false;
                  _isLoadingCounts = false;
                });
                _loadImapFoldersOnce();
              },
              tooltip: 'Refresh folders and counts',
            ),
            TextButton(
              onPressed: _toggleAllFolders,
              child: Text(_areAllFoldersSelected() ? 'Deselect All' : 'Select All'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...widget.accounts.map((account) => _buildAccountWithFolders(account)),
      ],
    );
  }

  Widget _buildAccountWithFolders(EmailAccount account) {
    final accountFolders = _accountFolders[account.username] ?? [];
    
    return Column(
      children: [
        // Account header (no checkbox)
        ListTile(
          title: Row(
            children: [
              CircleAvatar(
                radius: 10,
                backgroundColor: account.color,
                child: Text(
                  account.display,
                  style: const TextStyle(color: Colors.white, fontSize: 8),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      account.name,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    Text(
                      account.username,
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
            ],
          ),
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        
        // IMAP folders for this account
        if (accountFolders.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 8.0, bottom: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...accountFolders.map((folder) => Padding(
                  padding: const EdgeInsets.only(left: 4.0),
                  child: CheckboxListTile(
                    title: Row(
                      children: [
                        const Icon(Icons.folder, size: 14, color: Colors.grey),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            folder,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Email count badge (cached, no FutureBuilder)
                        _buildEmailCountBadge(account.username, folder),
                        // Unread badge (cached, no FutureBuilder)
                        _buildUnreadBadge(account.username, folder),
                      ],
                    ),
                    value: _currentFilter.enabledAccountFolders.contains(
                      AccountFolderPair(accountId: account.username, folderPath: folder)
                    ),
                    onChanged: (enabled) {
                      setState(() {
                        final newAccountFolders = Set<AccountFolderPair>.from(_currentFilter.enabledAccountFolders);
                        final pair = AccountFolderPair(accountId: account.username, folderPath: folder);
                        if (enabled == true) {
                          newAccountFolders.add(pair);
                        } else {
                          newAccountFolders.remove(pair);
                        }
                        _currentFilter = _currentFilter.copyWith(enabledAccountFolders: newAccountFolders);
                      });
                      _updateFilter();
                    },
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                )),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 32.0, bottom: 8.0),
            child: Text(
              'No folders found. Folders will appear after email sync.',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
      ],
    );
  }

  bool _areAllFoldersSelected() {
    return _currentFilter.enabledAccountFolders.isEmpty; // When empty, all folders are shown
  }

  void _toggleAllFolders() {
    setState(() {
      if (_areAllFoldersSelected()) {
        // Currently showing all - select only INBOX folders for each account
        final inboxOnly = <AccountFolderPair>{};
        for (final account in widget.accounts) {
          inboxOnly.add(AccountFolderPair(accountId: account.username, folderPath: 'INBOX'));
        }
        _currentFilter = _currentFilter.copyWith(
          enabledAccountFolders: inboxOnly,
        );
      } else {
        // Clear all folder selections to show all folders
        _currentFilter = _currentFilter.copyWith(
          enabledAccountFolders: {},
        );
      }
    });
    _updateFilter();
  }
}
