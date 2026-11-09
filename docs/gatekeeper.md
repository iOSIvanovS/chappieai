# Opening ChappieAI on macOS: Gatekeeper Guide

ChappieAI is distributed outside the Mac App Store and is not signed with an Apple Developer ID or notarized by Apple.
macOS therefore asks for a one-time confirmation the first time you open it.

---

## What you might see

When you open the app for the first time, macOS may show a dialog like one of these:

> **"ChappieAI" cannot be opened because Apple cannot check it for malicious software.**
>
> **"ChappieAI" cannot be opened because the developer cannot be verified.**

This is the standard Gatekeeper warning for any app that is not notarized. It means Apple has not reviewed the app. It says nothing about what the app does. The source code is public, so you can read it or build the app yourself (see the [README](../README.md#build-from-source)).

---

## How to open the app

Drag `ChappieAI.app` to **Applications** first, then use the method that matches your macOS version.

### Method 1: System Settings (works on every supported macOS)

1. Double-click `ChappieAI.app`. macOS blocks it. Close the dialog.
2. Open **System Settings** → **Privacy & Security**.
3. Scroll down to the **Security** section.
4. Next to the message about ChappieAI, click **Open Anyway**.
5. Confirm with your password or Touch ID, then click **Open** in the dialog that appears.

macOS remembers your choice, so you will not see this again for this copy of the app.

### Method 2: Right-click (macOS 14 Sonoma and earlier)

1. In **Finder**, find `ChappieAI.app`.
2. **Right-click** (or Control-click) the icon and choose **Open**.
3. Click **Open** in the dialog.

On macOS 15 Sequoia and later this shortcut no longer bypasses the warning. Use Method 1 there.

### Method 3: Terminal (advanced)

If the methods above do not work, remove the quarantine flag that macOS puts on downloaded files:

```bash
xattr -dr com.apple.quarantine /Applications/ChappieAI.app
```

---

## Updates

After the first launch, updates arrive inside the app through Sparkle and are verified with the project's own signature key. You do not need to repeat these steps for updates.

---

## Why does this happen?

Notarization requires Apple's paid Developer Program ($99 per year). ChappieAI is a free, open-source project and does not use it.

If you would rather not bypass the warning, build the app from source with your own signing identity. The steps are in the [README](../README.md#build-from-source).

---

## Still having trouble?

Open an issue on [GitHub](https://github.com/iOSIvanovS/chappieai/issues).
