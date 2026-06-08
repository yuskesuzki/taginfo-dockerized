# taginfo-docker

[taginfo](https://github.com/taginfo/taginfo) を自前の OSM データ(Geofabrik などの
地域抽出)で動かすための Docker 一式です。本家 taginfo と
[taginfo-tools](https://github.com/taginfo/taginfo-tools) のソースは**ビルド時に git
から取得**するため、このリポジトリ単体でビルド・実行が完結します。

## 構成

- **[`docker/generator/`](docker/generator/README.md)** — **db データソース生成用**。
  `.osm.pbf` から taginfo 本体がそのまま読み込める `taginfo-db.db` を生成します。
  内部で `taginfo-stats` / `taginfo-similarity` をビルドし、本家 taginfo の
  `sources/db/update.sh` を実行します。
- **[`docker/web/`](docker/web/README.md)** — **taginfo Web 起動用(動作確認)**。
  生成した `taginfo-db.db` から master DB を組み立て、Sinatra/Puma で Web を起動します。
  wiki / languages / projects は空スタブ、または `DOWNLOAD_SOURCES` で公式から取得します。

## クイックスタート

```sh
# 1. db ソースを生成(出力は docker/data/taginfo-db.db)
docker build -f docker/generator/Dockerfile -t taginfo-db docker/generator
docker run --rm -v "$(pwd)/docker/data:/data" \
    -e OSM_PBF_URL=https://download.geofabrik.de/europe/andorra-latest.osm.pbf \
    taginfo-db

# 2. Web を起動(http://localhost:4567)
docker build -f docker/web/Dockerfile -t taginfo-web docker/web
docker run --rm -p 4567:4567 -v "$(pwd)/docker/data:/taginfo-data" \
    -e DOWNLOAD_SOURCES="wiki languages projects" \
    taginfo-web
```

詳しい環境変数・運用(地域抽出時のノード位置索引、メモリ要件、地図のバウンディング
ボックス調整など)は各サブディレクトリの README を参照してください。

## データの扱い

`docker/data/` は生成物・ダウンロードキャッシュ・実行時データの置き場で、
`.gitignore` 済みです(リポジトリには含めません)。コンテナにはボリュームとして
マウントします。

## バージョンの同期

ビルド時に取得する本家 taginfo・taginfo-tools の参照は既定で `osmorg-taginfo-live`
タグ/ブランチです(両リポジトリは同じ版で同期させる運用)。変更する場合は各
Dockerfile の `--build-arg TAGINFO_REF` / `--build-arg TAGINFO_TOOLS_REF` を使います。
