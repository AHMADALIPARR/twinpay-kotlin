"""Run Burt Parr using Band's Codex adapter."""

import asyncio

from band import Agent, configure_logging
from band.adapters.codex import CodexAdapter, CodexAdapterConfig

from twinpay_agents.config import Settings
from twinpay_agents.prompts import BURT_PROMPT


async def run() -> None:
    settings = Settings.load()
    configure_logging()
    adapter = CodexAdapter(
        config=CodexAdapterConfig(
            transport="stdio",
            custom_section=BURT_PROMPT,
            fallback_send_agent_text=True,
        )
    )
    agent = Agent.create(adapter=adapter, agent_id=settings.agent_id, api_key=settings.api_key)
    await agent.run()


def main() -> None:
    asyncio.run(run())
