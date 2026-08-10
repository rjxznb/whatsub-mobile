# Video Learning Guide and Deep Gloss Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persisted, collapsible video learning guide and an on-demand contextual expression explanation shared by subtitle highlights and the Collections tab.

**Architecture:** Extend the existing managed/BYOK summary envelope with strictly validated `learningGuide` and `contextProfile` fields. The backend owns analysis fingerprints and stale-write protection; iOS owns lazy relay/BYOK generation, presentation, and a bounded deep-gloss cache. No new database table or desktop change is required.

**Tech Stack:** Swift 5.10 + SwiftUI + XCTest (iOS 16+), TypeScript + Hono + PostgreSQL JSONB + Vitest (Node 20)

## Global Constraints

- Do not add numeric scores, rating stars, score bars, or hidden numeric ranking fields.
- Keep `subtitles` and `keyPhrases` backward-compatible for existing clients and entries.
- A deep-gloss prompt contains at most nine cues: current cue plus four before and four after.
- BYOK and lazy summary messages are capped at 120,000 serialized characters using deterministic complete-cue sampling.
- Model output uses strict JSON with allow-listed keys, bounded arrays, bounded strings, and validated timestamps.
- Video, subtitle, pronunciation, collection, and existing key-note behavior remain usable when either new generation path fails.
- Managed calls use existing relay/job quota and concurrency controls; BYOK calls use the learner's provider.
- Backend deployment precedes the iOS TestFlight build.
- Preserve unrelated untracked files in both repository roots.

---

### Task 1: Establish isolated backend workspace and baseline

**Files:**
- No production files

**Interfaces:**
- Produces: backend worktree `whatsub-license/.worktrees/video-learning-guide` on branch `codex/video-learning-guide`

- [ ] **Step 1: Verify the worktree directory is ignored and create the backend branch**

```powershell
cd 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-license'
git check-ignore .worktrees
git worktree add '.worktrees/video-learning-guide' -b 'codex/video-learning-guide'
```

Expected: the new worktree starts at current backend `main`; root `.tmp-whatsub-release-builds/` and `public/admin/index.html.backup` remain untouched.

- [ ] **Step 2: Install and run the backend baseline**

```powershell
cd 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-license\.worktrees\video-learning-guide'
npm install
npm test
npm run typecheck
```

Expected: all existing Vitest tests and TypeScript checks pass before feature edits.

### Task 2: Define the backend guide schema, parser, and fingerprint

**Files:**
- Create: `whatsub-license/src/lib/videoLearningGuide.ts`
- Create: `whatsub-license/tests/video-learning-guide.test.ts`
- Modify: `whatsub-license/src/lib/types.ts`

**Interfaces:**
- Produces: `parseLearningGuideDraft(value, durationSec, cueBounds): ParsedLearningGuideDraft`
- Produces: `parseContextProfile(value): ParsedContextProfile`
- Produces: `analysisFingerprint(title, subtitles): string`
- Produces: `stampLearningGuide(draft, profile, fingerprint, now): PersistedLearningGuideFields`
- Produces: `normalizeLearningFieldsForFullSync(analysisJson, title, durationSec, now): unknown`

- [ ] **Step 1: Write failing strict-schema and fingerprint tests**

```ts
import { describe, expect, it } from 'vitest';
import {
  analysisFingerprint,
  parseContextProfile,
  parseLearningGuideDraft,
} from '../src/lib/videoLearningGuide.js';

const cues = [{
  index: 0, time: 10, endTime: 14, text: 'I see your point.', translation: '我明白你的意思。',
  isKeyPoint: true, highlightWords: ['see your point'],
  keyNotes: { 'see your point': '表示理解对方观点。' },
  highlightTranslations: { 'see your point': '明白你的意思' },
}];

describe('video learning guide contract', () => {
  it('accepts an evidence-based guide without a score', () => {
    const parsed = parseLearningGuideDraft({
      verdict: 'select_segments',
      overview: '这段访谈通过自然对话展示人物如何先认可对方观点，再用缓和语气委婉表达不同意见，并维持轻松友好的交流氛围。',
      contentOutline: ['先说明讨论背景和人物之间的关系', '再展示缓和分歧时常用的自然表达'],
      cefrLevel: 'B2', cefrReason: '语速自然，并包含需要结合上下文和说话语气理解的委婉表达。',
      recommendedFor: ['希望提升真实会话理解的学习者'],
      learningReasons: ['包含可直接迁移到讨论场景的表达'],
      cultureNotes: [], studyTips: ['先盲听，再跟读推荐片段'],
      topSegments: [{ startTime: 10, endTime: 14, title: '委婉认同',
        reason: '展示先认可再表达分歧的方式', focusExpressions: ['see your point'] }],
    }, 20, [{ start: 10, end: 14 }]);
    expect(parsed.verdict).toBe('select_segments');
    expect(parsed).not.toHaveProperty('score');
  });

  it('rejects extra score keys and out-of-range segments', () => {
    expect(() => parseLearningGuideDraft({ score: 8.4 }, 20, [])).toThrow();
  });

  it('allows empty unsupported cultural context', () => {
    expect(parseContextProfile({
      theme: '沟通', participants: '采访者与演员', setting: '访谈', tone: '轻松',
      culturalContext: '', recurringConcepts: ['委婉表达'],
    }).culturalContext).toBe('');
  });

  it('changes fingerprint when a quick note changes', () => {
    const before = analysisFingerprint('Title', cues);
    const after = analysisFingerprint('Title', [{ ...cues[0]!, keyNotes: { 'see your point': '新解释' } }]);
    expect(after).not.toBe(before);
    expect(analysisFingerprint('Title', cues)).toBe(before);
  });
});
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `npm test -- tests/video-learning-guide.test.ts`

Expected: FAIL because `src/lib/videoLearningGuide.ts` does not exist.

- [ ] **Step 3: Implement strict models, limits, canonicalization, and stamping**

```ts
export type LearningVerdict = 'study_all' | 'select_segments' | 'extensive_listening' | 'limited_value';
export type CefrLevel = 'A2' | 'B1' | 'B2' | 'C1' | 'C2';

