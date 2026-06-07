# InterviewCopilotMac UI Product Polish Sprint

## Current Problems

- The app exposed implementation surfaces too early: provider diagnostics, audio internals, RAG status, ASR state, capture events, and secure storage details were more prominent than the interview workflow.
- The default experience could be blocked by onboarding instead of landing on a clear Home / Interview workflow with one next action.
- Navigation mixed normal user tasks with debugging tasks, making diagnostics feel like the product.
- The floating assistant was not optimized for glance reading during an interview. Technical metadata competed with the answer.
- Document setup did not clearly explain that CV, job description, and notes become the app's memory.
- Readiness was implicit across several screens instead of summarized as a pre-interview checklist.
- Empty states and failure states often required users to infer what to do next.

## Proposed Information Architecture

The primary sidebar is now:

1. Home / Interview
2. Documents
3. Sessions
4. Readiness Check
5. Settings
6. Diagnostics

Home / Interview is the default screen. Diagnostics remain available but are no longer the default user path.

## Screen Redesign

### Home / Interview

- Presents a single interview status card with human states: Ready, Listening, Question detected, Generating first answer, Expanding answer, Needs attention, or Stopped.
- Shows capture mode, DeepSeek status, relevant context status, permissions, and floating panel visibility in plain language.
- Uses one primary CTA: Run Readiness Check, Start Interview, or Stop Listening.
- Includes a capture mode selector with explanations for System Audio Only, Microphone Only, and Mic + System.
- Shows an orange speaker-mode warning when built-in speakers and built-in microphone may leak interviewer audio.
- Shows a clean answer preview or an empty state with the next action.

### Floating Assistant

- Optimized for quick reading: current question, visually dominant Say First answer, short key points, optional follow-up, collapsed sources.
- Adds three modes:
  - Compact: question, Say First, two key points.
  - Normal: question, Say First, key points, follow-up, collapsed sources.
  - Diagnostic: provider, latency, relevant context mode, capture state, ASR health, and source scoring.
- Keeps diagnostics and source internals hidden by default.
- Preserves readability with minimum answer font size and a less transparent background.

### Documents

- Reframes CV, Job Description, and Additional Notes as the app's memory.
- Each card shows saved status, cleaned text status, chunk count, context index status, last rebuilt time, and LaTeX cleanup warnings.
- Adds Save Document, Rebuild Clean RAG Index, Preview Clean Text, and Clear Document actions.
- Preserves original input while using cleaned plain text for retrieval.

### Readiness Check

- Adds a dedicated checklist with pass, warning, and failed states.
- Covers DeepSeek configuration, documents, clean chunks, LaTeX pollution, permissions, capture mode, floating panel, transcript test, and first answer generation test.
- Each failed actionable item has one clear button: Open Settings, Open Documents, Rebuild Context, Open Permissions, or Show Floating Panel.

### Settings

- Groups configuration into cards: AI Provider, Embeddings / Relevant Context, Audio, Floating Window, and Privacy & Security.
- Uses product language outside diagnostics: securely saved, relevant context, interviewer audio, and your microphone.
- Hides raw API keys and technical diagnostics from the normal settings flow.

### Diagnostics

- Moves technical details into tabs: Provider, RAG, Audio, Capture Events, Latency, and Keychain.
- Keeps raw names and debug fields here only: recent capture events, ASR task state, capture running flags, stop reasons, source scores, latency, and masked secure storage status.

## Manual UI Verification Checklist

Do not use Accessibility automation for this checklist.

1. Launch the signed app bundle manually.
2. Confirm the default selected screen is Home / Interview.
3. Confirm a new user can identify the next action within 5 seconds.
4. With missing documents or missing DeepSeek key, confirm Home shows Needs attention and the primary CTA is Run Readiness Check.
5. Open Documents and confirm CV, Job Description, and Additional Notes cards are visible.
6. Paste LaTeX-like text into a document and confirm the LaTeX cleanup warning appears after saving.
7. Open Readiness Check and confirm each failed item has one action button.
8. Open Settings and confirm raw API keys are not displayed.
9. Select Mic + System with built-in microphone and built-in speakers and confirm the orange leakage warning appears on Home.
10. Show the Floating Assistant and verify Normal mode prioritizes the answer over sources and diagnostics.
11. Switch Floating Assistant to Compact and confirm long text remains readable and does not wrap letter-by-letter.
12. Switch Floating Assistant to Diagnostic and confirm provider, latency, capture, ASR, and source details are visible only there.
13. Confirm Diagnostics is reachable from the sidebar but is not selected by default.
14. Confirm Start Interview and Stop Listening are visually obvious on Home.
15. Confirm no repeated macOS permission prompts occur during these manual checks unless the user explicitly starts capture on a fresh permission state.

## Screenshot Note

Before/after screenshots were not captured automatically in this sprint because the app is a native macOS app with audio and screen/system audio permission surfaces, and the requested test constraint forbids Accessibility automation and repeated permission prompts. Use the manual checklist above for visual QA screenshots after launching the signed app bundle intentionally.
