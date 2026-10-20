#!/usr/bin/env python3
"""Fetch, review, and build OSM map hints for all enabled stations.

The generator is intentionally conservative:

* requests are sequential, cached, and retried with a 30 second minimum pause;
* anonymous H0-H2 facilities never contain a name in the runtime asset;
* coloured routes require a real OSM route relation with a strict #RRGGBB tag;
* high-speed geometry requires railway=rail and highspeed=yes and is selected by
  actual line-to-station distance, not a station stop list or a guessed name;
* empty collections are valid and the reason is recorded in the audit output.

Examples:

  python3 tool/prepare_map_hints_50stations.py --station tokyo --no-write
  python3 tool/prepare_map_hints_50stations.py
  python3 tool/prepare_map_hints_50stations.py --cache-only
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import http.client
import json
import math
import re
import shutil
import ssl
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parent.parent
CATALOG_PATH = ROOT / "assets/data/stations.json"
RUNTIME_PATH = ROOT / "assets/maps/map_hints_poc.json"
DOCS_DIR = ROOT / "docs/map-hints-50stations"
DEFAULT_CACHE = Path("/tmp/ekidoko-map-hints-50stations-sources")
LEGACY_SOURCE_DIR = Path("/tmp/ekidoko-poc-sources")

DEFAULT_ENDPOINTS = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
)
USER_AGENT = "ekidoko-map-hints-phase4/1.0 (+https://github.com/itoso0315/ekidoko)"
SCHEMA_VERSION = 2
QUERY_VERSION = 1
MAX_FACILITIES = 5
MAX_ROUTES = 6
MAX_REPRESENTATIVES = 3
FACILITY_RADIUS_METERS = 500.0
ROUTE_NEAR_METERS = 500.0
HIGH_SPEED_RADIUS_METERS = 500.0
REPRESENTATIVE_RADIUS_METERS = 2000.0

LEGACY_STATIONS = {"tokyo", "ueno", "kyoto"}
LEGACY_FACILITY_IDS = {
    "tokyo": {"node/3164340661", "node/4646514991", "node/2214684270", "node/6604348338"},
    "ueno": {"way/203960903", "way/203960902", "node/441655802", "way/625528441", "way/138585452"},
    "kyoto": {"node/5111884542", "way/441352467", "node/5936885886", "node/12462481217", "way/171692862"},
}
LEGACY_REPRESENTATIVE_IDS = {
    "tokyo": ("node/1420789601",),
    "ueno": ("way/203960903",),
}
# Keep the superseded PoC candidates in the fresh source query so prior
# acquisition caches remain reproducible; only the IDs above are rendered.
LEGACY_QUERY_OBJECT_IDS = {
    "tokyo": ("way/43934324", "node/4272532291", "node/1420789601"),
    "ueno": ("way/203960903", "way/203960902", "way/33439660"),
    "kyoto": ("relation/5333011", "way/31843043", "way/290375264"),
}

STRICT_COLOUR = re.compile(r"^#[0-9A-Fa-f]{6}$")
SIMPLE_REF = re.compile(r"^[A-Za-z0-9]{1,4}$")
FACILITY_KIND_ORDER = {
    "culture": 0,
    "shopping": 1,
    "education": 2,
    "religion": 3,
    "hospital": 4,
    "stadium": 5,
}


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def source_record(path: Path) -> dict[str, Any]:
    return {"name": path.name, "bytes": path.stat().st_size, "sha256": sha256_file(path)}


def normalize_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).lower()
    converted = "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in value)
    return re.sub(r"[\s\-_・,，.。()（）:：/／]", "", converted)


def label_key(value: str) -> str:
    """Match the app's answer-leak normalization exactly."""
    converted = []
    for character in value:
        codepoint = ord(character)
        if 0xFF01 <= codepoint <= 0xFF5E:
            character = chr(codepoint - 0xFEE0)
        elif 0x30A1 <= codepoint <= 0x30F6:
            character = chr(codepoint - 0x60)
        converted.append(character)
    return re.sub(
        r'''[\s　_\-‐‑‒–—―・･.,，。()（）\[\]【】「」『』:：/／'’"]''',
        "",
        "".join(converted).lower(),
    )


def answer_aliases(station: dict[str, Any]) -> list[str]:
    return [station["name"], station["nameKana"], *station.get("answerAliases", [])]


def safe_name(station: dict[str, Any], name: str) -> bool:
    key = label_key(name)
    if not key:
        return False
    for blocked in station.get("blockedLabels", []):
        if label_key(blocked) in key:
            return False
    aliases = [label_key(alias) for alias in answer_aliases(station)]
    # Answer-name substrings are never safe, including allow-list entries.
    if any(
        alias
        and (
            key == alias
            or f"{alias}駅" in key
            or f"{alias}station" in key
            or f"{alias}{label_key('ステーション')}" in key
            or f"{alias}stn" in key
        )
        for alias in aliases
    ):
        return False
    if any(alias and alias in key for alias in aliases):
        return False
    if any(label_key(value) == key for value in station.get("allowedLabels", [])):
        return True
    return True


def station_query(station: dict[str, Any]) -> str:
    lat, lon = station["latitude"], station["longitude"]
    legacy_ids: dict[str, list[str]] = defaultdict(list)
    for object_id in LEGACY_QUERY_OBJECT_IDS.get(station["id"], ()):
        object_type, numeric_id = object_id.split("/", 1)
        legacy_ids[object_type].append(numeric_id)
    legacy_selectors = "".join(
        f'{"rel" if object_type == "relation" else object_type}(id:{",".join(ids)});'
        for object_type, ids in sorted(legacy_ids.items())
    )
    return (
        "[out:json][timeout:35][maxsize:67108864];\n"
        f'way[railway~"^(rail|subway|light_rail|tram)$"](around:3500,{lat},{lon})->.rails;\n'
        'rel(bw.rails)[type=route][route~"^(train|subway|light_rail|tram)$"]->.routes;\n'
        ".routes out body;\n"
        ".rails out tags geom;\n"
        f'(nwr[amenity~"^(school|college|university|hospital|place_of_worship)$"](around:2500,{lat},{lon});'
        f'nwr[tourism~"^(museum|gallery)$"](around:2500,{lat},{lon});'
        f'nwr[shop~"^(mall|department_store)$"](around:2500,{lat},{lon});'
        f'nwr[leisure=stadium](around:2500,{lat},{lon});{legacy_selectors});out tags center;'
    )


def validate_raw(raw: Any) -> None:
    if not isinstance(raw, dict) or not isinstance(raw.get("elements"), list):
        raise ValueError("Overpass response has no elements array")
    if raw.get("remark"):
        raise ValueError(f"Overpass returned an incomplete response: {raw['remark']}")


def tls_context() -> ssl.SSLContext:
    """Keep verification enabled when a python.org macOS install lacks its CA link."""
    defaults = ssl.get_default_verify_paths()
    if defaults.cafile and Path(defaults.cafile).exists():
        return ssl.create_default_context()
    macos_bundle = Path("/etc/ssl/cert.pem")
    if macos_bundle.exists():
        return ssl.create_default_context(cafile=str(macos_bundle))
    return ssl.create_default_context()


def seed_legacy_cache(station_id: str, query: str, cache_dir: Path) -> bool:
    if station_id not in LEGACY_STATIONS:
        return False
    old_query = LEGACY_SOURCE_DIR / f"{station_id}.query"
    old_raw = LEGACY_SOURCE_DIR / f"{station_id}.json"
    if not old_query.exists() or not old_raw.exists() or old_query.read_text() != query:
        return False
    raw = json.loads(old_raw.read_text())
    validate_raw(raw)
    query_hash = sha256_bytes(query.encode())
    target = cache_dir / f"{station_id}-{query_hash[:12]}.json"
    query_path = cache_dir / f"{station_id}.query"
    meta_path = cache_dir / f"{station_id}.meta.json"
    shutil.copy2(old_raw, target)
    query_path.write_text(query)
    meta = {
        "stationId": station_id,
        "endpoint": "https://overpass-api.de/api/interpreter",
        "acquiredAt": "2026-10-14T14:04:23Z",
        "elapsedSeconds": None,
        "attempts": 0,
        "seededFrom": str(old_raw),
        "query": source_record(query_path),
        "raw": source_record(target),
        "osmBaseTimestamp": raw.get("osm3s", {}).get("timestamp_osm_base"),
    }
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
    return True


