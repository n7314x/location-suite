from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass

from backend.core.config import PMD3


@dataclass
class CommandResult:
    returncode: int | None
    stdout: str
    stderr: str
    timed_out: bool = False

    @property
    def combined(self) -> str:
        parts = (
            self.stdout.strip(),
            self.stderr.strip(),
        )
        return "\n".join(part for part in parts if part)

    @property
    def failed(self) -> bool:
        if self.timed_out:
            return True

        if self.returncode != 0:
            return True

        text = self.combined

        patterns = (
            r"Traceback \(most recent call last\)",
            r"Unable to connect to Tunneld",
            r"NoDeviceConnectedError",
            r"(^|\s)ERROR\s",
        )

        return any(
            re.search(pattern, text, flags=re.MULTILINE)
            for pattern in patterns
        )


def run_pmd3(
    args: list[str],
    timeout: int = 30,
) -> CommandResult:
    if not PMD3.exists():
        return CommandResult(
            returncode=None,
            stdout="",
            stderr=f"pymobiledevice3 not found at {PMD3}",
        )

    try:
        result = subprocess.run(
            [str(PMD3), *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""

        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")

        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")

        return CommandResult(
            returncode=None,
            stdout=stdout,
            stderr=stderr,
            timed_out=True,
        )

    return CommandResult(
        returncode=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
    )
