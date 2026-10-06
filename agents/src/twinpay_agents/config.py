"""Configuration with explicit errors and no credential logging."""

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Settings:
    agent_id: str
    api_key: str = field(repr=False)

    @classmethod
    def load(cls) -> "Settings":
        load_dotenv(PROJECT_ROOT / ".env", override=False)
        values = {name: os.environ.get(name, "").strip() for name in ("BURT_AGENT_ID", "BURT_API_KEY")}
        missing = [name for name, value in values.items() if not value]
        if missing:
            raise ValueError("Missing " + ", ".join(missing) + "; set environment variables or fill in .env.")
        return cls(agent_id=values["BURT_AGENT_ID"], api_key=values["BURT_API_KEY"])
