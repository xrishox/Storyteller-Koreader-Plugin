# Storyteller Koreader Plugin

Storyteller Koreader Plugin lets you use your [Storyteller](https://gitlab.com/storyteller-platform/storyteller) library from inside [KOReader](https://github.com/koreader/koreader).

Use it to browse your Storyteller books on your ereader, download them into KOReader, and keep your place in sync with your Storyteller server.

For a better user experience, I recommend [my Simple UI fork](https://github.com/xrishox/simpleui.koplugin). It has native Storyteller integration, but it is not required.

## What It Does

- Browse your Storyteller library directly from KOReader.
- View your books by currently reading, recently added, collections, series, or full library.
- Download standard EPUB books.
- Download Storyteller read-aloud EPUBs when they are available.
- Choose standard EPUB or read-aloud as your preferred download type.
- Send your KOReader reading position to Storyteller.
- Pull your Storyteller reading position into KOReader.
- Automatically sync your place while you read.
- Add KOReader gestures or shortcuts for manual push and pull.
- Use the Simple UI Storyteller page with the same Storyteller account and downloads.

## Privacy And Safety

- The plugin only syncs books downloaded through this plugin.
- It checks that a local book still matches the Storyteller book before syncing.
- It does not send your local file paths or KOReader's private position data to Storyteller.
- Logs stay on your device and redact sensitive information.

## Setup

1. Install the plugin folder as `storyteller.koplugin` in KOReader's plugins folder.
2. Open KOReader.
3. Go to `Tools` -> `Storyteller`.
4. Set your Storyteller server URL.
5. Link your device.
6. Browse your library and download a book.

## Notes

Storyteller and KOReader describe reading position differently. This plugin translates between them. For normal EPUB books it uses the book chapter and reading progress. For read-aloud books it can also use Storyteller's text/audio alignment data when it is available.

Most books should restore to the expected place. Some unusual EPUB files may restore slightly less precisely because the two apps do not use the exact same position system.

## Compatibility

Version `1.1.0-alpha` was audited against Storyteller `web-v3.0.0-beta.46`, KOReader KindleHF `v2026.07.2`, and the SimpleUI fork `v2.7.1-storyteller.1` with the optional background-loading adapter described below. Storyteller v3 beta still uses the `/api/v2` endpoints used by this plugin.

This update fixes nullable API responses in SimpleUI, server/account changes, progress conflicts, offline retries and pending progress, download integrity, and encoded EPUB resource references. See the [full audit and remaining limitations](docs/compatibility-audit-2026-10-02.md) and [regression test instructions](tests/README.md).

Unsent automatic progress is saved when the book closes or KOReader suspends and retried when that book is reopened. A server URL change requires linking again. Use the final server URL: authenticated redirects are deliberately rejected.

**Transport limitation:** the installed KOReader HTTPS client disables certificate verification by default. HTTPS encryption alone does not authenticate the server in this plugin. See the audit before treating the connection as secure on an untrusted network.

### Reliability update in 1.1.0-alpha

- Network requests run in background subprocesses for linking, browsing, downloads, and syncing. Downloads have a Cancel button and allow up to 30 minutes while retaining the connection timeout. SimpleUI can use the new optional async entry point with the adapter below; the existing API methods remain compatible.
- Settings and sidecar writes check write, flush, fsync, close and rename results. Failed sidecar updates remain retryable in memory while KOReader is running, and storage errors are reported.
- Book replacements stage their new metadata before committing the EPUB. Interrupted metadata commits recover on the next open or browse. No old-book backup is created.
- Requests for a closed document or changed account cannot apply stale results. Acknowledging an earlier upload preserves page turns recorded during that request.

The intentional backward-progress protection and 15-second suppression after applying a server position are unchanged. No KOReader core files or HTTP/TLS verification policy were changed. A storage failure can still prevent persistence across a crash or power loss; keep KOReader open until the storage problem is resolved.

### Optional SimpleUI background loading

The released SimpleUI fork `v2.7.1-storyteller.1` remains compatible with this companion. Its library screen requires a small adapter to load in the background and cancel a request when closed. The companion ZIP does not replace SimpleUI files automatically.

The [adapter patch](docs/simpleui-background-loading.patch) is included for that exact SimpleUI version. Apply it from a checkout of `xrishox/simpleui.koplugin`:

```sh
git apply --check /path/to/Storyteller-Koreader-Plugin/docs/simpleui-background-loading.patch
git apply /path/to/Storyteller-Koreader-Plugin/docs/simpleui-background-loading.patch
```

With KOReader closed, copy the resulting `screens/sui_storyteller.lua` to the same location in the installed `simpleui.koplugin` folder. If the patch is already applied, no further change is needed. The adapter also works with older companion versions.
