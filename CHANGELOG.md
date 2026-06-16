# Relay — Changelog

All notable changes to Relay, newest first. The current version's bullet list is
shown right inside the in-app update prompt ("A new version is available — would
you like to install it?"), so you can see what's new before updating.

## 1.0.7
- Fixed: an incoming message could fire a notification but never show up in the app — the conversation wouldn't move to the top, get an unread dot, or even appear if it was a new chat. Incoming messages now always update the sidebar (and create the conversation if it's a brand-new one).

## 1.0.6
- Hardened session security: any leftover plaintext copy of your login is now deleted automatically once it's safely in the Keychain, so your session never lingers in cleartext on disk.

## 1.0.5
- A photo that's no longer available now shows a clean placeholder instead of spinning forever.

## 1.0.4
- An "Update available" badge now appears in the app (in the sidebar and in Settings) the moment a new version is out, so you never have to go check — installing stays one click, on your terms.
- Relay now cleans up after itself: leftover temporary files, stale update downloads, and old backups are tidied automatically so updates and caches never pile up and fill your storage.
- Photos and GIFs you send are now stored durably, so they no longer risk quietly disappearing from older conversations.

## 1.0.3
- Fixed a stale "ghost" notification that replayed an old message every time the app reconnected.
- Update prompts now show this changelog, so you can see what changed before you install.

## 1.0.2
- Reaction bar no longer runs off the side of the window — it now opens toward the centre of the screen.
- Reaction picker stays put while you choose an emoji instead of flickering shut.
- Fixed the double "send" animation that made one message look like it was sent twice.

## 1.0.1
- Hardened Return-to-send on macOS Ventura so Enter reliably sends a message.
- Hid translation menu items on macOS versions that don't support them, so there are no dead buttons.

## 1.0
- First public release: a native macOS Messenger client over a Go backend that speaks Meta's real protocol.
- Messaging with reactions, replies, edit, unsend, forward, and multi-image media.
- Voice notes, emoji, drag-and-drop, scheduled send, snooze, pin, mute, and saved messages.
- Full-text search across all local history; per-chat accent colours, wallpapers, and nicknames.
- On-device translation (macOS 15+), Touch ID lock, menu-bar companion, and one-click in-app updates.
- Universal binary — runs on both Apple Silicon and Intel, macOS 13 Ventura or later.
