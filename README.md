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