export interface PersistedLearningGuideFields {
  learningGuide: ParsedLearningGuideDraft & { generatedAt: number };
  contextProfile: ParsedContextProfile;
  learningGuideSourceFingerprint: string;
}
```

Implement exact allow-list checks, specification cardinalities/string ceilings, `0 <= start < end <= duration`, and evidence overlap with at least one cue bound. When duration is absent, use the greatest validated cue end as the effective upper bound. Canonicalize the exact subtitle fields listed in the spec with recursively sorted object keys before SHA-256 hashing; canonical `index` is the cue's array position so older mobile payloads that omit a wire index hash identically after decode.

Use named constants for the remaining hard limits so TypeScript and Swift can mirror them: each `recommendedFor` item 1–160 characters, each `learningReasons`/`cultureNotes`/`studyTips` item 1–200, each focus expression 1–100, each context-profile scalar at most 500, at most eight recurring concepts of 1–120 characters, and a 4 KB serialized context-profile ceiling. Require non-empty theme/participants/setting/tone; allow empty `culturalContext` and an empty recurring-concepts array. Treat the design's 300–600-character context target as a prompt target, not a rejection minimum.

`normalizeLearningFieldsForFullSync` must preserve unrelated/unknown `analysisJson` keys. With neither new field it removes any orphan stamp and accepts the old payload unchanged. With both fields it validates, replaces any client `generatedAt`/stamp with server values, and stamps the current fingerprint. With only one field, malformed fields, or model-only extra keys it throws a typed validation error for a route-level 400.

- [ ] **Step 4: Run focused and type tests, then commit**

```powershell
npm test -- tests/video-learning-guide.test.ts
npm run typecheck
git add src/lib/videoLearningGuide.ts src/lib/types.ts tests/video-learning-guide.test.ts
git commit -m 'feat: define video learning guide contract'
```

### Task 3: Extend managed summary prompt, parser, and worker assembly

**Files:**
- Modify: `whatsub-license/src/lib/mobileAnalysisPrompts.ts`
- Modify: `whatsub-license/src/lib/mobileAnalysisParser.ts`
- Modify: `whatsub-license/src/lib/mobileAnalysisWorker.ts`
- Modify: `whatsub-license/tests/mobile-analysis-parser.test.ts`
- Modify: `whatsub-license/tests/mobile-analysis-worker.test.ts`

**Interfaces:**
- Changes: `ParsedAnalysisSummary` includes `learningGuide` and `contextProfile`
- Changes: `assembleLibraryAnalysis(...)` returns all new fields with server-owned `generatedAt` and fingerprint stamp

- [ ] **Step 1: Add failing parser and worker tests**

```ts
const validContextProfile = {
  theme: '委婉沟通与分歧处理',
  participants: '采访者与演员',
  setting: '轻松访谈',
  tone: '自然、友好并带有幽默感',
  culturalContext: '',
  recurringConcepts: ['先认可对方观点', '再表达不同意见'],
};

const validGuideDraft = {
  verdict: 'select_segments',
  overview: '这段访谈通过自然对话展示人物如何先认可对方观点，再用缓和语气委婉表达不同意见，并维持轻松友好的交流氛围。',
  contentOutline: ['先说明讨论背景和人物关系', '再展示缓和分歧的自然表达'],
  cefrLevel: 'B2',
  cefrReason: '语速自然，并包含需要结合语气理解的委婉表达。',
  recommendedFor: ['能理解日常对话、希望提升真实会话理解的学习者'],
  learningReasons: ['包含可直接迁移到讨论场景的表达和语气策略'],
  cultureNotes: [],
  studyTips: ['先盲听，再跟读推荐片段并模仿停顿和重音'],
  topSegments: [{
    startTime: 10, endTime: 14, title: '委婉认同',
    reason: '展示先认可对方观点、再补充自己立场的自然方式。',
    focusExpressions: ['see your point'],
  }],
};

