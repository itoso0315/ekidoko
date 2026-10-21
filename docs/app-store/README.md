# App Store公開ページ・ライセンス準備

調査日：2026-10-22
対象ブランチ：`release/1.0.0`

ここにあるHTMLは公開前の草案です。GitHub Pages設定、一般公開、App Store ConnectへのURL登録は行っていません。

## 作成ページ

- `index.html`：ページ案内
- `privacy-policy.html`：アプリの保存情報、外部通信、第三者サービス、問い合わせ、改定
- `support.html`：アプリ概要、遊び方、接続要件、FAQ、問い合わせ
- `licenses.html`：地図出典、ライセンス、OSM由来データの入手先

問い合わせ先は `soisoi315@icloud.com` に確定しています。プライバシーポリシーとサポートページでは、メールアプリを開く `mailto:` リンクで案内します。運営者の氏名・住所は提供されていないため記載していません。

## コードとサービスの調査結果

- iOSアプリの直接依存はFlutter、`maplibre_gl`、`shared_preferences`、`url_launcher`。`pubspec.yaml` / `pubspec.lock` に広告、解析、クラッシュ収集、認証、位置情報取得用SDKはありません。推移依存を含む全パッケージのライセンス棚卸しは別途必要です。
- `Info.plist` に位置情報などの利用目的文言はなく、位置情報要求もコード上で確認されませんでした。出題駅の静的座標を地図中心に使います。
- クイズ地図はデフォルトで `https://tiles.openfreemap.org/planet` のTileJSON、ベクトルタイル、`https://tiles.openfreemap.org/fonts/...` のフォントをHTTPS取得します。ホームの固定PNGはタイル通信をしません。地図のタイル要求範囲から、表示中の駅やエリアを推測される可能性があります。
- アプリは最高ランクの基準点のみをSharedPreferencesへ保存します。回答履歴・各ゲームの得点・選択駅履歴は保存・同期しません。
- OSM補助データは通常、アプリ同梱ファイルから読み込みます。Overpassへの取得コードは開発時のフォールバックで、`EKIDOKO_ALLOW_OSM_HINT_FETCH` が明示的に有効化された場合だけreleaseビルドでも動き得ます。通常の配布設定では無効です。
- 地図出典は地図上に「© OpenMapTiles · © OpenStreetMap contributors」と表示し、タップでOSM（ODbL）、OpenMapTiles、OpenFreeMap利用条件、関連ライセンスのリンクを開きます。
- `gh api repos/itoso0315/ekidoko/pages` は404でした（調査時点でPages未設定）。GitHub Issuesは有効ですが、投稿は公開です。

## 地図・第三者ライセンス

- OpenStreetMapデータ：ODbL 1.0。アプリ同梱の駅座標・線路・施設等OSM由来データは機械可読な派生データとして提供し、帰属・ライセンス・入手先を示す必要があります。
- OpenMapTiles：コード BSD 3-Clause、デザイン CC BY 4.0。単に「スキーマ全体がCC BY」とはせず、区分を分けて表示します。
- OpenFreeMap：公開案内で商用利用可能、登録・APIキー不要とされています。利用はas-isでSLAなし、停止・規約変更の可能性があります。2026-10-14更新の利用条件は、サービス利用者（統合者）に18歳以上かつ契約能力を要求します。運営者が条件を満たすか確認してください。アプリ利用者にはこの年齢条件は適用しないとの記載です。
- OpenFreeMapのプライバシー説明では、通常ログはIPを含まない匿名化ログ、エラーログはIPと要求URLを含む場合があり最長7日、セキュリティ事案時のIPログは最長30日、CloudflareをCDN利用する場合があるとしています。公開前に最新の提供者ポリシーを再確認します。
- MapLibre Flutterプラグイン：BSD 3-Clause。MapLibre Native：BSD 2-Clause。Noto Sans：SIL OFL 1.1。
- 上記は地図関係の主要ライセンスの調査です。iOSネイティブ依存と全推移依存を含む完全な第三者ライセンス一覧・同梱文書の要否は、公開前に `flutter pub licenses` 相当の棚卸しとXcode依存の確認が必要です。

## ODbLデータと公開方法

アプリの公開ブランチには次の機械可読データと証跡が含まれます。

- `assets/data/stations.json`
- `assets/maps/station_hints.json`
- `assets/maps/map_hints_poc.json`
- `docs/station-coordinate-sources.json`
- `docs/map-hints-50stations/sources.json`
- `docs/map-hints-50stations/audit.json`
- `docs/map-hints-poc/sources.json` and its OSM evidence records

`assets/maps/README.md`はOSM由来データをODbL 1.0で提供すると記載しています。アプリのバイナリだけではなく、第三者が取得・変更できるJSONとライセンス・出典・生成方法を安定したURLで提示する案です。草案のライセンスページは、現在公開リポジトリ内にあるデータと監査記録へのコミット固定リンクを掲載しています。さらに配布しやすくするには、審査・権利確認後にODbL対象データと説明をまとめたバージョン固定のZIPをGitHub Release等で提供し、同URLをページに掲示する方法が適切です。ZIPの作成・Release公開は行っていません。

### 権利・来歴の未解決事項

1. `docs/station-coordinate-sources.json`には40件の駅記録があります。そのうち21件のOSMレコードに`source=KSJ2`等の国土数値情報（国土交通省）への参照があります。これは直ちに不適法という意味ではありませんが、当該データの元ライセンス・OSMへの取り込み条件と、アプリでの再配布条件を確認する必要があります。40件の記録と、50駅カタログ全件の来歴が一致しているかも整理してください。ここでは権利関係を断定しません。
2. 50駅データの`source` manifestと監査記録には取得元・取得日・クエリ・ハッシュが記録されていますが、生成時raw cacheは`/tmp/ekidoko-map-hints-50stations-sources`に置かれ、リポジトリ外です。再生成・ライセンス監査に必要な記録を保存する場合は、権利確認後、OSM由来であることを明示して配布範囲を決めてください。
3. `tokyo_home_map.png`には地図出典表示がありますが、生成・取得過程、元データ、画像自体の再配布条件を示す独立した記録は未確認です。
4. リポジトリにルートのソフトウェアライセンス文書は見当たりません。これはODbLデータライセンスとは別の論点であり、アプリコードをどう扱うかは必要に応じて別途決定してください。
5. OpenFreeMapの規約上、サービスを統合する者に18歳以上・契約能力が求められます。運営主体の条件充足、サービス継続リスク、バックアップ案を公開前に確認してください。

## 公開方法とURL案

GitHub Pagesは未設定のため、設定変更や公開はこの作業では行いません。承認後、GitHub Actions等でこのディレクトリだけを静的サイト成果物へ出力し、Pagesにデプロイする方法を提案します。リポジトリ全体やQA証跡をPagesの公開ルートにしないようにします。

公開成果物のルートをこのディレクトリにした場合のURL案：

- プライバシーポリシー：`https://itoso0315.github.io/ekidoko/privacy-policy.html`
- サポート：`https://itoso0315.github.io/ekidoko/support.html`
- ライセンス：`https://itoso0315.github.io/ekidoko/licenses.html`

これらはURL案であり、現時点では公開・到達確認されていません。運営者の正式名称、個人情報向け非公開連絡先、KSJ2等のデータ権利、OpenFreeMap規約、ソフトウェアの全ライセンスを確認した後に公開設定を行ってください。
