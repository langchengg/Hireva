# Button Feedback Audit

Interaction Feedback / Button Responsiveness Sprint for Hireva.

## Feedback Contract

Every primary user-facing action should provide:

- Immediate local feedback near the button.
- A loading state for async or long-running work.
- A success, warning, or error terminal state.
- Duplicate-click prevention through `AppState.actionLoadingStates`.
- Plain-language next-step guidance.

Shared implementation:

- `ActionFeedback` and `ActionFeedbackKind` model action lifecycle state.
- `AppState.activeActionFeedbacks` stores recent local/global feedback.
- `AppState.actionLoadingStates` prevents duplicate async actions.
- `ActionButton`, `ProgressButton`, `InlineStatusBanner`, and `ToastBanner` render feedback consistently.

## Screen Audit

| Area | Status | Buttons Covered | Remaining Gap |
|---|---|---|---|
| Home / Interview | Complete | Start Interview, Stop Listening, Run Readiness Check, Show Floating Panel, Generate Answer, capture mode switch, empty-state CTAs, Diagnostics navigation | Header Diagnostics uses feedback but is still a secondary route, not a full diagnostic workflow refresh |
| Floating Assistant | Complete | Regenerate, Copy Answer, display mode switch, Stop Listening feedback surfaced locally | Sources and follow-up are disclosure toggles; their visual expansion is the feedback |
| Documents | Complete | Save Document, Rebuild Clean RAG Index, Preview Clean Text, Clear Document | Clear Document is immediate; no extra confirmation was added to keep document editing fast |
| Readiness Check | Complete | Open Interview, Fix First Issue, Open Settings, Open Documents, Test DeepSeek, Rebuild RAG, Open Permissions, Show Floating Panel | Permission flows still depend on macOS System Settings after the app opens them |
| Settings | Complete | Test DeepSeek, save embedding key, rebuild clean context, rebuild embeddings, save settings, clear local data with confirmation, add provider | Existing provider list is filtered to non-local providers |
| Provider Editor | Complete | Save Key, Use for Realtime, Use for Recap, Test, Save, Delete with confirmation | Provider delete feedback is local to the editor card |
| Provider Quick Switcher | Complete | Test active provider, select provider, switch model, apply custom model | Provider row selection relies on selected checkmark plus shared switch feedback |
| Manual Capture | Complete | Record Question, Stop & Transcribe, Cancel, Send to AI, Retry LLM, Retry Recording, Regenerate with DeepSeek confirmation, Clear, Open Provider Settings | Audio level meter remains separate from action feedback |
| Sessions | Complete | Generate Recap, Export Markdown, Delete Session with confirmation | Session list selection is navigation, not an async action |
| Diagnostics | Partial | Provider Test DeepSeek, provider connection tests, embedding test, rebuild embeddings, RAG clean index rebuild | Deep legacy permission diagnostics still contain raw debug utility buttons; these are intentionally kept in Diagnostics, not normal flow |
| Onboarding | Complete | Save CV, Save Job Description, Save Key, Test DeepSeek, Enter App | Optional API key remains optional and safely masked |

## Verification Targets

- Normal UI no longer exposes Ollama/local provider choices.
- Raw API keys are not shown in feedback titles, messages, or connection text.
- RAG rebuild feedback states that existing index is preserved on failure.
- Floating Assistant copy/regenerate actions provide immediate local feedback.
- Destructive local data/session/provider actions require confirmation before deletion.
- No Accessibility automation is required for verification.

## Manual Checklist

1. Launch the app and confirm it opens to Home / Interview.
2. Click Start Interview and confirm the button changes to a starting/loading state immediately.
3. Stop Listening and confirm the status card reports that listening stopped while the latest suggestion remains visible.
4. In Documents, save CV/JD text and confirm saved/indexed feedback appears under the relevant card.
5. Rebuild Clean RAG Index and confirm a local loading message appears, then a success/warning result.
6. In Readiness Check, click each failed item action and confirm it either opens the target screen or runs the configured test with visible feedback.
7. In Settings, test DeepSeek, save an embedding key, rebuild context, and clear local data; confirm no raw key is displayed and destructive clear requires confirmation.
8. In Floating Assistant, click Copy Answer and Regenerate; confirm local copied/regenerating feedback and that the old answer remains visible while regenerating.
9. In Manual Capture, Record, Stop & Transcribe, Cancel, Send to AI, Retry, and Clear; confirm loading states and duplicate-click prevention.
10. In Sessions, generate/export a recap and delete a session; confirm local feedback and delete confirmation.
11. Open Diagnostics and confirm technical controls are present there, not in Home or Readiness.