it('parses the complete score-free summary envelope', () => {
  const parsed = parseSummaryJsonLine(JSON.stringify({
    type: 'summary', keyPhrases: [],
    learningGuide: validGuideDraft,
    contextProfile: validContextProfile,
  }), { summaryDurationSec: 20, summaryCueBounds: [{ start: 10, end: 14 }] });
  expect(parsed.learningGuide.verdict).toBe('select_segments');
  expect(parsed.contextProfile.theme).toBe('委婉沟通与分歧处理');
});

it('assembles a stamped guide into the finalized Library analysis', async () => {
  const db = makeDb();
  const finalizable = await seedFinalizableJob(db, 'guide-finalize@example.com');
  const worker = workerFor(db, new FakeGateway([]));
  await expect(worker.runOne('worker-finalize', 1_001)).resolves.toBe('worked');
  const entry = await db.getLibraryEntry(finalizable.id, 'guide-finalize@example.com');
  const analysis = entry!.analysisJson as Record<string, any>;
  expect(analysis.learningGuideSourceFingerprint).toMatch(/^[a-f0-9]{64}$/);
  expect(analysis.learningGuide.generatedAt).toBeGreaterThan(0);
});
```

Extend the existing `summarySse()` and `seedFinalizableJob()` fixture summaries with the exact `validGuideDraft` and `validContextProfile` objects above; extend `FinalizableJob['summary']` to the new complete summary type. Do not create a second worker harness.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `npm test -- tests/mobile-analysis-parser.test.ts tests/mobile-analysis-worker.test.ts`

Expected: FAIL because the existing summary parser only accepts `type` and `keyPhrases`.

- [ ] **Step 3: Extend prompt and strict summary parsing**

Update the prompt's exact schema to include the two draft objects, explicitly forbid all numeric ratings, require timestamp evidence, and permit empty culture fields. Add `index`, `time`, and `endTime` to every compact summary cue; without them the model cannot produce evidence-based `topSegments`. Delegate nested validation to Task 2 functions rather than duplicating limits.

- [ ] **Step 4: Stamp finalized managed analyses**

Pass job title, duration, validated subtitles, and the worker clock into `stampLearningGuide(...)`. Store the complete validated summary in the existing durable summary batch so a finalization retry does not call the model again. Preserve the existing behavior where summary failure leaves usable cue batches and a lazy-generation path.

- [ ] **Step 5: Run tests and commit**

```powershell
npm test -- tests/mobile-analysis-parser.test.ts tests/mobile-analysis-worker.test.ts
npm run typecheck
git add src/lib/mobileAnalysisPrompts.ts src/lib/mobileAnalysisParser.ts src/lib/mobileAnalysisWorker.ts tests/mobile-analysis-parser.test.ts tests/mobile-analysis-worker.test.ts
git commit -m 'feat: generate learning guide in managed summary'
```

### Task 4: Add backend detail fingerprint and stale-safe guide persistence

**Files:**
- Modify: `whatsub-license/src/lib/db.ts`
- Modify: `whatsub-license/src/routes/library.ts`
- Modify: `whatsub-license/tests/library-db.test.ts`
- Modify: `whatsub-license/tests/library-routes.test.ts`

**Interfaces:**
- Produces: `Database.updateLibraryLearningGuide(input)` with id, owner, expected fingerprint, draft/profile, and server time
- Changes: `POST /api/library/sync` validates and server-stamps an included guide/profile pair while preserving old payloads
- Changes: `GET /api/library/entry/:id` adds `analysisFingerprint` and omits mismatched derived fields
- Produces: `PATCH /api/library/entry/:id/learning-guide`

- [ ] **Step 1: Write failing DB and route tests**

```ts
it('rejects a guide write after subtitle analysis changes', async () => {
  const { db } = makeDb();
  const originalCues = [{
    index: 0, time: 10, endTime: 14, text: 'I see your point.', translation: '我明白你的意思。',
    isKeyPoint: true, highlightWords: ['see your point'],
    keyNotes: { 'see your point': '表示理解对方观点。' },
    highlightTranslations: { 'see your point': '明白你的意思' },
  }];
  await db.upsertLibraryEntry(sampleInput({
    id: 'entry', title: 'Title', analysisJson: { subtitles: originalCues, keyPhrases: [] },
  }));
  const fingerprint = analysisFingerprint('Title', originalCues);
  await db.updateLibraryEntryCues(
    'entry', 'alice@example.com',
    { subtitles: [{ ...originalCues[0], translation: '我懂你的看法。' }], keyPhrases: [] },
    '1\n00:00:10,000 --> 00:00:14,000\nI see your point.\n', 2_000,
  );
  await expect(db.updateLibraryLearningGuide({
    id: 'entry', ownerEmail: 'alice@example.com', expectedFingerprint: fingerprint,
    guide: validGuideDraft, profile: validContextProfile, now: 3_000,
  })).resolves.toEqual({ status: 'analysis_changed' });
});

