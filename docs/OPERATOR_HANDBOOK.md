# Aur Bhai — Operator Handbook

Manual, terminal-first recipes for day-to-day maintainer work.
Append new processes as numbered sections below; keep each recipe self-contained.

**Conventions**

- Run commands from the Flutter project root unless a step says otherwise:
  `c:\Users\tomar\Documents\Vidyaman\project_aur_bhai_workspace\project_aur_bhai`
- Prefer PowerShell on Windows.
- Paths that contain secrets or local binaries stay out of git (`friend_share/`, PATs, etc.).

---

## 1. Build and locate the friend-share APK

**Goal:** Produce a release APK you can send to friends (Drive / WhatsApp), then print its path.

**When to use:** After code changes that friends need, or when you want a fresh installable build.

### 1.1 Go to the project root

```powershell
cd c:\Users\tomar\Documents\Vidyaman\project_aur_bhai_workspace\project_aur_bhai
```

| Part | Meaning |
|------|---------|
| `cd` | Change directory |
| path | Flutter project root (where `pubspec.yaml` lives) |

### 1.2 Build the release APK

```powershell
flutter build apk --release
```

| Part | Meaning |
|------|---------|
| `flutter` | Flutter CLI |
| `build` | Produce a compiled artifact (not a hot-reload run) |
| `apk` | Android Package — installable on phones |
| `--release` | Optimized release mode (not debug). This is what friends should install |

**Output (default):**  
`build\app\outputs\flutter-apk\app-release.apk`

Notes:

- First build after a clean can take several minutes.
- Package id today is `com.example.project_aur_bhai` — installing again **updates** the same app (no second icon) if friends already have it.
- Dev vs stage **flavors are not set up yet**; this is a single release APK.

### 1.3 Copy into the friend-share drop folder

```powershell
New-Item -ItemType Directory -Force friend_share | Out-Null
Copy-Item build\app\outputs\flutter-apk\app-release.apk friend_share\aur-bhai-friend-release.apk -Force
```

| Part | Meaning |
|------|---------|
| `New-Item … friend_share` | Create `friend_share/` if missing |
| `-Force` | Do not error if it already exists |
| `\| Out-Null` | Hide the directory-creation object from the console |
| `Copy-Item …` | Copy the Flutter output to a stable share name |
| `-Force` (on Copy-Item) | Overwrite an older friend APK |

**Why copy?**  
`friend_share\aur-bhai-friend-release.apk` is the canonical path the helper looks for first. That folder is gitignored so APKs stay local.

### 1.4 Print the path to share

```powershell
dart run tool/friend_share_ops.dart --apk
```

| Part | Meaning |
|------|---------|
| `dart run` | Run a Dart script with the project’s package resolution |
| `tool/friend_share_ops.dart` | Friend-share helper (checklist, circle check, APK path) |
| `--apk` | Only resolve and print the APK path (no GitHub calls) |

**Behavior:** Prefers `friend_share\aur-bhai-friend-release.apk`, else falls back to `build\app\outputs\flutter-apk\app-release.apk`. Prints the absolute path and a short upload hint.

### 1.5 Optional one-shot after a successful build

If the APK already exists and you only need the path:

```powershell
dart run tool/friend_share_ops.dart --apk
```

### 1.6 What to send friends

1. The APK file from the printed path.
2. Separately (not inside the APK): CLOSED CIRCLE settings — GitHub owner, repo (`aur_bhai_circle` by default), fine-grained PAT, display name — via Settings → CLOSED CIRCLE on each phone.

Do **not** put LLM API keys in the friend APK workflow unless you later implement a dedicated secret bootstrap.

---

## 2. Bluetooth wake / handshake smoke test

**Goal:** Verify wake + tap/hold acks on a Bluetooth headset (primary test surface).

**When to use:** After installing a build that includes WAKE & HANDSHAKE settings.

### 2.1 Settings checklist (on phone)

1. Connect the Bluetooth headset; confirm Command Center shows **Bluetooth**.
2. Settings → **WAKE & HANDSHAKE**:
   - **Listen:** Always-on (for wake word) or On-demand (UI / media controls only)
   - **Wake word library:** default **Hey Jarvis** (bundled, free openWakeWord). Optional: Download **Hey Rhasspy** / **Hey Mycroft**, set **Use**, or **Delete** dormant downloads to free space.
   - No Picovoice AccessKey (Porcupine deferred until scale).
   - **Tap ack:** Spoken (Response word e.g. Haan bhai) / Sound / Silent
   - **Hold ack:** Haptic / Beep / Silent (never spoken)
   - **Media controls → Aur Bhai** (Android): on = buds/car Play-Pause-Next → handshake
3. Save credentials / behavior.
4. Optional: set Command Center **Default** Mere Bhai for short prompts without “Ask …”.

### 2.2 Always-on path

1. Keep the wake notification visible (“Listening for wake word…”).
2. Say the **active** wake phrase (e.g. “Hey Jarvis”) → Command Center may flash **Heard:** → wait for tap ack → speak command.
3. With Spotify/YouTube playing: music should duck/pause during the turn, then resume.
4. During a phone call: handshake should refuse (busy message).

### 2.3 On-demand / headset buttons

1. Set Listen = On-demand (openWakeWord stopped — battery).
2. With **Media controls → Aur Bhai** on: headset **short press** → same as mic tap.
3. Headset **long press** → hold ack then record until release (only if the device sends media keys; ANC long-press on some buds never reaches apps).
4. OEM bike kits / car wheels use the same media-control path on Android.

### 2.4 Extra free wake models

1. Settings → Wake word library → **Download** (needs network once).
2. **Use** to make it active (only one active; others stay dormant on disk).
3. **Delete** a dormant download to reclaim space (cannot delete bundled Hey Jarvis or the active model).

---

## 3. (Append next process here)

**Template for new sections**

```markdown
## N. Short title

**Goal:** …
**When to use:** …

### N.1 Step name

```powershell
# command
```

| Part | Meaning |
|------|---------|
| … | … |

Notes: …
```

Suggested future sections:

- Circle repo check / ensure (`friend_share_ops.dart --check` / `--ensure-repo`)
- Pull Bro Code fixture from device
- Install APK to a USB phone via `adb`
- Dev vs stage flavor builds (when flavors land)
