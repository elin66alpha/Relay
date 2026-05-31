# AgentDeck — Card Mode Feature Implementation

## Project Overview

AgentDeck is a Flutter + Node.js app. The Flutter client connects to a local
Node backend (`server/server.js`) that runs CLI AI agents (Claude Code, Codex,
Antigravity). The current interaction model is a chat interface with SSE
streaming. All backend routes require `Authorization: Bearer <token>`.

**Before writing any code:** Read the following files to understand existing
patterns, then follow them exactly — state management, HTTP client style,
file naming, module format (CommonJS `require`, not ESM):

- `lib/core/backend/` — existing HTTP/SSE client patterns
- `lib/features/chat/` — existing screen and widget structure
- `lib/core/models/` — existing model classes
- `server/lib/agents.js` and `server/lib/usage.js` — backend module patterns
- `server/server.js` — how routes are registered

---

## Goal

Add **Card Mode** as a new, secondary interaction paradigm. Card Mode shows
AI-generated action suggestions derived from chat history. Users act on cards
with four-directional swipe gestures. Chat remains the primary mode — do not
alter it. Cards are additive and non-breaking.

---

## Strict Constraints

- **Do NOT modify** any existing route handlers in `server/server.js`
- **Do NOT modify** existing Flutter screens, models, or services
- **Do NOT change** any existing API contracts
- All new server endpoints must be registered in `server/server.js` by
  adding `require('./lib/cards')` and `require('./lib/chat-learner')` and
  wiring only the three new routes listed below
- Card execution reuses the existing `POST /api/chat` endpoint — no new
  execution path needed

---

## Backend — New Files

### `server/lib/cards.js`

Card store with persistence to `server/cards.json`. Exports functions used
by the new route handlers.

**Card schema (one entry in `cards` array):**
```json
{
  "id": "<uuid>",
  "agentKey": "claude | codex | agy",
  "title": "Short action title",
  "reason": "Why this was suggested (shown to user)",
  "prompt": "The exact prompt string to send to the agent",
  "confidence": 0.82,
  "source": "chat_history | rule",
  "status": "pending | executed | rejected | deferred | irrelevant",
  "deferUntil": null,
  "createdAt": "<ISO>",
  "updatedAt": "<ISO>"
}
```

**Functions to export:**
- `getActiveCards()` — returns cards where status is `pending`, plus any
  `deferred` cards whose `deferUntil` timestamp has passed (promote them
  back to `pending` before returning)
- `applyFeedback(cardId, gesture, deferUntil?)` — updates card status:
  - `"execute"` → set status `executed`
  - `"reject"` → set status `rejected`
  - `"defer"` → set status `deferred`, set `deferUntil`
  - `"irrelevant"` → set status `irrelevant`
- `replaceGeneratedCards(newCards)` — removes all `pending` cards (keeps
  `deferred`), inserts new ones; persists to `cards.json`
- Initialize `cards.json` with an empty `{ "cards": [] }` if it does not
  exist on startup

---

### `server/lib/chat-learner.js`

Reads existing session history files (same source as `GET /api/history`) to
extract patterns and generate candidate cards. No ML — keyword matching only.

**Export one function: `generateCards(agentKey)`**

Logic (apply to the most recent 60 messages for the given agent):

