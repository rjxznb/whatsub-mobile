# Video Learning Guide and Contextual Gloss Design

## Goal

Turn a completed Library analysis into two connected learning surfaces:

1. a compact, expandable video learning guide that tells the learner what the video contains, who it suits, and which three sections are most worth studying;
2. an on-demand contextual explanation for a highlighted or collected expression, grounded in the video's scene, tone, slang, and cultural context.

The feature must reuse the existing analysis summary phase, avoid sending the full transcript for every word tap, remain backward-compatible with every existing Library entry, and never block video or subtitle playback when generation fails.

## Product decisions

- There are no numeric scores, weighted dimensions, score bars, or pseudo-precise ratings.
- The guide keeps one qualitative verdict: `很值得完整学习`, `建议挑选重点片段`, `更适合泛听了解`, or `学习价值有限`.
- Every negative or positive learning recommendation must be supported by concrete reasons and timestamped subtitle evidence.
- New mobile analyses generate the guide and context profile in the existing final summary request.
- Existing entries and desktop-produced entries without the new fields generate lazily on first request.
- Deep explanation is never automatic. The learner explicitly taps `深度解读`.
- Free managed-experience users may use the feature against their existing relay allowance. Pro uses its monthly relay allowance. BYOK uses the learner's own provider and key.
- Desktop code is out of scope for this iteration. Desktop uploads that lack the new fields follow the same lazy path as older entries.

## Chosen architecture

Use a hybrid generation model.

For new iOS BYOK and managed-mobile analyses, extend the existing summary envelope so one final model turn returns `keyPhrases`, `learningGuide`, and `contextProfile`. This avoids another full-context model request.

For entries that predate the schema, iOS builds the same bounded summary prompt and sends it through the already configured `ChatCompletionsClient`: managed users use `/api/llm/chat`, while BYOK users call their provider directly. A narrow authenticated Library endpoint then validates and persists only the two derived fields.

Deep gloss generation always happens on iOS through the same selected LLM path. It receives the saved context profile plus a local subtitle window, not the entire transcript. Results live in a bounded local cache rather than creating a new server table.

Rejected alternatives:

- A separate summary model call for every new video adds cost and latency without improving the available context.
- Making every guide on demand leaves the primary guide card empty on every new video and weakens the first-run experience.
- Sending the entire transcript on every deep-gloss tap is expensive, slow, and unnecessary once a reusable context profile exists.
- A second contextual-gloss UI for the Collections tab would duplicate behavior and inevitably diverge from the subtitle highlight sheet.

## Analysis data model

`AnalysisJson` gains three optional fields. Existing payloads continue decoding with `nil` values.

```json
{
  "subtitles": [],
  "keyPhrases": [],
  "learningGuide": {},
  "contextProfile": {},
  "learningGuideSourceFingerprint": "server-stamped-hex"
}
```

### Learning guide

```json
{
  "verdict": "study_all",
  "overview": "这段访谈围绕……",
  "contentOutline": ["……", "……"],
  "cefrLevel": "B2",
  "cefrReason": "语速自然，并包含……",
  "recommendedFor": ["能够理解日常对话，希望……"],
  "learningReasons": ["……"],
  "cultureNotes": ["……"],
  "studyTips": ["……"],
  "topSegments": [
    {
      "startTime": 42.1,
      "endTime": 58.7,
      "title": "委婉表达不同意见",
      "reason": "包含自然的缓和语气和……",
      "focusExpressions": ["I see where you're coming from"]
    }
  ],
  "generatedAt": 1786348800000
}
```

Wire verdict values are `study_all`, `select_segments`, `extensive_listening`, and `limited_value`. iOS maps them to the approved Chinese labels. `cefrLevel` is `A2`, `B1`, `B2`, `C1`, or `C2`; the model may not output a more precise sublevel.

Limits:

- overview: 40–220 Chinese characters;
- contentOutline: 2–6 items, each 10–100 characters;
- cefrReason: 20–160 characters;
- recommendedFor: 1–4 items;
- learningReasons: 1–5 items;
- cultureNotes: 0–5 items;
- studyTips: 1–5 items;
- topSegments: 0–3 items;
- each segment must have `0 <= startTime < endTime <= video duration`, a 4–40 character title, a 10–160 character reason, and at most five focus expressions;
- `generatedAt` is supplied by trusted client/server assembly, never accepted from raw model text.

The model-facing `LearningGuideDraft` therefore omits `generatedAt`; the validated application model adds it after parsing.

The parser permits zero recommended segments when the transcript is too short or fragmented to support a reliable recommendation. It does not invent timestamps to fill the UI.

### Context profile

```json
{
  "theme": "……",
  "participants": "……",
  "setting": "……",
  "tone": "……",
  "culturalContext": "……",
  "recurringConcepts": ["……"]
}
```

The combined Chinese content target is 300–600 characters, with a hard serialized ceiling of 4 KB. `culturalContext` may be empty when the transcript does not support a reliable claim. This object is support context for later gloss requests and is not rendered as a separate card.

## Summary prompt and parsing

