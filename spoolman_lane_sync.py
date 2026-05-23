#!/usr/bin/env python3
"""
spoolman_lane_sync.py
=====================
Syncs Spoolman spool data into Moonraker's lane_data namespace so
OrcaSlicer automatically sees which filament is loaded in each tool.

Works with toolchangers (KTC, StealthChanger), IDEX, and any
multi-extruder Klipper setup. Hands off automatically if Happy Hare
or AFC is already managing lane_data.

Config (environment variables or .env file next to this script):
  MOONRAKER_URL      Moonraker base URL    (default: http://localhost:7125)
  SPOOLMAN_URL       Spoolman base URL     (default: http://localhost:7912)
  MOONRAKER_API_KEY  Optional API key      (if Moonraker auth is enabled)
  LOG_LEVEL          Logging verbosity     (default: INFO)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sys
from pathlib import Path
from typing import Any

try:
    import aiohttp
except ImportError:
    print("ERROR: aiohttp not found. Run:  pip install aiohttp", file=sys.stderr)
    sys.exit(1)

# ── Logging ────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
LOG = logging.getLogger("spoolman_lane_sync")

# ── Constants ──────────────────────────────────────────────────────────────────
_LANE_NS       = "lane_data"
_SOURCE_KEY    = "source"
_TOOLS_KEY     = "tools"
_MY_SOURCE     = "spoolman"
_EMPTY_SLOT: dict[str, Any] = {
    "material": "", "color": "", "vendor": "", "filament_id": ""
}
_LOC_RE        = re.compile(r"^[Tt](\d+)$")
_RECONNECT_INIT  = 2.0
_RECONNECT_MAX   = 60.0


# ── Service ────────────────────────────────────────────────────────────────────

class SpoolmanLaneSync:
    def __init__(
        self,
        moonraker_url: str,
        spoolman_url: str,
        api_key: str = "",
    ) -> None:
        self._moonraker = moonraker_url.rstrip("/")
        self._spoolman  = spoolman_url.rstrip("/")
        self._mr_headers: dict[str, str] = (
            {"X-Api-Key": api_key} if api_key else {}
        )

    # ── Entry point ────────────────────────────────────────────────────────────

    async def run(self) -> None:
        LOG.info("Moonraker: %s  |  Spoolman: %s", self._moonraker, self._spoolman)

        await self._wait_for_moonraker()

        if not await self._claim_source():
            LOG.info(
                "lane_data is owned by another system — exiting. "
                "Remove the '%s' key from the lane_data namespace to take over.",
                _SOURCE_KEY,
            )
            return

        # Run both WebSocket loops concurrently. Each does an initial sync
        # on connection (and again after every reconnect).
        await asyncio.gather(
            self._spoolman_ws_loop(),
            self._moonraker_ws_loop(),
        )

    # ── Source ownership ───────────────────────────────────────────────────────

    async def _claim_source(self) -> bool:
        """Return True if we own (or can claim) the lane_data source key."""
        source = await self._db_get(_SOURCE_KEY)
        if source is None or source == _MY_SOURCE:
            await self._db_set(_SOURCE_KEY, _MY_SOURCE)
            LOG.info("lane_data source key claimed: '%s'", _MY_SOURCE)
            return True
        LOG.warning(
            "lane_data is managed by '%s' — hands off. "
            "(Happy Hare / AFC printers should leave this running for the MMU.)",
            source,
        )
        return False

    # ── Sync ──────────────────────────────────────────────────────────────────

    async def _sync(self) -> None:
        """Fetch spools from Spoolman, build lane_data for every tool slot,
        and push to Moonraker's database."""
        try:
            num_tools = await self._get_num_tools()
            spools    = await self._fetch_spools()
        except Exception as exc:
            LOG.warning("Sync skipped: %s", exc)
            return

        # Build a map of tool-number → lane entry from spools with T* locations
        tool_map: dict[int, dict] = {}
        for spool in spools:
            loc = (spool.get("location") or "").strip()
            t = _tool_from_location(loc)
            if t is not None:
                tool_map[t] = _spool_to_lane(spool)

        # Emit every slot T0…T(n-1) — empty entry for unloaded slots so
        # OrcaSlicer knows the slot exists rather than treating it as missing.
        lane_data = {
            str(i): tool_map.get(i, _EMPTY_SLOT)
            for i in range(num_tools)
        }

        try:
            await self._db_set(_TOOLS_KEY, lane_data)
        except Exception as exc:
            LOG.warning("Failed to write lane_data: %s", exc)
            return

        loaded = sum(1 for v in lane_data.values() if v.get("material"))
        LOG.info(
            "Synced — %d/%d tools loaded:  %s",
            loaded, num_tools, _lane_summary(lane_data),
        )

    # ── Tool count (dynamic from Moonraker) ────────────────────────────────────

    async def _get_num_tools(self) -> int:
        """Query Moonraker for extruder objects to get the true tool count.
        Fully open-ended: works for 1-tool printers through 12-lane AFC systems."""
        async with aiohttp.ClientSession(headers=self._mr_headers) as s:
            async with s.get(
                f"{self._moonraker}/printer/objects/list",
                raise_for_status=True,
            ) as resp:
                data = await resp.json()

        objects: list[str] = data.get("result", {}).get("objects", [])
        extruders = [o for o in objects if re.match(r"^extruder\d*$", o)]
        count = max(len(extruders), 1)
        LOG.debug("Detected %d extruder(s): %s", count, extruders)
        return count

    # ── Spoolman REST ─────────────────────────────────────────────────────────

    async def _fetch_spools(self) -> list[dict]:
        async with aiohttp.ClientSession() as s:
            async with s.get(
                f"{self._spoolman}/api/v1/spool",
                params={"allow_archived": "false"},
                raise_for_status=True,
            ) as resp:
                return await resp.json()

    # ── Spoolman WebSocket ─────────────────────────────────────────────────────

    async def _spoolman_ws_loop(self) -> None:
        """Connect to Spoolman's WS feed, sync on every spool change event.
        Reconnects with exponential backoff on failure."""
        ws_url = (
            self._spoolman
            .replace("http://", "ws://")
            .replace("https://", "wss://")
            + "/api/v1/ws"
        )
        delay = _RECONNECT_INIT
        while True:
            try:
                async with aiohttp.ClientSession() as s:
                    async with s.ws_connect(ws_url) as ws:
                        LOG.info("Spoolman WS connected: %s", ws_url)
                        delay = _RECONNECT_INIT
                        # Sync immediately on (re)connect so we're never stale
                        await self._sync()
                        async for msg in ws:
                            if msg.type == aiohttp.WSMsgType.TEXT:
                                await self._on_spoolman_event(json.loads(msg.data))
                            elif msg.type in (
                                aiohttp.WSMsgType.CLOSED,
                                aiohttp.WSMsgType.ERROR,
                            ):
                                break
                LOG.warning("Spoolman WS closed — reconnecting in %.0fs…", delay)
            except asyncio.CancelledError:
                return
            except Exception as exc:
                LOG.warning("Spoolman WS error: %s — reconnecting in %.0fs…", exc, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, _RECONNECT_MAX)

    async def _on_spoolman_event(self, data: dict) -> None:
        if data.get("resource") == "spool" and data.get("type") in (
            "added", "updated", "deleted"
        ):
            LOG.debug("Spool '%s' event — re-syncing", data.get("type"))
            await self._sync()

    # ── Moonraker WebSocket ────────────────────────────────────────────────────

    async def _moonraker_ws_loop(self) -> None:
        """Connect to Moonraker's WS and re-sync whenever Klippy becomes ready.
        This handles printer config reloads (which can change extruder count)."""
        ws_url = (
            self._moonraker
            .replace("http://", "ws://")
            .replace("https://", "wss://")
            + "/websocket"
        )
        delay = _RECONNECT_INIT
        while True:
            try:
                headers = dict(self._mr_headers)
                async with aiohttp.ClientSession() as s:
                    async with s.ws_connect(ws_url, headers=headers) as ws:
                        LOG.info("Moonraker WS connected")
                        delay = _RECONNECT_INIT
                        async for msg in ws:
                            if msg.type == aiohttp.WSMsgType.TEXT:
                                await self._on_moonraker_event(json.loads(msg.data))
                            elif msg.type in (
                                aiohttp.WSMsgType.CLOSED,
                                aiohttp.WSMsgType.ERROR,
                            ):
                                break
                LOG.warning("Moonraker WS closed — reconnecting in %.0fs…", delay)
            except asyncio.CancelledError:
                return
            except Exception as exc:
                LOG.warning("Moonraker WS error: %s — reconnecting in %.0fs…", exc, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, _RECONNECT_MAX)

    async def _on_moonraker_event(self, data: dict) -> None:
        method = data.get("method", "")
        if method == "notify_klippy_ready":
            # Klippy restarted (e.g. after FIRMWARE_RESTART or config reload).
            # Extruder count may have changed — re-sync.
            LOG.info("Klippy ready — re-syncing lane_data")
            await self._sync()
        elif method == "notify_klippy_shutdown":
            LOG.info("Klippy shutdown — will re-sync when it comes back")

    # ── Moonraker database ─────────────────────────────────────────────────────

    async def _db_get(self, key: str) -> Any:
        async with aiohttp.ClientSession(headers=self._mr_headers) as s:
            async with s.get(
                f"{self._moonraker}/server/database/item",
                params={"namespace": _LANE_NS, "key": key},
            ) as resp:
                if resp.status == 404:
                    return None
                resp.raise_for_status()
                data = await resp.json()
                return data.get("result", {}).get("value")

    async def _db_set(self, key: str, value: Any) -> None:
        async with aiohttp.ClientSession(headers=self._mr_headers) as s:
            async with s.post(
                f"{self._moonraker}/server/database/item",
                json={"namespace": _LANE_NS, "key": key, "value": value},
                raise_for_status=True,
            ):
                pass

    # ── Startup wait ───────────────────────────────────────────────────────────

    async def _wait_for_moonraker(self) -> None:
        """Block until Moonraker is reachable and Klippy is ready."""
        LOG.info("Waiting for Moonraker…")
        delay = 2.0
        while True:
            try:
                async with aiohttp.ClientSession(headers=self._mr_headers) as s:
                    async with s.get(
                        f"{self._moonraker}/printer/info",
                        raise_for_status=True,
                    ) as resp:
                        info = await resp.json()
                        state = info.get("result", {}).get("state", "unknown")
                        if state == "ready":
                            LOG.info("Moonraker ready.")
                            return
                        LOG.info("Moonraker state: '%s' — waiting…", state)
            except Exception as exc:
                LOG.info("Moonraker not reachable (%s) — retrying in %.0fs…", exc, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 30.0)