it('patches only owned derived fields', async () => {
  const rig = makeApp();
  const token = await insertSessionFor(rig.db, 'alice@example.com');
  const sync = await rig.app.request('/api/library/sync', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify({
      ...VALID_BODY, id: 'entry', title: 'Title',
      analysisJson: { subtitles: originalCues, keyPhrases: [] },
    }),
  });
  expect(sync.status).toBe(200);
  const detail = await rig.app.request('/api/library/entry/entry', {
    headers: { authorization: `Bearer ${token}` },
  });
  const currentFingerprint = ((await detail.json()) as { analysisFingerprint: string }).analysisFingerprint;
  const response = await rig.app.request('/api/library/entry/entry/learning-guide', {
    method: 'PATCH', body: JSON.stringify({
      expectedAnalysisFingerprint: currentFingerprint,
      learningGuide: validGuideDraft,
      contextProfile: validContextProfile,
    }),
    headers: { 'Content-Type': 'application/json', authorization: `Bearer ${token}` },
  });
  expect(response.status).toBe(200);
  const stored = await rig.db.getLibraryEntry('entry', 'alice@example.com');
  expect((stored!.analysisJson as any).subtitles).toEqual(originalCues);
});
```

Copy the exact Task 3 `validGuideDraft`/`validContextProfile` constants into the top-level fixture section of both owning test files; place `originalCues` once in each file rather than redeclaring it inside individual cases. Add route cases for 401, another owner's 404, malformed payload 400, stale 409 `analysis_changed`, and out-of-range segment 400. Add `/sync` cases proving old `{subtitles,keyPhrases}` payloads still pass, a complete guide/profile is server-stamped, a client `generatedAt`/stamp is ignored, and a partial/invalid pair returns 400.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `npm test -- tests/library-db.test.ts tests/library-routes.test.ts`

Expected: FAIL because the DB method, fingerprint response, and route do not exist.

- [ ] **Step 3: Implement transactional stale protection**

Lock the owned Library row, compute the current fingerprint from title and stored subtitles, compare it with `expectedAnalysisFingerprint`, and update only:

```ts
analysisJson.learningGuide = { ...validatedGuide, generatedAt: now };
analysisJson.contextProfile = validatedProfile;
analysisJson.learningGuideSourceFingerprint = currentFingerprint;
```

Return discriminated statuses `updated | not_found | analysis_changed`. Never accept a client-provided stamp or `generatedAt`.

Before the existing `/sync` upsert, call `normalizeLearningFieldsForFullSync`. If no guide/profile is present, retain the old payload shape. If both are present, validate against submitted cues and `durationSec ?? maxCueEnd`, then replace client-owned metadata with the route clock's `generatedAt` and canonical fingerprint. Map typed validation failure to `{ error: 'invalid_learning_guide' }` with HTTP 400 and do not log the payload.

- [ ] **Step 4: Filter stale fields on detail reads**

Compute `analysisFingerprint` for every detail response. If the stored stamp differs, return the original subtitles/key phrases while omitting `learningGuide`, `contextProfile`, and the stale stamp.

- [ ] **Step 5: Run backend suite and commit**

```powershell
npm test -- tests/video-learning-guide.test.ts tests/mobile-analysis-parser.test.ts tests/mobile-analysis-worker.test.ts tests/library-db.test.ts tests/library-routes.test.ts
npm run typecheck
git add src/lib/db.ts src/routes/library.ts tests/library-db.test.ts tests/library-routes.test.ts
git commit -m 'feat: persist learning guides with stale-write protection'
```

### Task 5: Add iOS models, strict parsing, bounded summary generation, and API

**Files:**
- Create: `whatsub-mobile/Library/VideoLearningModels.swift`
- Create: `whatsub-mobile/LLM/VideoLearningParser.swift`
- Create: `whatsub-mobileTests/VideoLearningModelsTests.swift`
- Modify: `whatsub-mobile/Networking/DTOs.swift`
- Modify: `whatsub-mobile/Networking/WhatsubAPI.swift`
- Modify: `whatsub-mobile/LLM/AnalysisPrompts.swift`
- Modify: `whatsub-mobile/LLM/AnalysisEngine.swift`
- Modify: `whatsub-mobile/Import/AnalysisCheckpointStore.swift`
- Modify: `whatsub-mobile/Import/ImportViewModel.swift`
- Modify: `whatsub-mobileTests/AnalysisDecodeTests.swift`
- Modify: `whatsub-mobileTests/AnalysisEngineTests.swift`
- Modify: `whatsub-mobileTests/AnalysisCheckpointStoreTests.swift`
- Modify: `whatsub-mobileTests/ImportBYOKResumeTests.swift`

**Interfaces:**
- Produces: `LearningGuide`, `LearningGuideDraft`, `VideoContextProfile`, `RecommendedSegment`, `DeepGlossResult`
- Produces: `AnalysisSummary` containing `keyPhrases`, `learningGuide`, and `contextProfile`
- Produces: `VideoLearningParser.parseSummary(_:, durationSec:, cues:)`
- Produces: `AnalysisPrompts.boundedSummaryMessages(_:maxCharacters:)`, with compact cues retaining index/start/end
- Produces: `WhatsubAPI.updateLearningGuide(id:expectedFingerprint:guide:profile:token:)`
- Changes: `LibraryEntryDetail.analysisFingerprint: String` (custom decode defaults to empty only for a transitional old backend; generation is disabled until refresh returns a non-empty server fingerprint)
- Changes: BYOK checkpoints persist/resume the complete `AnalysisSummary`, with legacy `[KeyPhrase]` checkpoint decoding

- [ ] **Step 1: Write failing decode/parser/bounding tests**

```swift
func testOldAnalysisDecodesWithoutGuide() throws {
    let result = try JSONDecoder().decode(AnalysisJson.self, from: oldAnalysisJSON)
    XCTAssertNil(result.learningGuide)
    XCTAssertNil(result.contextProfile)
}