def fetch_one(
    station: dict[str, Any],
    cache_dir: Path,
    endpoints: list[str],
    cache_only: bool,
    request_pause: float,
    retries: int,
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    station_id = station["id"]
    query = station_query(station)
    query_hash = sha256_bytes(query.encode())
    query_path = cache_dir / f"{station_id}.query"
    raw_path = cache_dir / f"{station_id}-{query_hash[:12]}.json"
    meta_path = cache_dir / f"{station_id}.meta.json"
    query_path.write_text(query)

    if not raw_path.exists():
        seed_legacy_cache(station_id, query, cache_dir)
    cache_validation_failure: str | None = None
    if raw_path.exists():
        try:
            raw = json.loads(raw_path.read_text())
            validate_raw(raw)
            meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
            actual_query = source_record(query_path)
            actual_raw = source_record(raw_path)
            stored_query = meta.get("query")
            stored_raw = meta.get("raw")
            if (
                meta.get("stationId") != station_id
                or not isinstance(stored_query, dict)
                or stored_query.get("name") != actual_query["name"]
                or stored_query.get("bytes") != actual_query["bytes"]
                or stored_query.get("sha256") != actual_query["sha256"]
                or not isinstance(stored_raw, dict)
                or stored_raw.get("name") != actual_raw["name"]
                or stored_raw.get("bytes") != actual_raw["bytes"]
                or stored_raw.get("sha256") != actual_raw["sha256"]
            ):
                raise ValueError("cache metadata query/raw identity mismatch")
            meta.update(
                {
                    "stationId": station_id,
                    "cacheHit": True,
                    "acquiredByNetwork": bool(meta.get("endpoint")) and not bool(meta.get("seededFrom")),
                    "query": actual_query,
                    "raw": actual_raw,
                    "osmBaseTimestamp": raw.get("osm3s", {}).get("timestamp_osm_base"),
                }
            )
            return raw, meta
        except (OSError, ValueError, json.JSONDecodeError) as error:
            cache_validation_failure = f"{type(error).__name__}: {error}"
            if not cache_only:
                raw_path.unlink(missing_ok=True)
    if cache_only:
        return None, {
            "stationId": station_id,
            "cacheHit": False,
            "query": source_record(query_path),
            "failure": "cache-validation-failed" if cache_validation_failure else "cache-miss",
            "cacheValidationFailure": cache_validation_failure,
        }

    failures: list[dict[str, Any]] = []
    attempt = 0
    for endpoint_index, endpoint in enumerate(endpoints):
        for endpoint_attempt in range(retries):
            attempt += 1
            body = urllib.parse.urlencode({"data": query}).encode()
            request = urllib.request.Request(
                endpoint,
                data=body,
                headers={
                    "User-Agent": USER_AGENT,
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Accept": "application/json",
                },
                method="POST",
            )
            started = time.monotonic()
            try:
                with urllib.request.urlopen(request, timeout=180, context=tls_context()) as response:
                    payload = response.read()
                    status = response.status
                elapsed = round(time.monotonic() - started, 3)
                if status != 200:
                    raise RuntimeError(f"HTTP {status}")
                raw = json.loads(payload)
                validate_raw(raw)
                raw_path.write_bytes(payload)
                meta = {
                    "stationId": station_id,
                    "endpoint": endpoint,
                    "acquiredAt": utc_now(),
                    "elapsedSeconds": elapsed,
                    "attempts": attempt,
                    "cacheHit": False,
                    "acquiredByNetwork": True,
                    "query": source_record(query_path),
                    "raw": source_record(raw_path),
                    "osmBaseTimestamp": raw.get("osm3s", {}).get("timestamp_osm_base"),
                    "previousFailures": failures,
                }
                meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")
                time.sleep(max(0.0, request_pause))
                return raw, meta
            except urllib.error.HTTPError as error:
                elapsed = round(time.monotonic() - started, 3)
                failures.append(
                    {"endpoint": endpoint, "attempt": endpoint_attempt + 1, "httpStatus": error.code, "elapsedSeconds": elapsed}
                )
                retry_after = error.headers.get("Retry-After") if error.headers else None
                if error.code not in {406, 429, 500, 502, 503, 504}:
                    break
                pause = max(30.0, float(retry_after) if retry_after and retry_after.isdigit() else 0.0, 15.0 * 2**endpoint_attempt)
                print(f"{station_id}: HTTP {error.code}; pausing {pause:.0f}s", flush=True)
                time.sleep(pause)
            except (
                urllib.error.URLError,
                TimeoutError,
                ConnectionError,
                OSError,
                http.client.HTTPException,
                ssl.SSLError,
                json.JSONDecodeError,
                ValueError,
                RuntimeError,
            ) as error:
                elapsed = round(time.monotonic() - started, 3)
                failures.append(
                    {"endpoint": endpoint, "attempt": endpoint_attempt + 1, "error": type(error).__name__, "message": str(error)[:300], "elapsedSeconds": elapsed}
                )
                pause = max(30.0, 15.0 * 2**endpoint_attempt)
                print(f"{station_id}: {type(error).__name__}; pausing {pause:.0f}s", flush=True)
                time.sleep(pause)
        if endpoint_index + 1 < len(endpoints):
            print(f"{station_id}: switching Overpass endpoint", flush=True)
    failure_meta = {
        "stationId": station_id,
        "cacheHit": False,
        "query": source_record(query_path),
        "failure": "all-overpass-attempts-failed",
        "attempts": attempt,
        "failures": failures,
    }
    meta_path.write_text(json.dumps(failure_meta, ensure_ascii=False, indent=2) + "\n")
    return None, failure_meta


def lonlat(element: dict[str, Any]) -> list[float] | None:
    point = element if "lat" in element and "lon" in element else element.get("center", {})
    if isinstance(point.get("lat"), (int, float)) and isinstance(point.get("lon"), (int, float)):
        return [float(point["lon"]), float(point["lat"])]
    return None


def meters_xy(point: list[float], origin: list[float]) -> tuple[float, float]:
    return (
        (point[0] - origin[0]) * math.cos(math.radians(origin[1])) * 111320.0,
        (point[1] - origin[1]) * 111320.0,
    )


def point_distance(a: list[float], b: list[float]) -> float:
    x, y = meters_xy(a, b)
    return math.hypot(x, y)


def segment_distance(point: list[float], start: list[float], end: list[float]) -> float:
    ax, ay = meters_xy(start, point)
    bx, by = meters_xy(end, point)
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(ax, ay)
    t = max(0.0, min(1.0, -(ax * dx + ay * dy) / (dx * dx + dy * dy)))
    return math.hypot(ax + t * dx, ay + t * dy)


def geometry_distance(points: list[list[float]], origin: list[float]) -> float:
    if len(points) < 2:
        return min((point_distance(p, origin) for p in points), default=float("inf"))
    return min(segment_distance(origin, a, b) for a, b in zip(points, points[1:]))


def line_length(points: list[list[float]]) -> float:
    return sum(point_distance(a, b) for a, b in zip(points, points[1:]))


def feature_collection(features: Iterable[dict[str, Any]]) -> dict[str, Any]:
    return {"type": "FeatureCollection", "features": list(features)}


def feature_id(element: dict[str, Any]) -> str:
    return f"{element['type']}/{element['id']}"


def facility_kind(tags: dict[str, Any]) -> str | None:
    amenity = tags.get("amenity")
    tourism = tags.get("tourism")
    shop = tags.get("shop")
    if amenity in {"school", "college", "university"}:
        return "education"
    if amenity == "hospital":
        return "hospital"
    if amenity == "place_of_worship" and tags.get("religion") in {"buddhist", "shinto"}:
        return "religion"
    if tourism in {"museum", "gallery"}:
        return "culture"
    if shop in {"mall", "department_store"}:
        return "shopping"
    if tags.get("leisure") == "stadium":
        return "stadium"
    return None


def facility_priority(candidate: dict[str, Any], station: dict[str, Any]) -> tuple[Any, ...]:
    """Prefer recognizable, large clues before pure proximity."""
    tags = candidate["element"].get("tags", {})
    name_key = label_key(candidate["name"])
    allow_rank = next(
        (
            index
            for index, value in enumerate(station.get("allowedLabels", []))
            if label_key(value) == name_key
        ),
        999,
    )
    evidence = sum(
        1
        for key in ("wikidata", "wikipedia", "website", "operator")
        if isinstance(tags.get(key), str) and tags[key].strip()
    )
    subtype_rank = {
        "museum": 0,
        "gallery": 1,
        "stadium": 2,
        "university": 3,
        "college": 4,
        "hospital": 5,
        "mall": 6,
        "department_store": 7,
        "place_of_worship": 8,
        "school": 9,
    }.get(
        tags.get("tourism")
        or tags.get("leisure")
        or tags.get("amenity")
        or tags.get("shop"),
        20,
    )
    # Ways and relations usually represent the footprint of a substantial
    # facility, while a node may still win through explicit provenance tags.
    footprint_rank = 0 if candidate["element"]["type"] in {"way", "relation"} else 1
    return (
        0 if allow_rank != 999 else 1,
        allow_rank,
        subtype_rank,
        -evidence,
        footprint_rank,
        candidate["distanceMeters"],
        candidate["id"],
    )


def candidate_facilities(raw: dict[str, Any], station: dict[str, Any]) -> list[dict[str, Any]]:
    origin = [station["longitude"], station["latitude"]]
    result: list[dict[str, Any]] = []
    for element in raw["elements"]:
        tags = element.get("tags", {})
        kind = facility_kind(tags)
        point = lonlat(element)
        name = tags.get("name:ja") or tags.get("name")
        if kind is None or point is None or not name:
            continue
        distance = point_distance(point, origin)
        if distance > FACILITY_RADIUS_METERS:
            continue
        result.append(
            {
                "element": element,
                "id": feature_id(element),
                "kind": kind,
                "name": name,
                "position": point,
                "distanceMeters": round(distance, 1),
            }
        )
    return sorted(result, key=lambda c: facility_priority(c, station))


def select_facilities(
    candidates: list[dict[str, Any]],
    station_id: str,
    legacy_row: dict[str, Any] | None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    by_id = {c["id"]: c for c in candidates}
    selected_candidates: list[dict[str, Any]] = []
    features: list[dict[str, Any]] = []
    if station_id in LEGACY_STATIONS and legacy_row:
        for old in legacy_row["facilities"]["features"]:
            props = old["properties"]
            key = f"{props['osm_type']}/{props['osm_id']}"
            candidate = by_id.get(key)
            if candidate is None:
                raise ValueError(f"{station_id}: legacy facility {key} missing from current raw")
            if candidate["kind"] != props["kind"]:
                raise ValueError(
                    f"{station_id}: legacy facility {key} changed classification "
                    f"from {props['kind']} to {candidate['kind']}"
                )
            selected_candidates.append(candidate)
            # Keep only the reviewed identity/class/rank. Coordinates are
            # always rebuilt from the fresh Overpass response.
            features.append(
                {
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": candidate["position"]},
                    "properties": {
                        "kind": candidate["kind"],
                        "rank": props["rank"],
                        "osm_type": candidate["element"]["type"],
                        "osm_id": candidate["element"]["id"],
                    },
                }
            )
        return features, selected_candidates

    used: set[str] = set()
    for candidate in candidates:
        if candidate["kind"] in used:
            continue
        selected_candidates.append(candidate)
        used.add(candidate["kind"])
        if len(selected_candidates) == MAX_FACILITIES:
            break
    if len(selected_candidates) < MAX_FACILITIES:
        for candidate in candidates:
            if candidate in selected_candidates:
                continue
            selected_candidates.append(candidate)
            if len(selected_candidates) == MAX_FACILITIES:
                break
    for rank, candidate in enumerate(selected_candidates):
        element = candidate["element"]
        features.append(
            {
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": candidate["position"]},
                "properties": {
                    "kind": candidate["kind"],
                    "rank": rank,
                    "osm_type": element["type"],
                    "osm_id": element["id"],
                },
            }
        )
    return features, selected_candidates


def clean_route_name(value: str, ref: str | None = None) -> str:
    value = unicodedata.normalize("NFKC", value).strip()
    value = re.split(r"\s[:：]\s|\s[-–—]\s", value, maxsplit=1)[0]
    value = re.sub(r"\s*[（(][^）)]*(?:→|=>|->|内回り|外回り|上り|下り)[^）)]*[）)]", "", value)
    value = re.sub(r"[（(](上り|下り|内回り|外回り)[）)]", "", value)
    for prefix in (
        "東京メトロ", "都営地下鉄", "京都市営地下鉄", "札幌市営地下鉄", "仙台市地下鉄",
        "横浜市営地下鉄", "名古屋市営地下鉄", "大阪メトロ", "Osaka Metro", "福岡市地下鉄", "JR",
    ):
        if value.startswith(prefix):
            value = value[len(prefix):].strip()
    value = re.sub(
        r"\s+(各駅停車|普通|快速|区間快速|通勤快速|特別快速|新快速|急行|区間急行|通勤急行|快速急行|準急|区間準急|通勤準急|特急|通勤特急|準特急|快特)$",
        "",
        value,
    )
    value = re.sub(r"(上り|下り)$", "", value)
    if ref and SIMPLE_REF.fullmatch(ref):
        value = re.sub(rf"(?:\s|・)*{re.escape(ref)}$", "", value, flags=re.IGNORECASE)
    return value.strip(" :：-")


def looks_like_line_relation(tags: dict[str, Any], name: str) -> bool:
    """Reject train products whose colour is not a physical line colour."""
    joined = " ".join(
        str(tags.get(key) or "")
        for key in ("name", "name:ja", "network")
    ).lower()
    if tags.get("service") in {"express", "long_distance", "high_speed"}:
        return False
    if any(
        token in joined
        for token in (
            "直通運転",
            "直通列車",
            "liner",
            "ライナー",
            "limited express",
            "特急",
        )
    ):
        return False
    if name in {
        "各駅停車", "普通", "快速", "区間快速", "通勤快速", "急行", "準急",
        "通勤急行", "快速急行", "通勤準急", "Stopping service",
    }:
        return False
    return bool(
        re.search(
            r"(線|ライン|地下鉄|市電|モノレール|新交通|railway|railroad|\bline\b|\bmetro\b)",
            name,
            flags=re.IGNORECASE,
        )
    )


def way_points(way: dict[str, Any]) -> list[list[float]]:
    return [[float(p["lon"]), float(p["lat"])] for p in way.get("geometry", []) if "lon" in p and "lat" in p]


def join_ways(
    ways: list[dict[str, Any]], *, minimum_length_meters: float = 0.0
) -> list[tuple[list[list[float]], list[int]]]:
    pending: list[tuple[list[list[float]], list[int]]] = []
    seen: set[int] = set()
    for way in ways:
        if way["id"] in seen:
            continue
        seen.add(way["id"])
        points = way_points(way)
        if len(points) >= 2:
            pending.append((points, [way["id"]]))
    output: list[tuple[list[list[float]], list[int]]] = []
    while pending:
        points, ids = pending.pop(0)
        joined = True
        while joined:
            joined = False
            for index, (other, other_ids) in enumerate(pending):
                if points[-1] == other[0]:
                    points += other[1:]
                elif points[-1] == other[-1]:
                    points += list(reversed(other))[1:]
                elif points[0] == other[-1]:
                    points = other + points[1:]
                elif points[0] == other[0]:
                    points = list(reversed(other)) + points[1:]
                else:
                    continue
                ids += other_ids
                pending.pop(index)
                joined = True
                break
        if line_length(points) >= minimum_length_meters:
            output.append((points, ids))
    return output


def service_id(ref: str | None, colour: str, name: str, operator: str) -> str:
    signature = f"{ref or ''}|{colour}|{normalize_text(name)}|{normalize_text(operator)}"
    return "osm_" + hashlib.sha256(signature.encode()).hexdigest()[:12]


def select_routes(
    raw: dict[str, Any],
    station: dict[str, Any],
    legacy_row: dict[str, Any] | None,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]], dict[str, Any]]:
    legacy_revalidation_failure: str | None = None
    if station["id"] in LEGACY_STATIONS and legacy_row:
        try:
            old_features = legacy_row["routes"]["features"]
            relation_by_id = {e["id"]: e for e in raw["elements"] if e["type"] == "relation"}
            way_by_id = {e["id"]: e for e in raw["elements"] if e["type"] == "way"}
            origin = [station["longitude"], station["latitude"]]
            features: list[dict[str, Any]] = []
            services: dict[str, dict[str, Any]] = {}
            service_distances: dict[str, list[float]] = defaultdict(list)
            relation_operators: dict[int, str] = {}
            for feature in old_features:
                props = feature["properties"]
                relation_ids = props["osm_relation_ids"]
                way_ids = props["osm_way_ids"]
                relations = []
                for relation_id in relation_ids:
                    relation = relation_by_id.get(relation_id)
                    if relation is None:
                        raise ValueError(f"relation/{relation_id} absent from fresh source")
                    tags = relation.get("tags", {})
                    if (
                        tags.get("type") != "route"
                        or tags.get("route") not in {"train", "subway", "light_rail", "tram"}
                        or not isinstance(tags.get("colour"), str)
                        or not STRICT_COLOUR.fullmatch(tags["colour"])
                        or tags["colour"].upper() != props["color"].upper()
                    ):
                        raise ValueError(f"relation/{relation_id} no longer has the reviewed strict colour")
                    fresh_name = clean_route_name(
                        tags.get("name:ja") or tags.get("name") or "",
                        str(tags.get("ref")) if tags.get("ref") else None,
                    )
                    if normalize_text(props["name"]) not in normalize_text(fresh_name):
                        raise ValueError(
                            f"relation/{relation_id} name {fresh_name!r} no longer matches reviewed {props['name']!r}"
                        )
                    operator = tags.get("operator") or tags.get("network")
                    if not isinstance(operator, str) or not operator.strip():
                        raise ValueError(f"relation/{relation_id} has no fresh operator/network evidence")
                    relation_operators[relation_id] = operator
                    relations.append(relation)
                member_ids = {
                    member["ref"]
                    for relation in relations
                    for member in relation.get("members", [])
                    if member.get("type") == "way"
                }
                for way_id in way_ids:
                    if way_id not in way_by_id or len(way_points(way_by_id[way_id])) < 2:
                        raise ValueError(f"way/{way_id} absent from fresh source geometry")
                    if way_by_id[way_id].get("tags", {}).get("highspeed") == "yes":
                        raise ValueError(f"way/{way_id} is highspeed=yes and cannot receive a conventional route colour")
                    if way_id not in member_ids:
                        raise ValueError(f"way/{way_id} absent from reviewed relation membership")
                    service_distances[props["serviceId"]].append(
                        geometry_distance(way_points(way_by_id[way_id]), origin)
                    )
                fresh_parts = join_ways(
                    [way_by_id[way_id] for way_id in way_ids],
                    minimum_length_meters=10.0,
                )
                if not fresh_parts:
                    raise ValueError(
                        f"service {props['serviceId']} has no renderable fresh way geometry"
                    )
                for points, joined_ids in fresh_parts:
                    features.append(
                        {
                            "type": "Feature",
                            "geometry": {"type": "LineString", "coordinates": points},
                            "properties": {
                                "name": props["name"],
                                "color": props["color"],
                                "serviceId": props["serviceId"],
                                "lineOffset": props["lineOffset"],
                                "osm_way_ids": joined_ids,
                                "osm_relation_ids": relation_ids,
                            },
                        }
                    )
                services.setdefault(
                    props["serviceId"],
                    {"name": props["name"], "color": props["color"], "relationIds": []},
                )
                services[props["serviceId"]]["relationIds"] = sorted(
                    set(services[props["serviceId"]]["relationIds"] + relation_ids)
                )
            for sid, distances in service_distances.items():
                if not distances or min(distances) > ROUTE_NEAR_METERS:
                    raise ValueError(
                        f"service {sid} fresh geometry does not pass within {ROUTE_NEAR_METERS:.0f}m"
                    )
            selected = []
            for sid, service in services.items():
                selected.append(
                    {
                        "serviceId": sid,
                        **service,
                        "selectionReason": "preserved reviewed three-station PoC service after fresh relation/colour/way-membership validation",
                        "relations": [
                            {
                                "relationId": relation_id,
                                "operator": relation_operators[relation_id],
                                "tags": tags_for_audit(relation_by_id[relation_id]),
                            }
                            for relation_id in service["relationIds"]
                        ],
                        "minimumDistanceMeters": round(min(service_distances[sid]), 1),
                    }
                )
            return features, services, {
                "selected": selected,
                "excluded": {},
                "notSelectedDueToLimit": [],
                "conflictingColourGroups": [],
                "candidateCount": len(selected),
                "legacyRevalidation": "passed",
            }
        except (KeyError, TypeError, ValueError) as error:
            legacy_revalidation_failure = str(error)

    origin = [station["longitude"], station["latitude"]]
    raw_way_by_id = {
        e["id"]: e for e in raw["elements"] if e["type"] == "way"
    }
    ways = {
        e["id"]: e
        for e in raw["elements"]
        if e["type"] == "way"
        and e.get("tags", {}).get("railway") in {"rail", "subway", "light_rail", "tram"}
        and e.get("tags", {}).get("highspeed") != "yes"
        and len(way_points(e)) >= 2
        and e.get("tags", {}).get("service") not in {"yard", "siding", "spur"}
    }
    candidates: list[dict[str, Any]] = []
    excluded = Counter()
    if legacy_revalidation_failure:
        excluded["legacy-revalidation-failed; regenerated-from-fresh-source"] += 1
    for relation in (e for e in raw["elements"] if e["type"] == "relation"):
        tags = relation.get("tags", {})
        if tags.get("type") != "route" or tags.get("route") not in {"train", "subway", "light_rail", "tram"}:
            continue
        colour = tags.get("colour")
        if not isinstance(colour, str) or not STRICT_COLOUR.fullmatch(colour):
            excluded["missing-or-non-strict-colour"] += 1
            continue
        colour = colour.upper()
        ref = tags.get("ref")
        if ref and not SIMPLE_REF.fullmatch(str(ref)):
            excluded["through-or-composite-ref"] += 1
            continue
        raw_name = tags.get("name:ja") or tags.get("name")
        name = clean_route_name(raw_name or "", str(ref) if ref else None)
        if not name:
            excluded["missing-name"] += 1
            continue
        if not looks_like_line_relation(tags, name):
            excluded["train-service-not-line"] += 1
            continue
        if re.search(r"[・•]JR", name, flags=re.IGNORECASE):
            excluded["through-service-combines-multiple-lines"] += 1
            continue
        if "新幹線" in name:
            excluded["high-speed-is-category-only"] += 1
            continue
        if not safe_name(station, name):
            excluded["answer-name-exposure"] += 1
            continue
        relation_way_ids = {
            m["ref"] for m in relation.get("members", []) if m.get("type") == "way"
        }
        member_ids = relation_way_ids & set(ways)
        if not member_ids:
            if any(
                raw_way_by_id.get(way_id, {}).get("tags", {}).get("highspeed") == "yes"
                for way_id in relation_way_ids
            ):
                excluded["high-speed-member-ways-excluded-from-conventional-colour"] += 1
            else:
                excluded["no-local-member-geometry"] += 1
            continue
        nearest = min(geometry_distance(way_points(ways[i]), origin) for i in member_ids)
        if nearest > ROUTE_NEAR_METERS:
            excluded["does-not-pass-near-station"] += 1
            continue
        operator = tags.get("operator") or tags.get("network") or ""
        if not ref and not operator:
            excluded["insufficient-line-identity-no-ref-or-operator"] += 1
            continue
        group_key = (
            str(ref or normalize_text(name)),
            colour,
            normalize_text(operator),
        )
        candidates.append(
            {
                "relation": relation,
                "name": name,
                "colour": colour,
                "ref": str(ref) if ref else None,
                "operator": operator,
                "memberWayIds": member_ids,
                "nearestMeters": nearest,
                "groupKey": group_key,
            }
        )

    groups: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for candidate in candidates:
        groups[candidate["groupKey"]].append(candidate)
    grouped: list[dict[str, Any]] = []
    for key, rows in groups.items():
        names = Counter(row["name"] for row in rows)
        # When equally represented, keep the more specific reviewed line name
        # (e.g. 中央線快速 rather than the abbreviated 中央線).
        name = sorted(names, key=lambda n: (-names[n], -len(n), n))[0]
        grouped.append(
            {
                "key": key,
                "name": name,
                "colour": rows[0]["colour"],
                "ref": rows[0]["ref"],
                "operator": rows[0]["operator"],
                "relations": sorted({row["relation"]["id"] for row in rows}),
                "memberWayIds": sorted(set().union(*(row["memberWayIds"] for row in rows))),
                "nearestMeters": min(row["nearestMeters"] for row in rows),
            }
        )
    conflicting_colour_groups: list[dict[str, Any]] = []
    conflicted_indexes: set[int] = set()
    for first_index, first in enumerate(grouped):
        for second_index in range(first_index + 1, len(grouped)):
            second = grouped[second_index]
            if (
                first["colour"] != second["colour"]
                and first["ref"]
                and first["ref"] == second["ref"]
                and (
                    normalize_text(first["name"]) == normalize_text(second["name"])
                    or (
                        normalize_text(first["operator"])
                        and normalize_text(first["operator"]) == normalize_text(second["operator"])
                    )
                )
            ):
                conflicted_indexes.update({first_index, second_index})
                conflicting_colour_groups.append(
                    {
                        "name": first["name"],
                        "ref": first["ref"],
                        "operator": first["operator"],
                        "colours": sorted({first["colour"], second["colour"]}),
                        "relationIds": sorted(set(first["relations"] + second["relations"])),
                        "reason": "same OSM line identity has conflicting colours; default railway styling retained",
                    }
                )
    if conflicted_indexes:
        excluded["conflicting-colours-for-same-line-identity"] += len(conflicted_indexes)
        grouped = [group for index, group in enumerate(grouped) if index not in conflicted_indexes]

    # OSM sometimes has a ref-bearing line relation and an older relation with
    # the same name/colour but no operator/ref. Treat those as one service so a
    # duplicate overlay does not consume the six-line display budget.
    deduplicated: list[dict[str, Any]] = []
    for group in grouped:
        duplicate = next(
            (
                existing
                for existing in deduplicated
                if normalize_text(existing["name"]) == normalize_text(group["name"])
                and existing["colour"] == group["colour"]
            ),
            None,
        )
        if duplicate is None:
            deduplicated.append(group)
            continue
        excluded["duplicate-name-colour-relation-group-merged"] += 1
        duplicate["relations"] = sorted(set(duplicate["relations"] + group["relations"]))
        duplicate["memberWayIds"] = sorted(
            set(duplicate["memberWayIds"] + group["memberWayIds"])
        )
        duplicate["nearestMeters"] = min(duplicate["nearestMeters"], group["nearestMeters"])
        if not duplicate["ref"] and group["ref"]:
            duplicate["ref"] = group["ref"]
        if not duplicate["operator"] and group["operator"]:
            duplicate["operator"] = group["operator"]
    grouped = deduplicated
    grouped.sort(key=lambda g: (g["nearestMeters"], -len(g["memberWayIds"]), g["name"], g["colour"]))
    selected_groups = grouped[:MAX_ROUTES]
    not_selected_due_to_limit = [
        {
            "name": group["name"],
            "color": group["colour"],
            "ref": group["ref"],
            "operator": group["operator"],
            "relationIds": group["relations"],
            "minimumDistanceMeters": round(group["nearestMeters"], 1),
            "reason": f"beyond MAX_ROUTES={MAX_ROUTES} after nearest-service ordering",
        }
        for group in grouped[MAX_ROUTES:]
    ]
    if len(grouped) > MAX_ROUTES:
        excluded["representative-service-limit"] += len(grouped) - MAX_ROUTES

    selected_ids = [service_id(g["ref"], g["colour"], g["name"], g["operator"]) for g in selected_groups]
    way_memberships: dict[int, list[str]] = defaultdict(list)
    for sid, group in zip(selected_ids, selected_groups):
        for way_id in group["memberWayIds"]:
            way_memberships[way_id].append(sid)

    features: list[dict[str, Any]] = []
    services: dict[str, dict[str, Any]] = {}
    selected_audit: list[dict[str, Any]] = []
    for sid, group in zip(selected_ids, selected_groups):
        offsets: dict[float, list[dict[str, Any]]] = defaultdict(list)
        for way_id in group["memberWayIds"]:
            memberships = sorted(set(way_memberships[way_id]))
            offset = (memberships.index(sid) - (len(memberships) - 1) / 2) * 2.8
            offsets[offset].append(ways[way_id])
        output_way_ids: list[int] = []
        service_features: list[dict[str, Any]] = []
        for offset, group_ways in sorted(offsets.items()):
            for points, ids in join_ways(group_ways, minimum_length_meters=10.0):
                output_way_ids.extend(ids)
                service_features.append(
                    {
                        "type": "Feature",
                        "geometry": {"type": "LineString", "coordinates": points},
                        "properties": {
                            "name": group["name"],
                            "color": group["colour"],
                            "serviceId": sid,
                            "lineOffset": offset,
                            "osm_way_ids": ids,
                            "osm_relation_ids": group["relations"],
                        },
                    }
                )
        if not service_features:
            excluded["selected-service-had-no-renderable-geometry"] += 1
            continue
        features.extend(service_features)
        services[sid] = {
            "name": group["name"],
            "color": group["colour"],
            "relationIds": group["relations"],
        }
        selected_audit.append(
            {
                "serviceId": sid,
                "name": group["name"],
                "color": group["colour"],
                "ref": group["ref"],
                "operator": group["operator"],
                "relationIds": group["relations"],
                "wayIds": sorted(set(output_way_ids)),
                "minimumDistanceMeters": round(group["nearestMeters"], 1),
                "selectionReason": "strict colour relation grouped by ref/colour/operator and among six nearest distinct services",
            }
        )
    return features, services, {
        "candidateCount": len(grouped),
        "selected": selected_audit,
        "excluded": dict(sorted(excluded.items())),
        "conflictingColourGroups": conflicting_colour_groups,
        "notSelectedDueToLimit": not_selected_due_to_limit,
        "legacyRevalidationFailure": legacy_revalidation_failure,
    }


