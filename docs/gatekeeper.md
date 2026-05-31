# Opening ChappieAI on macOS — Gatekeeper Guide

ChappieAI is distributed outside the Mac App Store and is not notarized by Apple.
This is completely safe — macOS just needs a one-time confirmation from you.

---

## What you might see

When you double-click `ChappieAI.dmg` or the app for the first time, macOS may show one of these dialogs:

> **"ChappieAI cannot be opened because the developer cannot be verified."**
> macOS cannot verify that this app is free from malware.

This is a standard Gatekeeper warning for any app distributed outside the App Store. It does **not** mean the app is dangerous.

---

## How to open the app

### Method 1 — Right-click (recommended, 2 steps)

1. In **Finder**, locate `ChappieAI.app`
2. **Right-click** (or Control-click) the app icon → choose **Open**
3. A new dialog appears — click **Open** to confirm

Done. macOS remembers your choice — you won't see this again.

---

### Method 2 — System Settings

1. Try to open the app normally (double-click) — macOS will block it
2. Open **System Settings** → **Privacy & Security**
3. Scroll down to the **Security** section
4. You will see: *"ChappieAI was blocked from use because it is not from an identified developer"*
5. Click **Open Anyway**
6. Confirm in the dialog that appears

---

### Method 3 — Terminal (advanced)

If neither method works, open **Terminal** and run:

```bash
xattr -dr com.apple.quarantine /Applications/ChappieAI.app
```

This removes the quarantine flag that macOS sets on downloaded files.

---

## Why does this happen?

Apple requires developers to pay for a Developer ID certificate ($99/year) and submit apps for notarization.
ChappieAI is an indie app — we skip the App Store to keep the price fair and ship updates faster.

The app contains no malware. You can verify this yourself:

```bash
codesign -dv --verbose=4 /Applications/ChappieAI.app
spctl --assess --verbose /Applications/ChappieAI.app
```

---

## Still having trouble?

Join our Telegram channel — we respond quickly:
**[t.me/chappieaiapp](https://t.me/chappieaiapp)**