func testSummaryRejectsNumericScore() {
    XCTAssertThrowsError(try VideoLearningParser.parseSummary(
        scoredSummaryJSON, durationSec: 60, cues: cues
    ))
}

func testBoundedSummaryPreservesFirstAndLastCue() {
    let messages = try! AnalysisPrompts.boundedSummaryMessages(manyCues, maxCharacters: 20_000)
    let serialized = try! JSONSerialization.data(withJSONObject: messages.map {
        ["role": $0.role, "content": $0.content]
    })
    let text = String(decoding: serialized, as: UTF8.self)
    XCTAssertTrue(text.contains(manyCues.first!.text))
    XCTAssertTrue(text.contains(manyCues.last!.text))
    XCTAssertLessThanOrEqual(text.count, 20_000)
}

func testLegacyCheckpointSummaryArrayStillResumes() throws {
    let checkpoint = try JSONDecoder().decode(AnalysisCheckpoint.self, from: legacyVersionOneJSON)
    XCTAssertEqual(checkpoint.completedSummary?.keyPhrases.first?.expression, "save up")
    XCTAssertNil(checkpoint.completedSummary?.learningGuide)
}
```

Define `oldAnalysisJSON`, `scoredSummaryJSON`, and `legacyVersionOneJSON` as UTF-8 `Data` constants in their owning test classes. Build `manyCues` with at least 30 complete cues whose text is 2,000 characters each, ensuring the 20,000-character test actually exercises sampling. `legacyVersionOneJSON` must match the current version-1 on-disk shape where `completedSummary` is a raw array, so the test protects already-paid BYOK work from being discarded.

- [ ] **Step 2: Push the failing mobile tests and verify RED in macOS CI**

```powershell
git add whatsub-mobileTests/VideoLearningModelsTests.swift whatsub-mobileTests/AnalysisDecodeTests.swift whatsub-mobileTests/AnalysisEngineTests.swift whatsub-mobileTests/AnalysisCheckpointStoreTests.swift whatsub-mobileTests/ImportBYOKResumeTests.swift
git commit -m 'test: define video learning data contract'
git push origin codex/video-learning-guide
```

Expected CI failure: missing `VideoLearningParser`, new model fields, and bounded summary function.

- [ ] **Step 3: Implement Codable models and strict parser**

Use string-backed enums for verdict and CEFR. Decode the three `AnalysisJson` fields with `decodeIfPresent`. Keep the existing old payload initializers working by defaulting new assembled parameters to nil. `LearningGuideDraft` excludes `generatedAt`; `LearningGuide` includes it. `AnalysisSummary` decodes either the new object or the legacy checkpoint's `[KeyPhrase]` single value.

- [ ] **Step 4: Implement bounded prompt and AnalysisEngine assembly**

Add deterministic complete-cue uniform sampling to the 120,000-character serialized-message ceiling. Parse one envelope into key phrases, guide draft, and profile. For the local preview/checkpoint, assemble a `LearningGuide` with the local completion time; `/sync` remains authoritative and replaces that timestamp and stamp before storage. Managed server results decode the persisted model directly.

Change `AnalysisResumeContext.completedSummary`, `onSummaryCompleted`, `AnalysisCheckpoint.completedSummary`, and `recordSummary` from `[KeyPhrase]` to `AnalysisSummary`. Update both `ImportViewModel` resume call sites. Preserve the current checkpoint schema field names and custom-decode a legacy summary array into `AnalysisSummary(keyPhrases: ..., learningGuide: nil, contextProfile: nil)` rather than invalidating it or repeating a paid model call.

- [ ] **Step 5: Implement the narrow PATCH client and run green CI**

```swift
func updateLearningGuide(
    id: String,
    expectedFingerprint: String,
    guide: LearningGuideDraft,
    profile: VideoContextProfile,
    token: String
) async throws -> LearningGuideUpdateResponse
```

Also extend `syncLibraryEntry`'s manual JSON dictionary to send `learningGuide` and `contextProfile` when present, but never send `learningGuideSourceFingerprint`; the backend owns the stamp. Extend `updateLibraryEntryCues` to preserve neither derived field nor stamp, intentionally invalidating them after edits. Commit production files, push, and verify the full mobile CI succeeds.

```powershell
git add whatsub-mobile whatsub-mobileTests
git commit -m 'feat: add video learning guide data pipeline'
git push origin codex/video-learning-guide
```

### Task 6: Implement lazy guide generation and the collapsible guide card

**Files:**
- Create: `whatsub-mobile/Library/VideoLearningGuideService.swift`
- Create: `whatsub-mobile/Library/VideoLearningGuideCard.swift`
- Create: `whatsub-mobileTests/VideoLearningGuideServiceTests.swift`
- Create: `whatsub-mobileTests/VideoLearningGuidePresentationTests.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailViewModel.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`

**Interfaces:**
- Produces: `LearningGuidePersisting` protocol and `VideoLearningGuideService.generate(entry:settings:token:)`
- Produces: injectable `VideoLearningGuideService.SummaryProvider`
- Produces VM state: `guidePhase`, `guideExpanded`, `generateGuide`, `selectRecommendedSegment`
- Produces: `VideoLearningGuideCard`

- [ ] **Step 1: Write failing service and presentation tests**

```swift
func testLazyGenerationUsesCurrentFingerprintAndPersistsOnce() async throws {
    let api = LearningGuideAPISpy(response: .accepted(
        guide: makeGuide(verdict: .selectSegments), profile: profile, fingerprint: "f1"
    ))
    let llm = SummaryProviderSpy(summary: AnalysisSummary(keyPhrases: [], learningGuide: draft, contextProfile: profile))
    let service = VideoLearningGuideService(api: api, summaryProvider: llm.call)
    let result = try await service.generate(
        entry: makeEntry(fingerprint: "f1"), settings: LlmSettings(), token: "token"
    )
    XCTAssertEqual(await api.expectedFingerprints, ["f1"])
    XCTAssertEqual(await llm.callCount, 1)
    XCTAssertEqual(result.guide.verdict, .selectSegments)
}

