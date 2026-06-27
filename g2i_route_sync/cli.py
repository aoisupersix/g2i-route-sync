"""Command-line entrypoint."""

from __future__ import annotations

import argparse
import logging
import os

from dotenv import load_dotenv

from .config import AppConfig
from .sync import run_sync


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download Garmin Connect routes and upload to iGPSPORT"
    )
    parser.add_argument("--limit", type=int, default=50, help="Max routes to fetch")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be uploaded without calling iGPSPORT upload API",
    )
    parser.add_argument(
        "--state-file",
        default="sync_state.json",
        help="Deprecated and ignored (state-file based dedupe is disabled)",
    )
    parser.add_argument(
        "--garmin-session-dir",
        default="garmin_session",
        help="Directory used by garminconnect to store authentication session",
    )
    parser.add_argument(
        "--log-level",
        default=os.getenv("LOG_LEVEL", "INFO"),
        help="Logging level (DEBUG/INFO/WARNING/ERROR)",
    )
    return parser.parse_args()


def main() -> int:
    load_dotenv()
    args = parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    config = AppConfig.from_env()
    return run_sync(
        config,
        limit=args.limit,
        dry_run=args.dry_run,
        session_dir=args.garmin_session_dir,
    )
