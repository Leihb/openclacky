---
name: channel-setup
description: |
  Configure IM platform channels (Feishu, WeCom, Weixin) for open-clacky.
  Uses browser automation for navigation; guides the user to paste credentials and perform UI steps.
  Trigger on: "channel setup", "setup feishu", "setup wecom", "setup weixin", "setup wechat", "channel config",
  "channel status", "channel enable", "channel disable", "channel reconfigure", "channel doctor".
  Subcommands: setup, status, enable <platform>, disable <platform>, reconfigure, doctor.
argument-hint: "setup | status | enable <platform> | disable <platform> | reconfigure | doctor"
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - AskFollowupQuestion
  - Glob
  - Browser
---

# Channel Setup Skill

Configure IM platform channels for open-clacky. Config is stored at `~/.clacky/channels.yml`.

---

## Command Parsing

| User says | Subcommand |
|---|---|
| `channel setup`, `setup feishu`, `setup wecom`, `setup weixin`, `setup wechat` | setup |
| `channel status` | status |
| `channel enable feishu/wecom/weixin` | enable |
| `channel disable feishu/wecom/weixin` | disable |
| `channel reconfigure` | reconfigure |
| `channel doctor` | doctor |

---

## `status`

Read `~/.clacky/channels.yml` and display:

```
Channel Status
─────────────────────────────────────────────────────
Platform   Enabled   Details
feishu     ✅ yes    app_id: cli_xxx...  domain: feishu.cn
wecom      ❌ no     (not configured)
weixin     ✅ yes    2 account(s) logged in
─────────────────────────────────────────────────────
```

For Weixin, show `has_token: true/false` from the channels.yml entry (token is never displayed).

If the file doesn't exist: "No channels configured yet. Run `/channel-setup setup` to get started."

---

## `setup`

Ask:
> Which platform would you like to connect?
>
> 1. Feishu
> 2. WeCom (Enterprise WeChat)
> 3. Weixin (Personal WeChat via iLink QR login)

---

### Feishu setup

#### Step 1 — Try automated setup (script)

Run the setup script (full path is available in the supporting files list above):
```bash
ruby "SKILL_DIR/feishu_setup.rb"
```

**If exit code is 0:**
- The script completed successfully.
- Config is already written to `~/.clacky/channels.yml`.
- Tell the user: "✅ Feishu channel configured automatically! The channel is ready."
- **Stop here — do not proceed to manual steps.**

**If exit code is non-0 (or script not found):**
- Note the failure reason from stdout (the last `❌` line).
- Tell the user: "Automated setup encountered an issue: `<reason>`. Switching to guided setup..."
- Continue to Step 2 (manual flow) below.

---

#### Step 2 — Manual guided setup (fallback)

Only reach here if the automated script failed.

##### Phase 1 — Open Feishu Open Platform

1. Navigate: `open https://open.feishu.cn/app`. Pass `isolated: true`.
2. If a login page or QR code is shown, tell the user to log in and wait for "done".
3. Confirm the app list is visible.

##### Phase 2 — Create a new app

4. **Always create a new app** — do NOT reuse existing apps. Guide the user: "Click 'Create Enterprise Self-Built App', fill in name (e.g. Open Clacky) and description (e.g. AI assistant powered by open-clacky), then submit. Reply done." Wait for "done".

##### Phase 3 — Enable Bot capability

5. Feishu opens Add App Capabilities by default after creating an app. Guide the user: "Find the Bot capability card and click the Add button next to it, then reply done." Wait for "done".

##### Phase 4 — Get credentials

6. Navigate to Credentials & Basic Info in the left menu.
7. Guide the user: "Copy App ID and App Secret, then paste here. Reply with: App ID: xxx, App Secret: xxx" Wait for the reply. Parse `app_id` and `app_secret`.

##### Phase 5 — Add message permissions

8. Navigate to Permission Management and open the bulk import dialog.
9. Guide the user: "In the bulk import dialog, clear the existing example first (select all, delete), then paste the following JSON. Reply done." Wait for "done". Do NOT try to clear or edit via browser — user does it.

```json
{
  "scopes": {
    "tenant": [
      "im:message",
      "im:message.p2p_msg:readonly",
      "im:message:send_as_bot"
    ],
    "user": []
  }
}
```

##### Phase 6 — Configure event subscription (Long Connection)

**CRITICAL**: Feishu requires the long connection to be established *before* you can save the event config. The platform shows "No application connection detected" until `clacky server` is running and connected.

10. **Apply config and establish connection** — Run:
    ```bash
    curl -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/feishu \
      -H "Content-Type: application/json" \
      -d '{"app_id":"<APP_ID>","app_secret":"<APP_SECRET>","domain":"https://open.feishu.cn"}'
    ```
11. **Wait for connection** — Poll until log shows `[feishu-ws] WebSocket connected ✅`:
    ```bash
    for i in $(seq 1 20); do
      grep -q "\[feishu-ws\] WebSocket connected" ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log 2>/dev/null && echo "CONNECTED" && break
      sleep 1
    done
    ```
12. **Configure events** — Guide the user: "In Events & Callbacks, select 'Long Connection' mode. Click Save. Then click Add Event, search `im.message.receive_v1`, select it, click Add. Reply done." Wait for "done".

##### Phase 7 — Publish the app

13. Navigate to Version Management & Release. Guide the user: "Create a new version (e.g. 1.0.0, note: Initial release for Open Clacky) and publish it. Reply done." Wait for "done".