func testCardPresentationContainsNoScore() {
    let presentation = VideoLearningGuidePresentation(guide: makeGuide(verdict: .selectSegments))
    XCTAssertEqual(presentation.verdictText, "建议挑选重点片段")
    XCTAssertFalse(presentation.allVisibleText.contains("/10"))
    XCTAssertFalse(presentation.allVisibleText.contains("评分"))
}
```

Define `LearningGuideAPISpy` and `SummaryProviderSpy` as test-local actors with only the counters/results shown above; define `makeEntry`, `makeGuide`, `draft`, and `profile` once in the test fixture section. Also test single-flight, cancellation, 403, 409 refresh-required, and inline retry.

- [ ] **Step 2: Verify RED through mobile CI**

```powershell
git add whatsub-mobileTests/VideoLearningGuideServiceTests.swift whatsub-mobileTests/VideoLearningGuidePresentationTests.swift
git commit -m 'test: define video learning guide behavior'
git push origin codex/video-learning-guide
```

Expected: missing service/presentation types.

- [ ] **Step 3: Implement lazy generation service and VM state**

Use `ChatCompletionsClient` with current relay/BYOK settings, `AnalysisPrompts.boundedSummaryMessages`, strict parsing, then the Task 5 PATCH. The production initializer wraps that work in the injected `SummaryProvider`; tests never make network calls. Do not mutate the displayed entry until the PATCH response succeeds. On success, apply the PATCH response to `entry.analysisJson` through a pure `LibraryEntryDetail.applyingLearningGuide(_:)` copy helper; on 409 reload detail before exposing retry.

- [ ] **Step 4: Implement the Bilibili-style collapsible card**

Collapsed content is verdict + CEFR + one-line overview. Expanded content follows the exact approved section order. Missing old data shows `生成视频学习导览`; loading and error states remain inline.

- [ ] **Step 5: Wire segment selection and commit**

On segment selection set the detail tab to subtitles, collapse the card, call `seekTo(seconds:)`, and let the existing current-cue scroll path resolve the nearest cue.

```powershell
git add whatsub-mobile/Library whatsub-mobileTests
git commit -m 'feat: add collapsible video learning guide'
git push origin codex/video-learning-guide
```

Verify this branch run is green before starting the deep-gloss task.

### Task 7: Implement deep-gloss prompt, strict parser, and 200-entry LRU cache

**Files:**
- Create: `whatsub-mobile/Library/DeepGlossPrompt.swift`
- Create: `whatsub-mobile/Library/DeepGlossParser.swift`
- Create: `whatsub-mobile/Library/DeepGlossCache.swift`
- Create: `whatsub-mobile/Library/DeepGlossViewModel.swift`
- Create: `whatsub-mobileTests/DeepGlossTests.swift`
- Modify: `whatsub-mobile/Library/GlossSheet.swift`
- Modify: `whatsub-mobile/Library/HighlightWordCardModel.swift`
- Modify: `whatsub-mobileTests/HighlightWordCardModelTests.swift`

**Interfaces:**
- Produces: `DeepGlossPrompt.build(context:) -> DeepGlossPromptPayload` (`messages` + `includedCueIndexes`)
- Produces: `DeepGlossParser.parse(_:)`
- Produces: `DeepGlossCache.value/store` keyed by fingerprint + cue anchor + normalized expression
- Produces: `DeepGlossViewModel.load(...)`, `phase`, and structured result
- Changes: `WordGloss.SourceContext` carries title, fingerprint, optional profile, all displayed cues, and current cue index
- Changes: `WordGloss.CollectionState` is `collectable(SaveContext) | alreadyCollected | unavailable`
- Changes: `GlossSheet` accepts an optional async `ensureProfile` closure supplied by `LibraryDetailView`

- [ ] **Step 1: Write failing prompt, parser, and cache tests**

```swift
func testPromptUsesAtMostNineCues() {
    let cues = (0..<30).map { makeCue(index: $0, text: "cue-\($0)") }
    let context = DeepGlossContext(
        title: "Interview", profile: profile, expression: "see your point",
        quickTranslation: "明白你的意思", quickNote: "表示理解对方观点。",
        cues: cues, currentCueIndex: 15
    )
    let payload = DeepGlossPrompt.build(context: context)
    XCTAssertEqual(payload.includedCueIndexes, Array(11...19))
    XCTAssertFalse(payload.messages.map(\.content).joined().contains("cue-0"))
}

