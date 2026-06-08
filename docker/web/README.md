# taginfo Web を動かす(動作確認用)Docker イメージ

別途生成した **db ソース(`taginfo-db.db`)** を使って、`taginfo/taginfo` の
Web フロントエンド(Sinatra)をローカルで起動するためのイメージです。
生成済み db ソースが taginfo 上で正しく見えるかを確認する用途を想定しています。

## 仕組み

taginfo の Web は、単一ソースの DB を直接読むのではなく、複数ソースを統合した
`taginfo-master.db` を読みます。このイメージの entrypoint は次を自動で行います。

1. データディレクトリを taginfo の標準レイアウトに整える(フラット配置)
2. `wiki` / `languages` / `projects` を用意する。`DOWNLOAD_SOURCES` を指定すれば
   公式サーバから構築済み DB を取得し、未指定のものは **空スタブ DB**(スキーマのみ)
   で補う。スタブのままだと wiki 説明・プロジェクト利用状況・言語名などは空になる。
3. db ソースに Web 用の追加インデックス・全文検索(FTS)を付与
4. `sources/master/update.sh` で `taginfo-master.db` / `taginfo-history.db` /
   `selection.db` を組み立てる
5. Puma で Web を起動

## ビルド

taginfo 本体はビルド段で git から取得します。ローカルからは `entrypoint.sh`
のみ使うため、ビルドコンテキストは `docker/web` を指定します。

```sh
docker build -f docker/web/Dockerfile -t taginfo-web docker/web
```

本家 taginfo の参照は既定で `osmorg-taginfo-live` タグ。変更する場合は
`--build-arg TAGINFO_REF=...`。

## 実行

db ジェネレータの出力ディレクトリ(`taginfo-db.db` が直下にある)をそのまま
マウントします。

```sh
docker run --rm -p 4567:4567 \
    -v "$(pwd)/data:/taginfo-data" \
    taginfo-web
```

ブラウザで <http://localhost:4567/> を開きます。
(`/keys`, `/tags`, `/search` などが動作します。taginfo はロケールを URL パスに
前置きしないため `/ja/keys` のような URL は 404 になります。)

### wiki/projects/languages の実データを使う

空スタブの代わりに公式サーバの構築済み DB を取得して使えます:

```sh
docker run --rm -p 4567:4567 \
    -v "$(pwd)/data:/taginfo-data" \
    -e DOWNLOAD_SOURCES="wiki languages projects" \
    taginfo-web
```

これで wiki 説明・プロジェクト利用状況・言語名などが実データで表示されます
(取得した `.db.bz2` は `data/download/` にキャッシュされ、次回以降は更新時のみ
再取得します)。`db` ソースだけは取得できません(自分の OSM データに対応し、
master 処理で書き換えられるため)。

## 環境変数

| 変数 | 既定 | 説明 |
|------|------|------|
| `DATADIR` | `/taginfo-data` | データディレクトリ(マウント先) |
| `DB_SOURCE` | (なし) | `taginfo-db.db` を別パスから取り込む場合に指定(コピーされる) |
| `PORT` | `4567` | Web の待ち受けポート |
| `REBUILD_MASTER` | `0` | `1` で master/history を毎回作り直す(db ソースを更新したら指定) |
| `DOWNLOAD_SOURCES` | (なし) | 公式から取得するソースを空白区切りで指定(例 `"wiki languages projects"`)。取得分はスタブの代わりに使われ master を再構築。指定可: `wiki languages projects wikidata chronology sw`(`db` は不可) |
| `TAGINFO_DOWNLOAD_BASE` | `https://taginfo.openstreetmap.org/download` | 取得元ベース URL |
| `INSTANCE_NAME` | (例設定) | サイト名(ヘッダ/タイトル) |
| `INSTANCE_DESCRIPTION` | (例設定) | 説明(HTML 可) |
| `INSTANCE_ABOUT` / `INSTANCE_CONTACT` / `INSTANCE_AREA` | (例設定) | About 文 / 連絡先 / 対象エリア |
| `INSTANCE_ICON` | `/img/logo/...` | ヘッダ左の小アイコンの公開パス |
| `INSTANCE_ICON_FILE` | (なし) | 独自アイコン画像のパス(マウント)。`/img/custom/` に取り込み自動設定 |
| `MAP_BACKGROUND` | `/img/mapbg/world.png` | 分布マップの背景画像の公開パス |
| `MAP_BACKGROUND_FILE` | (なし) | 独自背景画像のパス(マウント)。`/img/custom/` に取り込み自動設定 |
| `MAP_ATTRIBUTION` | (空) | 背景地図の帰属表記 |
| `GEO_LEFT`/`GEO_BOTTOM`/`GEO_RIGHT`/`GEO_TOP`/`GEO_WIDTH`/`GEO_HEIGHT` | 全世界 | 分布マップの範囲・解像度 |

### 見た目のカスタマイズ(ヘッダ画像・地図)

環境変数で主要項目を上書きできます。独自画像はホスト側に置いてマウントし、
`*_FILE` で渡すと `/img/custom/` に取り込まれて自動でパスが設定されます。

```sh
docker run --rm -p 4567:4567 \
    -v "$(pwd)/data:/taginfo-data" \
    -v "$(pwd)/branding:/branding:ro" \
    -e INSTANCE_NAME="MIERUNE Taginfo" \
    -e INSTANCE_DESCRIPTION="<b>日本</b>のタグ統計" \
    -e INSTANCE_ICON_FILE=/branding/logo.png \
    -e MAP_BACKGROUND_FILE=/branding/japan.png \
    -e MAP_ATTRIBUTION="© MIERUNE" \
    taginfo-web
```

- ヘッダ左の小アイコンは `INSTANCE_ICON(_FILE)`(49×49 表示、正方形 PNG 推奨)。
  「taginfo」ロゴ文字(`/img/logo/taginfo.png`)は固定なので、変えるなら
  ビルド時にそのファイルを差し替えてください。
- 分布マップは「db ソース由来の密度 PNG」を `MAP_BACKGROUND` の上に重ねたものです。
  **背景画像のアスペクト比 =(右−左):(上−下)= `GEO_WIDTH`:`GEO_HEIGHT`** にします
  (全世界なら 2:1。例: world.png は 720×360)。
- **重要**: `GEO_*` を地域に変える場合は、db ソースも同じ範囲・解像度で再生成
  (db ジェネレータの `GEO_*`)してください。値がずれると密度マップが背景とズレます。

## 注意点

- entrypoint はマウントしたデータディレクトリに次を**書き込みます**:
  `taginfo-{wiki,languages,projects}.db`(スタブ)、`{db,wiki,languages,projects}/`
  サブディレクトリ(master ビルド用 symlink)、`taginfo-master.db` /
  `taginfo-history.db` / `selection.db`。また `taginfo-db.db` に追加インデックスと
  FTS を付与する(本番の taginfo と同じ処理)ためファイルがやや大きくなります。
- db ソースを更新したら `-e REBUILD_MASTER=1` で master を作り直してください。
- これは**動作確認用**の最小構成です。本番運用するなら wiki / projects /
  languages の各ソースも生成し、同じデータディレクトリ直下に
  `taginfo-{wiki,projects,languages}.db` として置いた上で master を作り直します。
- master 組み立てと FTS 付与は db 生成(`taginfo-stats`)ほどメモリを使いません
  (数百 MB 規模の地域データなら 4GB 程度の Docker メモリで動作します)。
