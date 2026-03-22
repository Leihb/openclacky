# Session Management Redesign

> Status: Design finalized, pending implementation
> Date: 2026-03-22

---

## Background

Current session management has several problems:

| Problem | Detail |
|---------|--------|
| **Delete bug (P0)** | `DELETE /api/sessions/:id` only removes from in-memory registry, disk JSON file is never deleted |
| **Retention too small** | `cleanup_by_count(keep: 10)` — floods quickly with cron + channel sessions |
| **Only 5 sessions restored on startup** | Misses most cron/channel history |
| **No agent type selection in WebUI** | Always creates `general` profile, no UI to choose |
| **No session source tracking** | No `source` field — can't distinguish manual vs cron vs channel |
| **No agent profile tracking** | No `agent_profile` field in session JSON |

---

## UI Design

### Sidebar Layout

```
┌─────────────────────────────────┐
│  Sessions          [+ ▾]        │
├─────────────────────────────────┤
│  Manual  Scheduled  Channel     │  ← tab 切换
├─────────────────────────────────┤
│                                  │
│  ● Session 3        2t  $0.02   │
│  ○ Session 2        5t  $0.08   │
│  ○ Session 1        1t  $0.01   │
│                                  │
├─────────────────────────────────┤
│  👨‍💻 Coding                       │  ← 固定区域，不参与 tab
├─────────────────────────────────┤
│  ● 重构 auth 模块   3t  $0.05   │
│  ○ 接口联调         1t  $0.02   │
└─────────────────────────────────┘
```

**Upper area — General Agent sessions:**
- Three tabs: `Manual` / `Scheduled` / `Channel`
- Default tab: `Manual`
- Each tab shows sessions filtered by `source` field AND `agent_profile = general`
- Scheduled and Channel tabs show sessions where `agent_profile = general` AND `source = cron/channel`

**Lower area — Coding Agent (and future agents):**
- Fixed section, always visible, does not participate in tab switching
- Shows all sessions where `agent_profile = coding`, regardless of source
- Future custom agents each get their own section below Coding

---

### New Session Button: `[+ ▾]`

```
┌─────────────────────────────────┐
│  Sessions          [+ ▾]        │
└─────────────────────────────────┘
```

- **Click `+`** → immediately create a new General session (zero friction, most common action)
- **Click `▾`** → dropdown appears:

```
                    ┌──────────────────┐
                    │ ✦ General        │
                    │ 👨‍💻 Coding         │
                    │ ──────────────── │
                    │ + Create Agent   │  ← future
                    └──────────────────┘
```

- Selecting an agent from the dropdown creates a new session with that `agent_profile`
- `Create Agent` is a placeholder for future custom agent creation UI

---

## Data Layer Changes

### Session JSON — new fields

```json
{
  "session_id": "...",
  "source": "manual",
  "agent_profile": "general",
  ...
}
```

**`source` values:** `manual` | `cron` | `channel`
**`agent_profile` values:** `general` | `coding` | `<custom-name>`

### `build_session` signature update

```ruby
build_session(
  name:,
  working_dir:,
  source: :manual,          # :manual | :cron | :channel
  profile: "general",       # agent profile name
  permission_mode: :confirm_all
)
```

Both `source` and `agent_profile` must be serialized into the session JSON and restored on `from_session`.

---

## New API Endpoints

### `GET /api/agents`

Returns all available agent profiles (built-in + user custom).

Scan order:
1. `~/.clacky/agents/<name>/profile.yml` (user override / custom)
2. `<gem>/lib/clacky/default_agents/<name>/profile.yml` (built-in)

Response:
```json
{
  "agents": [
    { "name": "general", "description": "A versatile digital employee living on your computer", "builtin": true },
    { "name": "coding",  "description": "AI coding assistant and technical co-founder", "builtin": true },
    { "name": "my-pm",   "description": "Product manager assistant", "builtin": false }
  ]
}
```

### `POST /api/sessions` — updated body

```json
{
  "name": "Session 4",
  "agent_profile": "coding"
}
```

`source` is always `manual` for API-created sessions. `agent_profile` defaults to `"general"` if omitted.

### `DELETE /api/sessions/:id` — fix

Must delete the disk JSON file in addition to removing from registry:

```ruby
def api_delete_session(session_id, res)
  if @registry.delete(session_id)
    @session_manager.delete(session_id)   # ← ADD THIS
    broadcast(session_id, { type: "session_deleted", session_id: session_id })
    unsubscribe_all(session_id)
    json_response(res, 200, { ok: true })
  else
    json_response(res, 404, { error: "Session not found" })
  end
end
```

`SessionManager` needs a `delete(session_id)` method that finds and removes the file by session_id prefix.

---

## Persistence Strategy Changes

| Setting | Current | New |
|---------|---------|-----|
| Count limit | `keep: 10` | `keep: 200` |
| Time-based cleanup | None | Delete sessions not accessed in **90 days** |
| Cleanup timing | On every save | On server startup + every 24h |
| Sessions restored on startup | 5 (current dir only) | 20 (current dir) |

---

## Implementation Order

1. **Fix DELETE bug** — `api_delete_session` + `SessionManager#delete` by session_id
2. **Data fields** — add `source` + `agent_profile` to `build_session`, `to_session_data`, `restore_session`
3. **Channel/Cron tagging** — pass `source: :channel` / `source: :cron` when `ChannelManager` and cron create sessions
4. **Persistence upgrade** — `keep: 200`, 90-day cleanup, restore 20 on startup
5. **`GET /api/agents`** — scan both dirs, merge, return list
6. **Frontend — sidebar redesign** — Manual/Scheduled/Channel tabs + Coding fixed section
7. **Frontend — `[+ ▾]` button** — split button with agent dropdown

---

## File Locations

| File | Change |
|------|--------|
| `lib/clacky/session_manager.rb` | Add `delete(session_id)`, change keep to 200, add 90-day cleanup |
| `lib/clacky/agent/session_serializer.rb` | Serialize/restore `source` + `agent_profile` |
| `lib/clacky/server/http_server.rb` | Fix `api_delete_session`, add `GET /api/agents`, update `build_session`, restore 20 sessions |
| `lib/clacky/server/session_registry.rb` | Expose `agent_profile` + `source` in `session_summary` |
| `lib/clacky/server/channel/channel_manager.rb` | Pass `source: :channel` to `build_session` |
| `lib/clacky/web/sessions.js` | Tab switching, Coding section, `[+ ▾]` button |
| CSS / HTML template | New sidebar layout, tab styles, split button |