# ── Pure helpers ───────────────────────────────────────────────────────────────

def _tool_from_location(location: str) -> int | None:
    """'T0' → 0, 'T1' → 1, 't2' → 2, anything else → None."""
    m = _LOC_RE.match(location)
    return int(m.group(1)) if m else None


def _spool_to_lane(spool: dict) -> dict:
    filament  = spool.get("filament") or {}
    vendor    = filament.get("vendor") or {}
    raw_color = filament.get("color_hex") or ""
    # Some filaments store multiple colours comma-separated; take the first.
    color_hex = raw_color.split(",")[0].replace("#", "").upper()
    return {
        "material":         filament.get("material") or "",
        "color":            color_hex,
        "vendor":           vendor.get("name") or "",
        "filament_id":      str(filament.get("id") or ""),
        "name":             filament.get("name") or "",
        "remaining_weight": spool.get("remaining_weight"),
    }


def _lane_summary(lane_data: dict) -> str:
    return "  ".join(
        f"T{i}={'empty' if not v.get('material') else v['material']}"
        for i, v in sorted(lane_data.items(), key=lambda x: int(x[0]))
    )


# ── Config (.env loader) ───────────────────────────────────────────────────────

def _load_env() -> None:
    """Load a .env file from the same directory as this script if present."""
    env_path = Path(__file__).parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        os.environ.setdefault(key.strip(), val.strip())


# ── Entry point ────────────────────────────────────────────────────────────────

def main() -> None:
    _load_env()

    level = os.getenv("LOG_LEVEL", "INFO").upper()
    logging.getLogger().setLevel(getattr(logging, level, logging.INFO))

    service = SpoolmanLaneSync(
        moonraker_url = os.getenv("MOONRAKER_URL", "http://localhost:7125"),
        spoolman_url  = os.getenv("SPOOLMAN_URL",  "http://localhost:7912"),
        api_key       = os.getenv("MOONRAKER_API_KEY", ""),
    )

    try:
        asyncio.run(service.run())
    except KeyboardInterrupt:
        LOG.info("Stopped.")


if __name__ == "__main__":
    main()
