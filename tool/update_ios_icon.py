"""Generate iOS icon sizes from assets/topicon.png using macOS sips."""
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
source = root / 'assets' / 'topicon.png'
catalog = root / 'ios' / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
entries = json.loads((catalog / 'Contents.json').read_text())['images']
processed = set()
for entry in entries:
    filename = entry['filename']
    if filename in processed:
        continue
    processed.add(filename)
    size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
    subprocess.run(['sips', '-z', str(size), str(size), str(source), '--out',
                    str(catalog / filename)], check=True, capture_output=True)
print(f'Generated {len(processed)} iOS icons from {source.name}.')
