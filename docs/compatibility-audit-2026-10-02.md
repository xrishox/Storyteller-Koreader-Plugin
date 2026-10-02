# Storyteller v3 beta / SimpleUI compatibility audit

Audited 2026-10-02. Result: the existing **v2 HTTP endpoints remain the correct API for Storyteller v3 beta**. No deprecated or removed endpoint was found among the plugin's requests. This update fixes client behavior and data handling; changing these URLs to `/api/v3` would break the integration.

## Baseline and scope

- Storyteller `web-v3.0.0-beta.46`, commit [`5938df3cf96427e5a0ebe9554e559378123d3d18`](https://gitlab.com/storyteller-platform/storyteller/-/tree/5938df3cf96427e5a0ebe9554e559378123d3d18). Source checkout lives outside both plugin repositories, in `/tmp/storyteller-api-audit-beta46`.
- SimpleUI fork `v2.7.1-storyteller.1`, commit `ab5e2dd1e700394f7e09bed1bba5cb5d9f005d52`. Actual `screens/sui_storyteller.lua` exercised by the tests. The 1.0.11-alpha update adds a small optional background-loading adapter to that screen; existing synchronous API calls remain compatible.
- KOReader KindleHF `v2026.07.2`, using the source files from the package installed on the Kindle Colorsoft. Reviewed plugin initialization, menu/dispatcher events, reader lifecycle, LuaSettings/DocSettings, socketutil, document content/XPointer and reader progress methods.
- All plugin Lua modules reviewed: authentication/configuration, transport/API, both browser contracts, downloads/sidecars, EPUB/locator conversion, sync, logging and initialization.
- Release version: `1.1.0-alpha`, incorporating the audit and the follow-up changes tested locally as `1.0.10-alpha` and `1.0.11-alpha`. The optional SimpleUI adapter is supplied as [a patch](simpleui-background-loading.patch); it is not installed automatically by the companion.

This is source review plus regression and local HTTP contract testing. It is **not** an end-to-end run against the user's authenticated Storyteller deployment, a running Storyteller server, or the Kindle reader process.

## Endpoint contracts

All paths below are prefixed by `/api/v2`. The authoritative implementations are under [`applications/web/src/app/api/v2`](https://gitlab.com/storyteller-platform/storyteller/-/tree/5938df3cf96427e5a0ebe9554e559378123d3d18/applications/web/src/app/api/v2).

| Operation | Current contract | Audit result |
| --- | --- | --- |
| `POST /device/start` | No credentials; returns device/user codes, verification URI, interval and expiry in seconds | Correct device authorization flow retained |
| `POST /device/token` | JSON `{device_code}`; 400 pending/slow_down/expired_token/access_denied errors | Poll handling retained; server identity guarded; minimum interval enforced |
| `GET /user` | Bearer token; returns user `id` and profile | Token verified before saving user identity |
| `GET /books` | Array of books, optional query limit; no mandatory pagination | Correct list format; JSON null normalized for both browsers |
| `GET /collections`, `GET /series` | Arrays scoped to the user | Existing relation UUIDs and series positions remain compatible |
| `GET /books/:id` | Book and format relations; 404 when unavailable | Checks local asset UUID/updatedAt against current server relation |
| `GET /books/:id/files?format=ebook\|readaloud` | Full EPUB 200; explicit range requests can return 206; SHA-256 in `X-Storyteller-Hash` | Full downloads only; bytes, length, sink completion and checksum verified |
| `GET /books/:id/positions` | `{locator,timestamp}`; 404 when no position exists | Correct missing-position handling |
| `POST /books/:id/positions` | JSON locator and Unix timestamp in milliseconds; 204 success; 409 conflict | Keeps original capture time; fetches conflict and asks the reader to resolve it |

The server's [position persistence](https://gitlab.com/storyteller-platform/storyteller/-/blob/5938df3cf96427e5a0ebe9554e559378123d3d18/applications/web/src/database/positions.ts) also rejects equal timestamps with different locators. A larger reading percentage does not override this rule. The official mobile client fetches the server position after a 409; the plugin now fetches it and offers the reader a choice rather than silently forcing another write.

The beta's [published book schema](https://gitlab.com/storyteller-platform/storyteller/-/blob/5938df3cf96427e5a0ebe9554e559378123d3d18/applications/web/src/schemas/v2/book.ts) omits legacy `readaloud.status`, while its actual database query still returns that field and current processing code maintains it. The plugin accepts the schema shape without status and continues requiring `ALIGNED` when the legacy string field is present. **This is compatibility hardening, not a claim that beta.46 has already removed the field.**

Upstream session token `expires_in` is not consistently reliable: the current implementation multiplies a JavaScript date's millisecond value by 1,000. The existing sanity cap is retained instead of inventing a refresh endpoint or applying the device-code expiry units to tokens. There is no refresh-token flow used by this plugin; expired credentials require linking again.

## Findings fixed

1. **SimpleUI nullable-field failure.** RapidJSON's `null` is truthy userdata. SimpleUI accesses fields such as `book.status.name` and `book.position.timestamp`, which can fail on legitimate null values. HTTP decoding now converts null fields to Lua nil recursively. Responses are no longer mutated to add an HTTP status inside a book or array.
2. **Credentials crossing server boundaries and stale settings instances.** Changing the server now clears the old token/profile and cancels the current instance's link/sync work. Pending device-code polling checks its original server. FileManager, ReaderUI and SimpleUI share one configuration instance per data directory. URLs containing embedded credentials, query strings, fragments or unsupported schemes are rejected.
3. **Progress conflict overwrite.** An unacknowledged newer server position takes priority even if the reader moved backward. Automatic pushes retain the original capture timestamp. A 409 no longer causes an automatic retry with the current clock. Explicit “Keep local and sync” rechecks the server asset before writing.
4. **Offline retry spin.** Once the old debounce/throttle deadlines expired, failed pushes could repeatedly reschedule with zero delay. Retry scheduling now has a positive minimum delay.
5. **Offline progress discarded on close.** Pending positions are saved in the book's Storyteller sidecar on suspend/stop and restored when the book reopens. Successful push/pull clears the persisted pending position. Initial page state avoids treating a simple reopen as a new page turn.
6. **Incomplete or wrong file accepted as a download.** The transport now honors LuaSocket's success return, checks file writes/close, rejects unsolicited 206 responses, compares received length where supplied, and verifies actual SHA-256 bytes against the server header. Failure removes the temporary file. Redirects are disabled so a bearer request cannot silently move to another host.
7. **Asset identity race and same-size local replacement.** Downloads recheck the server asset UUID/updatedAt before replacing a local file. Sidecar validation now hashes local contents, cached by file metadata, rather than relying solely on size. This prevents a different same-size file from syncing under the original identity under ordinary filesystem changes.
8. **Authentication/permission confusion.** HTML 401 responses are recognized as authentication failures. A 403 is a permission denial, not automatically a reason to relink; upstream also uses it for demo-mode write restrictions.
9. **Unusable outgoing locator.** Unknown XPointers fall back to an actual EPUB resource where possible. Empty resource hrefs and invalid timestamps are rejected before POST rather than placing an unrestorable location on the server.
10. **Readium href handling.** Percent-encoded fragment separators and fragments embedded in hrefs now restore correctly. Suffix matching requires a path boundary, preventing a short filename from matching the tail of a different filename.

The plugin still uses publication-relative EPUB paths and optional SMIL text fragments, rather than sending local filesystem paths or private KOReader XPointers. Server status, authors, collections, series ordering, preferred format, download/open callbacks and the SimpleUI fallback context were checked.

## Validation

65 regression cases pass using LuaJIT, RapidJSON 0.7.2, LuaSocket/LuaSec, LuaFileSystem, and the installed KOReader package's actual process/fsync helpers, LuaSettings reader, serializer, `socketutil.lua` and `ffi/sha2.lua`. Test coverage includes:

- Request contracts for every API wrapper, device-link polling and account verification.
- Nullable book responses, all SimpleUI shelves, its fallback context, and the standalone browser.
- 204/400/401/403/404/409 handling; timestamp conflicts and server rewinds.
- Real loopback HTTP transfers, truncated bodies, redirect rejection, SHA-256 validation, and asset changes during transfer.
- Sidecar identity, file integrity, persisted offline positions and retry scheduling.
- EPUB spine indices with non-linear entries, SMIL fragments, encoded hrefs and invalid-XPointer fallback.
- Plugin startup wiring and credential redaction in logs.

The UI/device services and document container reader are mocked. Subprocesses, settings serialization, filesystem syncing and loopback transfers run for real on the test host. The loopback server is a small fixture derived from the audited upstream contracts, not a substitute for a live Storyteller acceptance test. See [test instructions](../tests/README.md).

## Remaining findings and limits

- **Security: HTTPS certificate verification remains disabled by the installed KOReader LuaSec default (`common/ssl/https.lua`, `verify = "none"`).** HTTPS encrypts traffic but this client does not authenticate the server certificate/hostname. Redirect and credential-boundary fixes do not repair that. A proper fix needs a trusted CA source and hostname verification on supported devices; merely setting `verify = "peer"` would be incomplete. HTTP is also unencrypted and retains the existing warning. This audit is not a secure-transport sign-off.
- **Position precision:** KOReader rendering percentages and Readium position calculations differ. Standard EPUB progress is approximate; supported SMIL fragments are stronger anchors. CSS selectors, DOM ranges and partial CFIs are not implemented; the reader falls back to fragments/progression/chapter. The handwritten EPUB parser is not a complete XML/HTML parser, and unusual markup/entities can affect precision. Cross-format ebook/readaloud layouts and standalone audiobook positions can only be mapped approximately. Standalone audio download/playback is outside this plugin's supported formats.
- **Offline durability:** pending work is persisted on suspend/stop, not after every page turn. Sudden power loss or a process crash before those events can still lose an unsent update. Deferred positions retry when their book is reopened, not in a background queue covering the entire library.
- **Performance:** the plugin now runs network work in subprocesses, with a cancellable download and a 30-minute transfer deadline. Resume is not implemented. SHA-256 validation on first use still adds local CPU work, and library browsing loads the complete list. Local integrity caching uses filesystem size/time/inode metadata; it is not tamper-proof storage.
- **Deployment acceptance still needed:** link to the real server, browse both formats, download, read forward and backward, compare positions with the web/mobile reader, and exercise an offline close/reopen. Device installation/readback proves transferred bytes, not Kindle startup or server authentication.

Future v3 betas may change these contracts. This audit is pinned to beta.46 and does not guarantee compatibility with unpublished later changes.

## Follow-up reliability changes: 1.0.11-alpha

The user explicitly retained the backward-progress protection and 15-second page-update suppression. Those behaviors are now covered as intentional safeguards. HTTP/TLS policy and KOReader core files are unchanged.

The follow-up adds `st_storage.lua` for checked atomic LuaSettings-compatible writes and `st_async.lua` for subprocess work orchestrated by the UI scheduler. Storage failures are surfaced, failed sidecar state remains retryable in memory, and a successful remote write does not erase pending work when its local acknowledgement fails. A new EPUB's metadata is journaled before replacing the book; recovery distinguishes interruption before the EPUB rename from interruption before the metadata commit. File bytes are flushed to storage before committing them. This is a recoverable two-file operation, not a claim of atomic multi-file filesystem transactions.

Automatic/manual sync, linking, the standalone browser, downloads and the patched SimpleUI screen use the background path. The API endpoints and existing synchronous method signatures are preserved. Requests are scoped to the account and reader generation; cancellation cleans up workers and partial downloads. Reader-close uploads use captured positions and never operate on a destroyed document. Suspend saves pending work and cancels the current reader request; resume retries it. The SimpleUI adapter falls back to synchronous calls when paired with an older companion.

The expanded tests cover storage faults and recovery across a fresh module load, real worker responsiveness and cancellation, account/document changes during a request, queued manual work, cancellation of a SimpleUI library load, older API compatibility, partial-download cleanup, close-time uploads and single-close widget cleanup. Kindle-native rendering, the user's live Storyteller account and a physical startup still require on-device acceptance.

## Published integration update: 1.1.1

The companion is paired with SimpleUI `v2.7.1-storyteller.2`, which includes the background-loading adapter and upstream through `3444cc9c03756df1b4c7cb1847d56f517116f842` (the Chinese translation update). No manual adapter patch is required with this SimpleUI release. The companion's runtime behavior is unchanged from `1.1.0-alpha`; version metadata and installation/test documentation now describe the jointly released pair. The beta.46 API baseline and the live-server/device acceptance limits above still apply.