The iOS `AnalysisPrompts.summaryPrompt` and backend `buildSummaryMessages` use the same bounded, compact analyzed-cue input. iOS gains the backend's existing deterministic 120,000-character ceiling: if all analyzed cues do not fit, preserve the complete first and last cue and uniformly sample complete middle cue objects until the serialized messages fit. This applies to new BYOK final summaries and lazy summaries, so BYOK's unlimited video duration cannot create an unbounded single request. Their response schema becomes one strict line:

```json
{
  "type": "summary",
  "keyPhrases": [],
  "learningGuide": {},
  "contextProfile": {}
}
```

The prompt explicitly forbids numeric scores and requires timestamp evidence from supplied cues. It instructs the model to leave culture notes empty when unsupported.

Both parsers use the same allow-listed keys, enum values, cardinality limits, string limits, and segment-time validation. The backend remains authoritative for managed analysis. iOS applies the same checks for BYOK and lazy generation so malformed output never enters Library storage.

If cue analysis succeeds but the final summary fails, the existing behavior remains: subtitles are usable, while `keyPhrases`, guide, and profile are absent and can be generated later.

## Analysis fingerprint and stale-write protection

The backend computes an `analysisFingerprint` from the Library title plus the ordered subtitle fields that affect learning context: index, start, end, English text, translation, key-point status, highlighted expressions, quick notes, and highlight translations. It uses canonical UTF-8 JSON and SHA-256. Any cue analysis repair therefore invalidates the guide and deep-gloss cache instead of reusing context derived from older annotations.

`GET /api/library/entry/:id` adds `analysisFingerprint`. It is server-computed and never trusted from stored JSON or the client.

When a full sync, managed finalization, or desktop replacement includes a valid guide/profile, the backend stamps the current fingerprint into `learningGuideSourceFingerprint`. When the stored stamp does not equal the current computed fingerprint, the detail response omits the stale guide and profile.

Subtitle editing and replacement therefore invalidate derived context automatically. No client can make stale data appear current by copying an old stamp.

## Lazy guide persistence

iOS generates a missing guide through the existing selected LLM client, then calls:

`PATCH /api/library/entry/:id/learning-guide`

Request:

```json
{
  "expectedAnalysisFingerprint": "hex",
  "learningGuide": {},
  "contextProfile": {}
}
```

The route:

1. requires the existing authenticated session and entry ownership;
2. recomputes the current fingerprint and returns `409 analysis_changed` on mismatch;
3. strictly validates both structures and every timestamp against the entry duration and cue bounds;
4. updates only the derived fields and server-owned source fingerprint inside `analysis_json`;
5. returns the accepted guide, profile, and fingerprint.

The route cannot modify subtitles, key phrases, transcript SRT, media identity, or OSS objects. A malicious client can at worst alter derived learning notes on its own Library entry.

Only one lazy guide task runs per detail view. Navigating away cancels the client request. A completed validated write remains available across devices.

## Contextual deep gloss

### Input

The prompt receives:

- video title;
- `contextProfile`;
- normalized target expression and its existing quick translation/note;
- the current cue plus up to four preceding and four following cues;
- the current cue timestamp.

If an old entry lacks a context profile, tapping `深度解读` first runs the lazy guide/profile generation, persists it, then performs the small gloss request. The UI labels the first stage `正在准备视频语境…` and the second `正在深度解读…`.

### Output

```json
{
  "contextualMeaning": "……",
  "toneAndSubtext": "……",
  "slangOrIdiom": "……",
  "culturalContext": "……",
  "naturalAlternatives": ["……"],
  "usageWarning": "……"
}
```

All fields are Chinese learning explanations except English alternatives. `slangOrIdiom`, `culturalContext`, and `usageWarning` may be empty. The parser rejects extra keys, more than five alternatives, any field over 500 characters, or a serialized result over 4 KB.

No model output may claim that an expression is slang or culturally specific without grounding it in the supplied cue window/profile. The prompt prefers an empty field over speculation.

### Local cache

`Caches/deep_gloss_cache.json` stores at most 200 least-recently-used entries. The key is:

```text
analysisFingerprint + cueIndex/nearestTimestamp + normalizedExpression
```

The cached value contains only the structured deep-gloss result and access time. A new analysis fingerprint automatically misses every stale entry. Corrupt cache files are discarded, and cache-write failure never blocks the explanation UI.

## Learning guide UI

The card sits below the player/managed-analysis banner and above the existing `字幕 / 收藏 / 角色扮演` picker.

Collapsed state shows:

- qualitative verdict;
- CEFR level;
- one-line overview;
- expansion chevron.

It contains no score, score ring, dimension bar, star rating, or hidden numeric value.

Expanded state presents, in order:

1. 30-second overview;
2. content outline;
3. why the video is or is not worth studying;
4. recommended learner profile and CEFR explanation;
5. cultural/context notes;
6. study tips;
7. up to three timestamped recommended segments.

Selecting a recommended segment switches to the subtitle tab, collapses the guide, seeks the shared player or YouTube embed, and scrolls to the nearest cue through the existing seek/current-index pipeline.

For a missing old guide, the collapsed card shows `生成视频学习导览`. While generating it shows bounded progress copy without blocking the subtitle list. Failure becomes an inline retry state. A quota response uses the existing Pro/BYOK guidance.

