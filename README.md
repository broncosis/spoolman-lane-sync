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
4. Fetches active spools from Spoolman, maps `Location = T0/T1/…` to slots
5. Pushes all tool slots to `lane_data.tools` — empty entry for unloaded slots
6. Listens to **Spoolman's WebSocket** — re-syncs on every spool change
7. Listens to **Moonraker's WebSocket** — re-syncs when Klippy restarts
8. Reconnects both WebSockets automatically with exponential backoff

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

## Tool assignment

In Spoolman, set the **Location** field on each spool to its tool number:

| Spoolman Location | Result in OrcaSlicer |
|-------------------|----------------------|
| `T0`              | Tool 0 (first tool)  |
| `T1`              | Tool 1               |
| `T2`              | Tool 2               |
| *(blank)*         | Slot left empty      |
| `Dry Box`         | Ignored              |

Location is case-insensitive (`t0` and `T0` both work).

Slots with no spool assigned get an empty entry — OrcaSlicer knows the slot
exists but has nothing loaded.

---

## Verify it's working

```bash
curl -s 'http://localhost:7125/server/database/item?namespace=lane_data&key=tools' \
  | python3 -m json.tool
```

Expected output (5-tool toolchanger, T0 and T1 loaded):
```json
{
  "result": {
    "namespace": "lane_data",
    "key": "tools",
    "value": {
      "0": { "material": "PLA",  "color": "FF3D00", "vendor": "eSun",  "name": "PLA Basic" },
      "1": { "material": "PETG", "color": "0047AB", "vendor": "Bambu", "name": "PETG HF"   },
      "2": { "material": "",     "color": "",        "vendor": "",      "name": ""           },
      "3": { "material": "",     "color": "",        "vendor": "",      "name": ""           },
      "4": { "material": "",     "color": "",        "vendor": "",      "name": ""           }
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
- Verify the `Location` field in Spoolman is exactly `T0`, `T1`, etc.
- Check the `lane_data.tools` key with the curl command above
- Set `LOG_LEVEL=DEBUG` and check `journalctl -u spoolman-lane-sync -f`

**Service won't start**
```bash
journalctl -u spoolman-lane-sync -n 50
```
Usually a Python version or aiohttp issue. Re-run `./install.sh`.
