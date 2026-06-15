# Mock Central Server

A tiny stand-in for an mSupply central server, for testing Open mSupply sync
integration locally without a real central.

It responds to all `/sync/v5/*` endpoints with minimal valid responses so that
`manualSync` can reach the integration step and process `sync_buffer` records.
Auth is not validated — any username/password is accepted, and `/api/v4/login`
returns 404 so the OMS server falls back to its local `user_account` table.

## Requirements

- Python 3 (standard library only — no dependencies)

## Usage

```bash
python3 mock_central.py --site-id <SITE_ID> --uuid <UUID> [--port 8080]
```

| Argument | Required | Description |
|---|---|---|
| `--site-id` | Yes | `siteId` reported on `/sync/v5/site` — must match your local site |
| `--uuid` | Yes | `id` (uuid) reported on `/sync/v5/site` |
| `--port` | No | Port to listen on (default: `8080`) |

### Finding `--site-id` and `--uuid`

Both values live in your local OMS database's `key_value_store` table:

| Argument | `key_value_store` key | Column |
|---|---|---|
| `--site-id` | `SETTINGS_SYNC_SITE_ID` | `value_int` |
| `--uuid` | `SETTINGS_SYNC_SITE_UUID` | `value_string` |

```sql
SELECT id, value_int, value_string
FROM key_value_store
WHERE id IN ('SETTINGS_SYNC_SITE_ID', 'SETTINGS_SYNC_SITE_UUID');
```

## Then point Open mSupply at it

Configure your `local.yaml` (username/password can be anything):

```yaml
sync:
  url: "http://localhost:8080"
  username: "anything"
  password_sha256: "anything"
```

## Example

```bash
python3 mock_central.py --site-id 42 --uuid C29FA38B0C16AC4FAEAE794DF4641ECC
```