## Gloss sheet UI

The existing `GlossSheet` remains the single explanation surface.

- Initial compact content remains pronunciation, IPA, quick translation/note, and collection state.
- A new `深度解读` button starts the on-demand request and expands the sheet to `.large`.
- Success renders labeled sections for contextual meaning, tone/subtext, slang/idiom, culture, alternatives, and warning. Empty optional sections are omitted.
- Failure leaves pronunciation, quick meaning, and collection controls intact and shows a retry action.
- A cache hit renders immediately without a network request.

`WordGloss` gains context sufficient to locate the source cue and an explicit collection presentation state. Subtitle-highlight glosses remain collectable. Glosses opened from the Collections tab are marked already collected and show a disabled `已收藏` state rather than creating a duplicate pending phrase.

## Collections tab interaction

The current row-body tap seeks the video. To make explanation discoverable without losing seek:

- tapping the phrase/meaning body opens the shared `GlossSheet` and pauses current video audio before automatic pronunciation;
- tapping the timestamp chip seeks the video and nearest subtitle;
- the pending-row cloud upload button is unchanged;
- pending and synced rows both expose context sentence, timestamp, quick meaning, and usage note to the gloss;
- no single-tap/double-tap gesture distinction is introduced.

`EntryCollectionsList` reports a typed gloss selection to `LibraryDetailView`; the parent owns sheet presentation and player pausing, matching subtitle highlight behavior.

## Quota and permissions

- New managed-mobile guide/profile generation is part of the existing analysis job and its existing token accounting.
- Lazy managed guide generation and managed deep gloss use the existing `/api/llm/chat` relay, so free/Pro allowance and concurrency policy stay centralized.
- BYOK guide and deep gloss calls go directly to the configured provider and do not consume managed quota.
- No new Pro-only gate is added.
- A relay 403 preserves existing quick explanations and offers the current subscription/BYOK route.

## Error handling

- Guide generation failure never changes video, subtitle, or existing key-phrase availability.
- Deep-gloss failure never removes the quick note, pronunciation, or collection state.
- `409 analysis_changed` discards the generated result, refreshes the detail entry, and offers one explicit retry against the new subtitles.
- `429` shows a bounded retry message and does not automatically hammer the relay.
- A segment outside cue/video bounds is dropped; invalid remaining guide fields reject the guide.
- Unknown future fields in stored `AnalysisJson` do not break older clients; new clients decode the three fields optionally.
- The backend never logs prompt text, subtitles, expressions, model output, API keys, or complete derived payloads in ordinary request logs.

## Testing

### iOS

- old `AnalysisJson` decodes with nil guide/profile/fingerprint;
- new JSON round-trips all structures and strict enums;
- BYOK summary parsing accepts the exact envelope and rejects scores, extra keys, oversized fields, and invalid segments;
- guide card collapsed/expanded presentation contains no numeric score source;
- segment selection switches tab, seeks, collapses, and resolves the nearest cue;
- lazy generation single-flight, cancellation, `403`, `409`, and retry behavior;
- deep-gloss prompt contains only profile plus a maximum nine-cue window;
- deep-gloss parser optional sections and strict limits;
- 200-entry LRU, cache hit, corruption recovery, and fingerprint invalidation;
- subtitle highlight and Collections rows both open the same gloss presentation;
- Collections timestamp still seeks and collected gloss cannot duplicate-save;
- explanation errors leave quick pronunciation and collection behavior usable.

### Backend

- managed summary prompt/parser emits and validates all three summary products;
- final assembled Library JSON includes the guide/profile and server stamp;
- fingerprint is deterministic and changes for title, timing, text, translation, or highlight-annotation edits;
- stale stored guides are omitted from detail responses;
- PATCH ownership, strict payload validation, timestamp bounds, and stale-write conflict;
- PATCH cannot mutate subtitles, key phrases, transcript, or media fields;
- old clients syncing only subtitles/keyPhrases remain valid;
- managed worker summary failure preserves analyzed cues and lazy recovery eligibility.

## Rollout

1. Deploy the backward-compatible backend parser, fingerprint, persistence route, and managed worker changes.
2. Verify one new managed job, one old-entry lazy write, and one stale-fingerprint rejection in production-safe diagnostics.
3. Ship iOS with optional decoding, BYOK/lazy generation, guide UI, shared deep gloss, Collections interaction, and cache.
4. Test new managed, new BYOK, old mobile, and desktop-origin entries in TestFlight.
5. Instrument feature use only after the separately designed first-party analytics pipeline is approved and implemented; this feature does not silently introduce analytics.

## Success criteria

- Every completed new mobile analysis can expose a guide without an additional full-transcript model call.
- A deep-gloss request never sends more than nine cues and one bounded context profile.
- Old entries remain playable and can generate a guide on demand.
- Reanalysis, editing, or desktop replacement cannot display a stale guide or hit stale deep-gloss cache.
- Collections phrases and subtitle highlights use one explanation experience while preserving timestamp seeking.
- No UI or stored structure contains a numeric learning score.
