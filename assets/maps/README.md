# OSM由来の補助データ

`station_hints.json` の線路形状・路線名・施設/地名・代表点、
`map_hints_poc.json` の確認済み路線・施設位置、および
`../data/stations.json` の駅座標は © OpenStreetMap contributors。
データ部分は ODbL 1.0 で提供します。

- https://www.openstreetmap.org/copyright
- https://opendatacommons.org/licenses/odbl/1-0/

元要素のID、取得日、クエリ、OSMの版は `station_hints.json` の
`_provenance` と各地物のpropertiesに記録しています。
東京・上野・京都のPoCは、OSM route relationとOpenFreeMapの
実タイルPOIを照合しています。クエリ、元要素、タイル座標、
入力hashは`../../docs/map-hints-poc/sources.json`に記録しています。
この監査証跡のOSM由来データ部分もODbL 1.0です。OpenMapTilesの
レイヤースキーマはCC BY 4.0です。
公園・施設ポリゴンのラベルはOSMの実ノード、または境界の中心に配置します。
施設・地名はそれぞれ18件までを優先度と距離から選びます。
`station_hints.json`の路線色はアプリの識別用配色です。
`map_hints_poc.json`のRGBは、記録したOSM relationの`colour`タグと
一致する確認済み路線だけに使用します。事業者のブランド仕様RGBと
同一であるとは断定しません。

再生成: `python3 tool/prepare_station_maps.py --fetch --station <id>`
PoC再生成: `python3 tool/prepare_map_hints_poc.py <source_dir>`
公開時は、このデータと出典・ライセンスを入手できるURLを用意してください。
アプリのDartコードのライセンスとは別です。

## ホーム固定プレビュー

ホームの東京駅プレビューは、`tokyo_home_map.png`の固定画像です。背景地図と
線路を含み、ホーム表示時に地図タイル通信は行いません。左上のプレビュー見出しや
地図ラベルは重ねず、方位・範囲と出典を表示します。出典をタップすると
ライセンスを確認できます。クイズ中の実地図とは別の静的プレビューです。