def select_high_speed(raw: dict[str, Any], station: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    origin = [station["longitude"], station["latitude"]]
    relations = [e for e in raw["elements"] if e["type"] == "relation"]
    selected: list[tuple[dict[str, Any], float]] = []
    excluded = Counter()
    for way in (e for e in raw["elements"] if e["type"] == "way"):
        tags = way.get("tags", {})
        if tags.get("highspeed") != "yes":
            continue
        if tags.get("railway") != "rail":
            excluded["highspeed=yes-but-not-railway=rail"] += 1
            continue
        points = way_points(way)
        if len(points) < 2:
            excluded["missing-geometry"] += 1
            continue
        distance = geometry_distance(points, origin)
        if distance > HIGH_SPEED_RADIUS_METERS:
            excluded["outside-500m"] += 1
            continue
        selected.append((way, distance))
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    distance_by_id = {way["id"]: distance for way, distance in selected}
    for way, _ in selected:
        tags = way.get("tags", {})
        groups[str(tags.get("name:ja") or tags.get("name") or tags.get("ref") or "unnamed")].append(way)
    features: list[dict[str, Any]] = []
    audit: list[dict[str, Any]] = []
    for _, ways in sorted(groups.items()):
        for points, ids in join_ways(ways):
            features.append(
                {
                    "type": "Feature",
                    "geometry": {"type": "LineString", "coordinates": points},
                    "properties": {"railType": "highSpeed", "osm_way_ids": ids},
                }
            )
        for way in ways:
            supporting_relations = [
                relation
                for relation in relations
                if any(m.get("type") == "way" and m.get("ref") == way["id"] for m in relation.get("members", []))
            ]
            tags = way.get("tags", {})
            audit.append(
                {
                    "wayId": way["id"],
                    "wayName": tags.get("name:ja") or tags.get("name"),
                    "wayRef": tags.get("ref"),
                    "minimumDistanceMeters": round(distance_by_id[way["id"]], 1),
                    "supportingRelations": [
                        {
                            "relationId": relation["id"],
                            "tags": {
                                key: relation.get("tags", {}).get(key)
                                for key in ("name", "name:ja", "ref", "network", "operator", "route", "type")
                                if relation.get("tags", {}).get(key) is not None
                            },
                        }
                        for relation in supporting_relations
                    ],
                    "requiredTags": {"railway": tags.get("railway"), "highspeed": tags.get("highspeed")},
                    "observedTags": {
                        key: tags.get(key) for key in ("usage", "gauge", "service", "layer", "tunnel", "bridge")
                    },
                    "selectionReason": "railway=rail, highspeed=yes, and actual geometry intersects the station-centred 500m circle",
                }
            )
    return features, {"selectedWays": audit, "excluded": dict(sorted(excluded.items()))}


def select_representatives(
    raw: dict[str, Any], station: dict[str, Any]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    desired = LEGACY_REPRESENTATIVE_IDS.get(station["id"], ())
    desired_set = set(desired)
    origin = [station["longitude"], station["latitude"]]
    by_id: dict[str, dict[str, Any]] = {}
    for element in raw["elements"]:
        if element.get("type") not in {"node", "way", "relation"}:
            continue
        tags = element.get("tags", {})
        object_id = feature_id(element)
        kind = facility_kind(tags)
        if kind is None and object_id not in desired_set:
            continue
        name = tags.get("name:ja") or tags.get("name")
        coordinates = lonlat(element)
        if not isinstance(name, str) or coordinates is None:
            continue
        if not safe_name(station, name):
            continue
        distance = point_distance(coordinates, origin)
        if distance > REPRESENTATIVE_RADIUS_METERS:
            continue
        by_id[object_id] = {
            "element": element,
            "id": object_id,
            "kind": kind or "landmark",
            "name": name,
            "position": coordinates,
            "distanceMeters": round(distance, 1),
        }
    candidates = list(by_id.values())
    if desired:
        missing = desired_set - set(by_id)
        if missing:
            raise ValueError(f"{station['id']}: legacy representative facilities missing: {sorted(missing)}")
        selected = [by_id[object_id] for object_id in desired]
    else:
        ordered = sorted(candidates, key=lambda candidate: facility_priority(candidate, station))
        selected = []
        used_kinds: set[str] = set()
        for candidate in ordered:
            if candidate["kind"] in used_kinds:
                continue
            selected.append(candidate)
            used_kinds.add(candidate["kind"])
            if len(selected) == MAX_REPRESENTATIVES:
                break
        if len(selected) < MAX_REPRESENTATIVES:
            for candidate in ordered:
                if candidate in selected:
                    continue
                selected.append(candidate)
                if len(selected) == MAX_REPRESENTATIVES:
                    break
    features = []
    selected_audit = []
    for rank, candidate in enumerate(selected):
        element = candidate["element"]
        features.append(
            {
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": candidate["position"]},
                "properties": {
                    "kind": "facility",
                    "name": candidate["name"],
                    "rank": rank,
                    "osm_type": element["type"],
                    "osm_id": element["id"],
                },
            }
        )
        selected_audit.append(
            {
                "osmObject": candidate["id"],
                "classification": candidate["kind"],
                "name": candidate["name"],
                "coordinates": candidate["position"],
                "distanceMeters": candidate["distanceMeters"],
                "tags": tags_for_audit(element),
                "selectionReason": (
                    "preserved prior visible PoC representative after fresh OSM revalidation"
                    if desired
                    else "safe named supported facility selected by category diversity, facility significance, provenance signals, footprint, and distance"
                ),
            }
        )
    return features, selected_audit


def tags_for_audit(element: dict[str, Any]) -> dict[str, Any]:
    allowed = {
        "name", "name:ja", "amenity", "tourism", "shop", "leisure", "religion", "historic",
        "railway", "highspeed", "usage", "gauge", "service", "route", "type", "ref", "operator",
        "network", "colour", "layer", "tunnel", "bridge",
        "wikidata", "wikipedia", "website",
    }
    return {key: value for key, value in element.get("tags", {}).items() if key in allowed}


def validate_runtime(runtime: dict[str, Any], station_ids: set[str]) -> None:
    if not isinstance(runtime, dict) or set(runtime) != {"schemaVersion", "provenance", "services", "stations"}:
        raise ValueError("runtime top-level schema mismatch")
    if runtime.get("schemaVersion") != SCHEMA_VERSION or not isinstance(runtime.get("provenance"), dict):
        raise ValueError("wrong runtime schema version")
    services = runtime.get("services")
    if not isinstance(services, dict):
        raise ValueError("runtime services must be an object")
    for service_id, service in services.items():
        if not isinstance(service_id, str) or not service_id or not isinstance(service, dict):
            raise ValueError("invalid runtime service")
        if set(service) != {"name", "color", "relationIds"}:
            raise ValueError(f"{service_id}: service property schema mismatch")
        relation_ids = service["relationIds"]
        if (
            not isinstance(service["name"], str)
            or not service["name"].strip()
            or not isinstance(service["color"], str)
            or not STRICT_COLOUR.fullmatch(service["color"])
            or not isinstance(relation_ids, list)
            or not relation_ids
            or any(not isinstance(value, int) or isinstance(value, bool) or value <= 0 for value in relation_ids)
            or len(relation_ids) != len(set(relation_ids))
        ):
            raise ValueError(f"{service_id}: invalid service evidence")
    rows = runtime.get("stations")
    if not isinstance(rows, dict) or set(rows) != station_ids:
        raise ValueError("runtime station coverage mismatch")
    referenced_services: set[str] = set()

    def positive_ids(value: Any) -> bool:
        return (
            isinstance(value, list)
            and bool(value)
            and all(isinstance(item, int) and not isinstance(item, bool) and item > 0 for item in value)
            and len(value) == len(set(value))
        )

    def valid_position(position: Any) -> bool:
        return (
            isinstance(position, list)
            and len(position) == 2
            and all(isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) for value in position)
            and abs(position[0]) <= 180
            and abs(position[1]) <= 90
        )

    def add_unique(values: set[Any], value: Any) -> bool:
        if value in values:
            return False
        values.add(value)
        return True

    for station_id, row in rows.items():
        station = next_station_by_id[station_id]
        if (
            not isinstance(row, dict)
            or set(row) != {
                "latitude", "longitude", "facilities", "routes",
                "highSpeedRailways", "representativeFacilities",
            }
            or row["latitude"] != station["latitude"]
            or row["longitude"] != station["longitude"]
        ):
            raise ValueError(f"{station_id}: station row/coordinates mismatch")
        for key, geometry_type, maximum in (
            ("facilities", "Point", MAX_FACILITIES),
            ("routes", "LineString", None),
            ("highSpeedRailways", "LineString", None),
            ("representativeFacilities", "Point", MAX_REPRESENTATIVES),
        ):
            collection = row.get(key)
            if (
                not isinstance(collection, dict)
                or set(collection) != {"type", "features"}
                or collection.get("type") != "FeatureCollection"
            ):
                raise ValueError(f"{station_id}: invalid {key}")
            features = collection.get("features")
            if not isinstance(features, list) or (maximum is not None and len(features) > maximum):
                raise ValueError(f"{station_id}: invalid {key} count")
            for feature in features:
                if (
                    not isinstance(feature, dict)
                    or set(feature) != {"type", "geometry", "properties"}
                    or feature.get("type") != "Feature"
                    or not isinstance(feature.get("properties"), dict)
                ):
                    raise ValueError(f"{station_id}: invalid {key} feature")
                geometry = feature.get("geometry")
                if (
                    not isinstance(geometry, dict)
                    or set(geometry) != {"type", "coordinates"}
                    or geometry.get("type") != geometry_type
                ):
                    raise ValueError(f"{station_id}: invalid {key} geometry")
                coordinates = geometry["coordinates"]
                positions = [coordinates] if geometry_type == "Point" else coordinates
                if (
                    not isinstance(positions, list)
                    or (geometry_type == "LineString" and len(positions) < 2)
                    or any(not valid_position(position) for position in positions)
                ):
                    raise ValueError(f"{station_id}: invalid {key} coordinates")
        facility_ids: set[str] = set()
        facility_ranks: set[int] = set()
        for feature in row["facilities"]["features"]:
            props = feature["properties"]
            object_id = f"{props.get('osm_type')}/{props.get('osm_id')}"
            if (
                set(props) != {"kind", "rank", "osm_type", "osm_id"}
                or props["kind"] not in FACILITY_KIND_ORDER
                or not isinstance(props["rank"], int)
                or isinstance(props["rank"], bool)
                or props["rank"] < 0
                or not add_unique(facility_ranks, props["rank"])
                or props["osm_type"] not in {"node", "way", "relation"}
                or not isinstance(props["osm_id"], int)
                or isinstance(props["osm_id"], bool)
                or props["osm_id"] <= 0
                or not add_unique(facility_ids, object_id)
            ):
                raise ValueError(f"{station_id}: anonymous facility leaked properties")
        if facility_ranks != set(range(len(facility_ranks))):
            raise ValueError(f"{station_id}: facility ranks are not contiguous")
        for feature in row["routes"]["features"]:
            props = feature["properties"]
            if set(props) != {
                "name", "color", "serviceId", "lineOffset", "osm_way_ids", "osm_relation_ids",
            }:
                raise ValueError(f"{station_id}: route property schema mismatch")
            service = services.get(props.get("serviceId"))
            if (
                service is None
                or props["name"] != service["name"]
                or props["color"].upper() != service["color"].upper()
                or not safe_name(station, props["name"])
                or not isinstance(props["lineOffset"], (int, float))
                or isinstance(props["lineOffset"], bool)
                or not math.isfinite(props["lineOffset"])
                or abs(props["lineOffset"]) > 10
                or not positive_ids(props["osm_way_ids"])
                or not positive_ids(props["osm_relation_ids"])
                or not set(props["osm_relation_ids"]).issubset(service["relationIds"])
            ):
                raise ValueError(f"{station_id}: unverified route feature")
            referenced_services.add(props["serviceId"])
        high_speed_way_ids: set[int] = set()
        for feature in row["highSpeedRailways"]["features"]:
            props = feature["properties"]
            if (
                set(props) != {"railType", "osm_way_ids"}
                or props["railType"] != "highSpeed"
                or not positive_ids(props["osm_way_ids"])
                or any(not add_unique(high_speed_way_ids, value) for value in props["osm_way_ids"])
            ):
                raise ValueError(f"{station_id}: high-speed runtime properties leaked")
        representative_ids: set[str] = set()
        representative_ranks: set[int] = set()
        for feature in row["representativeFacilities"]["features"]:
            props = feature["properties"]
            object_id = f"{props.get('osm_type')}/{props.get('osm_id')}"
            if (
                set(props) != {"kind", "name", "rank", "osm_type", "osm_id"}
                or props["kind"] != "facility"
                or not isinstance(props["name"], str)
                or not props["name"].strip()
                or not safe_name(station, props["name"])
                or not isinstance(props["rank"], int)
                or isinstance(props["rank"], bool)
                or props["rank"] < 0
                or not add_unique(representative_ranks, props["rank"])
                or props["osm_type"] not in {"node", "way", "relation"}
                or not isinstance(props["osm_id"], int)
                or isinstance(props["osm_id"], bool)
                or props["osm_id"] <= 0
                or not add_unique(representative_ids, object_id)
            ):
                raise ValueError(f"{station_id}: unsafe representative facility")
        if representative_ranks != set(range(len(representative_ranks))):
            raise ValueError(f"{station_id}: representative ranks are not contiguous")
    if referenced_services != set(services):
        raise ValueError(
            f"runtime service linkage mismatch: unused={sorted(set(services) - referenced_services)}, "
            f"missing={sorted(referenced_services - set(services))}"
        )


next_station_by_id: dict[str, dict[str, Any]] = {}


def write_docs(
    generated_at: str,
    runtime: dict[str, Any],
    source_manifest: dict[str, Any],
    audit: dict[str, Any],
) -> dict[str, Any]:
    DOCS_DIR.mkdir(parents=True, exist_ok=True)
    sources_path = DOCS_DIR / "sources.json"
    audit_path = DOCS_DIR / "audit.json"
    sources_path.write_text(compact_json(source_manifest) + "\n")
    audit_path.write_text(compact_json(audit) + "\n")
    stations = runtime["stations"]
    summary = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "stationCount": len(stations),
        "facilityIconCount": sum(len(row["facilities"]["features"]) for row in stations.values()),
        "stationsWithFacilityIcons": sum(bool(row["facilities"]["features"]) for row in stations.values()),
        "routeFeatureCount": sum(len(row["routes"]["features"]) for row in stations.values()),
        "colourServiceCount": len(runtime["services"]),
        "colourLineColourPairCount": len(
            {(service["name"], service["color"].upper()) for service in runtime["services"].values()}
        ),
        "stationsWithColourServices": sum(bool(row["routes"]["features"]) for row in stations.values()),
        "highSpeedFeatureCount": sum(len(row["highSpeedRailways"]["features"]) for row in stations.values()),
        "highSpeedStationIds": [sid for sid, row in stations.items() if row["highSpeedRailways"]["features"]],
        "representativeFacilityCount": sum(len(row["representativeFacilities"]["features"]) for row in stations.values()),
        "stationsWithRepresentativeFacilities": sum(bool(row["representativeFacilities"]["features"]) for row in stations.values()),
        "sourceFailures": [sid for sid, row in source_manifest["stations"].items() if row.get("failure")],
        "classificationFailures": [
            sid for sid, row in source_manifest["stations"].items() if row.get("classificationFailures")
        ],
        "cacheHits": sum(bool(row.get("cacheHit")) for row in source_manifest["stations"].values()),
        "networkRequests": sum(not bool(row.get("cacheHit")) and not bool(row.get("failure")) for row in source_manifest["stations"].values()),
        "sourcesAcquiredByNetwork": sum(bool(row.get("acquiredByNetwork")) for row in source_manifest["stations"].values()),
        "rawBytes": sum(row.get("raw", {}).get("bytes", 0) for row in source_manifest["stations"].values()),
        "requestElapsedSeconds": round(sum(row.get("elapsedSeconds") or 0 for row in source_manifest["stations"].values()), 3),
    }
    summary_path = DOCS_DIR / "summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    station_rows = []
    for station_id, row in stations.items():
        station_audit = audit["stations"][station_id]
        unavailable = []
        for key, label in (
            ("facilities", "施設"),
            ("routes", "色"),
            ("highSpeedRailways", "新幹線"),
            ("representativeFacilities", "代表名"),
        ):
            reason = station_audit[key].get("unavailableReason")
            if reason:
                unavailable.append(f"{label}: {reason}")
        station_rows.append(
            "| {sid} | {name} | {facilities} | {services} | {high_speed} | {representatives} | {note} |".format(
                sid=station_id,
                name=station_audit["stationName"],
                facilities=len(row["facilities"]["features"]),
                services=len({f["properties"]["serviceId"] for f in row["routes"]["features"]}),
                high_speed="あり" if row["highSpeedRailways"]["features"] else "なし",
                representatives=len(row["representativeFacilities"]["features"]),
                note=" / ".join(unavailable).replace("|", "\\|") or "-",
            )
        )
    station_table = "\n".join(station_rows)
    readme = f"""# 50駅 地図ヒントデータ

生成日時：{generated_at}

`tool/prepare_map_hints_50stations.py`が50駅を同一schemaで生成する。実行用データは
`assets/maps/map_hints_poc.json`、取得manifestは`sources.json`、採否根拠は
`audit.json`、集計は`summary.json`に保存する。

## 集計

- 駅：{summary['stationCount']}件
- 匿名施設アイコン：{summary['facilityIconCount']}件（{summary['stationsWithFacilityIcons']}駅）
- 色付きroute feature：{summary['routeFeatureCount']}件、distinct service：{summary['colourServiceCount']}件、名称＋色の組：{summary['colourLineColourPairCount']}件（{summary['stationsWithColourServices']}駅）
- 新幹線feature：{summary['highSpeedFeatureCount']}件（{len(summary['highSpeedStationIds'])}駅）
- 代表施設名：{summary['representativeFacilityCount']}件（{summary['stationsWithRepresentativeFacilities']}駅）
- 取得失敗：{len(summary['sourceFailures'])}駅
- 分類失敗：{len(summary['classificationFailures'])}駅
- network取得済みraw：{summary['sourcesAcquiredByNetwork']}駅（この生成runのnetwork request：{summary['networkRequests']}件、cache hit：{summary['cacheHits']}駅）

## 駅別登録状況

| ID | 駅 | 匿名施設 | 色付き路線 | 新幹線 | 代表施設名 | 未登録理由 |
|---|---|---:|---:|---|---:|---|
{station_table}

## 生成

```sh
python3 tool/prepare_map_hints_50stations.py
# 保存済みrawだけで再生成
python3 tool/prepare_map_hints_50stations.py --cache-only
```

raw/query/cacheは`/tmp/ekidoko-map-hints-50stations-sources`に置く。公開Overpassには
固有User-Agentを付けて直列アクセスし、成功後に間隔を置く。HTTP 406/429/5xxと
通信失敗は30秒以上のbackoffで再試行する。query、endpoint、取得時刻、OSM base
timestamp、response bytes/SHA-256、所要時間は`sources.json`へ記録する。

## 選定規則

- 匿名施設はOSM実要素の6分類から駅中心500m以内を最大5件選び、runtimeには
  `kind/rank/osm_type/osm_id`だけを入れる。
- 路線色は`type=route`かつ`route=train|subway|light_rail|tram`のrelationにstrictな
  `#RRGGBB`の`colour`がある場合だけ採用する。上下・運行variantを
  ref/colour/operatorでまとめ、駅中心に近いdistinct serviceを最大6件にする。
  ref・名称が同じrelation群で色が競合する場合や、ref/operatorの根拠がない場合は
  採用せず従来色を維持する。OSM relation tagの整合確認は自動だが、事業者資料との
  独立照合と画面上の色の目視確認は別途必要である。
- 新幹線は`railway=rail`と`highspeed=yes`の両方を持つwayだけを対象にし、
  実geometryが駅中心500m円と交差する場合に表示する。名称はruntimeへ入れない。
  `usage/gauge/service`は採否条件にせず監査値として残す。
- 代表施設は同じ取得日のOverpass responseにある駅中心2000m以内の実OSM ID・名称・座標から最大3件を選ぶ。
  正規化した正解駅名・読み・aliasを含む名称は、`allowedLabels`の有無にかかわらず除外する。
  路線名・地名も同じ漏洩フィルターを通す。既存PoCの代表施設IDはfresh responseで
  再確認し、駅名を含む候補は表示対象から除外する。
- collectionは空を許容し、候補なし・曖昧・取得失敗を`audit.json`へ記録する。

## 出典・ライセンス

施設、線路、route relation、名称、座標は© OpenStreetMap contributors、ODbL 1.0。
取得元は`sources.json`のendpoint欄に記録する。runtimeの匿名施設と新幹線sourceは
推理開始時に名称を公開しない。データ差し替え時もquery/raw SHAと取得時刻を更新する。

- https://www.openstreetmap.org/copyright
- https://wiki.openstreetmap.org/wiki/Key:highspeed
- https://wiki.openstreetmap.org/wiki/Relation:route
- https://wiki.openstreetmap.org/wiki/Overpass_API
"""
    (DOCS_DIR / "README.md").write_text(readme)
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--station", action="append", help="Fetch/build only selected station IDs; intended for smoke inspection")
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--endpoint", action="append", help="Ordered Overpass endpoint; repeat for fallbacks")
    parser.add_argument("--cache-only", action="store_true", help="Never access the network")
    parser.add_argument("--no-write", action="store_true", help="Build and validate in memory without replacing outputs")
    parser.add_argument("--request-pause", type=float, default=2.0)
    parser.add_argument("--retries", type=int, default=3)
    args = parser.parse_args()
    endpoints = args.endpoint or list(DEFAULT_ENDPOINTS)
    args.cache_dir.mkdir(parents=True, exist_ok=True)

    catalog = json.loads(CATALOG_PATH.read_text())
    stations = [s for s in catalog if s.get("enabled")]
    selected_ids = set(args.station or [])
    if selected_ids:
        unknown = selected_ids - {s["id"] for s in stations}
        if unknown:
            parser.error(f"Unknown station IDs: {sorted(unknown)}")
        stations = [s for s in stations if s["id"] in selected_ids]
    global next_station_by_id
    next_station_by_id = {s["id"]: s for s in stations}
    baseline = json.loads(RUNTIME_PATH.read_text()) if RUNTIME_PATH.exists() else {"stations": {}, "services": {}}
    baseline_rows = baseline.get("stations", {})

    generated_at = utc_now()
    runtime: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "provenance": {
            "generatedAt": generated_at,
            "attribution": "© OpenStreetMap contributors",
            "license": "ODbL-1.0",
            "queryVersion": QUERY_VERSION,
            "sourceManifest": "docs/map-hints-50stations/sources.json",
            "selectionAudit": "docs/map-hints-50stations/audit.json",
        },
        "services": {},
        "stations": {},
    }
    source_manifest: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "provenance": {
            "attribution": "© OpenStreetMap contributors",
            "license": "ODbL-1.0",
            "userAgent": USER_AGENT,
            "endpoints": endpoints,
            "queryVersion": QUERY_VERSION,
            "cacheDirectory": str(args.cache_dir),
            "successPauseSeconds": args.request_pause,
            "retriesPerEndpoint": args.retries,
            "policy": "sequential requests; cache by query SHA-256; >=30 second backoff for 406/429/5xx or network failure",
        },
        "stations": {},
    }
    audit: dict[str, Any] = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "provenance": {
            "attribution": "© OpenStreetMap contributors",
            "license": "ODbL-1.0",
            "highSpeedDefinition": "railway=rail + highspeed=yes + geometry intersects station-centred 500m circle",
            "routeColourDefinition": "OSM route relation strict #RRGGBB colour only",
        },
        "stations": {},
    }

    for index, station in enumerate(stations, 1):
        station_id = station["id"]
        print(f"[{index}/{len(stations)}] {station_id}", flush=True)
        raw, source = fetch_one(
            station,
            args.cache_dir,
            endpoints,
            args.cache_only,
            args.request_pause,
            args.retries,
        )
        source_manifest["stations"][station_id] = source
        station_audit: dict[str, Any] = {
            "stationName": station["name"],
            "stationCenter": [station["longitude"], station["latitude"]],
            "facilities": {"selected": [], "candidateCount": 0, "unavailableReason": None},
            "routes": {"selected": [], "candidateCount": 0, "excluded": {}, "unavailableReason": None},
            "highSpeedRailways": {"selectedWays": [], "excluded": {}, "unavailableReason": None},
            "representativeFacilities": {
                "selected": [],
                "source": "fresh station Overpass response",
                "sourceAcquiredAt": source.get("acquiredAt"),
                "osmBaseTimestamp": source.get("osmBaseTimestamp"),
                "unavailableReason": None,
            },
        }
        if raw is None:
            reason = source.get("failure", "Overpass source unavailable")
            facilities: list[dict[str, Any]] = []
            routes: list[dict[str, Any]] = []
            high_speed: list[dict[str, Any]] = []
            representatives: list[dict[str, Any]] = []
            services: dict[str, dict[str, Any]] = {}
            station_audit["facilities"]["unavailableReason"] = reason
            station_audit["routes"]["unavailableReason"] = reason
            station_audit["highSpeedRailways"]["unavailableReason"] = reason
            station_audit["representativeFacilities"]["unavailableReason"] = reason
        else:
            facilities, routes, high_speed, representatives = [], [], [], []
            services = {}
            capability_failures: dict[str, str] = {}

            def record_capability_failure(key: str, error: Exception) -> None:
                reason = f"classification-error: {type(error).__name__}: {error}"
                station_audit[key]["unavailableReason"] = reason
                capability_failures[key] = reason
                print(f"{station_id}/{key}: {reason}", file=sys.stderr, flush=True)

            try:
                candidates = candidate_facilities(raw, station)
                facilities, facility_audit = select_facilities(
                    candidates, station_id, baseline_rows.get(station_id)
                )
                station_audit["facilities"] = {
                    "candidateCount": len(candidates),
                    "selected": [
                        {
                            "osmObject": candidate["id"],
                            "classification": candidate["kind"],
                            "nameForAuditOnly": candidate["name"],
                            "coordinates": candidate["position"],
                            "distanceMeters": candidate["distanceMeters"],
                            "tags": tags_for_audit(candidate["element"]),
                            "selectionReason": (
                                "preserved reviewed PoC icon after fresh OSM identity/classification/coordinate revalidation"
                                if station_id in LEGACY_STATIONS
                                else "selected by category diversity, facility significance, provenance signals, footprint, and distance within 500m"
                            ),
                        }
                        for candidate in facility_audit
                    ],
                    "unavailableReason": None if facilities else "no supported named OSM facility center within 500m",
                }
            except Exception as error:
                facilities = []
                record_capability_failure("facilities", error)

            try:
                routes, services, route_audit = select_routes(
                    raw, station, baseline_rows.get(station_id)
                )
                station_audit["routes"] = {
                    **route_audit,
                    "unavailableReason": None if routes else "no unambiguous nearby route relation with strict #RRGGBB colour",
                }
            except Exception as error:
                routes, services = [], {}
                record_capability_failure("routes", error)

            try:
                high_speed, high_speed_audit = select_high_speed(raw, station)
                station_audit["highSpeedRailways"] = {
                    **high_speed_audit,
                    "unavailableReason": None if high_speed else "no railway=rail/highspeed=yes geometry intersects 500m circle",
                }
            except Exception as error:
                high_speed = []
                record_capability_failure("highSpeedRailways", error)

            try:
                representatives, rep_audit = select_representatives(raw, station)
                station_audit["representativeFacilities"]["selected"] = rep_audit
                station_audit["representativeFacilities"]["unavailableReason"] = (
                    None if representatives else "no safe named supported OSM facility within 2000m"
                )
            except Exception as error:
                representatives = []
                record_capability_failure("representativeFacilities", error)
            if capability_failures:
                source_manifest["stations"][station_id]["classificationFailures"] = capability_failures

        for sid, service in services.items():
            existing = runtime["services"].get(sid)
            if existing is None:
                runtime["services"][sid] = service
            elif existing["name"] != service["name"] or existing["color"].upper() != service["color"].upper():
                raise ValueError(f"service ID collision: {sid}")
            else:
                existing["relationIds"] = sorted(set(existing["relationIds"] + service["relationIds"]))
        runtime["stations"][station_id] = {
            "latitude": station["latitude"],
            "longitude": station["longitude"],
            "facilities": feature_collection(facilities),
            "routes": feature_collection(routes),
            "highSpeedRailways": feature_collection(high_speed),
            "representativeFacilities": feature_collection(representatives),
        }
        audit["stations"][station_id] = station_audit
        print(
            f"  facilities={len(facilities)} routes={len(routes)} services={len(services)} "
            f"highSpeed={len(high_speed)} representatives={len(representatives)}",
            flush=True,
        )

    validate_runtime(runtime, {s["id"] for s in stations})
    if args.no_write:
        print(compact_json({"stations": len(runtime["stations"]), "services": len(runtime["services"])}))
        return 0
    if selected_ids:
        parser.error("--station may only be combined with --no-write; full outputs always require all enabled stations")
    RUNTIME_PATH.write_text(compact_json(runtime) + "\n")
    summary = write_docs(generated_at, runtime, source_manifest, audit)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
