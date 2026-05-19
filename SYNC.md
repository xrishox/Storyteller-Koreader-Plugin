# Storyteller Sync Behavior

This document is the source of truth for Storyteller position sync in KOReader.
It describes what sync should do, not how an older implementation happened to do
it.

## Goals

Storyteller sync should feel automatic while protecting the reader from
accidentally overwriting a better position on another device.

The server position is protected unless KOReader has clearly advanced through
normal reading or the user explicitly chooses to sync the local position.

The sync code must be understandable:

- one pending local position at most
- one scheduled push at most
- one scheduled remote check at most
- one conflict prompt at most
- no recursive retry loops
- no unbounded queues
- every scheduled action must verify that the same book is still open

## Public Interface

The plugin-facing sync API is stable:

- `Sync:new(plugin)`
- `manualPush()`
- `manualFetch()`
- `startAuto()`
- `stopAuto(flush)`
- `onPageUpdate(page)`
- `onNavigation()`
- `onSuspend()`
- `onResume()`
- `onNetworkConnected()`
- `onCloseDocument()`

Simple UI and KOReader integration should call these methods. They should not
reimplement Storyteller sync logic.

## Position Data

Storyteller positions are Readium-style locators sent to:

- `GET /api/v2/books/:bookId/positions`
- `POST /api/v2/books/:bookId/positions`

The plugin sends the locator shape Storyteller already stores:

```lua
{
    href = "OEBPS/chapter.xhtml",
    type = "application/xhtml+xml",
    locations = {
        progression = 0.25,
        totalProgression = 0.42,
        fragments = { "chapter.xhtml-s12" },
    },
}
```

`fragments` is required for readaloud sync. Standard EPUB sync can work with
`href`, chapter `progression`, and `totalProgression`.

The plugin must not push a locator with an empty `href`. If KOReader cannot
provide an exact XPointer, the plugin should derive a best-effort locator from
the EPUB spine and total progression. If that still cannot produce an `href`,
the push must be skipped instead of storing an unusable server position.

The plugin should never send CFI data because Storyteller does not use it.

## Local Sidecar

Only books downloaded by this plugin are eligible for sync. Eligibility is
tracked in the KOReader sidecar file for the local EPUB.

The sidecar must identify:

- Storyteller server URL
- Storyteller user id
- Storyteller book UUID
- downloaded format, either `ebook` or `readaloud`
- Storyteller asset UUID
- asset update timestamp
- downloaded hash received from Storyteller
- local file size

Sync must refuse to run if:

- the sidecar is missing
- the local file is missing
- the sidecar belongs to another server or user
- the local file size does not match the sidecar
- the Storyteller asset has changed since download

The sidecar may store the last successful sync timestamp and a locator summary
for diagnostics.

## Movement Classification

The plugin distinguishes reading from navigation.

### Reading

Reading means adjacent page movement at a normal pace after the plugin has a
valid baseline.

Normal reading should mark one pending local position and schedule one push.
The push should happen on the next KOReader tick so quick repeated events can be
coalesced without building a long queue.

### Navigation

Navigation means:

- explicit KOReader goto events
- TOC jumps
- search result jumps
- chapter jumps
- non-adjacent page changes

Navigation updates the movement baseline but does not create pending sync state.

After navigation, the plugin resumes reading only after two non-rapid adjacent
page turns. This prevents a jump target from being pushed immediately just
because the user was looking around.

### Skimming

Rapid adjacent turns are treated as skimming. The threshold is currently three
seconds between page updates.

After three rapid adjacent turns, the plugin is in skimming mode. Skimming does
not create pending sync state.

After skimming, the plugin resumes reading only after two non-rapid adjacent
page turns.

### Readaloud Chapter Boundaries

Readalouds rely on Storyteller fragment data. If a page turn crosses the
underlying document fragment/chapter boundary, that position may be pushed even
when the page turn was fast, as long as the generated locator contains a
Storyteller fragment.

If the plugin cannot generate a fragment for a readaloud position, it must skip
the push, clear that unsendable pending position, and log
`readaloud_fragment_missing_skip`.

## Auto Push

Auto push is allowed only when all of these are true:

- auto-sync is enabled
- the current document is still the same file
- the sidecar validates
- the Storyteller asset is still fresh
- there is pending local reading progress
- no conflict prompt is open
- no timeout prompt is open
- no sync safety ignore is active
- the network is available

