# Project Aur Bhai 🎙️⚡
**The Sovereign, Voice-Orchestrated Mobile Agentic OS & Local Edge Server**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![QuickJS](https://img.shields.io/badge/Runtime-Embedded_QuickJS-F7DF1E?logo=javascript)](https://bellard.org/quickjs/)
[![MCP](https://img.shields.io/badge/Bridge-Model_Context_Protocol-00F0FF)](docs/DEVELOPER_MCP_GUIDE.md)
[![Privacy](https://img.shields.io/badge/Telemetry-Zero_Cloud_Storage-10B981)](#sovereign-philosophy)

Turn your Android smartphone into an autonomous, sovereign edge server. Aur Bhai lets you orally prompt your device to generate, test, and execute sandboxed JavaScript tools (**Bhai Codes**) locally on your phone's CPU with **100% Bring-Your-Own-Key (BYOK) privacy**.

---

## 🌟 Key Pillars

1. **🛡️ 100% Sovereign & Zero-Liability BYOK:**
   - Plug in your free Google Gemini or OpenAI API key.
   - Sensor telemetry, voice recordings, and database tables stay encrypted in an on-device SQLite vault. Zero platform tracking.
2. **🧠 Embedded QuickJS Sandbox:**
   - The AI writes dynamic JavaScript on the fly.
   - Tools run directly on your phone with an automated 7-point due diligence security check (blocking malicious SQL, network exfiltration, or `eval`).
3. **🌐 Local Edge Server & HTML5 Dashboards:**
   - Built-in background Shelf HTTP server serves real-time HTML5/PWA dashboards directly from `http://localhost:8080/` or your local Wi-Fi.
4. **🔌 Desktop Developer Bridge via MCP:**
   - Author, debug, and hot-reload Bhai Code directly from **Google Antigravity**, **Cursor**, or **Claude Desktop** straight to your phone over Wi-Fi.

---

## 📐 Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                             USER VOICE / TAP                             │
└────────────────────────────────────┬─────────────────────────────────────┘
                                     │ (Audio-Direct / Text Intent)
                                     ▼
┌──────────────────────────────────────────────────────────────────────────┐
│                      AUR BHAI CORE & INTENT ROUTER                       │
│    (Single-Call Elicitation · C1 Native Shell · 4-Tier Security Matrix)  │
└──────┬─────────────────────────────┬─────────────────────────────┬───────┘
       │                             │                             │
       ▼                             ▼                             ▼
┌──────────────┐             ┌──────────────┐             ┌────────────────┐
│  QuickJS JS  │             │  Sovereign   │             │   Shelf Edge   │
│   Sandbox    │ ◄─────────► │ Vault SQLite │ ◄─────────► │  HTTP Server   │
│  (Bhai Code) │             │ (Encrypted)  │             │ (Port 8080)    │
└──────────────┘             └──────────────┘             └────────┬───────┘
                                                                   │
                                    Wi-Fi (JSON-RPC stdio proxy)   │
                          ◄────────────────────────────────────────┘
                          ▼
┌──────────────────────────────────────────────────────────────────────────┐
│            DESKTOP DEVELOPER ENVIRONMENT (MCP BRIDGE)                    │
│      Google Antigravity · Cursor · VS Code · Claude Desktop              │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 📦 Seed Bhai Code Catalog

Aur Bhai ships with a curated, inspectable seed catalog of official tools:
* **Accountant (Expenditure Logger):** Natural-language expense tracking with live categorical breakdown dashboards.
* **Telemeter:** High-frequency inertial sensor capture and real-time canvas charting.
* **Calculator:** Pure JavaScript mathematical evaluator with spoken voice responses.
* **Note Taker:** Voice-dictated notes with automatic hashtag extraction and Markdown export.
* **I Wish:** Built-in sovereign feature wishlist and offline AI roadmap triage pipeline.

---

## 🌐 Sovereign Sharing & Multi-Hop Lineage

Aur Bhai rejects central app store gatekeeping and account tracking in favor of sovereign, decentralized distribution:

1. **📦 Portable `.bundle.json` Export & Side-Loading:**
   - Tap **EXPORT** on any Bhai Code to create a portable JSON bundle containing the QuickJS script, input schema, HTML dashboards, and audit records.
   - Send via AirDrop, Bluetooth, messaging apps, or email; recipients can import and test directly in their Sandbox.
2. **👥 Friend Circle Git Sync:**
   - Connect your GitHub Personal Access Token (PAT) to sync community tools and file issue reports from the device.
   - Publish your creations directly to your friend repository or pick up community tools in Sabke Bhai.
3. **🏷️ Sovereign Handles (`@core`, `@you`, `@yourname`):**
   - Customize your sovereign creator handle in **Settings → SOVEREIGN IDENTITY & HANDLE**.
   - Your handle is cryptographically stamped on all new tools, remixes, and export bundles you author.
4. **🔀 Immutable Multi-Hop Remix Lineage:**
   - Every time a Bhai Code is remixed or modified, Aur Bhai appends a new `LineageEntry` (`@core → @alice → @bob → @you`).
   - Root creators retain permanent attribution across infinite remix hops.

---

## 🚀 Quickstart (Under 2 Minutes)

### 1. Install Android APK
Download the latest `aur-bhai-v3.12.apk` from [Releases](https://github.com/tomarishan89/project_aur_bhai/releases) and install it on any Android 8.0+ smartphone.

### 2. Enter Your Free Gemini Key
1. Open the app and open **Settings → API / LLM**.
2. Paste your free key from [Google AI Studio](https://aistudio.google.com/).
3. The app automatically validates and saves credentials in the Android Keystore.

### 3. Tap & Speak
Single-tap the glowing aura on the Command Center and say:
> *"Haan Bhai, log 350 rupees for lunch at cafe"*  
> *"Ask Calculator what is 2 to the power of 16"*  
> *"Bhai, I wish we had an offline pomodoro timer"*

---

## 💻 Developer Mode: Remote IDE Agent Authoring (MCP)

To author tools on your phone using desktop AI agents:
1. On your phone, go to **Settings → Local Edge Server** and toggle **Allow LAN access** to **ON**. Note the pair code (e.g. `8NSVBE`).
2. Open `http://<PHONE_IP>:8080/dev` on your computer to view the Developer Setup Portal.
3. Download `mcp_proxy.py` directly:
   ```bash
   curl http://<PHONE_IP>:8080/tool/mcp_proxy.py -o mcp_proxy.py
   ```
4. Add the server to your desktop MCP config (`~/.gemini/config/mcp_config.json` or Cursor Settings):
   ```json
   {
     "mcpServers": {
       "aur-bhai-phone": {
         "command": "python",
         "args": [
           "path/to/mcp_proxy.py",
           "--url", "http://<PHONE_IP>:8080/api/mcp",
           "--token", "<PAIR_TOKEN>"
         ]
       }
     }
   }
   ```
5. Full documentation is available in [`docs/DEVELOPER_MCP_GUIDE.md`](docs/DEVELOPER_MCP_GUIDE.md).

---

## 📄 Documentation & Links
* 🌐 **Showcase Landing Page:** [`docs/index.html`](docs/index.html)
* 📖 **Master Ecosystem Manifest:** [`AUR_BHAI_MANIFEST.md`](AUR_BHAI_MANIFEST.md)
* 🛠️ **Developer MCP Guide:** [`docs/DEVELOPER_MCP_GUIDE.md`](docs/DEVELOPER_MCP_GUIDE.md)

---

## 📜 License
Distributed under the **MIT License**. See `LICENSE` for more information.
