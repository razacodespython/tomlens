# Install TomLens on your Mac

TomLens is a menu-bar tutor. It watches only the one trading window you pick, listens only while you hold a hotkey, and talks back. It never clicks, types, moves the mouse, or places orders.

You need macOS 14.2 or newer. The download is an unsigned app, so macOS will ask you to confirm before it opens. That is expected.

## 1. Download and unzip

1. Download `TomLens-unsigned.zip` from the GitHub Actions artifact (or the `v0.1.0-alpha` prerelease, if one is attached).
2. Double-click the zip. macOS expands it into `TomLens.app`.
3. Drag `TomLens.app` into your **Applications** folder.

Leave it in Applications. Do not run it from the Downloads folder.

## 2. Open it the first time

macOS blocks unsigned apps on the first open.

1. In Applications, **right-click** (or Control-click) **TomLens** and choose **Open**.
2. In the dialog, choose **Open** again.

If you double-clicked it first and macOS only showed "cannot be opened":

1. Open **System Settings**.
2. Go to **Privacy & Security**.
3. Scroll to the message about TomLens being blocked and click **Open Anyway**.
4. Confirm **Open**.

You only do this once.

## 3. Grant three permissions, and nothing else

TomLens asks for only these:

- **Screen Recording** — so it can see the one window you pick. After you allow it, quit TomLens and open it again. macOS does not apply Screen Recording until the app restarts.
- **Microphone** — so it can hear you while the hotkey is held.
- **Speech Recognition** — so it can turn what you say into text, on your Mac. macOS shows this the first time you hold the talk key.

Click the TomLens triangle in the menu bar. In the panel, use **Grant** next to Microphone and Screen Recording. When a row says **Screen Content**, that is the same Screen Recording permission letting TomLens list windows. It is not a fourth permission, and it is not access to your whole screen.

Do not turn on Accessibility, Input Monitoring, or the camera. TomLens does not use them. If macOS offers those, deny them.

## 4. Turn it on

TomLens starts **off**. Off means the hotkey is not listening, and there is no capture, no microphone, and no ChatGPT calls. A status window opens on launch so you can see that. If you closed it, click the menu-bar triangle and choose **Open TomLens**.

The menu-bar triangle is dimmed with a slash while TomLens is off, and filled while it is on.

1. In the status window (or the menu-bar panel), flip the switch until it says **TomLens is on**.
2. The window should say **Hold Control+Option+Z**. If another app already uses that shortcut, the window says so instead of pretending it worked.

## 5. Sign in with ChatGPT

In the same panel, click **Sign in with ChatGPT**. Your browser opens. Sign in with the ChatGPT account you already pay for. When the page says you can close the tab, come back to TomLens. Your email shows in the panel.

TomLens uses your ChatGPT plan. It does not turn on paid credits. If you hit your plan limit, it pauses.

## 6. Pick the Tradovate window

Open the Tradovate desktop app and leave that window visible.

In the TomLens panel, open the **Window** menu and pick the Tradovate window. TomLens captures that window only. It will not list wallet apps. If you pick a browser, it warns you, because a browser window would include every tab.

## 7. Talk

Hold **Control + Option + Z**. Speak while the keys are down. Release them when you are done.

The status window changes from **Idle** to **Listening** (with a microphone level), then **Thinking**, then **Speaking**. Your last words and Tom's last reply stay on that window.

**Test** sends one “What do you see?” question about the window you picked. It uses one of the 40 calls allowed each hour. **Open journal folder** shows the notes on your Mac.

TomLens answers out loud and may draw a short hint on top of the window you picked. The drawing ignores clicks, so it never gets in the way of the trading app.

## 8. Where notes are saved

Each session is written on your Mac, under:

`~/TomLens/journal`

In Finder, choose **Go > Go to Folder…** and paste that path. Each folder is one session (named by date and time) with the frames it saw and text logs. Nothing is uploaded.

## Turn it off

Flip the switch back to **TomLens is off**, or quit the app from the menu bar icon. Off stops the hotkey, the microphone, window capture, and ChatGPT calls.
