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

## 2. (Append next process here)

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

Suggested future sections (not written yet):

- Circle repo check / ensure (`friend_share_ops.dart --check` / `--ensure-repo`)
- Pull Bro Code fixture from device
- Install APK to a USB phone via `adb`
- Dev vs stage flavor builds (when flavors land)
