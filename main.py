#!/usr/bin/env python3
"""Sync routes from Garmin Connect to iGPSPORT via API.

Thin entrypoint; implementation lives in the ``g2i_route_sync`` package.
"""

from __future__ import annotations

from g2i_route_sync.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