##### Phase 8 — Validate

```bash
curl -s -X POST "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal" \
  -H "Content-Type: application/json" \
  -d '{"app_id":"<APP_ID>","app_secret":"<APP_SECRET>"}'
```

Check for `"code":0`. On success: "✅ Feishu channel configured."

---

### WeCom setup

1. Navigate: `open https://work.weixin.qq.com/wework_admin/frame#/aiHelper/create`. Pass `isolated: true`.
2. If a login page or QR code is shown, tell the user to log in and wait for "done".
3. Guide the user: "Scroll to the bottom of the right panel and click 'API mode creation'. Reply done." Wait for "done".
4. Guide the user: "Click 'Add' next to 'Visible Range'. Select the top-level company node. Click Confirm. Reply done." Wait for "done".
5. Guide the user: "If Secret is not visible, click 'Get Secret'. Copy Bot ID and Secret **before** clicking Save. Paste here. Reply with: Bot ID: xxx, Secret: xxx" Wait for "done".
6. Guide the user: "Click Save. Enter name (e.g. Open Clacky) and description. Click Confirm. Click Save again. Reply done." Wait for "done".
7. Parse credentials. Trim whitespace. Ensure bot_id (starts with `aib`) and secret are not swapped. Run:
   ```bash
   curl -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/channels/wecom \
     -H "Content-Type: application/json" \
     -d '{"bot_id":"<BOT_ID>","secret":"<SECRET>"}'
   ```

On success: "✅ WeCom channel configured. WeCom client → Contacts → Smart Bot to find it."

---

### Weixin setup (Personal WeChat via iLink QR login)

Weixin uses a QR code login — no app_id/app_secret needed. The token from the QR scan is saved directly in `channels.yml`.

#### Step 1 — Fetch QR code and open in browser

Run the script in `--fetch-qr` mode to get the QR URL without blocking:

```bash
QR_JSON=$(ruby "SKILL_DIR/weixin_setup.rb" --fetch-qr 2>/dev/null)
echo "$QR_JSON"
```

Parse the JSON output:
- `qrcode_url` — the URL to open in browser (this IS the QR code content)
- `qrcode_id`  — the session ID needed for polling

If the output contains `"error"`, show it and stop.

Tell the user:
> Opening the WeChat QR code in your browser. Please scan it with WeChat, then confirm in the app.

**Open the QR code page in browser** — build a local URL and navigate to it:

```
http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/weixin-qr.html?url=<URL-encoded qrcode_url>
```

Use the browser tool to open this URL. The page renders a proper scannable QR code image using qrcode.js.
Do NOT open the raw `qrcode_url` directly — that page shows "请使用微信扫码打开" with no actual QR image.

#### Step 3 — Wait for scan and save credentials

Once the browser shows the QR page, immediately run the polling script in the background:

```bash
ruby "SKILL_DIR/weixin_setup.rb" --qrcode-id "$QRCODE_ID"
```

Where `$QRCODE_ID` is the `qrcode_id` from Step 2's JSON output.

This command blocks until the user scans and confirms in WeChat (up to 5 minutes), then automatically saves the token via `POST /api/channels/weixin`.

Tell the user while waiting:
> Waiting for you to scan the QR code and confirm in WeChat... (this may take a moment)

**If exit code is 0:** "✅ Weixin channel configured! You can now message your bot on WeChat."

**If exit code is non-0 or times out:** Show the error and offer to retry from Step 2.

---

## `enable`

Read `~/.clacky/channels.yml`, set `channels.<platform>.enabled: true`, write back.

If the platform has no credentials, redirect to `setup`.

Say: "✅ `<platform>` channel enabled. Restart `clacky server` to activate."

---

## `disable`

Read `~/.clacky/channels.yml`, set `channels.<platform>.enabled: false`, write back.

Say: "❌ `<platform>` channel disabled. Restart `clacky server` to deactivate."

---

## `reconfigure`

1. Show current config (mask secrets).
2. Ask: update credentials / change allowed users / add a new platform / enable or disable a platform.
3. For credential updates, re-run the relevant setup flow.
4. Write atomically: write to `~/.clacky/channels.yml.tmp` then rename to `~/.clacky/channels.yml`.
5. Say: "Restart `clacky server` to apply changes."

---

## `doctor`

Check each item, report ✅ / ❌ with remediation:

1. **Config file** — does `~/.clacky/channels.yml` exist and is it readable?
2. **Required keys** — for each enabled platform:
   - Feishu: `app_id`, `app_secret` present and non-empty
   - WeCom: `bot_id`, `secret` present and non-empty
   - Weixin: `token` present and non-empty in `channels.yml`
3. **Feishu credentials** (if enabled) — run the token API call, check `code=0`.
4. **Weixin token** (if enabled) — call `GET /api/channels` and check `has_token: true` for the weixin entry.
5. **WeCom credentials** (if enabled) — search today's log:
   ```bash
   grep -iE "wecom adapter loop started|WeCom authentication failed|WeCom WS error response|WecomAdapter" \
     ~/.clacky/logger/clacky-$(date +%Y-%m-%d).log
   ```
   - `WeCom authentication failed` or non-zero errcode → ❌ "WeCom credentials incorrect"
   - `adapter loop started` with no auth error → ✅

---

## Security

- Always mask secrets in output (last 4 chars only).
- Config file must be `chmod 600`.