func testFingerprintChangeMissesCache() async throws {
    await cache.store(result, fingerprint: "old", cueAnchor: "15", expression: "see your point")
    XCTAssertNil(await cache.value(fingerprint: "new", cueAnchor: "15", expression: "see your point"))
}

func testCacheEvictsLeastRecentlyUsedPastTwoHundred() async throws {
    for index in 0..<201 {
        await cache.store(result, fingerprint: "f", cueAnchor: "\(index)", expression: "p\(index)")
    }
    XCTAssertNil(await cache.value(fingerprint: "f", cueAnchor: "0", expression: "p0"))
}
```

Define `makeCue`, `profile`, and `result` once in `DeepGlossTests`. Add parser tests for empty optional culture/slang/warning, extra keys, oversized fields, more than five alternatives, and a serialized result over 4 KB.

- [ ] **Step 2: Verify RED through mobile CI**

```powershell
git add whatsub-mobileTests/DeepGlossTests.swift whatsub-mobileTests/HighlightWordCardModelTests.swift
git commit -m 'test: define contextual deep gloss behavior'
git push origin codex/video-learning-guide
```

Expected: missing prompt/cache/view-model types.

- [ ] **Step 3: Implement prompt, parser, and atomic cache persistence**

Implement `DeepGlossCache` as an actor. Store `deep_gloss_cache.json` under Caches, cap at 200 LRU entries, normalize expressions with trim + whitespace collapse + locale-independent lowercase, recover from corrupt JSON by replacing it with an empty cache, write atomically, and never throw cache-write errors into the UI.

- [ ] **Step 4: Implement two-stage old-video flow**

When profile is absent, `DeepGlossViewModel` invokes `GlossSheet.ensureProfile`; `LibraryDetailView` implements that closure by awaiting the Task 6 view-model single-flight generator, so the card and gloss never launch duplicate full-summary requests and the accepted profile is written back to `vm.entry`. Show phase text `正在准备视频语境…`, then make the nine-cue explanation request with `正在深度解读…`. Inject a `DeepGlossProvider` closure for tests and wrap `ChatCompletionsClient` only in the production initializer. On a 409 refresh, stop before gloss generation and expose explicit retry against the refreshed entry. Cache only strictly parsed success.

- [ ] **Step 5: Expand the shared GlossSheet and commit**

Replace `WordGloss.saveContext` with `WordGloss.CollectionState` (`collectable(SaveContext)`, `alreadyCollected`, `unavailable`) and update `HighlightWordCardModel.canCollect/collect`. Keep pronunciation, IPA, quick note, and collection control visible. Add `深度解读`, programmatically select `.large`, omit empty result sections, and retain quick content with an inline retry on error.

```powershell
git add whatsub-mobile/Library whatsub-mobileTests/DeepGlossTests.swift whatsub-mobileTests/HighlightWordCardModelTests.swift
git commit -m 'feat: add contextual deep expression explanations'
git push origin codex/video-learning-guide
```

Verify the branch is green before changing Collections interactions.

### Task 8: Reuse deep gloss from the Collections tab without losing seek

**Files:**
- Modify: `whatsub-mobile/Library/EntryCollectionsList.swift`
- Modify: `whatsub-mobile/Library/LibraryDetailView.swift`
- Modify: `whatsub-mobile/Library/GlossSheet.swift`
- Create: `whatsub-mobileTests/EntryCollectionsInteractionTests.swift`

**Interfaces:**
- Produces: `CollectionGlossSelection` carrying phrase, meaning, usage note, context sentence, timestamp, and collected state
- Produces: pure `EntryCollectionRowInteraction.action(for:timestamp:)`
- Changes: `EntryCollectionsList` accepts `onTapGloss` separately from `onTapPhrase`

- [ ] **Step 1: Write failing interaction tests**

```swift
func testPhraseBodyOpensCollectedGlossWhileTimestampSeeks() {
    XCTAssertEqual(EntryCollectionRowInteraction.action(for: .body, timestamp: 42), .openGloss)
    XCTAssertEqual(EntryCollectionRowInteraction.action(for: .timestamp, timestamp: 42), .seek(42))
    let selection = CollectionGlossSelection(
        phrase: "see your point", meaning: "明白你的意思", usageNote: "表示理解对方观点。",
        contextSentence: "I see your point.", timestamp: 42, collectionState: .alreadyCollected
    )
    XCTAssertEqual(selection.collectionState, .alreadyCollected)
}

