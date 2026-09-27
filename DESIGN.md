# Design
## Source of truth
Active, 2026-09-27. Surfaces: native macOS floating audio player and local voice demo website. Evidence: user explicitly requested Apple styling, compact Notch/top or bottom-center above Aqua modes, live visualization, 100 selectable demos. Existing native player and offline Thorsten INT8 backend inspected. User failure screenshot supplied 27.09.2026: clipped settings menu; independent Opus audit rejected that state.
## Brand
Quiet, precise, lightweight. Trust through actual playback, named voices, honest language/size labels. Avoid marketing gradients, crowded controls, fake demos, invented quality ratings.
## Product goals
Hear text locally from a context action; select a voice by listening; keep work visible. Default model 18.6 MB. Download other models only after selection. Success: real demo playback, selection reaches native engine, live native controls work.
## Personas and jobs
German-speaking Mac operator listening while working, using Aqua Voice and the display Notch. Needs quick controls with minimal obstruction.
## Information architecture
Native player: fixed black 180×32 capsule with Start/Pause, Stop, saved tempo, tiny actual level and always-visible settings gear. Hover never moves controls or resizes the capsule; all voice/model/language settings live in the local website. Text input is optional. Its footer displays the current state and a ⌘Return hint; normal Return continues to insert newlines. Website: 100 voice options, German first, search, language and size filters, preview, use in player; current selection/download state.
## Design principles
One clear primary action. Native macOS materials. Prefer modest spacing and legible controls over dashboard density. Treat hover-text capture limits honestly.
## Visual language
System SF typography. Native near-black opaque capsule matching the Notch, 16px corners, subtle border, white icons, almost no text. Website warm-white canvas, near-black type, neutral separators, rounded cards, soft blue selection. 8px spacing base. Meter responds to actual audio power; no fake spectrum claims.
## Components
Native floating panel, real audio level view, transport buttons, screen-bounded speed menu, anchored settings popover, mode switch, expandable editor with right-aligned gear. Web searchable voice cards, language chips, demo audio control, download status, selected state.
## Accessibility
Keyboard navigation, explicit labels, visible focus, sufficient contrast, reduced-motion support; do not depend on color alone. Native accessible transport and tempo labels. Tooltips follow the actual transport state. Gear and the current reading section must be reachable without hover; ⌘T toggles persistent reading text and ⌘E toggles input.
## Responsive behavior
Player anchors top-center just below Notch or bottom-center with clearance above Aqua/Dock; remember mode. Website grid collapses to single column on narrow screens. Avoid horizontal overflow.
## Interaction states
Idle, generating/buffering (distinct busy indicator rather than fake audio levels), playing, paused, finished, failed; selected voice downloading and ready. Preview network unavailable must show error. Never indicate ready until model validated and configuration committed.
## Content voice
Short clear German labels: Hörprobe, Im Player verwenden, Lokal, Tempo. Use compact decimal-comma rates (1×, 1,25×). A transient settings popover groups reading actions, display choices and voice selection. It opens toward available space above/below the player; show compact status and voice context. Quit stays in the app menu, away from frequent actions. Use explicit anheften/lösen text for the reading-section toggle. No implementation jargon in primary flow. Show model size where it affects download choice.
## Implementation constraints
AppKit Objective-C, Python local server and Piper, vanilla HTML/CSS/JS without new frontend dependencies. Bind only loopback. Protect state-changing API against cross-site requests. Validate using Codex Computer Use and real synthesis; preserve existing source/installation backups.
## Open questions
User clarified all languages, ready-made samples, downloadable higher-quality models. German first, 100 actual samples. Latest screenshot rejects former 448×164 panel as too large. Subsequent user requests require the existing 180×32 footprint and simpler, clearer UI/UX. No unresolved design-critical questions; current section display follows buffer boundaries, not word timestamps.
