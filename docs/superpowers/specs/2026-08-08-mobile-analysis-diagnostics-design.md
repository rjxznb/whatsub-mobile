# Mobile AI Analysis Diagnostics Design

## Goal

Ship a temporary-but-safe diagnostic surface that makes the two production failures actionable from a user screenshot:

1. Managed analysis rejects every job before persistence with HTTP 400.
2. BYOK analysis can remain at zero analyzed cues without presenting an error.

The diagnostic build must not expose or persist subtitle text, API keys, bearer tokens, complete request bodies, or complete source URLs.

## Recommended architecture

Use correlated diagnostics on both sides of the managed-analysis request and explicit lifecycle instrumentation around the BYOK stream.

The iOS client produces a short diagnostic report only after an error or a no-progress timeout. The backend returns a stable, field-level validation reason and logs the same reason with a generated diagnostic ID. A screenshot or copied report is therefore sufficient to identify whether the request failed on duration, cue shape, thumbnail, URL identity, or another bounded validation rule.

## Managed-analysis diagnostics

### Backend

Refactor request validation to return a private structured reason in addition to the existing public policy code. Examples:

- `invalid_source_url`
- `invalid_thumbnail`
- `invalid_cue_index`
- `invalid_cue_timing`
- `cue_end_after_duration`
- `invalid_transcript`

For HTTP 400 validation failures, return:

```json
{
  "error": "invalid_input",
  "diagnosticCode": "cue_end_after_duration",
  "diagnosticId": "short-random-id"
}
```

The server log records the diagnostic ID, code, authenticated account hash, cue count, declared duration, final cue end time, encoded body size, and thumbnail byte count. It must not record email, subtitle text, API credentials, session token, full source URL, or request JSON.

Public policy responses and successful job responses retain their current wire behavior. Older clients continue to understand the top-level `error` field.

### iOS

Extend `ManagedAnalysisClientError.server` to retain `diagnosticCode` and `diagnosticId`. On managed submission failure, display the normal Chinese error plus a collapsible/copyable diagnostic block containing:

- HTTP status and server error code
- diagnostic code and diagnostic ID, when present
- video ID only
- declared duration
- cue count and final cue end time
- encoded request byte count
- decoded thumbnail byte count, or `none`

The report excludes title, subtitle text, API key, bearer token, full URL, and request body.

## BYOK diagnostics

Introduce a small analysis lifecycle tracker with these stages:

- `preparing_request`
- `connecting`
- `response_open`
- `first_content`
- `parsing`
- `batch_complete`

`ChatCompletionsClient.streamChat` emits lifecycle events without changing its data stream. `AnalysisEngine` reports when parsed cue count advances. `ImportViewModel` stores only the latest safe stage, elapsed seconds, provider host, model name, batch number, and parsed cue count.

If the first batch remains at zero parsed cues for 90 seconds, the client stops waiting and presents an actionable timeout instead of spinning indefinitely. The report distinguishes:

- no HTTP response (`connecting`)
- HTTP/SSE opened but no content (`response_open`)
- content arrived but yielded no valid JSON cue (`first_content`)

The report must never contain streamed model output, prompts, API keys, or authorization headers.

## User interface

Normal successful imports do not show diagnostics. Error screens and the 90-second BYOK timeout show a secondary `复制诊断信息` button. The copied text begins with the app build/version and one stable category (`managed-submit` or `byok-stream`) so it can be pasted directly into a support conversation.

Diagnostic details are selectable monospaced text in a sheet. This avoids making the primary error screen dense while still allowing a screenshot.

## Testing

Backend tests cover every new validation reason, verify the response correlation fields, and assert that the safe log payload contains no sensitive values.

iOS tests cover:

- decoding and presenting managed diagnostic fields;
- request-summary calculations without sensitive fields;
- BYOK lifecycle transitions;
- the 90-second no-progress timeout for each relevant stage;
- successful progress cancelling the timeout;
- copied reports excluding subtitle text, API key, bearer token, and full URL.

CI remains the authority for Swift compilation and simulator tests because the local Windows environment has no Xcode. Backend tests run locally before deployment. TestFlight is published only after backend deployment and both repository checks succeed.

## Rollout

1. Deploy the backward-compatible backend diagnostic response and logging.
2. Push the iOS diagnostic build and wait for CI and TestFlight upload success.
3. Reproduce one managed and one BYOK failure, then use the returned reports to implement the actual fixes.
4. Keep the safe diagnostic codes as support tooling, but remove or reduce any temporary UI verbosity after both root causes are fixed.
