from __future__ import annotations

import sqlite3
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

from backend.storage.database import (
    DuplicateFavorite,
    FavoriteNotFound,
    LocationStore,
)


class LocationStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.database_path = (
            Path(self.temporary_directory.name) / "nested" / "locations.sqlite3"
        )
        self.store = LocationStore(self.database_path, history_limit=3)

    def test_initializes_database_schema_automatically(self) -> None:
        self.assertFalse(self.database_path.exists())

        self.store.list_favorites()

        self.assertTrue(self.database_path.exists())
        with sqlite3.connect(self.database_path) as connection:
            tables = {
                row[0]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'"
                )
            }
            version = connection.execute("PRAGMA user_version").fetchone()[0]

        self.assertIn("favorites", tables)
        self.assertIn("location_history", tables)
        self.assertEqual(version, LocationStore.SCHEMA_VERSION)

    def test_favorites_crud_and_duplicate_prevention(self) -> None:
        favorite = self.store.create_favorite(40.6892, -74.0445)
        self.assertEqual(favorite["name"], "40.689200, -74.044500")
        self.assertEqual(self.store.list_favorites(), [favorite])

        with self.assertRaises(DuplicateFavorite):
            self.store.create_favorite(
                40.6892,
                -74.0445,
                "Duplicate",
            )

        renamed = self.store.rename_favorite(favorite["id"], "Liberty")
        self.assertEqual(renamed["name"], "Liberty")

        self.store.delete_favorite(favorite["id"])
        self.assertEqual(self.store.list_favorites(), [])
        with self.assertRaises(FavoriteNotFound):
            self.store.delete_favorite(favorite["id"])

    def test_history_prunes_to_limit_and_clears(self) -> None:
        beginning = datetime(2026, 1, 1, tzinfo=UTC)
        for index in range(5):
            self.store.add_history(
                float(index),
                float(-index),
                f"Place {index}",
                created_at=beginning + timedelta(minutes=index),
            )

        history = self.store.list_history()
        self.assertEqual(len(history), 3)
        self.assertEqual(
            [item["name"] for item in history],
            ["Place 4", "Place 3", "Place 2"],
        )
        self.assertEqual(self.store.clear_history(), 3)
        self.assertEqual(self.store.list_history(), [])


if __name__ == "__main__":
    unittest.main()
