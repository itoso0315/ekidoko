"""Run native map QA in ten-station batches, or summarize existing reports.

python3 tool/check_station_maps.py --device <simulator-id>
python3 tool/check_station_maps.py --device <id> --batches 2
python3 tool/check_station_maps.py --summary-only
Physical-device example: --batches 0 4 --profile --no-capture
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def summarize(directory, stations):
    reports = [json.loads(path.read_text()) for path in sorted(directory.glob('batch-*.json'))]
    records = {(row['stationId'], row['hint']): row for report in reports for row in report.get('records', [])}
    failures = {(row.get('stationId'), row.get('hint')): row['error'] for report in reports for row in report.get('failures', [])}
    table = ['# Phase 3 地図品質記録', '',
             'OKはnative描画・中心/ズーム・共通ラベルフィルターの機械確認です。全文の可読性・意味上の漏洩・人による難易度は別途目視/プレイ確認が必要です。', '',
             '| 駅 | 初期 | H1 | H2 | H3 | 備考 |', '|---|---|---|---|---|---|']
    counts = {'ok': 0, 'failed': 0, 'unconfirmed': 0}
    matrix = []
    detail = ['# 駅別・段階別の確認項目', '',
              '機械OKはnative描画とカメラ検査。建物は初期/H1で必須、H2/H3ではタイルLODにより省略されます。',
              '全段階のラベル全文の可読性・意味上の答え漏洩・個々のタイル欠落は目視確認が必要です。', '',
              '| 駅 | 段階 | 描画 | 中心/縮尺 | 道路/線路/建物 | 路線名 | 施設/地名 | 直接駅名フィルター | 目視 |',
              '|---|---|---|---|---|---|---|---|---|']
    for station in stations:
        statuses = []
        notes = []
        for hint in range(4):
            key = station['id'], hint
            row = records.get(key)
            if key in failures:
                state = 'failed'; notes.append(f'H{hint}: {failures[key]}')
            elif row and row.get('renderStatus') == 'ok':
                state = 'ok'
                if hint == 3:
                    notes.append(f"施設{len(row['facilityNames'])} / 地名{len(row['placeNames'])}")
            else:
                state = 'unconfirmed'
            counts[state] += 1
            statuses.append({'ok': 'OK', 'failed': '失敗', 'unconfirmed': '未確認'}[state])
            matrix.append({'stationId': station['id'], 'hint': hint, 'status': state, 'record': row, 'error': failures.get(key)})
            checked = state == 'ok'
            geometry = f"{row['roadCount']}/{row['railCount']}/{row['buildingCount']}" if checked else '未確認'
            routes = (str(len(row['routeNames'])) if hint >= 2 else '非表示OK') if checked else '未確認'
            labels = (f"{len(row['facilityNames'])}/{len(row['placeNames'])}" if hint == 3 else '非表示OK') if checked else '未確認'
            detail.append('| ' + ' | '.join([
                station['name'], ['初期', 'H1', 'H2', 'H3'][hint], statuses[-1],
                'OK' if checked else '未確認', geometry, routes, labels,
                'OK' if checked and row.get('labelFilterStatus') == 'passed' else '未確認',
                '目視確認が必要',
            ]) + ' |')
        notes.append('Easy対象' if station.get('easyEligible') else 'Hardのみ')
        table.append('| ' + ' | '.join([station['name'], *statuses, '；'.join(notes).replace('|', '/').replace('\n', ' ')]) + ' |')
    performance = {}
    for hint in range(4):
        values = [row['elapsedFromActionMs'] for row in records.values() if row['hint'] == hint]
        if values:
            performance[str(hint)] = {'samples': len(values), 'medianMs': statistics.median(values), 'minMs': min(values), 'maxMs': max(values)}
    rss = [row['rssBytes'] for row in records.values() if row.get('rssBytes') is not None]
    summary = {'generatedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'environment': list(dict.fromkeys(r.get('environment', 'unknown') for r in reports)),
               'counts': counts, 'stationCount': len(stations), 'matrix': matrix,
               'performance': performance, 'rss': {'samples': len(rss), 'minBytes': min(rss), 'maxBytes': max(rss)} if rss else None,
               'games': [{k: report.get(k) for k in ['batch', 'difficulty', 'completed', 'gameScore', 'correctCount', 'replayReset', 'testSetupToHomeMapMs', 'quizTransitionMs', 'screenshotCopyErrors']} for report in reports],
               'limitations': ['Native feature counts cannot guarantee every tile downloaded.', 'Label filtering does not prove full visual readability or semantic leak prevention.', 'Timings include test polling/pumps; setup time excludes OS/Flutter engine startup.', 'RSS includes Dart, native SDK, cache and screenshot activity; not a release performance guarantee.']}
    (directory / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    (directory / 'stations.md').write_text('\n'.join(table) + '\n')
    (directory / 'stage-checks.md').write_text('\n'.join(detail) + '\n')
    print(f"QA summary: {counts}, {directory / 'stations.md'}", flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device')
    parser.add_argument('--batches', nargs='+', type=int)
    parser.add_argument('--summary-only', action='store_true')
    parser.add_argument('--report-dir', default='docs/map-quality-phase3')
    parser.add_argument('--environment', default='iPhone 17 Pro / iOS 26.5 simulator, debug; network and tile cache enabled')
    parser.add_argument('--profile', action='store_true')
    parser.add_argument('--no-capture', action='store_true')
    parser.add_argument('--diagnose-labels', action='store_true', help='Diagnostic run only; always fails after isolating a missing route label')
    args = parser.parse_args()
    stations = [row for row in json.loads((ROOT / 'assets/data/stations.json').read_text()) if row['enabled']]
    directory = (ROOT / args.report_dir).resolve(); directory.mkdir(parents=True, exist_ok=True)
    failures = 0
    if not args.summary_only:
        if not args.device:
            parser.error('--device is required to run native tests')
        batches = args.batches if args.batches is not None else list(range((len(stations) + 9) // 10))
        log_dir = Path('/tmp/ekidoko-quality-logs'); log_dir.mkdir(exist_ok=True)
        for batch in batches:
            if batch < 0 or batch * 10 + 10 > len(stations):
                parser.error('Each batch must contain ten valid stations')
            report = directory / f'batch-{batch}.json'
            if report.exists():
                history = directory / 'history'
                history.mkdir(exist_ok=True)
                stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
                report.rename(history / f'batch-{batch}-{stamp}.json')
            command = ['flutter', 'drive', '--driver=test_driver/integration_test.dart',
                       '--target=integration_test/real_map_test.dart', '-d', args.device,
                       '--dart-define=EKIDOKO_PHASE3=true', f'--dart-define=EKIDOKO_MAP_BATCH={batch}',
                       f"--dart-define=EKIDOKO_CAPTURE={'false' if args.no_capture else 'true'}"]
            if args.profile:
                command.append('--profile')
            if args.diagnose_labels:
                command.append('--dart-define=EKIDOKO_DIAG_LABELS=true')
            env = {**os.environ, 'EKIDOKO_QUALITY_REPORT_DIR': str(directory), 'EKIDOKO_QUALITY_PLATFORM': args.environment}
            print(f'QA batch {batch}: ' + ', '.join(s['name'] for s in stations[batch * 10:batch * 10 + 10]), flush=True)
            with (log_dir / f'{directory.name}-batch-{batch}.log').open('w') as log:
                process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                for line in process.stdout:
                    log.write(line); log.flush()
                    if any(token in line for token in ['VERIFY', 'LABELS', 'DIAG', 'All tests passed', 'Some tests failed', 'Error', 'error:', 'Xcode build done', 'Installing and launching']):
                        print(line.rstrip(), flush=True)
                exit_code = process.wait()
            if exit_code != 0:
                failures += 1
                print(f'QA batch {batch}: failed (exit {exit_code}); see {log.name}', flush=True)
            summarize(directory, stations)
    summary = summarize(directory, stations)
    if failures or summary['counts']['failed'] or (not args.batches and summary['counts']['unconfirmed']):
        sys.exit(1)


if __name__ == '__main__':
    main()
