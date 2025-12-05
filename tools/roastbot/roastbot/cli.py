from __future__ import annotations
# Note: Keep PR sizes small; this CLI supports polling but use sensible intervals.


import logging
import time
from typing import Optional

import rich
import typer

from .config import Settings
from .controller import Controller

app = typer.Typer(add_completion=False)


def _setup_logging(level: str) -> None:
    logging.basicConfig(level=getattr(logging, level.upper(), logging.INFO), format="[%(levelname)s] %(message)s")


@app.command()
def run(config: Optional[str] = typer.Option(None, help="Path to config.yaml")) -> None:
    settings = Settings.from_env_or_file(config)
    _setup_logging(settings.log_level)
    rich.print(f"[bold]RoastBot[/bold] starting; repos: {settings.repos}")
    Controller(settings).run_once()


@app.command()
def poll(config: Optional[str] = typer.Option(None, help="Path to config.yaml")) -> None:
    settings = Settings.from_env_or_file(config)
    _setup_logging(settings.log_level)
    rich.print(f"[bold]RoastBot[/bold] polling every {settings.poll_interval}s; repos: {settings.repos}")
    ctl = Controller(settings)
    while True:
        try:
            ctl.run_once()
        except Exception as e:
            logging.exception("Run failed: %s", e)
        time.sleep(settings.poll_interval)


if __name__ == "__main__":
    app()
