# EPUB Handling Spec

This document describes what the Storyteller KOReader plugin's EPUB layer must
do. It is the compatibility contract for `st_epub.lua` and the helper modules it
loads.

## Purpose

The EPUB layer translates between two worlds:

- KOReader's internal CREngine positions, represented mainly as XPointers.
- Storyteller's position API, which stores Readium-style locators.

The rest of the plugin should not need to know how EPUB files are packaged,
which spine item contains a location, how SMIL overlays point at text fragments,
or how to fall back when a precise position cannot be restored.

## Public Module Contract

`st_epub.lua` must continue to exist and export the same public functions:

- `getSpine(document)`
- `resolveHref(document, href)`
- `readChapter(document, item)`
- `totalProgressionToLocator(document, total_progression, format)`
- `xpointerToLocator(document, xpointer, total_progression, format)`
- `hrefProgressionToXPointer(document, href, progression)`
- `hrefFragmentToXPointer(document, href, fragment)`
- `hrefStartToXPointer(document, href)`
- `totalProgressionToXPointer(document, total_progression)`
- `locatorToXPointer(document, locator, validator)`

Callers may use colon syntax, so methods must accept `self` as the first
implicit argument.

## Locator Shape

Storyteller locators sent by this plugin must look like:

```lua
{
    href = "OEBPS/chapter.xhtml",
    type = "application/xhtml+xml",
    locations = {
        progression = 0.25,
        totalProgression = 0.42,
        fragments = { "fragment-id" }, -- readaloud only when available
    },
}
```

The plugin must not send CFI, partial CFI, CSS selector, DOM range, local file
paths, or KOReader XPointers to Storyteller.

For standard EPUB downloads:

- `href` is required.
- `locations.progression` is required when it can be derived.
- `locations.totalProgression` is required.
- `locations.fragments` should not be added.

For readaloud downloads:

- `href` is required.
- `locations.progression` is required when it can be derived.
- `locations.totalProgression` is required.
- `locations.fragments[1]` should be the best Storyteller text fragment ID.
- The sync layer may reject a readaloud payload if no fragment can be derived.

## Spine And Href Rules

The EPUB layer must parse `META-INF/container.xml`, then the referenced OPF.
From the OPF it must collect:

- manifest items by ID
- spine items in package order
- readable text items in reading order

Readable text items are manifest items with media type:

- `application/xhtml+xml`
- `text/html`

Spine items with `linear="no"` are not part of reading order, but the full spine
is still useful for matching KOReader DocFragment indexes.

Href matching must be tolerant because Storyteller, Readium, and KOReader can use
slightly different strings for the same resource. Matching must:

- ignore URL query strings and fragments
- decode percent-encoded bytes
- ignore leading slashes
- strip Storyteller `/api/v2/books/.../read/` and `/listen/` URL prefixes
- normalize `.` and `..` path segments
- prefer exact normalized href/path matches
- allow suffix matches as a fallback

Diagnostics from href resolution should include enough context to debug bad
matches, including requested href, matched href/path, match kind, and spine
counts.

## XHTML Text Mapping

KOReader XPointers and Storyteller progression values cannot be mapped perfectly
without CREngine internals, so the EPUB layer builds a best-effort text map from
the XHTML body.

The text map must:

- read the XHTML body from the EPUB package through KOReader's document API
- parse element nesting enough to follow simple XPointer steps
- record `id` and `xml:id` values and their text offsets
- record text-node offsets using UTF-16 length because Readium positions are
  based on JavaScript string offsets
- treat common named entities and numeric entities consistently
- ignore comments, declarations, and processing instructions
- handle void elements without pushing them onto the parse stack

The parser is intentionally lightweight. It is not a general XML parser, but it
must fail softly. If it cannot map a precise location, callers should receive
`nil` or a less precise fallback rather than an exception.

## KOReader XPointer To Storyteller Locator

When converting the current KOReader position to a Storyteller locator:

1. Parse `/body/DocFragment[n]/body/...` from the KOReader XPointer.
2. Use the DocFragment index to find the matching spine item.
3. If that spine item is not readable, fall back to the reading-order item at
   the same index.
4. If no readable item can be found, fall back to total progression.
5. Convert the body path to a text offset in the selected chapter.
6. Convert that offset to chapter `progression`.
7. Preserve KOReader's total percent as `totalProgression`.
8. For readaloud, choose the nearest valid text fragment at or before the
   offset.

The resulting locator must use the Storyteller-facing href, which is the OPF path
when available, not a KOReader XPointer or local filesystem path.

## Total Progression To Storyteller Locator

When only total progression is available:

1. Clamp total progression to `0..1`.
2. Parse all readable chapters.
3. Use combined text length to choose the chapter and offset. Interior exact
   chapter boundaries should resolve to the next chapter start, not the previous
   chapter end.
4. If text length is unavailable, fall back to reading-order index.
5. Compute chapter `progression`.
6. For readaloud, choose the nearest valid text fragment at or before the
   selected offset.

This is less precise than XPointer-based conversion, but it must produce a valid
href when the EPUB spine can be parsed.

## Readaloud Fragment Rules

For readaloud books, Storyteller currently relies on fragments for good
text/audio sync. The EPUB layer must therefore make fragment selection as strong
as possible.

Fragment selection should:

- read the spine item's `media-overlay` manifest item when present
- collect SMIL `<text src="chapter.xhtml#fragment">` targets for the chapter
- prefer IDs that appear in that SMIL overlay
- fall back to all XHTML IDs when no overlay IDs match
- sort candidate IDs by text offset, then by ID
- choose the last candidate whose offset is at or before the current offset

If no candidate exists, the EPUB layer may return a locator without a fragment.
The sync layer decides whether that is sendable.

## Storyteller Locator To KOReader XPointer

When applying a remote Storyteller locator, the EPUB layer must try candidates in
this order:

1. `href + locations.fragments[1]`
2. `locations.totalProgression`, only after a fragment failed and chapter
   `progression` is `0`
3. `href + locations.progression`
4. chapter start from `href`
5. `locations.totalProgression`

Candidate construction alone is not enough. If a validator is supplied, each
candidate must be passed to it before being accepted. This allows KOReader's
`isXPointerInDocument()` result to reject an XPointer and continue to safer
fallbacks.

The returned diagnostic must include every attempted candidate and whether it was
resolved, accepted, or rejected.

## Failure Behavior

The EPUB layer must not throw on malformed EPUB markup, missing OPF data,
unrecognized hrefs, unreadable chapters, missing SMIL overlays, or invalid
locators. It should return `nil` plus diagnostics where useful.

The sync layer is responsible for deciding whether failure means:

- skip sending this position
- apply a less precise remote position
- warn the user
- retry later

## Performance Expectations

This code runs on low-power e-readers. The EPUB layer should avoid unnecessary
work in hot paths.

Required behavior:

- cache parsed spine data per KOReader document object
- keep parsing local to the needed conversion
- avoid network access
- avoid hashing or scanning the full downloaded file
- avoid background timers or async work

Acceptable behavior:

- parse the OPF once per document
- parse chapter XHTML when a locator conversion needs text offsets
- parse all readable chapters when only total progression is available

Future optimization may add per-chapter text-map caching, but correctness and
soft failure are more important than caching complexity.