Before pushing, the plugin must fetch the current server position and compare it
to the local pending position.

If the local position is accepted, the plugin sends it with a fresh timestamp.
On success, pending state and sync safety ignore state are cleared.

If push receives a 409 conflict, the plugin fetches the server position and
re-runs the same conflict rules.

## Remote Checks

Remote checks are used to find newer or farther server positions.

Remote checks should run:

- when a synced book opens
- when KOReader resumes or wakes
- when the network reconnects

Remote checks should not run when local pending progress exists. Local pending
progress must be resolved first through push, conflict prompt, or ignore.

Remote checks do not retry in a timed loop. They run once for the current event.
Another lifecycle or page event can schedule another check later.

## Conflict and Safety Rules

Progress is compared with `locations.totalProgression`.

If either side lacks usable total progression, timestamp is used only as a
fallback to detect a newer server position. Unknown progress should not cause a
silent local overwrite.

### Server Ahead

If the server is more than 1% ahead of KOReader, the plugin must ask before
pushing local state.

This protects the common case where another device is farther ahead.

### Server Newer

If progress is effectively the same but the server timestamp is newer than the
last successful local sync timestamp, the plugin must ask before applying or
overwriting.

### Local Ahead

If KOReader is ahead from normal page-by-page reading, it may auto-push even if
it is more than 10% ahead. This supports offline reading and long sessions.

If KOReader is more than 10% ahead and the pending position came from
navigation or skimming, the plugin must ask before pushing.

This protects accidental jumps, TOC browsing, and search result navigation.

### Prompt Choices

Conflict prompts must offer:

- `Use server`: apply the server position locally.
- `Sync this position`: intentionally push KOReader's current position.
- `Ignore for 2 minutes`: suppress auto-push and repeat prompts temporarily.
- `Ignore until manual sync`: suppress auto-push and repeat prompts until manual
  push/fetch or reopening the book.

Manual push and manual fetch are explicit user intent and clear sync safety
ignore state.

## Remote Apply

Applying a remote position must suppress local capture briefly so KOReader page
updates caused by the apply do not immediately overwrite the server.

The suppression window is currently 15 seconds.

When suppression ends:

- clear pending local progress
- reset movement to reading mode
- set the current page as the new movement baseline

If remote apply fails:

- restore the previous pending local state
- restore the previous movement state
- schedule a push if pending local progress still exists

## Suspend and Close

Suspend and close should flush pending real reading progress if possible.

They must not force-push:

- skimming state
- navigation-only state
- ignored sync safety state
- readaloud state without a fragment

Skipped locator data must not remain pending forever. Future page movement can
create a new pending position, but an unsendable position should not block later
remote checks.

Suspend and close should not show new conflict prompts. If a conflict exists, it
should be handled on the next normal sync event.

## Timeout and Network Behavior

Network absence should not create retry queues.

On timeout during auto-sync, the plugin may show a timeout prompt except during
suspend.

The timeout prompt may offer:

- try again
- ignore this time
- pause until wake/open

Network reconnect should schedule either a pending push or a remote check,
depending on whether local pending progress exists.

## Logging and Privacy

Logs should be useful for diagnosing sync behavior without leaking sensitive
data.

Logs may include:

- event names
- decision names
- sanitized locator summaries
- progress percentages
- boolean state
- non-sensitive error kinds

Logs must redact:

- file paths
- server URLs
- user names
- user ids
- email addresses
- book UUIDs
- asset UUIDs
- access tokens
- device/user codes
- raw HTTP status lines
- raw response bodies

## Manual Scenario Checklist

Before release, verify these scenarios manually or with lightweight local
checks:

- normal reading pushes every page
- quick skimming does not push
- TOC jump followed by two normal page turns resumes pushing
- server more than 1% ahead prompts before local overwrite
- navigation-origin local position more than 10% ahead prompts before push
- normal offline reading more than 10% ahead pushes without prompting
- `Ignore for 2 minutes` suppresses repeat prompts and resumes afterward
- `Ignore until manual sync` suppresses auto-push until manual push/fetch or
  reopen
- readaloud without a fragment does not push
- readaloud with a fragment pushes a fragment locator
- remote apply does not immediately overwrite itself
- suspend flushes only pending real reading progress
- no sync path creates an unbounded queue or recursive retry loop