func testCollectedGlossCannotCreatePendingDuplicate() {
    let gloss = WordGloss(
        word: "see your point", translation: "明白你的意思", note: "表示理解对方观点。",
        sourceContext: nil, collectionState: .alreadyCollected
    )
    let model = HighlightWordCardModel(gloss: gloss)
    XCTAssertFalse(model.canCollect)
    XCTAssertFalse(model.collect())
}
```

- [ ] **Step 2: Verify RED through mobile CI**

```powershell
git add whatsub-mobileTests/EntryCollectionsInteractionTests.swift
git commit -m 'test: define collection explanation interactions'
git push origin codex/video-learning-guide
```

Expected: missing typed selection, split actions, and collection state.

- [ ] **Step 3: Split row hit targets and route selection to the parent**

Make the timestamp a dedicated seek button that uses `.seek(timestamp)`. Make phrase/meaning content use `.openGloss` even when a timestamp is unavailable. Leave the cloud-upload rail unchanged. Pending and synced rows both build `CollectionGlossSelection`; both are `alreadyCollected` because either local pending or cloud storage already contains the phrase.

- [ ] **Step 4: Reuse parent playback pause and GlossSheet**

`LibraryDetailView` pauses AVPlayer/YouTube, resolves the nearest cue around the row timestamp, creates the same `WordGloss` with the entry fingerprint/profile and cue window, and presents the existing sheet with `.alreadyCollected`.

- [ ] **Step 5: Run full branch CI and commit**

```powershell
git add whatsub-mobile/Library whatsub-mobileTests
git commit -m 'feat: explain expressions from video collections'
git push origin codex/video-learning-guide
```

Expected: complete simulator build, all unit tests, app installation, screenshot, and artifact upload succeed.

### Task 9: Cross-repository verification, review, and release handoff

**Files:**
- Modify: `whatsub-license/AGENTS.md`
- Modify: `whatsub-mobile/README.md`

**Interfaces:**
- Consumes: all prior tasks
- Produces: verified backend and mobile branches ready for integration

- [ ] **Step 1: Perform focused contract and code review**

Compare backend TypeScript and iOS Swift field names, verdict/CEFR enum values, string/array ceilings, timestamp rules, summary envelope, fingerprint response, and PATCH body line by line. Review the diff for payload logging, stale-write bypasses, duplicate generation, and playback regressions. Fix every mismatch with a failing test before editing production code.

- [ ] **Step 2: Document and commit the final contract**

Add one concise architecture section to backend `AGENTS.md` covering the full-sync stamp, detail fingerprint, stale filtering, and PATCH contract. Add one feature section to mobile `README.md` covering the collapsible guide, lazy generation, nine-cue deep gloss, cache, and Collections behavior. State explicitly that there is no numeric score and no new entitlement gate.

```powershell
git -C 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-license\.worktrees\video-learning-guide' add AGENTS.md
git -C 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-license\.worktrees\video-learning-guide' commit -m 'docs: document video learning guide contract'
git -C 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-mobile\.worktrees\video-learning-guide' add README.md
git -C 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-mobile\.worktrees\video-learning-guide' commit -m 'docs: document video learning guide experience'
```

- [ ] **Step 3: Run fresh backend verification**

```powershell
cd 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-license\.worktrees\video-learning-guide'
npm test
npm run typecheck
npm run build
git diff --check
```

- [ ] **Step 4: Push both final branch heads**

```powershell
git -C 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-license\.worktrees\video-learning-guide' push -u origin codex/video-learning-guide
git -C 'C:\Users\Jimmy Spector\Desktop\whatsub\whatsub-mobile\.worktrees\video-learning-guide' push -u origin codex/video-learning-guide
```

- [ ] **Step 5: Verify mobile CI at the exact final HEAD**

Use `gh run list --workflow ci.yml --branch codex/video-learning-guide` and confirm the successful run's `headSha` equals `git rev-parse HEAD`. Inspect the unit-test/build steps and screenshot artifact; a success from an earlier pre-documentation SHA does not count.

- [ ] **Step 6: Request integration choice and perform approved release**

Present the verified branches for merge. After merge approval, deploy backend first using the repository's documented release procedure, verify production health and one backward-compatible detail response, then push/trigger the iOS TestFlight workflow and wait for upload success.
