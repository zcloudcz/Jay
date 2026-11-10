# Clickable links in messages

Status: approved (owner request 2026-11-10: "odkazy na stránky, klikatelné ze zprávy").

## Problem

`message_bubble.dart` renders the message body as plain `Text`, channel posts as plain `SelectableText`. A URL in a message cannot be opened; the user has to select and copy it by hand (and on touch the whole message is copied, not the URL).

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Detected: `http://` and `https://` URLs, `www.` hosts (opened as `https://`), `mailto:` links and plain e-mail addresses (`name@host.tld`, opened as `mailto:`). Case-insensitive scheme. | What people paste. |
| D2 | NOT detected: bare domains without `www.` (`seznam.cz`), `ftp:`, `tel:`, `javascript:`, `file:`, `intent:` or any other scheme. | Bare domains give too many false positives (`file.txt`, `v1.2`); other schemes are not needed and some are dangerous. |
| D3 | A URL ends at whitespace, `<`, `>`, `"`, or a character that is not a URL character (letters and digits of any script, marks, and `-._~:/?#[]@!$&'()*+,;=%`), so an emoji glued to a URL is not part of it. Trailing `.,;:!?'` and unbalanced closing `)`, `]`, `}` are trimmed (repeatedly), so `(viz https://cs.wikipedia.org/wiki/Brno_(město)).` keeps the inner balanced parentheses and drops the outer `).`. | Matches how the URL appears in prose. |
| D4 | The scheme must open the text or follow a non-letter, `www.` must open the text or follow a character that is not a letter, digit, `.`, `-`, `@` or `/`; an e-mail must follow a character that is not part of an address and its domain must end in a label of 2+ letters. An e-mail inside a URL (`https://x.cz/@user`, `https://user@host`) belongs to the URL. A `@mention` without a dotted domain is never an e-mail. | Avoids matches inside words and double matches. |
| D5 | The host must be non-empty and must parse with `Uri.tryParse`; `www.` needs at least one more dot-free label after it (`www.` alone is text). Non-ASCII (IDN) host labels are converted to punycode (`xn--`) for the target Uri; the visible text stays as typed. | Some platforms do not accept a raw or percent-encoded Unicode host. |
| D6 | The detector is pure Dart (`lib/features/chat/links.dart`, no Flutter import) and linear in the text length; it runs once per text (cached in the widget state), not per frame. | Unit-testable; long bot messages must not jank. |
| D7 | Where: chat message bubbles (1:1, groups, business, bots, edited text, photo captions) and channel posts. NOT: the quoted reply preview inside a bubble (stays plain, a tap there is not a link), pinned message bar and pin list, search result snippets, chat list previews, notifications. | The pinned and search rows are tap targets of their own (open the message), a link inside them would fight that tap. |
| D8 | Tap on a link opens it with `url_launcher` `LaunchMode.externalApplication` (system browser / mail app; on web a new tab, `webOnlyWindowName: '_blank'`). Only `http`, `https` and `mailto` Uris are ever passed to the launcher (checked again at launch, not only in the detector). If launching fails, a snackbar says so. | The app must not become a browser; defence in depth. |
| D9 | No confirmation before opening: the visible text IS the target (we never render a label that differs from the URL), and long URLs are shown in full (wrapped), never shortened. | Nothing is hidden, so a confirm step would add friction without safety. |
| D10 | Long press on a link (touch), or right click on a link (mouse), opens a small link sheet: the full URL as its title, "Open link", "Copy link". Copy puts the VISIBLE text on the clipboard (for an e-mail the bare address, for `www.` the text as written) and shows "Link copied". Long press anywhere else in the bubble opens the existing message sheet as before; right click elsewhere does what it does today (nothing in Flutter). The three-dots menu on desktop/web is unchanged. | Keeps the message menu reachable; copying a single link is the most common need. |
| D11 | Channel posts stay `SelectableText` (selection is their long-press behaviour today and gives Copy); links in them get tap-to-open and the hover cursor only, no link sheet. | Deviation from the original brief: replacing selection with the link sheet would remove a working feature. |
| D12 | Style: underlined. In other people's bubbles (`surfaceContainerHighest`) the color is `colorScheme.primary`; in my own bubbles (`primaryContainer`) the color stays `onPrimaryContainer` (same as the text) and the underline marks the link. Channel posts use `colorScheme.primary`. Desktop/web show the click cursor over a link. Links are exposed to screen readers as links (span recognizer). | `onPrimaryContainer` is the pair the theme guarantees contrast for in light and dark; `primary` on `primaryContainer` is the same hue family and can be weak. |
| D13 | No link previews (no fetching of titles or images). | Privacy: fetching would tell the site (and its trackers) that the message was read, from the reader's IP; out of scope. |
| D14 | Bots: their messages are ordinary messages and get the same rendering. Bot buttons stay as they are. | Simple. |
| D15 | Mentions: `@Name` stays plain text next to links in the same message (there is no mention highlighting in bubbles today); an `@` that is part of an e-mail or URL belongs to the link. | Nothing to break. |
| D16 | No wire, server or storage change. Old clients show the same text as plain text. | Pure rendering. |

## Strings (all 19 ARB files)

`chatLinkOpen` "Open link", `chatLinkCopy` "Copy link", `chatLinkCopied` "Link copied", `chatLinkOpenFailed` "Could not open the link". Czech: "Otevřít odkaz", "Kopírovat odkaz", "Odkaz zkopírován", "Odkaz se nepodařilo otevřít".

## Tests

- Unit (`test/features/chat/links_test.dart`): each kind, trailing punctuation, balanced and unbalanced brackets, query and fragment, Wikipedia parentheses, Czech text around links, IDN host to punycode, emoji next to a URL, e-mail vs `@mention`, e-mail inside a URL, rejected schemes, bare domains not matched, 200 KB text within a time bound.
- Widget (`test/features/chat/link_text_test.dart`): tap launches the right Uri through a fake launcher; long press on a link shows the link sheet; Copy writes the clipboard; long press outside the link still opens the message sheet; mention and link in one message; own vs other bubble link color; quote stays plain; channel post link opens.
- l10n guard (existing `test/l10n`).

## Limits

- No link previews (D13).
- On web, right click on a link may also show the browser's own context menu next to the link sheet.
- Bare domains (`seznam.cz`) and phone numbers are not linkified.
- Links in pinned messages, search results and quotes are not clickable (D7).
- Manual checks on real devices are listed in `docs/acceptance/clickable-links.md`.
