"""Run and verify the Phase 4 native map QA suite.

A normal successful run means five completed games, 50 stations x four
stages, and 200 readable, consistently-sized screenshots. Every invocation
uses a new report directory and screenshot namespace.

Examples:
  python3 tool/check_station_maps.py --device <simulator-id>
  python3 tool/check_station_maps.py --device <id> --run-id smoke-001 \
      --batches 0 --allow-partial
  python3 tool/check_station_maps.py --summary-only --run-id <existing-run-id>
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
REPORT_SCHEMA_VERSION = 4
BATCH_SIZE = 10
HINTS = range(4)
STAGES = ('initial', 'hint1', 'hint2', 'hint3')
RUN_ID_PATTERN = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')


class ValidationError(Exception):
    """A native QA artifact is incomplete or inconsistent."""


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def git_revision(excluded_paths=(), root=ROOT):
    revision = subprocess.run(
        ['git', 'rev-parse', 'HEAD'], cwd=root, check=True,
        capture_output=True, text=True,
    ).stdout.strip()
    status_command = [
        'git', 'status', '--porcelain', '--untracked-files=all', '--', '.',
    ]
    resolved_root = root.resolve()
    for path in excluded_paths:
        try:
            relative = Path(path).resolve().relative_to(resolved_root)
        except ValueError:
            continue
        if relative == Path('.'):
            continue
        value = relative.as_posix()
        status_command.extend([
            f':(exclude){value}',
            f':(exclude){value}/**',
        ])
    status = subprocess.run(
        status_command, cwd=root, check=True,
        capture_output=True, text=True,
    ).stdout.splitlines()
    return revision, bool(status)


def evidence_snapshot(excluded_paths=(), root=ROOT):
    revision, dirty = git_revision(excluded_paths, root)
    return {
        'commitSha': revision,
        'sourceTreeDirty': dirty,
        'mapHintsAssetSha256': sha256(root / 'assets/maps/map_hints_poc.json'),
        'stationHintsAssetSha256': sha256(
            root / 'assets/maps/station_hints.json'
        ),
        'stationCatalogSha256': sha256(root / 'assets/data/stations.json'),
    }


def snapshot_errors(expected, actual):
    errors = []
    if actual.get('commitSha') != expected.get('commitSha'):
        errors.append('HEAD commit changed during the QA run')
    if actual.get('sourceTreeDirty'):
        errors.append('tracked source or non-evidence files changed during the QA run')
    for key in (
        'mapHintsAssetSha256',
        'stationHintsAssetSha256',
        'stationCatalogSha256',
    ):
        if actual.get(key) != expected.get(key):
            errors.append(f'{key} changed during the QA run')
    return errors


def new_run_id():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        'phase4-%Y%m%dT%H%M%S%fZ'
    )


def checked_run_id(value):
    if value is None or not RUN_ID_PATTERN.fullmatch(value):
        raise ValidationError(
            'run ID must be 1-80 characters using letters, numbers, dot, _ or -'
        )
    return value


def image_size(path):
    """Decode an image with macOS ImageIO and return its pixel dimensions."""
    result = subprocess.run(
        [
            '/usr/bin/sips', '-g', 'format', '-g', 'pixelWidth', '-g',
            'pixelHeight', str(path),
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise ValidationError(
            f'{path}: image decode failed: {result.stderr.strip()}'
        )
    values = dict(re.findall(
        r'^\s*(format|pixelWidth|pixelHeight):\s*(.+?)\s*$',
        result.stdout,
        flags=re.MULTILINE,
    ))
    try:
        width, height = int(values['pixelWidth']), int(values['pixelHeight'])
    except (KeyError, ValueError) as error:
        raise ValidationError(
            f'{path}: dimensions were not reported by sips'
        ) from error
    if values.get('format') not in {'jpeg', 'jpg'} or width < 320 or height < 500:
        raise ValidationError(
            f'{path}: expected a portrait JPEG of at least 320x500, got '
            f"{values.get('format')} {width}x{height}"
        )
    return width, height


def read_reports(directory):
    reports = []
    for path in sorted(directory.glob('batch-*.json')):
        try:
            reports.append(json.loads(path.read_text()))
        except (OSError, json.JSONDecodeError) as error:
            raise ValidationError(f'{path}: unreadable report: {error}') from error
    return reports


def expected_batch_keys(stations, batch):
    station_ids = [
        row['id']
        for row in stations[batch * BATCH_SIZE:(batch + 1) * BATCH_SIZE]
    ]
    return {
        (station_id, hint) for station_id in station_ids for hint in HINTS
    }


def osm_object_key(properties):
    osm_type = properties.get('osm_type')
    if osm_type not in {'node', 'way', 'relation'}:
        return None
    raw_id = properties.get('osm_id')
    if (
        isinstance(raw_id, (int, float))
        and not isinstance(raw_id, bool)
        and raw_id > 0
        and float(raw_id).is_integer()
    ):
        osm_id = str(int(raw_id))
    elif isinstance(raw_id, str) and re.fullmatch(r'[1-9][0-9]*', raw_id):
        osm_id = raw_id
    else:
        return None
    return f'{osm_type}/{osm_id}'


def point_in_bounds(point, bounds):
    return (
        isinstance(point, list)
        and len(point) == 2
        and all(isinstance(value, (int, float)) for value in point)
        and bounds['west'] <= point[0] <= bounds['east']
        and bounds['south'] <= point[1] <= bounds['north']
    )


def validate_batch(
    report, stations, run_id, capture, expected_metadata,
    expected_capabilities, expected_representatives,
    formal,
    expected_dimensions=None,
):
    errors = []
    batch = report.get('batch')
    batch_count = len(stations) // BATCH_SIZE
    if not isinstance(batch, int) or batch not in range(batch_count):
        return (
            ['report has no valid batch number'],
            expected_dimensions,
            {},
            True,
        )
    expected_keys = expected_batch_keys(stations, batch)
    records = report.get('records')
    if not isinstance(records, list):
        message = f'batch {batch}: records is not a list'
        return (
            [message],
            expected_dimensions,
            {key: [message] for key in expected_keys},
            True,
        )
    keys = [
        (row.get('stationId'), row.get('hint'))
        for row in records if isinstance(row, dict)
    ]
    if len(records) != BATCH_SIZE * 4:
        errors.append(f'batch {batch}: expected 40 records, got {len(records)}')
    if len(keys) != len(set(keys)):
        errors.append(f'batch {batch}: duplicate station/hint records')
    if set(keys) != expected_keys:
        errors.append(
            f'batch {batch}: record key mismatch; '
            f'missing={sorted(expected_keys - set(keys))}, '
            f'extra={sorted(set(keys) - expected_keys)}'
        )
    if report.get('schemaVersion') != REPORT_SCHEMA_VERSION:
        errors.append(
            f'batch {batch}: unexpected schemaVersion '
            f'{report.get("schemaVersion")}'
        )
    if report.get('runId') != run_id:
        errors.append(f'batch {batch}: runId mismatch')
    if report.get('captureEnabled') is not capture:
        errors.append(f'batch {batch}: captureEnabled mismatch')
    for key, expected in expected_metadata.items():
        if report.get(key) != expected:
            errors.append(
                f'batch {batch}: {key} mismatch; '
                f'expected {expected!r}, got {report.get(key)!r}'
            )
    if not isinstance(report.get('environment'), str) or not report['environment']:
        errors.append(f'batch {batch}: missing environment')
    if not isinstance(report.get('sourceTreeDirty'), bool):
        errors.append(f'batch {batch}: sourceTreeDirty must be boolean')
    elif formal and report['sourceTreeDirty']:
        errors.append(
            f'batch {batch}: formal evidence requires a clean source tree'
        )
    if report.get('cacheCondition') not in {
        'cold', 'warm', 'uncleared', 'unknown'
    }:
        errors.append(f'batch {batch}: invalid cacheCondition')
    if report.get('failures'):
        errors.append(f'batch {batch}: recorded failures: {report["failures"]}')
    if report.get('screenshotCopyErrors'):
        errors.append(
            f'batch {batch}: screenshot copy errors: '
            f'{report["screenshotCopyErrors"]}'
        )
    if report.get('completed') is not True:
        errors.append(f'batch {batch}: game did not complete')
    if report.get('replayReset') is not True:
        errors.append(f'batch {batch}: replay did not reset')
    if report.get('gameScore') != 90 or report.get('correctCount') != 9:
        errors.append(
            f'batch {batch}: expected score/correctCount 90/9, got '
            f'{report.get("gameScore")}/{report.get("correctCount")}'
        )
    expected_station_ids = [
        row['id']
        for row in stations[batch * BATCH_SIZE:(batch + 1) * BATCH_SIZE]
    ]
    question_ids = report.get('questionStationIds')
    if (
        question_ids != expected_station_ids
        or len(set(question_ids or [])) != BATCH_SIZE
    ):
        errors.append(f'batch {batch}: question order/uniqueness mismatch')
    choices = report.get('choiceAudits')
    if not isinstance(choices, list) or len(choices) != BATCH_SIZE:
        errors.append(f'batch {batch}: expected ten choice audits')
    else:
        for index, audit in enumerate(choices):
            ids = audit.get('choiceIds', []) if isinstance(audit, dict) else []
            if len(ids) != 4 or len(set(ids)) != 4:
                errors.append(
                    f'batch {batch} question {index}: choices are not unique'
                )
            if (
                not isinstance(audit, dict)
                or audit.get('correctChoiceCount') != 1
            ):
                errors.append(
                    f'batch {batch} question {index}: '
                    'correct choice count is not one'
                )
            expected_station = expected_station_ids[index]
            if (
                not isinstance(audit, dict)
                or audit.get('question') != index
                or audit.get('stationId') != expected_station
            ):
                errors.append(
                    f'batch {batch} question {index}: choice audit identity '
                    'does not match the forced question order'
                )
            if batch == 0 and audit.get('allEasyEligible') is not True:
                errors.append(
                    f'batch {batch} question {index}: Easy choices include '
                    'a Hard-only station'
                )

    station_by_id = {station['id']: station for station in stations}
    for row in records:
        if not isinstance(row, dict):
            errors.append(f'batch {batch}: non-object record')
            continue
        station_id = row.get('stationId')
        hint = row.get('hint')
        station = station_by_id.get(station_id)
        prefix = f'batch {batch} {station_id}/H{hint}'
        if station is None or hint not in HINTS:
            continue
        if row.get('stationName') != station['name']:
            errors.append(f'{prefix}: station name mismatch')
        if row.get('renderStatus') != 'ok':
            errors.append(f'{prefix}: render status is not ok')
        if row.get('labelFilterStatus') != 'passed':
            errors.append(f'{prefix}: label filter did not pass')
        if row.get('difficulty') != ('Easy' if batch == 0 else 'Hard'):
            errors.append(f'{prefix}: difficulty mismatch')
        for coordinate_key, expected in (
            ('latitude', station['latitude']),
            ('longitude', station['longitude']),
        ):
            value = row.get(coordinate_key)
            if (
                not isinstance(value, (int, float))
                or abs(value - expected) > 0.000001
            ):
                errors.append(f'{prefix}: map {coordinate_key} is off-centre')
        if not isinstance(row.get('zoom'), (int, float)):
            errors.append(f'{prefix}: missing camera zoom')
        if not isinstance(row.get('roadCount'), int) or row['roadCount'] <= 0:
            errors.append(f'{prefix}: no rendered roads')
        if not isinstance(row.get('railCount'), int) or row['railCount'] <= 0:
            errors.append(f'{prefix}: no rendered railways')
        if (
            hint < 2
            and (
                not isinstance(row.get('buildingCount'), int)
                or row['buildingCount'] <= 0
            )
        ):
            errors.append(f'{prefix}: no close-range buildings')
        expected_building_verification = (
            'machine-confirmed-rendered-feature'
            if hint < 2
            else 'manual-required-vector-tile-zoom-limit'
        )
        if row.get('buildingVerification') != expected_building_verification:
            errors.append(f'{prefix}: invalid building verification status')

        capabilities = row.get('capabilities')
        expected_capability_keys = {
            'facilities', 'routes', 'highSpeedRailways',
            'representativeFacilities',
        }
        if (
            not isinstance(capabilities, dict)
            or set(capabilities) != expected_capability_keys
            or any(not isinstance(value, bool) for value in capabilities.values())
        ):
            errors.append(f'{prefix}: invalid capability manifest')
            capabilities = {}
        elif capabilities != expected_capabilities.get(station_id):
            errors.append(f'{prefix}: capability manifest differs from asset')
        icon_count = row.get('facilityIconCount')
        if not isinstance(icon_count, int) or icon_count < 0 or icon_count > 5:
            errors.append(f'{prefix}: invalid facility icon count')
        if row.get('anonymousFacilityNameCount') != 0:
            errors.append(f'{prefix}: anonymous facility leaked a name')
        expects_icons = row.get('expectsFacilityIconsInViewport')
        if not isinstance(expects_icons, bool):
            errors.append(f'{prefix}: missing facility viewport expectation')
        elif hint < 3 and expects_icons and icon_count == 0:
            errors.append(f'{prefix}: expected facility icon did not render')
        if hint == 3 and icon_count != 0:
            errors.append(f'{prefix}: anonymous icons are visible at H3')

        color_count = row.get('verifiedRouteColorCount')
        if not isinstance(color_count, int) or color_count < 0:
            errors.append(f'{prefix}: invalid verified route colour count')
        expects_colors = row.get('expectsRouteColorsInViewport')
        if not isinstance(expects_colors, bool):
            errors.append(f'{prefix}: missing route viewport expectation')
        elif hint >= 1 and expects_colors and color_count == 0:
            errors.append(f'{prefix}: expected route colour did not render')
        if hint == 0 and color_count != 0:
            errors.append(f'{prefix}: route colours are visible initially')

        high_speed_count = row.get('highSpeedRailCount')
        casing_count = row.get('highSpeedRailCasingCount')
        if (
            not isinstance(high_speed_count, int)
            or not isinstance(casing_count, int)
            or high_speed_count < 0
            or casing_count < 0
        ):
            errors.append(f'{prefix}: invalid high-speed feature counts')
        expects_high_speed = row.get('expectsHighSpeedInViewport')
        if not isinstance(expects_high_speed, bool):
            errors.append(f'{prefix}: missing high-speed viewport expectation')
        elif expects_high_speed and (
            high_speed_count == 0 or casing_count == 0
        ):
            errors.append(f'{prefix}: expected high-speed overlay did not render')

        route_names = row.get('routeNames')
        place_names = row.get('placeNames')
        facility_names = row.get('facilityNames')
        if not all(
            isinstance(value, list)
            and all(isinstance(item, str) for item in value)
            for value in (route_names, place_names, facility_names)
        ):
            errors.append(f'{prefix}: rendered label lists are missing')
            route_names, place_names, facility_names = [], [], []
        else:
            if hint < 2 and route_names:
                errors.append(f'{prefix}: route names appeared before H2')
            if hint >= 2 and not route_names:
                errors.append(f'{prefix}: no route name rendered at H2/H3')
            if hint < 3 and (place_names or facility_names):
                errors.append(f'{prefix}: place/facility names appeared before H3')
            if hint == 3 and not place_names and not facility_names:
                errors.append(f'{prefix}: H3 has no place or facility name')

        bounds = row.get('visibleBounds')
        if (
            not isinstance(bounds, dict)
            or set(bounds) != {'west', 'south', 'east', 'north'}
            or any(
                not isinstance(bounds.get(key), (int, float))
                for key in ('west', 'south', 'east', 'north')
            )
            or bounds.get('west', 0) >= bounds.get('east', 0)
            or bounds.get('south', 0) >= bounds.get('north', 0)
        ):
            errors.append(f'{prefix}: invalid visible bounds')
            bounds = None
        asset_representatives = expected_representatives.get(station_id, [])
        in_view_representatives = (
            [
                feature for feature in asset_representatives
                if point_in_bounds(feature['geometry']['coordinates'], bounds)
            ]
            if hint == 3 and bounds is not None else []
        )
        expected_rep_keys = {
            osm_object_key(feature['properties'])
            for feature in in_view_representatives
        }
        expected_rep_keys.discard(None)
        expected_rep_names = {
            feature['properties']['name']
            for feature in in_view_representatives
        }
        reported_expected_keys = row.get('expectedRepresentativeKeys')
        reported_rendered_keys = row.get('renderedRepresentativeKeys')
        rendered_objects = row.get('renderedRepresentativeObjects')
        representative_count = row.get('representativeLabels')
        expected_count = row.get('expectedRepresentativeLabels')
        matched_count = row.get('matchedRepresentativeLabels')
        missing_count = row.get('missingRepresentativeLabels')
        for name, value in (
            ('representativeLabels', representative_count),
            ('expectedRepresentativeLabels', expected_count),
            ('matchedRepresentativeLabels', matched_count),
            ('missingRepresentativeLabels', missing_count),
        ):
            if (
                not isinstance(value, int)
                or isinstance(value, bool)
                or value < 0
            ):
                errors.append(f'{prefix}: invalid {name} count')
        if (
            not isinstance(reported_expected_keys, list)
            or any(not isinstance(key, str) for key in reported_expected_keys)
            or len(reported_expected_keys) != len(set(reported_expected_keys))
            or set(reported_expected_keys) != expected_rep_keys
        ):
            errors.append(f'{prefix}: expected representative keys mismatch')
        if not isinstance(rendered_objects, list) or any(
            not isinstance(item, dict)
            or set(item) != {'key', 'osmType', 'osmId', 'name'}
            for item in (rendered_objects or [])
        ):
            errors.append(f'{prefix}: invalid rendered representative objects')
            rendered_objects = []
        rendered_object_keys = {
            item.get('key') for item in rendered_objects
            if isinstance(item.get('key'), str)
        }
        rendered_names = {
            item.get('name') for item in rendered_objects
            if isinstance(item.get('name'), str)
        }
        if (
            not isinstance(reported_rendered_keys, list)
            or any(not isinstance(key, str) for key in reported_rendered_keys)
            or len(reported_rendered_keys) != len(set(reported_rendered_keys))
            or set(reported_rendered_keys) != rendered_object_keys
        ):
            errors.append(f'{prefix}: rendered representative keys mismatch')
        all_asset_keys = {
            osm_object_key(feature['properties'])
            for feature in asset_representatives
        }
        all_asset_names = {
            feature['properties']['name'] for feature in asset_representatives
        }
        for item in rendered_objects:
            normalized_key = osm_object_key({
                'osm_type': item.get('osmType'),
                'osm_id': item.get('osmId'),
            })
            fallback_key = (
                f"name:{item['name'].strip()}"
                if isinstance(item.get('name'), str) else None
            )
            if item.get('key') not in {normalized_key, fallback_key}:
                errors.append(
                    f'{prefix}: representative OSM/name key is inconsistent'
                )
            if (
                item.get('key') not in all_asset_keys
                and item.get('name') not in all_asset_names
            ):
                errors.append(
                    f'{prefix}: non-registered representative label rendered'
                )
        if representative_count != len(rendered_objects):
            errors.append(f'{prefix}: representative label count mismatch')
        if expected_count != len(expected_rep_keys):
            errors.append(f'{prefix}: expected representative count mismatch')
        if matched_count != len(expected_rep_keys) or missing_count != 0:
            errors.append(
                f'{prefix}: not all expected representatives were rendered'
            )
        for feature in in_view_representatives:
            properties = feature['properties']
            key = osm_object_key(properties)
            if key not in rendered_object_keys and properties['name'] not in rendered_names:
                errors.append(
                    f'{prefix}: representative {key} was replaced or missing'
                )
        if hint < 3 and (
            rendered_objects
            or reported_expected_keys
            or reported_rendered_keys
            or representative_count != 0
            or expected_count != 0
            or matched_count != 0
            or missing_count != 0
        ):
            errors.append(f'{prefix}: representative label appeared before H3')
        if isinstance(facility_names, list) and set(facility_names) != rendered_names:
            errors.append(f'{prefix}: representative names/objects mismatch')

    if capture:
        for station_id, hint in sorted(expected_keys):
            stage = STAGES[hint]
            relative = (
                Path('phase4') / run_id / 'stations' / station_id
                / f'{stage}.jpg'
            )
            matching = [
                row for row in records
                if row.get('stationId') == station_id
                and row.get('hint') == hint
            ]
            if (
                len(matching) == 1
                and matching[0].get('screenshot') != relative.as_posix()
            ):
                errors.append(
                    f'batch {batch} {station_id}/H{hint}: '
                    'screenshot path mismatch'
                )
            path = ROOT / 'docs/screenshots' / relative
            if not path.is_file():
                errors.append(
                    f'batch {batch} {station_id}/H{hint}: '
                    f'{relative} screenshot is missing'
                )
                continue
            try:
                dimensions = image_size(path)
                if expected_dimensions is None:
                    expected_dimensions = dimensions
                elif dimensions != expected_dimensions:
                    errors.append(
                        f'batch {batch} {station_id}/H{hint}: '
                        f'{relative} expected {expected_dimensions[0]}x'
                        f'{expected_dimensions[1]}, got '
                        f'{dimensions[0]}x{dimensions[1]}'
                    )
            except ValidationError as error:
                errors.append(
                    f'batch {batch} {station_id}/H{hint}: {error}'
                )

    issues_by_key = {}
    batch_wide_errors = []
    station_error = re.compile(
        rf'^batch {batch} ([a-z0-9_]+)/H([0-3]):'
    )
    for error in errors:
        match = station_error.match(error)
        if match:
            key = match.group(1), int(match.group(2))
            if key in expected_keys:
                issues_by_key.setdefault(key, []).append(error)
                continue
        batch_wide_errors.append(error)
    if batch_wide_errors:
        for key in expected_keys:
            issues_by_key.setdefault(key, []).extend(batch_wide_errors)
    return errors, expected_dimensions, issues_by_key, bool(batch_wide_errors)


def summarize(
    directory, stations, run_id, require_complete, capture,
    expected_metadata, expected_capabilities, expected_representatives,
    current_tree_dirty,
):
    reports = read_reports(directory)
    records_list = [
        row
        for report in reports
        for row in report.get('records', [])
        if isinstance(row, dict)
    ]
    records = {}
    duplicate_keys = []
    for row in records_list:
        key = row.get('stationId'), row.get('hint')
        if key in records:
            duplicate_keys.append(key)
        records[key] = row
    failures = {}
    run_failures = []
    for report in reports:
        for row in report.get('failures', []):
            key = row.get('stationId'), row.get('hint')
            if key[0] in {None, '__setup__'} or not isinstance(key[1], int):
                run_failures.append(row)
            else:
                failures[key] = row.get('error', 'unknown failure')

    validation_errors = []
    validation_issues = {}
    global_validation_errors = []
    if not reports:
        message = 'no batch reports found'
        validation_errors.append(message)
        global_validation_errors.append(message)
    if duplicate_keys:
        message = f'duplicate report keys: {sorted(duplicate_keys)}'
        validation_errors.append(message)
        for key in duplicate_keys:
            validation_issues.setdefault(key, []).append(message)
    expected_batches = set(range(len(stations) // BATCH_SIZE))
    actual_batches = {report.get('batch') for report in reports}
    if require_complete and actual_batches != expected_batches:
        message = (
            f'expected batches {sorted(expected_batches)}, '
            f'got {sorted(map(str, actual_batches))}'
        )
        validation_errors.append(message)
        global_validation_errors.append(message)
    if require_complete and not capture:
        message = 'formal evidence requires screenshot capture'
        validation_errors.append(message)
        global_validation_errors.append(message)
    if require_complete and current_tree_dirty:
        message = 'formal evidence requires the current source tree to be clean'
        validation_errors.append(message)
        global_validation_errors.append(message)
    expected_dimensions = None
    for report in reports:
        errors, expected_dimensions, report_issues, batch_wide = validate_batch(
            report,
            stations,
            run_id,
            capture,
            expected_metadata,
            expected_capabilities,
            expected_representatives,
            require_complete,
            expected_dimensions,
        )
        validation_errors.extend(errors)
        for key, messages in report_issues.items():
            validation_issues.setdefault(key, []).extend(messages)
        if batch_wide and not report_issues:
            global_validation_errors.extend(errors)
    if require_complete:
        expected_keys = {
            (station['id'], hint) for station in stations for hint in HINTS
        }
        actual_keys = set(records)
        if len(records_list) != 200 or actual_keys != expected_keys:
            message = (
                'expected exactly 200 unique station/hint records; '
                f'rows={len(records_list)}, unique={len(actual_keys)}, '
                f'missing={len(expected_keys - actual_keys)}, '
                f'extra={len(actual_keys - expected_keys)}'
            )
            validation_errors.append(message)
            for key in expected_keys - actual_keys:
                validation_issues.setdefault(key, []).append(message)
            if actual_keys - expected_keys or len(records_list) != len(actual_keys):
                global_validation_errors.append(message)
    if run_failures:
        message = f'run/setup failures: {run_failures}'
        validation_errors.append(message)
        global_validation_errors.append(message)
    for key in (
        'environment',
        'commitSha',
        'sourceTreeDirty',
        'mapHintsAssetSha256',
        'stationHintsAssetSha256',
        'stationCatalogSha256',
        'cacheCondition',
    ):
        values = {
            json.dumps(report.get(key), sort_keys=True)
            for report in reports
        }
        if len(values) > 1:
            message = f'inconsistent {key} metadata across batch reports'
            validation_errors.append(message)
            global_validation_errors.append(message)

    all_expected_keys = {
        (station['id'], hint) for station in stations for hint in HINTS
    }
    for message in global_validation_errors:
        for key in all_expected_keys:
            validation_issues.setdefault(key, []).append(message)
    if validation_errors and not any(
        key in all_expected_keys and messages
        for key, messages in validation_issues.items()
    ):
        # Defensive invariant: a failed validation can never coexist with a
        # 200/200 OK matrix, even for an unforeseen run-level error.
        message = 'run validation failed; evidence is not stage-valid'
        for key in all_expected_keys:
            validation_issues.setdefault(key, []).append(message)

    table = [
        '# Phase 4 地図品質記録',
        '',
        f'Run ID: `{run_id}`',
        '',
        'OKはnative描画・能力別レイヤー・中心/ズーム・漏洩防止の'
        '機械確認です。全文の可読性と個々のタイル欠落は目視確認が必要です。',
        '建物は初期/H1のみ描画featureを機械確認します。H2/H3はvector tileの'
        'ズーム制約があるため、スクリーンショットによる目視確認が必要です。',
        '',
        '| 駅 | 初期 | H1 | H2 | H3 | 備考 |',
        '|---|---|---|---|---|---|',
    ]
    detail = [
        '# 駅別・段階別の確認項目',
        '',
        '| 駅 | 段階 | 描画 | 中心/縮尺 | 基図 | 路線色 | 路線名 | '
        '施設/地名 | 漏洩防止 | 目視 |',
        '|---|---|---|---|---|---|---|---|---|---|',
    ]
    counts = {'ok': 0, 'failed': 0, 'unconfirmed': 0}
    matrix = []
    for station in stations:
        statuses, notes = [], []
        for hint in HINTS:
            key = station['id'], hint
            row = records.get(key)
            issue_messages = [
                *([failures[key]] if key in failures else []),
                *validation_issues.get(key, []),
            ]
            if issue_messages:
                state = 'failed'
                notes.append(f'H{hint}: {issue_messages[0]}')
            elif row and row.get('renderStatus') == 'ok':
                state = 'ok'
            else:
                state = 'unconfirmed'
            counts[state] += 1
            display = {
                'ok': 'OK', 'failed': '失敗', 'unconfirmed': '未確認'
            }[state]
            statuses.append(display)
            matrix.append({
                'stationId': station['id'],
                'hint': hint,
                'status': state,
                'record': row,
                'error': issue_messages[0] if issue_messages else None,
                'errors': issue_messages,
            })
            checked = state == 'ok'
            capabilities = row.get('capabilities', {}) if row else {}
            if checked:
                building = (
                    str(row.get('buildingCount', 0))
                    if hint < 2 else '目視確認'
                )
                base = (
                    f"道路{row.get('roadCount', 0)}/"
                    f"線路{row.get('railCount', 0)}/建物{building}"
                )
            else:
                base = '未確認'
            colors = (
                str(row.get('verifiedRouteColorCount', 0))
                if checked and hint >= 1 and capabilities.get('routes')
                else (
                    '対象なし'
                    if checked and not capabilities.get('routes')
                    else ('非表示OK' if checked else '未確認')
                )
            )
            routes = (
                str(len(row.get('routeNames', [])))
                if checked and hint >= 2
                else ('非表示OK' if checked else '未確認')
            )
            labels = (
                f"代表{row.get('matchedRepresentativeLabels', 0)}/"
                f"{row.get('expectedRepresentativeLabels', 0)}・"
                f"地名{len(row.get('placeNames', []))}"
                if checked and hint == 3
                else ('非表示OK' if checked else '未確認')
            )
            detail.append('| ' + ' | '.join([
                station['name'],
                STAGES[hint],
                display,
                'OK' if checked else '未確認',
                base,
                colors,
                routes,
                labels,
                (
                    'OK'
                    if checked and row.get('labelFilterStatus') == 'passed'
                    else '未確認'
                ),
                '目視確認が必要',
            ]) + ' |')
        notes.append('Easy対象' if station.get('easyEligible') else 'Hardのみ')
        table.append('| ' + ' | '.join([
            station['name'],
            *statuses,
            '；'.join(notes).replace('|', '/').replace('\n', ' '),
        ]) + ' |')

    performance = {}
    for hint in HINTS:
        values = [
            row['elapsedFromActionMs']
            for row in records.values()
            if row.get('hint') == hint
            and isinstance(row.get('elapsedFromActionMs'), int)
        ]
        if values:
            performance[str(hint)] = {
                'samples': len(values),
                'medianMs': statistics.median(values),
                'minMs': min(values),
                'maxMs': max(values),
            }
    rss = [
        row['rssBytes']
        for row in records.values()
        if isinstance(row.get('rssBytes'), int)
    ]
    h3_records = [
        row for row in records.values()
        if row.get('hint') == 3 and row.get('renderStatus') == 'ok'
    ]
    def representative_value(row, key):
        value = row.get(key)
        return value if isinstance(value, int) and not isinstance(value, bool) else 0

    representative_contract = {
        'h3Frames': len(h3_records),
        'framesWithExpectedRepresentatives': sum(
            representative_value(row, 'expectedRepresentativeLabels') > 0
            for row in h3_records
        ),
        'expectedLabels': sum(
            representative_value(row, 'expectedRepresentativeLabels')
            for row in h3_records
        ),
        'matchedLabels': sum(
            representative_value(row, 'matchedRepresentativeLabels')
            for row in h3_records
        ),
        'missingLabels': sum(
            representative_value(row, 'missingRepresentativeLabels')
            for row in h3_records
        ),
    }
    metadata = {
        key: sorted({
            report.get(key)
            for report in reports
            if report.get(key) is not None
        })
        for key in (
            'environment',
            'commitSha',
            'sourceTreeDirty',
            'mapHintsAssetSha256',
            'stationHintsAssetSha256',
            'stationCatalogSha256',
            'cacheCondition',
        )
    }
    formal_evidence = {
        'requested': require_complete,
        'passed': (
            require_complete
            and capture
            and not current_tree_dirty
            and not validation_errors
            and bool(reports)
            and all(report.get('sourceTreeDirty') is False for report in reports)
        ),
        'requirements': {
            'fiveBatchesAnd200Stages': True,
            'screenshotsRequired': True,
            'cleanCommittedSourceRequired': True,
            'currentCommitAndAssetHashesRequired': True,
        },
    }
    summary = {
        'schemaVersion': REPORT_SCHEMA_VERSION,
        'generatedAt': datetime.datetime.now(
            datetime.timezone.utc
        ).isoformat(),
        'runId': run_id,
        'captureEnabled': capture,
        'completeRunRequired': require_complete,
        'metadata': metadata,
        'counts': counts,
        'stationCount': len(stations),
        'recordCount': len(records_list),
        'uniqueRecordCount': len(records),
        'imageDimensions': (
            {
                'width': expected_dimensions[0],
                'height': expected_dimensions[1],
            }
            if expected_dimensions else None
        ),
        'matrix': matrix,
        'performance': performance,
        'representativeContract': representative_contract,
        'formalEvidence': formal_evidence,
        'rss': (
            {
                'samples': len(rss),
                'minBytes': min(rss),
                'maxBytes': max(rss),
            }
            if rss else None
        ),
        'games': [{
            key: report.get(key)
            for key in (
                'batch',
                'difficulty',
                'completed',
                'gameScore',
                'correctCount',
                'replayReset',
                'testSetupToHomeMapMs',
                'quizTransitionMs',
                'screenshotCopyErrors',
            )
        } for report in reports],
        'validation': {
            'passed': not validation_errors,
            'errors': validation_errors,
        },
        'limitations': [
            'Rendered feature counts cannot prove that every tile downloaded.',
            'Label filtering cannot prove visual readability or semantic leakage.',
            'H2/H3 building presence requires screenshot review because the '
            'vector tile source may omit buildings at those zoom levels.',
            'Timings include polling and screenshot work.',
            'RSS includes Dart, native SDK, caches and screenshot activity.',
        ],
    }
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'summary.json').write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + '\n'
    )
    (directory / 'stations.md').write_text('\n'.join(table) + '\n')
    (directory / 'stage-checks.md').write_text('\n'.join(detail) + '\n')
    print(
        f'QA summary: {counts}, records={len(records_list)}, '
        f'valid={not validation_errors}, {directory}',
        flush=True,
    )
    for error in validation_errors:
        print(f'VALIDATION: {error}', file=sys.stderr, flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device')
    parser.add_argument('--batches', nargs='+', type=int)
    parser.add_argument('--allow-partial', action='store_true')
    parser.add_argument('--summary-only', action='store_true')
    parser.add_argument('--report-dir', default='docs/map-quality-phase4')
    parser.add_argument('--run-id')
    parser.add_argument(
        '--environment',
        default='iOS simulator, debug; network enabled',
    )
    parser.add_argument(
        '--cache-condition',
        choices=('cold', 'warm', 'uncleared', 'unknown'),
        default='uncleared',
    )
    parser.add_argument('--profile', action='store_true')
    parser.add_argument('--no-capture', action='store_true')
    parser.add_argument(
        '--diagnose-labels',
        action='store_true',
        help='Diagnostic run only; cannot pass the release gate',
    )
    args = parser.parse_args()

    try:
        run_id = checked_run_id(
            args.run_id or (None if args.summary_only else new_run_id())
        )
    except ValidationError:
        parser.error(
            '--run-id is required for --summary-only and must be path-safe'
        )
    stations = [
        row
        for row in json.loads((ROOT / 'assets/data/stations.json').read_text())
        if row['enabled']
    ]
    if len(stations) != 50:
        parser.error(
            f'Phase 4 requires exactly 50 enabled stations; got {len(stations)}'
        )
    map_hints_document = json.loads(
        (ROOT / 'assets/maps/map_hints_poc.json').read_text()
    )
    station_ids = {station['id'] for station in stations}
    if (
        map_hints_document.get('schemaVersion') != 2
        or set(map_hints_document.get('stations', {})) != station_ids
    ):
        parser.error(
            'Phase 4 map hints asset must use schema v2 and contain all 50 '
            'enabled stations'
        )
    expected_capabilities = {
        station_id: {
            'facilities': bool(row['facilities']['features']),
            'routes': bool(row['routes']['features']),
            'highSpeedRailways': bool(row['highSpeedRailways']['features']),
            'representativeFacilities': bool(
                row['representativeFacilities']['features']
            ),
        }
        for station_id, row in map_hints_document['stations'].items()
    }
    expected_representatives = {
        station_id: row['representativeFacilities']['features']
        for station_id, row in map_hints_document['stations'].items()
    }
    report_root = (ROOT / args.report_dir).resolve()
    directory = report_root / run_id
    capture = not args.no_capture
    all_batches = list(range(len(stations) // BATCH_SIZE))
    selected_batches = (
        args.batches if args.batches is not None else all_batches
    )
    if len(set(selected_batches)) != len(selected_batches):
        parser.error('--batches must not contain duplicates')
    if any(batch not in all_batches for batch in selected_batches):
        parser.error(f'--batches must be in {all_batches}')
    require_complete = not args.allow_partial
    if (
        require_complete
        and selected_batches != all_batches
        and not args.summary_only
    ):
        parser.error(
            'a release run requires all five batches; '
            'use --allow-partial for smoke tests'
        )

    failures = 0
    revision, dirty = git_revision()
    if require_complete and not capture:
        parser.error(
            '--no-capture is only allowed with --allow-partial; formal '
            'Phase 4 evidence requires all 200 screenshots'
        )
    if require_complete and dirty:
        parser.error(
            'formal Phase 4 evidence requires a clean committed source tree; '
            'commit the implementation or use --allow-partial for diagnostics'
        )
    hashes = {
        'EKIDOKO_MAP_HINTS_SHA256': sha256(
            ROOT / 'assets/maps/map_hints_poc.json'
        ),
        'EKIDOKO_STATION_HINTS_SHA256': sha256(
            ROOT / 'assets/maps/station_hints.json'
        ),
        'EKIDOKO_STATIONS_SHA256': sha256(
            ROOT / 'assets/data/stations.json'
        ),
    }
    expected_metadata = {
        'commitSha': revision,
        'mapHintsAssetSha256': hashes['EKIDOKO_MAP_HINTS_SHA256'],
        'stationHintsAssetSha256': hashes['EKIDOKO_STATION_HINTS_SHA256'],
        'stationCatalogSha256': hashes['EKIDOKO_STATIONS_SHA256'],
    }
    if not args.summary_only:
        if not args.device:
            parser.error('--device is required to run native tests')
        if directory.exists() and any(directory.iterdir()):
            parser.error(
                f'{directory} already contains artifacts; choose a new '
                '--run-id to preserve the existing result'
            )
        directory.mkdir(parents=True, exist_ok=True)
        screenshot_directory = ROOT / 'docs/screenshots/phase4' / run_id
        if screenshot_directory.exists():
            parser.error(
                f'{screenshot_directory} already exists; '
                'choose a new --run-id'
            )
        log_dir = Path('/tmp/ekidoko-quality-logs') / run_id
        log_dir.mkdir(parents=True, exist_ok=False)
        for batch in selected_batches:
            command = [
                'flutter',
                'drive',
                '--driver=test_driver/integration_test.dart',
                '--target=integration_test/real_map_test.dart',
                '-d',
                args.device,
                '--dart-define=EKIDOKO_PHASE4=true',
                f'--dart-define=EKIDOKO_MAP_BATCH={batch}',
                (
                    '--dart-define=EKIDOKO_CAPTURE='
                    f'{"true" if capture else "false"}'
                ),
                f'--dart-define=EKIDOKO_QUALITY_RUN_ID={run_id}',
                f'--dart-define=EKIDOKO_COMMIT_SHA={revision}',
                (
                    '--dart-define=EKIDOKO_SOURCE_DIRTY='
                    f'{"true" if dirty else "false"}'
                ),
                (
                    '--dart-define=EKIDOKO_CACHE_CONDITION='
                    f'{args.cache_condition}'
                ),
                *[
                    f'--dart-define={key}={value}'
                    for key, value in hashes.items()
                ],
            ]
            if args.profile:
                command.append('--profile')
            if args.diagnose_labels:
                command.append('--dart-define=EKIDOKO_DIAG_LABELS=true')
            env = {
                **os.environ,
                'EKIDOKO_QUALITY_REPORT_DIR': str(directory),
                'EKIDOKO_QUALITY_PLATFORM': args.environment,
            }
            names = ', '.join(
                station['name']
                for station in stations[
                    batch * BATCH_SIZE:(batch + 1) * BATCH_SIZE
                ]
            )
            print(
                f'Phase 4 run {run_id}, batch {batch}: {names}',
                flush=True,
            )
            log_path = log_dir / f'batch-{batch}.log'
            with log_path.open('w') as log:
                process = subprocess.Popen(
                    command,
                    cwd=ROOT,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    if any(token in line for token in (
                        'VERIFY',
                        'LABELS',
                        'DIAG',
                        'All tests passed',
                        'Some tests failed',
                        'Error',
                        'error:',
                        'Xcode build done',
                        'Installing and launching',
                    )):
                        print(line.rstrip(), flush=True)
                exit_code = process.wait()
            if exit_code != 0:
                failures += 1
                print(
                    f'Batch {batch}: flutter drive failed ({exit_code}); '
                    f'see {log_path}',
                    file=sys.stderr,
                    flush=True,
                )
            report_path = directory / f'batch-{batch}.json'
            if not report_path.is_file():
                failures += 1
                print(
                    f'Batch {batch}: report was not produced',
                    file=sys.stderr,
                    flush=True,
                )
            summarize(
                directory,
                stations,
                run_id,
                require_complete=False,
                capture=capture,
                expected_metadata=expected_metadata,
                expected_capabilities=expected_capabilities,
                expected_representatives=expected_representatives,
                current_tree_dirty=dirty,
            )

    summary = summarize(
        directory,
        stations,
        run_id,
        require_complete=require_complete,
        capture=capture,
        expected_metadata=expected_metadata,
        expected_capabilities=expected_capabilities,
        expected_representatives=expected_representatives,
        current_tree_dirty=dirty,
    )
    if (
        args.diagnose_labels
        or failures
        or not summary['validation']['passed']
    ):
        sys.exit(1)


if __name__ == '__main__':
    main()
