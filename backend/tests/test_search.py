from __future__ import annotations

import unittest

from backend.routing.search import PhotonSearchProvider, SearchProviderError


class SearchNormalizationTests(unittest.TestCase):
    def test_normalizes_photon_geojson_into_application_schema(self) -> None:
        payload = {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "geometry": {
                        "type": "Point",
                        "coordinates": [-74.0445, 40.6892],
                    },
                    "properties": {
                        "osm_type": "W",
                        "osm_id": 12345,
                        "osm_key": "tourism",
                        "osm_value": "attraction",
                        "name": "Statue of Liberty",
                        "city": "New York",
                        "state": "New York",
                        "postcode": "10004",
                        "country": "United States",
                        "countrycode": "US",
                    },
                },
                {
                    "geometry": {"coordinates": [999, 999]},
                    "properties": {"name": "Invalid"},
                },
            ],
        }

        results = PhotonSearchProvider.normalize_response(payload)

        self.assertEqual(len(results), 1)
        self.assertEqual(
            results[0].as_dict(),
            {
                "id": "osm:W:12345",
                "displayName": (
                    "Statue of Liberty, New York, 10004, United States"
                ),
                "latitude": 40.6892,
                "longitude": -74.0445,
                "category": "tourism",
                "type": "attraction",
                "addressComponents": {
                    "city": "New York",
                    "state": "New York",
                    "postcode": "10004",
                    "country": "United States",
                    "countryCode": "US",
                },
            },
        )

    def test_rejects_malformed_provider_payload(self) -> None:
        with self.assertRaises(SearchProviderError):
            PhotonSearchProvider.normalize_response({"items": []})


if __name__ == "__main__":
    unittest.main()
