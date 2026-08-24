# Project Aur Bhai — Remote Developer Guide (MCP Bridge)

This guide explains how external developers can author, refine, test, and deploy **Bhai Code (Agents)** directly on an Android device using desktop IDEs (**Antigravity**, **Cursor**, **VS Code**, or **Claude Desktop**) via the Model Context Protocol (MCP).

---

## 1. Overview & Architecture

Instead of coding on a mobile touch keyboard in "Author Mode", the **MCP Bridge** lets you use full desktop AI coding agents to write JavaScript and HTML/CSS dashboards that execute directly in your phone's secure QuickJS sovereign sandbox over local Wi-Fi.

```
┌───────────────────────────┐           Wi-Fi (HTTP / JSON-RPC)          ┌───────────────────────────────────┐
│        Desktop IDE        │ ◄────────────────────────────────────────► │     Aur Bhai Android Device       │
│ (Antigravity / Cursor)    │                                            │ (Local Shelf Server on Port 8080) │
│             │             │                                            └─────────────────┬─────────────────┘
│       stdio │             │                                                              │
│             ▼             │                                                              │
│      mcp_proxy.py         │                                                              ▼
│  (JSON-RPC stdio adapter) │                                                    Sovereign Vault & QuickJS
└───────────────────────────┘                                                   (JS Agent Registry & SQLite)
```

---

## 2. Setting Up Your Phone

1. Ensure your phone and your computer are connected to the **same Wi-Fi network**.
2. Open **Project Aur Bhai** on your phone.
3. Open the navigation drawer and go to **Settings → Local Edge Server**.
4. Toggle **Allow LAN access** to **ON**.
5. Note the **DEVELOPER MODE (MCP BRIDGE)** info card:
   - **Local Edge Server URL**: e.g., `http://192.168.1.50:8080/api/mcp`
   - **Pair Code / Token**: e.g., `8NSVBE`

---

## 3. Configuring Your Desktop IDE

### A. Google Antigravity
Add the server definition to `~/.gemini/config/mcp_config.json`:

```json
{
  "mcpServers": {
    "aur-bhai-phone": {
      "command": "python",
      "args": [
        "path/to/tool/mcp_proxy.py",
        "--url",
        "http://<PHONE_IP>:8080/api/mcp",
        "--token",
        "<PAIR_TOKEN>"
      ]
    }
  }
}
```

### B. Cursor / Claude Desktop
In Cursor (**Settings → Features → MCP**) or Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "aur-bhai": {
      "command": "python",
      "args": [
        "path/to/tool/mcp_proxy.py",
        "--url",
        "http://<PHONE_IP>:8080/api/mcp",
        "--token",
        "<PAIR_TOKEN>"
      ]
    }
  }
}
```

---

## 4. Available MCP Tools

Once connected, your desktop AI agent has direct access to the phone via 5 tools:

| Tool | Purpose | Example Usage |
| :--- | :--- | :--- |
| `mcp_list_agents` | Lists all installed agents on the device | *"What agents are installed on my phone?"* |
| `mcp_read_agent` | Reads the active script, schema, and vault assets (HTML) | *"Read the Accountant agent source code."* |
| `mcp_deploy_agent` | Deploys/updates an agent directly into the phone's Sovereign Vault | *"Deploy this updated script to my Accountant agent."* |
| `mcp_run_agent` | Executes an agent live in the phone's QuickJS engine and returns logs | *"Run the Accountant agent with parameters."* |
| `mcp_query_telemetry` | Executes a guarded read-only SQL query on the device vault | *"Check the last 10 entries in the telemetry table."* |

---

## 5. Distributing `mcp_proxy.py` to External Contributors

Because the primary Project Aur Bhai repository is private, external creators and circle members should not need full repository access just to author Bhai Code.

### Distribution Strategies (Roadmap):
1. **Direct Download from the Phone (Recommended)**:
   The phone's Local Edge Server can serve `mcp_proxy.py` directly from `http://<PHONE_IP>:8080/tool/mcp_proxy.py` or through the Web Vault dashboard. A contributor connects their browser to the phone, downloads the 50-line single-file proxy script, and pastes it into their IDE.
2. **Public Gist / Single-File Release**:
   Host `mcp_proxy.py` in a public GitHub Gist or lightweight standalone public repo (`project-aur-bhai-bridge`) with zero external dependencies (uses Python standard library `urllib`).
3. **Stand-alone npx / pip CLI**:
   `npx @aur-bhai/mcp-proxy --url http://192.168.1.50:8080/api/mcp --token ABCDEF` for zero-install execution.