| Condition | Card to generate |
|---|---|
| Any message contains `error`, `exception`, `traceback`, `TypeError`, `NullPointer`, `undefined is not` | Title: "Debug recent error" · Prompt: "Review the error in our recent conversation and suggest a fix" |
| User has sent a message containing `npm test`, `pytest`, `go test`, or `cargo test` in the last 7 days | Title: "Run tests again" · Prompt: "Run the test suite and summarize any failures" |
| Any message contains a fenced code block (``` ` ``` ` ``` ` ```) longer than 20 lines | Title: "Explain this code" · Prompt: "Explain the code we discussed recently, section by section" |
| Any message mentions a file path (contains `/` or `\` and a file extension) | Title: "Review recent file changes" · Prompt: "Review the file changes we discussed and suggest improvements" |
| None of the above match | Title: "Summarize our session" · Prompt: "Summarize what we accomplished in this session and list any open tasks" |

Generate at most **4 cards** per call. Assign `confidence` values: error
cards 0.88, test cards 0.82, code cards 0.76, file cards 0.72, summary
card 0.60. Set `source: "chat_history"`.

Also export `generateCardsForAllAgents()` — calls `generateCards` for each
known agent key and merges results.

---

### New Routes in `server/server.js`

Add these three routes after the existing route registrations. Do not touch
anything else in this file.

```
GET  /api/cards             → cards.getActiveCards()
POST /api/cards/feedback    → body: { cardId, gesture, deferUntil? }
POST /api/cards/refresh     → triggers chat-learner, returns { generated: N }
```

All three require the existing Bearer token auth middleware (same guard used
by all other `/api/*` routes).

On server startup, after existing initialization: if `cards.json` exists but
has zero pending cards, call `generateCardsForAllAgents()` once silently.

---

## Frontend — New Files

All new files go under `lib/features/cards/`. Follow the naming and class
conventions used in `lib/features/chat/`.

### `lib/core/models/card_model.dart`

Dart model class mirroring the card schema. Named constructor `fromJson`,
method `toJson`. All fields nullable where appropriate. Place with other
models in `lib/core/models/`.

---

### `lib/features/cards/cards_service.dart`

HTTP client for the three card endpoints. Follow the exact same pattern as
the existing backend HTTP client in `lib/core/backend/`. Methods:

- `Future<List<CardModel>> getCards()`
- `Future<void> sendFeedback(String cardId, String gesture, {DateTime? deferUntil})`
- `Future<int> refresh()`

---

### `lib/features/cards/card_widget.dart`

Stateless widget that renders a single card. Displays:
- Title: large, weight 600
- Reason: muted subtitle below title
- Agent badge: small chip showing `agentKey` with appropriate color
- Confidence bar: thin linear progress indicator at bottom of card (value =
  `confidence`, color green above 0.8, amber 0.6–0.8, muted below 0.6)
- "From chat" label if `source == "chat_history"`

Card background: `Theme.of(context).cardColor`. Elevation 4. Rounded corners
`BorderRadius.circular(16)`. Padding 20px all sides.

---

### `lib/features/cards/card_deck_screen.dart`

The main cards screen.

**Layout:**
- AppBar with title "Card Mode" and a refresh `IconButton` (calls
  `cardsService.refresh()` then reloads)
- Body: centered stack area showing up to 3 cards. Top card is interactive;
  the second and third are visible below it, offset by 8px and 16px vertically
  and scaled slightly (0.97, 0.94) to create a deck perspective effect.
- Empty state (no cards): centered column with a deck icon, text "No
  suggestions yet", subtext "Keep chatting and cards will appear here",
  and a "Refresh" button.
- Loading state: `CircularProgressIndicator`.

**Gesture handling on the top card** — use `GestureDetector` with
`onPanUpdate` and `onPanEnd`:

During `onPanUpdate`: translate and rotate the card smoothly
(`dx * 0.4` translation, `dx * 0.03` rotation in radians). Show a colored
overlay on the card that fades in based on drag distance (full opacity at
60px). Overlay colors and labels:
- Right (dx > 0): green, checkmark icon, "Execute"
- Left (dx < 0): red, X icon, "Reject"
- Up (dy < 0): amber, pause icon, "Defer"
- Down (dy > 0): grey, minus icon, "Irrelevant"

Determine primary direction by comparing `abs(dx)` vs `abs(dy)`.

On `onPanEnd`:
- If the drag distance in the primary direction is **< 60px**: snap card
  back to center with a spring animation.
- If **≥ 60px**, execute the action for that direction:

  **Right (Execute):** Call `cardsService.sendFeedback(id, "execute")`.
  Construct the message exactly as the existing chat send path does (see
  `lib/features/chat/`) using the card's `agentKey` and `prompt`. Switch
  to the matching agent if necessary. Navigate to the chat screen. The
  user sees the prompt sent and the agent's streaming response.

  **Left (Reject):** Call `cardsService.sendFeedback(id, "reject")`.
  Animate card flying off to the left. Remove from local list.

  **Up (Defer):** Show a `showModalBottomSheet` with three options:
  "In 30 minutes", "In 2 hours", "Tomorrow morning (9 AM)". On selection,
  call `cardsService.sendFeedback(id, "defer", deferUntil: <computed DateTime>)`.
  Animate card flying off upward. Remove from local list.

  **Down (Irrelevant):** Call `cardsService.sendFeedback(id, "irrelevant")`.
  Animate card flying off downward. Remove from local list.

After any dismiss: next card in the stack becomes the top interactive card.
When the last card is dismissed, show the empty state with a "Generate new
cards" button (calls refresh).

---

## Navigation — Existing Files to Edit

**Edit only these two locations, nothing else:**

1. In the existing drawer widget (`lib/features/drawer/` — find the correct
   file by reading it first), add a new `ListTile` or equivalent entry for
   "Card Mode" with a card/deck icon, placed after the existing agent items
   and before settings. Tapping it navigates to `CardDeckScreen`.

2. In the main router/navigation setup (find it by reading the existing code),
   register the route for `CardDeckScreen`.

---

## What NOT to Build in This Phase

- No push notifications for deferred card revival (passive revival on
  `GET /api/cards` is sufficient)
- No manual card creation UI
- No cross-device card sync
- No ML model or embeddings
- No modification to existing chat history display — cards never appear in
  chat history

---

## Verification Checklist

Before finishing, confirm:
1. `flutter analyze` produces no new errors or warnings
2. All existing tests in `test/` still pass
3. Card Mode is accessible from the drawer
4. All four swipe directions show correct overlay color while dragging
5. Right swipe sends the card's prompt via the existing chat path and
   navigates to the chat screen
6. `GET /api/cards` returns valid JSON matching the schema
7. `POST /api/cards/feedback` accepts all four gesture values
8. `POST /api/cards/refresh` returns `{ "generated": N }` where N > 0
9. Existing chat, settings, credentials, and workdir features are unaffected
