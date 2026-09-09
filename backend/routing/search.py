from __future__ import annotations

import hashlib
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from backend.core.config import (
    SEARCH_BASE_URL,
    SEARCH_CACHE_ENTRIES,
    SEARCH_CACHE_SECONDS,
    SEARCH_TIMEOUT,
)


class SearchProviderError(RuntimeError):
    pass


@dataclass(frozen=True)
class SearchResult:
    id: str
    display_name: str
    latitude: float
    longitude: float
    category: str | None = None
    result_type: str | None = None
    address_components: dict[str, str] | None = None

    def as_dict(self) -> dict:
        result = {
            "id": self.id,
            "displayName": self.display_name,
            "latitude": self.latitude,
            "longitude": self.longitude,
        }
        if self.category is not None:
            result["category"] = self.category
        if self.result_type is not None:
            result["type"] = self.result_type
        if self.address_components:
            result["addressComponents"] = self.address_components
        return result


class SearchProvider(Protocol):
    def search(self, query: str, *, limit: int = 6) -> list[SearchResult]: ...


JsonFetcher = Callable[[str, float, dict[str, str]], object]


def _fetch_json(
    url: str,
    timeout: float,
    headers: dict[str, str],
) -> object:
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
        raise SearchProviderError(f"Search provider unavailable: {exc}") from exc
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise SearchProviderError("Search provider returned invalid JSON") from exc


class PhotonSearchProvider:
    """OpenStreetMap Photon adapter with normalized application results."""

    _ADDRESS_KEYS = {
        "housenumber": "houseNumber",
        "street": "street",
        "district": "district",
        "locality": "locality",
        "city": "city",
        "county": "county",
        "state": "state",
        "postcode": "postcode",
        "country": "country",
        "countrycode": "countryCode",
    }

    def __init__(
        self,
        *,
        base_url: str = SEARCH_BASE_URL,
        timeout: float = SEARCH_TIMEOUT,
        fetch_json: JsonFetcher = _fetch_json,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout
        self._fetch_json = fetch_json

    def search(self, query: str, *, limit: int = 6) -> list[SearchResult]:
        parameters = urllib.parse.urlencode(
            {
                "q": query,
                "limit": limit,
                "lang": "en",
            }
        )
        payload = self._fetch_json(
            f"{self._base_url}/api?{parameters}",
            self._timeout,
            {
                "Accept": "application/geo+json, application/json",
                "User-Agent": "Location-Suite/0.4",
            },
        )
        return self.normalize_response(payload, limit=limit)

    @classmethod
    def normalize_response(
        cls,
        payload: object,
        *,
        limit: int = 6,
    ) -> list[SearchResult]:
        if not isinstance(payload, dict):
            raise SearchProviderError("Search provider returned an invalid response")

        features = payload.get("features")
        if not isinstance(features, list):
            raise SearchProviderError("Search provider response has no features")

        results: list[SearchResult] = []
        for feature in features:
            normalized = cls.normalize_feature(feature)
            if normalized is not None:
                results.append(normalized)
            if len(results) >= limit:
                break
        return results

    @classmethod
    def normalize_feature(cls, feature: object) -> SearchResult | None:
        if not isinstance(feature, dict):
            return None

        geometry = feature.get("geometry")
        properties = feature.get("properties")
        if not isinstance(geometry, dict) or not isinstance(properties, dict):
            return None

        coordinates = geometry.get("coordinates")
        if not isinstance(coordinates, list) or len(coordinates) < 2:
            return None

        try:
            longitude = float(coordinates[0])
            latitude = float(coordinates[1])
        except (TypeError, ValueError):
            return None

        if not (-90 <= latitude <= 90 and -180 <= longitude <= 180):
            return None

        address_components = {
            normalized_key: value.strip()
            for provider_key, normalized_key in cls._ADDRESS_KEYS.items()
            if isinstance((value := properties.get(provider_key)), str)
            and value.strip()
        }

        display_name = cls._display_name(properties, address_components)
        if not display_name:
            return None

        osm_type = cls._clean_string(properties.get("osm_type"))
        osm_id = properties.get("osm_id")
        if osm_type and osm_id is not None:
            result_id = f"osm:{osm_type}:{osm_id}"
        else:
            identity = f"{display_name}|{latitude:.7f}|{longitude:.7f}"
            digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]
            result_id = f"photon:{digest}"

        return SearchResult(
            id=result_id,
            display_name=display_name,
            latitude=latitude,
            longitude=longitude,
            category=cls._clean_string(properties.get("osm_key")),
            result_type=(
                cls._clean_string(properties.get("osm_value"))
                or cls._clean_string(properties.get("type"))
            ),
            address_components=address_components or None,
        )

    @classmethod
    def _display_name(
        cls,
        properties: dict,
        address: dict[str, str],
    ) -> str:
        name = cls._clean_string(properties.get("name"))
        street = address.get("street")
        house_number = address.get("houseNumber")
        street_address = " ".join(
            part for part in (house_number, street) if part
        )

        candidates = [
            name,
            street_address or None,
            address.get("district"),
            address.get("locality"),
            address.get("city"),
            address.get("state"),
            address.get("postcode"),
            address.get("country"),
        ]
        parts: list[str] = []
        seen: set[str] = set()
        for candidate in candidates:
            if not candidate:
                continue
            key = candidate.casefold()
            if key not in seen:
                seen.add(key)
                parts.append(candidate)
        return ", ".join(parts)

    @staticmethod
    def _clean_string(value: object) -> str | None:
        if not isinstance(value, str):
            return None
        value = value.strip()
        return value or None


class CachedSearchProvider:
    """Small thread-safe TTL cache around any search provider."""

    def __init__(
        self,
        provider: SearchProvider,
        *,
        ttl: float = SEARCH_CACHE_SECONDS,
        max_entries: int = SEARCH_CACHE_ENTRIES,
    ) -> None:
        self._provider = provider
        self._ttl = ttl
        self._max_entries = max_entries
        self._cache: OrderedDict[
            tuple[str, int], tuple[float, list[SearchResult]]
        ] = OrderedDict()
        self._lock = threading.Lock()
        self._provider_lock = threading.Lock()

    def search(self, query: str, *, limit: int = 6) -> list[SearchResult]:
        key = (" ".join(query.casefold().split()), limit)
        now = time.monotonic()

        with self._lock:
            cached = self._cache.get(key)
            if cached is not None and now - cached[0] <= self._ttl:
                self._cache.move_to_end(key)
                return list(cached[1])
            if cached is not None:
                del self._cache[key]

        # Photon supports type-ahead, but its public demo is intentionally
        # moderate-use. Serialize cache misses from this application instance.
        with self._provider_lock:
            results = self._provider.search(query, limit=limit)

        with self._lock:
            self._cache[key] = (time.monotonic(), list(results))
            self._cache.move_to_end(key)
            while len(self._cache) > self._max_entries:
                self._cache.popitem(last=False)
        return results


search_provider: SearchProvider = CachedSearchProvider(PhotonSearchProvider())
