# 50駅 地図ヒントデータ

生成日時：2026-10-20T14:42:32.890583Z

`tool/prepare_map_hints_50stations.py`が50駅を同一schemaで生成する。実行用データは
`assets/maps/map_hints_poc.json`、取得manifestは`sources.json`、採否根拠は
`audit.json`、集計は`summary.json`に保存する。

## 集計

- 駅：50件
- 匿名施設アイコン：241件（50駅）
- 色付きroute feature：370件、distinct service：100件、名称＋色の組：93件（40駅）
- 新幹線feature：135件（23駅）
- 代表施設名：146件（50駅）
- 取得失敗：0駅
- 分類失敗：0駅
- network取得済みraw：50駅（この生成runのnetwork request：0件、cache hit：50駅）

## 駅別登録状況

| ID | 駅 | 匿名施設 | 色付き路線 | 新幹線 | 代表施設名 | 未登録理由 |
|---|---|---:|---:|---|---:|---|
| tokyo | 東京 | 4 | 4 | あり | 1 | - |
| shinjuku | 新宿 | 5 | 6 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| shibuya | 渋谷 | 5 | 6 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| shinagawa | 品川 | 2 | 5 | あり | 3 | - |
| ueno | 上野 | 5 | 4 | あり | 1 | - |
| ikebukuro | 池袋 | 5 | 6 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| nagoya | 名古屋 | 5 | 3 | あり | 3 | - |
| osaka | 大阪 | 5 | 5 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kyoto | 京都 | 5 | 5 | あり | 3 | - |
| yokohama | 横浜 | 5 | 5 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| sapporo | 札幌 | 5 | 2 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| sendai | 仙台 | 5 | 1 | あり | 3 | - |
| omiya | 大宮 | 5 | 5 | あり | 3 | - |
| kanazawa | 金沢 | 5 | 0 | あり | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour |
| shizuoka | 静岡 | 5 | 1 | あり | 3 | - |
| shin_osaka | 新大阪 | 5 | 3 | あり | 3 | - |
| sannomiya | 三ノ宮 | 5 | 4 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| hiroshima | 広島 | 5 | 5 | あり | 3 | - |
| takamatsu | 高松 | 5 | 0 | なし | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour / 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| hakata | 博多 | 5 | 4 | あり | 3 | - |
| hakodate | 函館 | 5 | 1 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| asahikawa | 旭川 | 5 | 0 | なし | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour / 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| morioka | 盛岡 | 5 | 0 | あり | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour |
| kita_senju | 北千住 | 5 | 6 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| akihabara | 秋葉原 | 5 | 6 | あり | 3 | - |
| tachikawa | 立川 | 5 | 1 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kawasaki | 川崎 | 5 | 3 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| chiba | 千葉 | 5 | 2 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| funabashi | 船橋 | 5 | 3 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kashiwa | 柏 | 5 | 4 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kanayama | 金山 | 5 | 6 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| chikusa | 千種 | 5 | 3 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| gifu | 岐阜 | 5 | 4 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| hamamatsu | 浜松 | 5 | 1 | あり | 3 | - |
| nagano | 長野 | 5 | 0 | あり | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour |
| niigata | 新潟 | 5 | 0 | あり | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour |
| tennoji | 天王寺 | 5 | 6 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kyobashi_osaka | 京橋 | 5 | 2 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| namba_nankai | 難波 | 5 | 6 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| nara | 奈良 | 5 | 2 | なし | 3 | 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kobe_jr | 神戸 | 5 | 0 | なし | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour / 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| okayama | 岡山 | 5 | 6 | あり | 3 | - |
| fukuyama | 福山 | 5 | 2 | あり | 3 | - |
| matsue | 松江 | 2 | 0 | なし | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour / 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| tokushima | 徳島 | 5 | 0 | なし | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour / 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kochi | 高知 | 5 | 0 | なし | 3 | 色: no unambiguous nearby route relation with strict #RRGGBB colour / 新幹線: no railway=rail/highspeed=yes geometry intersects 500m circle |
| kokura | 小倉 | 5 | 3 | あり | 3 | - |
| kumamoto | 熊本 | 3 | 3 | あり | 3 | - |
| kagoshima_chuo | 鹿児島中央 | 5 | 1 | あり | 3 | - |
| kurume | 久留米 | 5 | 2 | あり | 3 | - |

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
