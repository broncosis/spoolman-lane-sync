# Spoolman Lane Sync

Syncs Spoolman filament data into Moonraker's `lane_data` namespace so
OrcaSlicer automatically sees which filament is loaded in each tool slot.

Works with toolchangers (KTC, StealthChanger), IDEX, and any multi-extruder
Klipper setup. Fully open-ended tool count — 1 tool through 12+ lanes, no
configuration required.

**Hands off automatically** if Happy Hare or AFC is already managing
`lane_data` — safe to install on any printer.

---

## How it works

1. On startup, checks Moonraker's `lane_data.source` key
2. If unclaimed (or claimed by `spoolman`), takes ownership and syncs
3. Queries Moonraker for the actual extruder count (open-ended)
4. Reads per-tool spool assignments from Klipper's `save_variables`
5. Fetches each spool's details from Spoolman by ID
6. Pushes all tool slots to `lane_data.tools` — empty entry for unloaded slots
7. Listens to **Spoolman's WebSocket** — re-syncs on every spool change
8. Listens to **Moonraker's WebSocket** — re-syncs when a spool is reassigned or Klippy restarts
9. Reconnects both WebSockets automatically with exponential backoff

---

## Requirements

- Python 3.10+
- `aiohttp` (installed automatically by `install.sh`)
- Moonraker and Spoolman accessible on your local network

---

## Install

```bash
cd ~
git clone https://github.com/Broncosis/spoolman-lane-sync
cd spoolman-lane-sync
./install.sh
```

Edit config:
```bash
nano .env
```

Start:
```bash
sudo systemctl start spoolman-lane-sync
```

Watch logs:
```bash
journalctl -u spoolman-lane-sync -f
```

---

## How spool assignments work

The service reads spool assignments directly from Klipper's `save_variables`.
No extra steps needed — if your tool macros already track which spool is loaded,
the sync is fully automatic.

### save_variables (primary — recommended)

Your tool macros store the active Spoolman spool ID in a saved variable named
`T0__spool_id`, `T1__spool_id`, etc. The service reads these automatically.

If you use KTC, StealthChanger, or a similar toolchanger setup that already
manages spool IDs in macros, **nothing extra is required**.

Example variables file entry:
```
[Variables]
t0__spool_id = 32
t1__spool_id = 15
t2__spool_id = 22
```

### Spoolman Location field (fallback)

If no `save_variables` assignments are found, the service falls back to
matching spools by their **Location** field in Spoolman. Set the Location
to the tool number to assign it:

| Spoolman Location | Result in OrcaSlicer |
|-------------------|----------------------|
| `T0`              | Tool 0 (first tool)  |
| `T1`              | Tool 1               |
| `T2`              | Tool 2               |
| *(blank)*         | Slot left empty      |
| `Dry Box`         | Ignored              |

Location is case-insensitive (`t0` and `T0` both work).

---

## Verify it's working

```bash
curl -s 'http://localhost:7125/server/database/item?namespace=lane_data&key=tools' \
  | python3 -m json.tool
```

Expected output (5-tool toolchanger, all slots loaded):
```json
{
  "result": {
    "namespace": "lane_data",
    "key": "tools",
    "value": {
      "0": { "material": "PLA",  "color": "E22A15", "vendor": "Mater3d", "name": "Pla Red"   },
      "1": { "material": "PLA",  "color": "2815D6", "vendor": "Mater3d", "name": "Pla Blue"  },
      "2": { "material": "PLA",  "color": "B80FD2", "vendor": "Eryone",  "name": "Pla Purple"},
      "3": { "material": "PLA",  "color": "000000", "vendor": "Mater3d", "name": "Pla Black" },
      "4": { "material": "PLA+", "color": "FFFFFF", "vendor": "ELEGOO",  "name": "Pla White" }
    }
  }
}
```

---

## Configuration

All settings go in `.env` (copied from `.env.example` by `install.sh`):

| Variable           | Default                   | Description                        |
|--------------------|---------------------------|------------------------------------|
| `MOONRAKER_URL`    | `http://localhost:7125`   | Moonraker base URL                 |
| `SPOOLMAN_URL`     | `http://localhost:7912`   | Spoolman base URL                  |
| `MOONRAKER_API_KEY`| *(blank)*                 | API key if Moonraker auth is on    |
| `LOG_LEVEL`        | `INFO`                    | `DEBUG` / `INFO` / `WARNING`       |

Set `LOG_LEVEL=DEBUG` to see every sync and WebSocket event in the logs.

---

## Coexistence with Happy Hare / AFC

This service checks the `lane_data.source` key in Moonraker's database before
doing anything:

- If the key is **absent** or set to `spoolman` → takes ownership and syncs
- If the key is set to `happy_hare`, `afc`, or anything else → exits immediately

To take over from a previous system (e.g. if you switched from Happy Hare to
a toolchanger):

```bash
curl -s -X DELETE \
  'http://localhost:7125/server/database/item?namespace=lane_data&key=source'
sudo systemctl restart spoolman-lane-sync
```

---

## Uninstall

```bash
sudo systemctl stop spoolman-lane-sync
sudo systemctl disable spoolman-lane-sync
sudo rm /etc/systemd/system/spoolman-lane-sync.service
sudo systemctl daemon-reload
```

---

## Troubleshooting

**"lane_data is owned by another system"**
Another service (Happy Hare, AFC) wrote the source key first. See *Coexistence*
section above.

**"Sync skipped: …"**
Spoolman or Moonraker wasn't reachable at sync time. The service retries
automatically via the WebSocket reconnect loop. Check URLs in `.env`.

**OrcaSlicer shows wrong/no filament**
- Check that `save_variables` has `t0__spool_id`, `t1__spool_id`, etc.
- Verify with: `curl -s 'http://localhost:7125/printer/objects/query?save_variables' | python3 -m json.tool`
- Check the `lane_data.tools` key with the curl command above
- Set `LOG_LEVEL=DEBUG` and check `journalctl -u spoolman-lane-sync -f`

**Service won't start**
```bash
journalctl -u spoolman-lane-sync -n 50
```
Usually a Python version or aiohttp issue. Re-run `./install.sh`.
