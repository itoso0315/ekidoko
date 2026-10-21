"""Synthetic regression checks for the Phase 4 native QA release gate."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    'check_station_maps', ROOT / 'tool/check_station_maps.py'
)
QA = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(QA)


class QualityGateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stations = [
            row for row in json.loads(
                (ROOT / 'assets/data/stations.json').read_text()
            )
            if row['enabled']
        ]
        cls.metadata = {
            'commitSha': 'synthetic-commit',
            'mapHintsAssetSha256': 'map-hash',
            'stationHintsAssetSha256': 'hint-hash',
            'stationCatalogSha256': 'catalog-hash',
        }

    def fixtures(self, *, source_dirty=False, capture=False):
        capabilities = {
            station['id']: {
                'facilities': False,
                'routes': False,
                'highSpeedRailways': False,
                'representativeFacilities': False,
            }
            for station in self.stations
        }
        representatives = {station['id']: [] for station in self.stations}
        reports = []
        for batch in range(5):
            batch_stations = self.stations[batch * 10:(batch + 1) * 10]
            records = []
            for station in batch_stations:
                for hint in range(4):
                    records.append({
                        'stationId': station['id'],
                        'stationName': station['name'],
                        'hint': hint,
                        'renderStatus': 'ok',
                        'labelFilterStatus': 'passed',
                        'difficulty': 'Easy' if batch == 0 else 'Hard',
                        'latitude': station['latitude'],
                        'longitude': station['longitude'],
                        'zoom': 12.0,
                        'roadCount': 1,
                        'railCount': 1,
                        'buildingCount': 1 if hint < 2 else 0,
                        'buildingVerification': (
                            'machine-confirmed-rendered-feature'
                            if hint < 2 else
                            'manual-required-vector-tile-zoom-limit'
                        ),
                        'capabilities': dict(capabilities[station['id']]),
                        'facilityIconCount': 0,
                        'anonymousFacilityNameCount': 0,
                        'expectsFacilityIconsInViewport': False,
                        'verifiedRouteColorCount': 0,
                        'expectsRouteColorsInViewport': False,
                        'highSpeedRailCount': 0,
                        'highSpeedRailCasingCount': 0,
                        'expectsHighSpeedInViewport': False,
                        'routeNames': [] if hint < 2 else ['検証線'],
                        'placeNames': ['検証町'] if hint == 3 else [],
                        'facilityNames': [],
                        'visibleBounds': {
                            'west': station['longitude'] - .1,
                            'south': station['latitude'] - .1,
                            'east': station['longitude'] + .1,
                            'north': station['latitude'] + .1,
                        },
                        'representativeLabels': 0,
                        'expectedRepresentativeLabels': 0,
                        'matchedRepresentativeLabels': 0,
                        'missingRepresentativeLabels': 0,
                        'expectedRepresentativeKeys': [],
                        'renderedRepresentativeKeys': [],
                        'renderedRepresentativeObjects': [],
                        'screenshot': (
                            f"phase4/synthetic/stations/{station['id']}/"
                            f'{QA.STAGES[hint]}.jpg'
                        ),
                    })
            reports.append({
                'schemaVersion': QA.REPORT_SCHEMA_VERSION,
                'runId': 'synthetic',
                'batch': batch,
                'records': records,
                'failures': [],
                'choiceAudits': [
                    {
                        'question': index,
                        'stationId': station['id'],
                        'choiceIds': [
                            station['id'],
                            f'choice-a-{batch}-{index}',
                            f'choice-b-{batch}-{index}',
                            f'choice-c-{batch}-{index}',
                        ],
                        'correctChoiceCount': 1,
                        'allEasyEligible': batch == 0,
                    }
                    for index, station in enumerate(batch_stations)
                ],
                'captureEnabled': capture,
                **self.metadata,
                'sourceTreeDirty': source_dirty,
                'cacheCondition': 'unknown',
                'environment': 'synthetic',
                'completed': True,
                'replayReset': True,
                'gameScore': 90,
                'correctCount': 9,
                'questionStationIds': [
                    station['id'] for station in batch_stations
                ],
            })
        return reports, capabilities, representatives

    def summarize(
        self,
        reports,
        capabilities,
        representatives,
        *,
        require_complete,
        current_tree_dirty,
        capture=False,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for report in reports:
                (directory / f"batch-{report['batch']}.json").write_text(
                    json.dumps(report, ensure_ascii=False)
                )
            return QA.summarize(
                directory,
                self.stations,
                'synthetic',
                require_complete=require_complete,
                capture=capture,
                expected_metadata=self.metadata,
                expected_capabilities=capabilities,
                expected_representatives=representatives,
                current_tree_dirty=current_tree_dirty,
            )

    def test_stage_validation_failure_changes_matrix_and_counts(self):
        reports, capabilities, representatives = self.fixtures()
        station = self.stations[0]
        capabilities[station['id']]['representativeFacilities'] = True
        representative = {
            'type': 'Feature',
            'geometry': {
                'type': 'Point',
                'coordinates': [station['longitude'], station['latitude']],
            },
            'properties': {
                'kind': 'facility',
                'name': '検証博物館',
                'rank': 0,
                'osm_type': 'node',
                'osm_id': 123,
            },
        }
        representatives[station['id']] = [representative]
        for row in reports[0]['records']:
            if row['stationId'] == station['id']:
                row['capabilities'] = dict(capabilities[station['id']])

        summary = self.summarize(
            reports,
            capabilities,
            representatives,
            require_complete=False,
            current_tree_dirty=False,
        )
        self.assertFalse(summary['validation']['passed'])
        self.assertEqual(summary['counts'], {
            'ok': 199,
            'failed': 1,
            'unconfirmed': 0,
        })
        failed = [row for row in summary['matrix'] if row['status'] == 'failed']
        self.assertEqual(
            [(row['stationId'], row['hint']) for row in failed],
            [(station['id'], 3)],
        )

    def test_git_cleanliness_ignores_qa_evidence_but_not_source_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(
                ['git', '-C', str(root), 'config', 'user.name', 'QA Test'],
                check=True,
            )
            subprocess.run(
                [
                    'git', '-C', str(root), 'config', 'user.email',
                    'qa@example.invalid',
                ],
                check=True,
            )
            source = root / 'lib/source.dart'
            source.parent.mkdir()
            source.write_text('const value = 1;\n')
            subprocess.run(
                ['git', '-C', str(root), 'add', 'lib/source.dart'],
                check=True,
            )
            subprocess.run(
                ['git', '-C', str(root), 'commit', '-qm', 'baseline'],
                check=True,
            )
            report = root / 'docs/qa/run/summary.json'
            screenshot = root / 'docs/screenshots/phase4/run/stage.jpg'
            report.parent.mkdir(parents=True)
            screenshot.parent.mkdir(parents=True)
            report.write_text('{}\n')
            screenshot.write_bytes(b'image')

            _, dirty = QA.git_revision(
                [root / 'docs/qa', root / 'docs/screenshots/phase4'],
                root=root,
            )
            self.assertFalse(dirty)

            source.write_text('const value = 2;\n')
            _, dirty = QA.git_revision(
                [root / 'docs/qa', root / 'docs/screenshots/phase4'],
                root=root,
            )
            self.assertTrue(dirty)

    def test_formal_summary_requires_screenshots_and_clean_tree(self):
        reports, capabilities, representatives = self.fixtures()
        summary = self.summarize(
            reports,
            capabilities,
            representatives,
            require_complete=True,
            current_tree_dirty=True,
        )
        self.assertFalse(summary['validation']['passed'])
        self.assertFalse(summary['formalEvidence']['passed'])
        self.assertEqual(summary['counts']['ok'], 0)
        self.assertEqual(summary['counts']['failed'], 200)
        errors = '\n'.join(summary['validation']['errors'])
        self.assertIn('requires screenshot capture', errors)
        self.assertIn('requires the current source tree to be clean', errors)

    def test_missing_screenshots_invalidate_every_affected_stage(self):
        reports, capabilities, representatives = self.fixtures(capture=True)
        summary = self.summarize(
            reports,
            capabilities,
            representatives,
            require_complete=False,
            current_tree_dirty=False,
            capture=True,
        )
        self.assertFalse(summary['validation']['passed'])
        self.assertEqual(summary['counts'], {
            'ok': 0,
            'failed': 200,
            'unconfirmed': 0,
        })
        self.assertTrue(all(
            any('screenshot is missing' in error for error in row['errors'])
            for row in summary['matrix']
        ))

    def test_stale_metadata_invalidates_the_formal_matrix(self):
        reports, capabilities, representatives = self.fixtures()
        reports[2]['commitSha'] = 'stale-commit'
        summary = self.summarize(
            reports,
            capabilities,
            representatives,
            require_complete=False,
            current_tree_dirty=False,
        )
        self.assertFalse(summary['validation']['passed'])
        self.assertEqual(summary['counts'], {
            'ok': 0,
            'failed': 200,
            'unconfirmed': 0,
        })
        self.assertTrue(all(
            row['status'] == 'failed' for row in summary['matrix']
        ))

    def test_partial_dirty_no_capture_run_is_never_formal_evidence(self):
        reports, capabilities, representatives = self.fixtures(
            source_dirty=True
        )
        summary = self.summarize(
            reports,
            capabilities,
            representatives,
            require_complete=False,
            current_tree_dirty=True,
        )
        self.assertTrue(summary['validation']['passed'])
        self.assertEqual(summary['counts']['ok'], 200)
        self.assertEqual(summary['counts']['failed'], 0)
        self.assertFalse(summary['formalEvidence']['requested'])
        self.assertFalse(summary['formalEvidence']['passed'])


if __name__ == '__main__':
    unittest.main()
