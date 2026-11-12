# Anki FSRS for KOReader

Review Anki decks (.apkg) on a KOReader device with FSRS-6 scheduling.

## Install
Copy the `ankifsrs.koplugin` folder to `koreader/plugins/` (Kindle: `/mnt/us/koreader/plugins/`), restart KOReader.
Menu → Tools → More tools → **Anki FSRS**. Existing data is upgraded automatically.

## Importing
Export from Anki/AnkiDroid with *Include scheduling information* and *Include media*. Both package formats work.
Re-importing is safe: note text is updated, new cards are added, progress made on the e-reader is kept.
Past reviews in the package are imported too (used for statistics and the optimiser).

## Studying
* Deck list: tap a parent deck to expand/collapse, "Study all of this deck" studies the whole branch,
  **hold** a deck for browse / daily limits. Limits apply to the deck you open (including its sub-decks).
* Page-turn buttons: next = reveal then Pass/Good, previous = reveal then Fail/Again (swap in Options).
* **Options** (deck list and study screen): Pass/Fail buttons, font size, suspend, skip until tomorrow,
  edit note, card info, frontlight, statistics, browse, more settings.
* Leeches: a review card failed N times (default 8) is suspended and listed under Browse → Leeches.
* Bury siblings, review/new card order, full refresh every N cards: More settings.

## Newer features
* **Study a Browse list:** open Browse, pick a list (e.g. danger zone, failed this week) and choose
  "Study these N cards" or "Study just the first 20". Cards are scheduled normally; suspended ones are skipped.
* **Repeat after Fail/Again:** the same card comes straight back for your own practice. Only the first rating is
  recorded; the second look has a single "Continue" button and changes nothing. Toggle in Options.
* **Night mode:** uses KOReader's own night mode (screen-wide), toggled from Options or the settings menu.
* **Zoom on diagrams:** a "Zoom" button appears when a card has images (tapping an image also tries to open it),
  opening KOReader's image viewer with pinch-to-zoom.
* **Per-deck retention:** hold a deck → Deck settings. Retention is inherited by sub-decks, and each card is
  scheduled with the retention of its own deck, even in an "all decks" session. Decks with their own retention
  show e.g. [95%] in the deck list.

## Browsing a deck before studying
Hold a deck in the deck list: **Read through this deck** (question and answer together, Next/Previous or the
page-turn buttons, nothing is recorded) or **Browse cards in this deck**. Browse has *All cards*, *Read through*,
*Preview today's new cards* and *Due today* besides the smart lists. Every list has a "Read through these N cards" row;
holding a card row starts the read-through at that card.

## The pet
A card-eating monster that grows as you review (egg, Nibbler, Muncher, Gobbler). Everything is derived from the
reviews done on this device (imported Anki reviews do not count), so it can never get out of sync.
* Daily goal (default 20 cards) fills its belly. Reaching it keeps your streak; every 7 goal days earn a shield
  (max 3) that lets the pet hibernate through a missed day.
* Strictness (Pet settings): **Gentle** (only sleeps), **Needs care** (looks weak after 3 missed days),
  **Hardcore** (dies after 5 unprotected missed days and restarts as an egg; only days after switching on count).
* Shown after a session of 5+ cards, from the deck list row, and from the Anki FSRS menu. Badges are listed there too.
* Sprites live in the `pet/` folder (32x32 art, pre-scaled PNGs).

## Statistics & forecast
Reviews due per day, next 7/30 days, retention (today/7/30/all), streak, average answer time and the
estimated time to clear today. Answer time is capped at 120 s per card.

## Browse
Smart lists: danger zone (lowest recall now), leeches, most lapses, high difficulty, fragile cards,
failed in the last 7 days, slowest to answer, suspended, skipped, new, and text search.

## FSRS parameters
Applied automatically from the imported deck when available, or load a text file with the 21 numbers.
**Optimise FSRS parameters** fits them on this device from your review history (needs 300+ usable reviews,
1000+ recommended). A held-out split decides whether the result is better; nothing changes unless it is, and the
previous parameters can be restored.

## Limits
Review progress is stored on the device; no live sync with AnkiDroid/AnkiWeb. Editing a note on the device is
local: importing the same deck again overwrites the edit. Image occlusion, JavaScript templates, audio and
type-in answers are not supported.
