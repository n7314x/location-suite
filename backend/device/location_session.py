from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
from concurrent.futures import TimeoutError as FutureTimeoutError
from collections.abc import Callable, Coroutine
from typing import Any
from urllib.request import urlopen

from backend.core.config import (
    DEVICE_COMMAND_TIMEOUT,
    TUNNELD_HOST,
    TUNNELD_PORT,
    TUNNEL_PROBE_TIMEOUT,
)


class LocationSessionError(RuntimeError):
    pass


class DirectDvtLocationSession:
    """Synchronous facade over one persistent pymobiledevice3 DVT session.

    All pymobiledevice3 objects remain on a dedicated asyncio loop for their
    entire lifetime. Public methods may be called from the simulation worker
    thread and are serialized by that worker.
    """

    def __init__(
        self,
        on_terminated: Callable[[str], None],
        *,
        command_timeout: float = DEVICE_COMMAND_TIMEOUT,
        preferred_udid: str | None = None,
    ) -> None:
        if command_timeout <= 0:
            raise ValueError("command_timeout must be positive")

        self._on_terminated = on_terminated
        self._command_timeout = command_timeout
        self._preferred_udid = (
            preferred_udid
            if preferred_udid is not None
            else os.environ.get("PYMOBILEDEVICE3_UDID")
        )

        self._thread_lock = threading.Lock()
        self._loop_ready = threading.Event()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._thread: threading.Thread | None = None
        self._shutdown = False

        # These resources are created, used, and released only on _loop.
        self._rsd: Any | None = None
        self._dvt: Any | None = None
        self._location: Any | None = None
        self._disconnect_task: asyncio.Task | None = None
        self._expected_close = False

        self._state_lock = threading.Lock()
        self._active = False
        self._logger = logging.getLogger(__name__)

    @property
    def active(self) -> bool:
        with self._state_lock:
            return self._active

    def set_termination_callback(
        self,
        callback: Callable[[str], None],
    ) -> None:
        self._on_terminated = callback

    def start(self, latitude: float, longitude: float) -> None:
        self._run(
            self._start(latitude, longitude),
            "establish persistent location session",
        )

    def update(self, latitude: float, longitude: float) -> None:
        self._run(
            self._update(latitude, longitude),
            "update simulated location",
        )

    def clear(self) -> None:
        self._run(self._clear(), "clear simulated location")

    def close(self) -> None:
        self._run(self._close(), "close location session")

    def shutdown(self) -> None:
        with self._thread_lock:
            if self._shutdown:
                return
            thread = self._thread

        if thread is None:
            with self._thread_lock:
                self._shutdown = True
            return

        try:
            self.clear()
        except LocationSessionError:
            try:
                self.close()
            except LocationSessionError:
                self._logger.exception(
                    "Unable to close persistent DVT location resources"
                )
        finally:
            with self._thread_lock:
                self._shutdown = True
                loop = self._loop

            if loop is not None:
                loop.call_soon_threadsafe(loop.stop)
            thread.join(timeout=self._command_timeout)
            if thread.is_alive():
                self._logger.error(
                    "Persistent DVT location event loop did not stop"
                )

    def _ensure_loop(self) -> asyncio.AbstractEventLoop:
        with self._thread_lock:
            if self._shutdown:
                raise LocationSessionError("Location session is shut down")

            if self._thread is None:
                self._loop_ready.clear()
                self._thread = threading.Thread(
                    target=self._loop_main,
                    name="location-dvt-session",
                    daemon=True,
                )
                self._thread.start()

        if not self._loop_ready.wait(self._command_timeout):
            raise LocationSessionError(
                "Timed out starting persistent DVT event loop"
            )

        with self._thread_lock:
            if self._loop is None:
                raise LocationSessionError(
                    "Persistent DVT event loop did not start"
                )
            return self._loop

    def _run(
        self,
        coroutine: Coroutine[Any, Any, None],
        operation: str,
    ) -> None:
        try:
            loop = self._ensure_loop()
        except Exception:
            coroutine.close()
            raise

        future = asyncio.run_coroutine_threadsafe(coroutine, loop)
        try:
            future.result(timeout=self._command_timeout)
        except FutureTimeoutError as exc:
            future.cancel()
            raise LocationSessionError(
                f"Timed out trying to {operation}"
            ) from exc
        except LocationSessionError:
            raise
        except Exception as exc:
            message = str(exc).strip() or repr(exc)
            raise LocationSessionError(message) from exc

    def _loop_main(self) -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        with self._thread_lock:
            self._loop = loop
        self._loop_ready.set()

        try:
            loop.run_forever()
        finally:
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(
                    asyncio.gather(*pending, return_exceptions=True)
                )
            loop.close()
            with self._thread_lock:
                self._loop = None

    async def _start(self, latitude: float, longitude: float) -> None:
        if self._location is not None:
            await self._update(latitude, longitude)
            return

        providers = await self._discover_providers()
        if not providers:
            raise LocationSessionError(
                "No device tunnel is available from tunneld"
            )

        try:
            rsd = self._select_provider(providers)
        except Exception:
            await asyncio.gather(
                *(provider.close() for provider in providers),
                return_exceptions=True,
            )
            raise

        await asyncio.gather(
            *(provider.close() for provider in providers if provider is not rsd),
            return_exceptions=True,
        )

        self._rsd = rsd
        self._expected_close = False

        try:
            dvt = self._create_dvt(rsd)
            location = self._create_location(dvt)
            self._dvt = dvt
            self._location = location
            await dvt.connect()
            await location.connect()
            await location.set(latitude, longitude)
        except BaseException:
            await self._release_resources()
            raise

        self._set_active(True)
        self._disconnect_task = asyncio.create_task(
            self._watch_disconnect(dvt),
            name="location-dvt-disconnect-watcher",
        )

    async def _update(self, latitude: float, longitude: float) -> None:
        if self._location is None:
            raise LocationSessionError(
                "No persistent location session is active"
            )
        await self._location.set(latitude, longitude)

    async def _clear(self) -> None:
        self._expected_close = True
        try:
            if self._location is not None:
                await self._location.clear()
        finally:
            await self._release_resources()
            self._expected_close = False

    async def _close(self) -> None:
        self._expected_close = True
        try:
            await self._release_resources()
        finally:
            self._expected_close = False

    async def _watch_disconnect(self, dvt: Any) -> None:
        try:
            await dvt.dtx.wait_disconnected()
        except asyncio.CancelledError:
            return

        if self._expected_close or dvt is not self._dvt:
            return

        self._set_active(False)
        try:
            self._on_terminated(
                "Persistent DVT location session terminated unexpectedly"
            )
        except Exception:
            self._logger.exception(
                "Location session termination callback failed"
            )
        await self._release_resources(cancel_disconnect_task=False)

    async def _release_resources(
        self,
        *,
        cancel_disconnect_task: bool = True,
    ) -> None:
        disconnect_task = self._disconnect_task
        self._disconnect_task = None

        location = self._location
        dvt = self._dvt
        rsd = self._rsd
        self._location = None
        self._dvt = None
        self._rsd = None
        self._set_active(False)

        current_task = asyncio.current_task()
        if (
            cancel_disconnect_task
            and disconnect_task is not None
            and disconnect_task is not current_task
        ):
            disconnect_task.cancel()
            await asyncio.gather(disconnect_task, return_exceptions=True)

        # LocationSimulation.close() is intentionally a no-op in 9.12.0;
        # DvtProvider owns the DTX connection and all of its channels.
        _ = location
        if dvt is not None:
            try:
                await dvt.close()
            except Exception:
                self._logger.exception("Unable to close DVT provider")
        if rsd is not None:
            try:
                await rsd.close()
            except Exception:
                self._logger.exception("Unable to close RSD provider")

    def _select_provider(self, providers: list[Any]) -> Any:
        if self._preferred_udid:
            provider = next(
                (
                    candidate
                    for candidate in providers
                    if candidate.udid == self._preferred_udid
                ),
                None,
            )
            if provider is None:
                raise LocationSessionError(
                    "Configured iPhone is not available from tunneld"
                )
            return provider

        if len(providers) > 1:
            raise LocationSessionError(
                "Multiple tunneled devices are available; set "
                "PYMOBILEDEVICE3_UDID to select one"
            )
        return providers[0]

    async def _discover_providers(self) -> list[Any]:
        try:
            from pymobiledevice3.remote.remote_service_discovery import (
                RemoteServiceDiscoveryService,
            )
        except ImportError as exc:
            raise LocationSessionError(
                "pymobiledevice3 Python package is not available"
            ) from exc

        # pymobiledevice3 9.12.0's tunneld helper performs this HTTP request
        # without a timeout. Use the same response format with a bounded local
        # request so a wedged daemon cannot strand the session event loop.
        with urlopen(
            f"http://{TUNNELD_HOST}:{TUNNELD_PORT}",
            timeout=TUNNEL_PROBE_TIMEOUT,
        ) as response:
            tunnels = json.load(response)

        if not isinstance(tunnels, dict):
            raise LocationSessionError("Unexpected response from tunneld")

        providers = []
        for details in tunnels.values():
            for tunnel in details:
                rsd = RemoteServiceDiscoveryService(
                    (
                        tunnel["tunnel-address"],
                        tunnel["tunnel-port"],
                    ),
                    name=tunnel["interface"],
                )
                try:
                    await asyncio.wait_for(
                        rsd.connect(),
                        timeout=TUNNEL_PROBE_TIMEOUT,
                    )
                except (TimeoutError, ConnectionError):
                    await asyncio.gather(
                        rsd.close(),
                        return_exceptions=True,
                    )
                    continue
                except BaseException:
                    await asyncio.gather(
                        rsd.close(),
                        return_exceptions=True,
                    )
                    raise
                providers.append(rsd)

        return providers

    @staticmethod
    def _create_dvt(rsd: Any) -> Any:
        from pymobiledevice3.services.dvt.instruments.dvt_provider import (
            DvtProvider,
        )

        return DvtProvider(rsd)

    @staticmethod
    def _create_location(dvt: Any) -> Any:
        from pymobiledevice3.services.dvt.instruments.location_simulation import (
            LocationSimulation,
        )

        return LocationSimulation(dvt)

    def _set_active(self, value: bool) -> None:
        with self._state_lock:
            self._active = value
