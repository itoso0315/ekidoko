# OSM由来の補助データ

`station_hints.json` の線路形状・路線名・施設/地名・代表点、および
`../data/stations.json` の駅座標は © OpenStreetMap contributors。
データ部分は ODbL 1.0 で提供します。

- https://www.openstreetmap.org/copyright
- https://opendatacommons.org/licenses/odbl/1-0/

元要素のID、取得日、クエリ、OSMの版は `station_hints.json` の
`_provenance` と各地物のpropertiesに記録しています。
公園・施設ポリゴンのラベルはOSMの実ノード、または境界の中心に配置します。
施設・地名はそれぞれ18件までを優先度と距離から選びます。
路線の色はアプリの識別用配色です。

再生成: `python3 tool/prepare_station_maps.py --fetch --station <id>`
公開時は、このデータと出典・ライセンスを入手できるURLを用意してください。
アプリのDartコードのライセンスとは別です。
