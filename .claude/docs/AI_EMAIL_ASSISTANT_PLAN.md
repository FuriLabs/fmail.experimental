# AI Email Assistant - Implementation Plan

## Overview

AI-powered email reply assistant for fMail. Manual trigger with copy/paste workflow for safety and review.

## Core Workflow

1. **Email comes in** → User views email in fMail
2. **User clicks ✨ button** → Triggers AI response generation
3. **AI reads email and thread** → Analyzes full conversation context
4. **AI fetches external data** → Order status, FAQs, etc. from configured APIs
5. **AI crafts reply** → Generated response with specific system info
6. **User reviews and copies** → Manual copy/paste into reply (no auto-send)

## Build-Time Toggle (Not Public Yet)

```dart
// lib/config.dart
class FeatureFlags {
  static const bool AI_ASSISTANT_ENABLED = bool.fromEnvironment(
    'AI_ASSISTANT',
    defaultValue: false
  );
}
```

**Usage:**
```bash
# Development with AI enabled
flutter run --dart-define=AI_ASSISTANT=true -d linux

# Production without AI (default)
flutter build linux --release
```

## UI Components

### Email Detail View Button
Add to email detail screen (near reply/forward buttons):

```dart
if (FeatureFlags.AI_ASSISTANT_ENABLED && _isAIEnabledForAccount(email['accountId'])) {
  IconButton(
    icon: Text('✨'),
    tooltip: 'Draft AI Reply',
    onPressed: () => _generateAIReply(email),
  ),
}
```

### AI Reply Dialog
Shows generated draft with:
- Generated reply text (formatted, editable preview)
- **"Copy to Clipboard"** button
- **"Edit & Reply"** button (opens compose screen pre-filled)
- **"Regenerate"** button (try again with same context)
- Loading state while generating

## Settings Configuration

### Account Selection
```json
{
  "ai_enabled_accounts": ["orders@furilabs.com", "support@furilabs.com"],
  "ai_config": {
    "provider": "anthropic",
    "api_key": "stored_in_secure_storage",
    "model": "claude-3-5-sonnet-20241022",
    "max_tokens": 1000
  }
}
```

### Per-Account AI Configuration
```dart
class AIAssistantConfig {
  final String accountId;
  final List<APIEndpoint> endpoints;      // External data sources
  final String systemPrompt;              // Custom instructions
  final Map<String, String> templates;    // Common response patterns
  final String tone;                      // "professional", "friendly", etc.
}

class APIEndpoint {
  final String name;              // "Orders API", "FAQ Database"
  final String url;               // "https://api.example.com/orders/{order_id}"
  final String authToken;         // Stored in flutter_secure_storage
  final String extractionHint;    // "Extract order ID from email body"
}
```

## Context Building for AI

### What Gets Sent to AI:
```dart
Future<String> buildAIContext(String emailThread, String accountId) async {
  var context = "Email thread:\n$emailThread\n\n";

  // 1. Extract structured data (order numbers, tracking IDs, etc.)
  final orderMatch = RegExp(r'#(\d+)').firstMatch(emailThread);
  if (orderMatch != null) {
    final orderData = await fetchOrderStatus(orderMatch.group(1)!);
    context += "Order Status:\n$orderData\n\n";
  }

  // 2. Fetch relevant FAQs based on keywords
  final keywords = extractKeywords(emailThread);
  final faqs = await searchFAQs(keywords);
  context += "Relevant FAQs:\n$faqs\n\n";

  // 3. Add account-specific instructions
  final config = await getAIConfig(accountId);
  context += "Instructions:\n${config.systemPrompt}\n\n";

  return context;
}
```

### Example AI Prompt Structure:
```
System: You are a helpful customer support assistant for FuriLabs.
Use the provided order information and FAQs to craft a professional,
friendly response. Be concise but thorough.

Context:
- Previous email thread: [full conversation]
- Order #12345 Status: Shipped, tracking: ABC123, ETA: Jan 20
- Relevant FAQ: "Shipping typically takes 5-7 business days"

Customer's latest email:
"Hi, when will my order arrive? I haven't received tracking info yet."

Draft a reply:
```

## API Integration Architecture

### External Data Sources
Configure in settings per account:

1. **Orders API**
   - URL: `https://api.furilabs.com/v1/orders/{order_id}`
   - Auth: Bearer token
   - Extraction: Regex for order numbers in email

2. **FAQ Database**
   - URL: `https://api.furilabs.com/v1/faqs/search?q={query}`
   - Keywords extracted from email content
   - Return top 3 relevant FAQs

3. **Tracking API** (optional)
   - URL: `https://api.carrier.com/track/{tracking_number}`
   - Real-time shipping updates

### API Call Flow:
```dart
// 1. Parse email for data points
final orderIds = extractOrderNumbers(emailContent);
final trackingNumbers = extractTrackingNumbers(emailContent);

// 2. Fetch from configured endpoints
final orderData = await Future.wait(
  orderIds.map((id) => fetchOrderStatus(id))
);

final faqResults = await searchFAQs(extractKeywords(emailContent));

// 3. Build context for AI
final context = formatContext(emailThread, orderData, faqResults);

// 4. Call AI API
final aiResponse = await generateReply(context);
```

## Privacy & Security

### Data Handling
- **Email content** → Sent to AI provider (Claude/OpenAI) - never cached
- **API keys** → Stored in `flutter_secure_storage` (already in use)
- **External APIs** → Document what data leaves device in settings
- **Warning in settings**:
  > "AI features send email content to [provider]. Only enable for accounts where this is acceptable."

