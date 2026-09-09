from __future__ import annotations

import sqlite3
import threading
from datetime import UTC, datetime
from pathlib import Path

from backend.core.config import DATABASE_PATH, HISTORY_LIMIT


class FavoriteNotFound(LookupError):
    pass


class DuplicateFavorite(ValueError):
    pass


class LocationStore:
    SCHEMA_VERSION = 1

    def __init__(
        self,
        path: Path = DATABASE_PATH,
        *,
        history_limit: int = HISTORY_LIMIT,
    ) -> None:
        if history_limit < 1:
            raise ValueError("history_limit must be at least 1")
        self.path = Path(path)
        self.history_limit = history_limit
        self._initialized = False
        self._initialization_lock = threading.Lock()

    def initialize(self) -> None:
        if self._initialized:
            return
        with self._initialization_lock:
            if self._initialized:
                return
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self._connect() as connection:
                connection.executescript(
                    """
                    CREATE TABLE IF NOT EXISTS favorites (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT NOT NULL,
                        latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
                        longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180),
                        created_at TEXT NOT NULL,
                        updated_at TEXT NOT NULL,
                        UNIQUE(latitude, longitude)
                    );

                    CREATE TABLE IF NOT EXISTS location_history (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT,
                        latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
                        longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180),
                        created_at TEXT NOT NULL
                    );

                    CREATE INDEX IF NOT EXISTS idx_history_created_at
                    ON location_history(created_at DESC, id DESC);
                    """
                )
                connection.execute(f"PRAGMA user_version = {self.SCHEMA_VERSION}")
            self._initialized = True

    def create_favorite(
        self,
        latitude: float,
        longitude: float,
        name: str | None = None,
    ) -> dict:
        self.initialize()
        now = self._timestamp()
        normalized_name = self._location_name(name, latitude, longitude)
        try:
            with self._connect() as connection:
                cursor = connection.execute(
                    """
                    INSERT INTO favorites(
                        name, latitude, longitude, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    (normalized_name, latitude, longitude, now, now),
                )
                row = connection.execute(
                    "SELECT * FROM favorites WHERE id = ?",
                    (cursor.lastrowid,),
                ).fetchone()
        except sqlite3.IntegrityError as exc:
            if "UNIQUE" in str(exc).upper():
                raise DuplicateFavorite(
                    "That location is already a favorite"
                ) from exc
            raise
        return self._favorite_dict(row)

    def list_favorites(self) -> list[dict]:
        self.initialize()
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM favorites
                ORDER BY updated_at DESC, id DESC
                """
            ).fetchall()
        return [self._favorite_dict(row) for row in rows]

    def rename_favorite(self, favorite_id: int, name: str) -> dict:
        self.initialize()
        normalized_name = name.strip()
        if not normalized_name:
            raise ValueError("Favorite name cannot be empty")
        with self._connect() as connection:
            cursor = connection.execute(
                """
                UPDATE favorites SET name = ?, updated_at = ? WHERE id = ?
                """,
                (normalized_name, self._timestamp(), favorite_id),
            )
            if cursor.rowcount == 0:
                raise FavoriteNotFound("Favorite not found")
            row = connection.execute(
                "SELECT * FROM favorites WHERE id = ?",
                (favorite_id,),
            ).fetchone()
        return self._favorite_dict(row)

    def delete_favorite(self, favorite_id: int) -> None:
        self.initialize()
        with self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM favorites WHERE id = ?",
                (favorite_id,),
            )
            if cursor.rowcount == 0:
                raise FavoriteNotFound("Favorite not found")

    def add_history(
        self,
        latitude: float,
        longitude: float,
        name: str | None = None,
        *,
        created_at: datetime | None = None,
    ) -> dict:
        self.initialize()
        timestamp = self._timestamp(created_at)
        normalized_name = name.strip() if name and name.strip() else None
        with self._connect() as connection:
            cursor = connection.execute(
                """
                INSERT INTO location_history(
                    name, latitude, longitude, created_at
                ) VALUES (?, ?, ?, ?)
                """,
                (normalized_name, latitude, longitude, timestamp),
            )
            history_id = cursor.lastrowid
            connection.execute(
                """
                DELETE FROM location_history
                WHERE id NOT IN (
                    SELECT id FROM location_history
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                )
                """,
                (self.history_limit,),
            )
            row = connection.execute(
                "SELECT * FROM location_history WHERE id = ?",
                (history_id,),
            ).fetchone()
        return self._history_dict(row)

    def list_history(self, *, limit: int | None = None) -> list[dict]:
        self.initialize()
        requested_limit = self.history_limit if limit is None else limit
        requested_limit = max(1, min(requested_limit, self.history_limit))
        with self._connect() as connection:
            rows = connection.execute(
                """
                SELECT * FROM location_history
                ORDER BY created_at DESC, id DESC
                LIMIT ?
                """,
                (requested_limit,),
            ).fetchall()
        return [self._history_dict(row) for row in rows]

    def clear_history(self) -> int:
        self.initialize()
        with self._connect() as connection:
            cursor = connection.execute("DELETE FROM location_history")
        return cursor.rowcount

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        return connection

    @staticmethod
    def _timestamp(value: datetime | None = None) -> str:
        timestamp = value or datetime.now(UTC)
        if timestamp.tzinfo is None:
            timestamp = timestamp.replace(tzinfo=UTC)
        return timestamp.astimezone(UTC).isoformat()

    @staticmethod
    def _location_name(
        name: str | None,
        latitude: float,
        longitude: float,
    ) -> str:
        if name and name.strip():
            return name.strip()
        return f"{latitude:.6f}, {longitude:.6f}"

    @staticmethod
    def _favorite_dict(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "name": row["name"],
            "latitude": row["latitude"],
            "longitude": row["longitude"],
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    @staticmethod
    def _history_dict(row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "name": row["name"],
            "latitude": row["latitude"],
            "longitude": row["longitude"],
            "createdAt": row["created_at"],
        }


location_store = LocationStore()
