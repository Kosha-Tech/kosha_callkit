# Kosha CallKit (forked `connectycube_flutter_call_kit`)

A Flutter plugin for showing a configurable incoming-call screen on Android and using native CallKit on iOS — works in foreground, background, and killed states.

This is a fork of [`connectycube_flutter_call_kit` v2.8.2](https://pub.dev/packages/connectycube_flutter_call_kit) with the changes needed by the KoshaX app baked in. The Dart import path (`package:connectycube_flutter_call_kit/…`) and class names are unchanged — only the Android native side and the screen layout API have evolved.

> ⚠️ This is a **path-based local plugin**, not a published package. Reference it from your app's `pubspec.yaml`:
>
> ```yaml
> dependencies:
>   connectycube_flutter_call_kit:
>     path: ../kosha_callkit   # adjust path to wherever the package lives
> ```

---

## What this fork adds on top of upstream

### 1. Tapping the floater opens the call screen (not the app launcher)
The notification's `setContentIntent` was rewritten to launch `IncomingCallActivity` directly. Upstream launches `MainActivity`, which means tapping the floater dumps the user into the app's home screen instead of the call UI.

### 2. Ringtone keeps playing on tap
`setAutoCancel(false)` so the notification (and its ringtone) survives until the user explicitly accepts, declines, or it times out. Upstream cancelled the notification on tap, killing the sound.

### 3. Layout-driven UI customisation
The Android incoming call screen reads optional overrides from `CallEvent.userInfo`. **No native code changes required** — define the layout in your host app under `android/app/src/main/res/layout/activity_incoming_call.xml` (resource merging makes Android pick your layout over the plugin's).

| `userInfo` key | Effect |
|---|---|
| `headerText` | Top-of-screen header text (e.g. `"Reminder"`, `"Incoming Call"`) |
| `subtitleText` | Subtitle below the title (e.g. `"REMINDER"`, `"Incoming Audio call"`) |
| `hiddenViews` | Comma-separated view IDs to hide (e.g. `"quick_actions_row,location_pill"`) |
| `viewTexts` | JSON map `{ "<view_id>": "<text>" }` — sets text on any `TextView` in your layout |

If you don't pass any of these, the screen renders with sensible defaults (caller name + "Incoming Audio/Video call" subtitle).

### 4. Generic `onClick` for custom action buttons
In addition to upstream's `onStartCall` / `onEndCall`, the activity exposes a third click handler — `onClick(view)` — for any extra buttons you put in the layout (Snooze, Mark done, etc).

The view's `android:tag` tells the plugin what to do:

```xml
<!-- Snooze pill: routes through reject + sends action="snooze" to Dart -->
<View android:onClick="onClick" android:tag="reject:snooze" />

<!-- Mark done pill: routes through reject + sends action="mark_done" to Dart -->
<View android:onClick="onClick" android:tag="reject:mark_done" />
```

Tag format: `"<accept|reject>:<your_action_key>"`.
- `accept:*` → plugin broadcasts `ACCEPT` (opens the app, like the main green button)
- `reject:*` → plugin broadcasts `REJECT` (dismisses without opening the app)

Dart receives the regular `onCallAccepted` / `onCallRejected` callback and reads `event.userInfo['action']` to dispatch to the right handler:

```dart
static Future<void> _onCallRejected(CallEvent event) async {
    final action = event.userInfo?['action'];
    switch (action) {
      case 'snooze':    await rescheduleReminder(...); break;
      case 'mark_done': await completeReminder(...);   break;
      // null/default → just dismiss
    }
    await ConnectycubeFlutterCallKit.reportCallEnded(sessionId: event.sessionId);
}
```

### 5. Custom action buttons don't bring the app to the foreground
`EventReceiver` skips `startActivity` when `userInfo['action']` is set, so tapping a custom action (mark done / snooze) leaves the user wherever they were (lock screen, other app, etc) instead of launching MainActivity.

---

## Required layout view IDs

If you ship a custom `activity_incoming_call.xml` in your app, these IDs are looked up by name in `IncomingCallActivity.kt`. Keep them:

| ID | Type | Purpose |
|---|---|---|
| `user_name_txt` | `TextView` | Caller name / reminder title |
| `call_type_txt` | `TextView` | Subtitle (set from `subtitleText` or default) |
| `avatar_img` | `ShapeableImageView` | Caller photo (URL from `CallEvent.callPhoto`) |
| `start_call_btn` | `ImageView` | Main accept button — use `android:onClick="onStartCall"` |
| `accept_button_animation` | `RippleBackground` | Ripple wrapper around accept |
| `reject_button_animation` | `RippleBackground` | Ripple wrapper around decline (the decline `ImageView` itself uses `android:onClick="onEndCall"`) |

Plus any optional IDs you want the plugin to drive via `viewTexts` / `hiddenViews` (e.g. `header_title_txt`, `snooze_txt`, `mark_done_txt`, `quick_actions_row`).

---

## Bumping the notification channel after changing the ringtone

Android caches a notification channel's sound on first creation; you can't change it at runtime. When you swap the bundled ringtone, bump `CALL_CHANNEL_ID` in `NotificationsManager.kt` so a fresh channel is created on next install. Current value: `calls_channel_call_notification_v3` (`call_notification.wav`).

---

## Supported platforms

- Android
- iOS (stock CallKit — UI not customisable by Apple's design)

---

## License & attribution

Licensed under the **Apache License, Version 2.0** — see [LICENSE](LICENSE).

This is a modified fork of [`connectycube_flutter_call_kit`](https://github.com/ConnectyCube/connectycube_flutter_call_kit) v2.8.2.
Original copyright © ConnectyCube. Modifications © KoshaX team.

Modifications are summarised in the "What this fork adds on top of upstream" section above. As required by Apache 2.0 §4(b), this NOTICE constitutes the statement that this distribution contains modifications from the original work.
