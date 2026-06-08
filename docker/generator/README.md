# taginfo db ソース生成用 Docker イメージ

OSM の地域抽出データ(Geofabrik など)から、taginfo 本体がそのまま読み込める
**完全な db データソース**(`taginfo-db.db`)を生成するためのイメージです。

内部では本リポジトリ(taginfo-tools)の `taginfo-stats` / `taginfo-similarity`
を使い、本家 [taginfo](https://github.com/taginfo/taginfo) リポジトリの
`sources/db/update.sh` をそのまま実行します。これにより
`count_all` の集計・`prevalent_values`・`keys.characters`・`update_end` 等まで
埋まった db ソースが得られます。

> 本番の db ソースでは `taginfo-unicode` は使われず、`key_characters` テーブルは
> 空のままです(上流の仕様どおり)。キーの文字種分類は `update_characters.rb` が
> `keys.characters` 列に書き込みます。

## ビルド

taginfo-tools のソースはイメージのビルド段で
[taginfo/taginfo-tools](https://github.com/taginfo/taginfo-tools) から
abseil サブモジュールごと自動取得します。手元の作業ツリーや
`git submodule update --init` は不要です。ローカルからは `entrypoint.sh` のみ
使うため、ビルドコンテキストは `docker/generator` を指定します。

```sh
docker build -f docker/generator/Dockerfile -t taginfo-db docker/generator
```

taginfo-tools・本家 taginfo とも参照は既定で `osmorg-taginfo-live` タグです
(両リポジトリは同じタグで同期させる方針)。変更する場合:

```sh
docker build -f docker/generator/Dockerfile \
    --build-arg TAGINFO_TOOLS_REF=osmorg-taginfo-live \
    --build-arg TAGINFO_REF=osmorg-taginfo-live \
    -t taginfo-db docker/generator
```

## 実行(ワンショット)

出力先をボリュームにマウントし、`OSM_PBF_URL` に Geofabrik などの抽出 URL を渡します。
生成物は `<マウント先>/taginfo-db.db` です。

```sh
docker run --rm \
    -v "$(pwd)/data:/data" \
    -e OSM_PBF_URL=https://download.geofabrik.de/asia/japan-latest.osm.pbf \
    taginfo-db
```

すでに手元にある pbf を使う場合(ダウンロードしない):

```sh
docker run --rm \
    -v "$(pwd)/data:/data" \
    -v /path/to/region.osm.pbf:/in/region.osm.pbf:ro \
    -e OSM_PBF_FILE=/in/region.osm.pbf \
    taginfo-db
```

## 環境変数

| 変数 | 既定 | 説明 |
|------|------|------|
| `OSM_PBF_URL` | (なし) | ダウンロードする `.osm.pbf` の URL |
| `OSM_PBF_FILE` | (なし) | 既存ファイルを使う場合のパス(`OSM_PBF_URL` より優先) |
| `DATADIR` | `/data` | 出力先ディレクトリ |
| `KEEP_PBF` | `1` | `0` でダウンロードした pbf を生成後に削除 |
| `GEO_LEFT` / `GEO_BOTTOM` / `GEO_RIGHT` / `GEO_TOP` | `-180` / `-90` / `180` / `90` | 分布画像のバウンディングボックス |
| `GEO_WIDTH` / `GEO_HEIGHT` | `360` / `180` | 分布画像の解像度 |
| `TAGINFO_INDEX` | `SparseMemArray` | ノード位置索引の種類。地域抽出は Sparse 系必須(後述)|
| `MIN_TAG_COMBINATION_COUNT` | `1000` | DB に書き出すタグ組み合わせの最小出現回数 |

> 地域抽出では、その地域に合わせて `GEO_*` のバウンディングボックスを
> 設定すると分布画像が意味のあるものになります(既定は全世界)。

## 定期実行

コンテナは 1 回の「ダウンロード → 生成」で終了します。定期生成はホスト側の
スケジューラから `docker run` を起動してください。

cron の例(毎日 3:00 に日本の抽出から再生成):

```cron
0 3 * * * docker run --rm -v /srv/taginfo/data:/data \
    -e OSM_PBF_URL=https://download.geofabrik.de/asia/japan-latest.osm.pbf \
    taginfo-db >> /var/log/taginfo-db.log 2>&1
```

systemd timer や Kubernetes CronJob でも同様に、このイメージを 1 ショットの
ジョブとして起動すれば構いません。

## ノード位置索引とメモリ

`TAGINFO_INDEX`(`taginfo-stats` のノード位置ストア)の選択が重要です。

- **`SparseMemArray`(既定)**: メモリ使用量がノード数に比例。**地域抽出はこれを使う**。
- **`FlexMem`**: ノード ID が `1..max` まで密に詰まった **planet 全体専用**。
  地域抽出に使うと、実 OSM ノード ID(最大 ~130億)に対して巨大な密配列を確保しようとし、
  メモリを使い果たして OOM kill(終了コード 137)されます。**抽出データには使わないこと**。
- **`SparseMmapArray` / `DenseMmapArray`(Linux のみ)**: ディスクにメモリマップして
  RAM を節約。対象が非常に大きく RAM が足りない場合に。

> 全テーブル 0 件・終了コード 137 になる場合は、ほぼ FlexMem による OOM です。
> 既定(`SparseMemArray`)のまま実行してください。

利用可能な索引種類はコンテナ内で確認できます(ENTRYPOINT を上書き):

```sh
docker run --rm --entrypoint /opt/taginfo-tools/build/src/taginfo-stats \
    taginfo-db -I
```