### Security Checklist
- [ ] Encrypt API keys at rest
- [ ] Use HTTPS for all API calls
- [ ] No logging of email content with AI requests
- [ ] Clear user consent before enabling AI per account
- [ ] Rate limiting to prevent abuse/cost overruns

## Implementation Phases

### Phase 1: MVP (Start Here)
- [ ] Add build-time feature flag
- [ ] Single AI provider (Claude API via Anthropic SDK)
- [ ] ✨ button in email detail view
- [ ] Basic context: email thread only (no external APIs yet)
- [ ] Simple dialog with copy/paste
- [ ] Account selection in settings (which accounts have AI enabled)

### Phase 2: External Integrations
- [ ] Configure API endpoints in settings
- [ ] Order status lookup integration
- [ ] FAQ database search
- [ ] Custom system prompts per account
- [ ] Response templates/examples

### Phase 3: Advanced Features
- [ ] Multiple AI providers (OpenAI, local Ollama)
- [ ] Few-shot learning with examples
- [ ] Usage analytics (% of AI drafts actually used)
- [ ] Cost tracking per account
- [ ] Tone customization (professional/friendly/technical)

## FuriLabs-Specific Example

### orders@furilabs.com Configuration
```dart
AIAssistantConfig(
  accountId: 'orders@furilabs.com',
  systemPrompt: '''
    You are a FuriLabs customer support agent.
    - Always be professional and empathetic
    - Reference specific order details when available
    - Provide tracking info if asked
    - Mention our 30-day return policy when relevant
    - Sign off with "Best regards, FuriLabs Team"
  ''',
  endpoints: [
    APIEndpoint(
      name: 'Orders API',
      url: 'https://api.furilabs.com/orders/{order_id}',
      authToken: 'stored_securely',
      extractionHint: 'Find order numbers with pattern #\\d+',
    ),
    APIEndpoint(
      name: 'FAQ Search',
      url: 'https://api.furilabs.com/faqs/search',
      authToken: 'stored_securely',
      extractionHint: 'Extract keywords: shipping, returns, warranty, etc.',
    ),
  ],
  templates: {
    'shipping_delay': 'We apologize for the delay. Your order #{{ORDER}} is...',
    'tracking_request': 'Your tracking number is {{TRACKING}}. You can track at...',
  },
)
```

### Example Interaction

**Customer Email:**
```
Subject: Where is my FLX1 order?

Hi, I ordered a FuriPhone FLX1 (order #584839) two weeks ago
and haven't received any updates. Can you help?

Thanks,
John
```

**AI Context Built:**
- Email thread: [above]
- Order #584839 status: `{"status": "shipped", "tracking": "1Z999AA1234567890", "eta": "2026-01-20"}`
- FAQ result: "Shipping typically takes 5-7 business days from order date"

**AI Generated Reply:**
```
Hi John,

Thank you for reaching out! I've checked on your order #584839.

Good news - your FuriPhone FLX1 was shipped on January 10th.
Your tracking number is 1Z999AA1234567890, and it's currently
scheduled to arrive by January 20th.

You can track your package here: [tracking link]

If you have any other questions or if the package doesn't arrive
by the expected date, please let us know!

Best regards,
FuriLabs Team
```

**User then reviews, edits if needed, and pastes into reply.**

## Technical Considerations

### 1. Cost Management
- Claude API: ~$3 per million input tokens, ~$15 per million output tokens
- Estimate: ~2000 tokens per email reply = $0.03 per generation
- Add usage limits in settings (e.g., max 100 AI replies/day per account)

### 2. Latency
- Target: <5 seconds for reply generation
- Parallel API calls for order/FAQ lookups
- Show loading indicator with progress

### 3. Error Handling
```dart
try {
  final reply = await generateAIReply(context);
  showReplyDialog(reply);
} catch (e) {
  if (e is NetworkException) {
    showError('Network error. Please check connection.');
  } else if (e is APIRateLimitException) {
    showError('AI service rate limit reached. Try again in a few minutes.');
  } else {
    showError('Failed to generate reply. Please try again.');
  }
}
```

### 4. Testing Strategy
- Unit tests for context building logic
- Mock AI responses for UI testing
- Manual QA: Generate 20+ replies and check for hallucinations
- A/B test: Compare AI drafts vs. manual replies for accuracy

## Open Questions

1. **Which AI provider to start with?**
   - Claude API: Great for long context (emails + FAQs), JSON mode
   - OpenAI: Also solid, more familiar to developers
   - Local (Ollama): Privacy-first but requires local compute

2. **Tone/style per account?**
   - orders@ = professional, empathetic
   - support@ = friendly, technical
   - Different system prompts per account?

3. **Fallback if external APIs fail?**
   - Still generate reply but note "Unable to fetch order status"
   - Or fail entirely and ask user to try again?

4. **How to validate AI isn't hallucinating order details?**
   - Clearly mark what data came from APIs vs. AI inference
   - Never let AI invent tracking numbers or ETAs
   - Use structured output (JSON) to ensure data integrity

## Next Steps

1. Save this plan ✅
2. Finish calendar sync issue (current priority)
3. Return to AI assistant when ready
4. Start with Phase 1 MVP implementation

---

**Note:** Feature controlled by build flag. Not enabled by default. For internal testing only initially.
