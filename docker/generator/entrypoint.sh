#!/usr/bin/env bash
#-----------------------------------------------------------------------------
#
#  entrypoint.sh - OSM 抽出データをダウンロードし taginfo db ソースを生成する
#
#  生成物: $DATADIR/taginfo-db.db
#
#  環境変数:
#    OSM_PBF_URL    ダウンロードする .osm.pbf の URL(例: Geofabrik)
#    OSM_PBF_FILE   ダウンロードせず既存ファイルを使う場合のパス
#                   (OSM_PBF_URL より優先)
#    DATADIR        出力先ディレクトリ(既定 /data)
#    KEEP_PBF       1 ならダウンロードした pbf を生成後も残す(既定: 残す)
#    S3_BUCKET      アップロード先の S3 バケット名(未指定ならアップロードしない)
#    S3_PREFIX      S3 のプレフィックス(既定 taginfo/)
#
#    地理分布画像のバウンディングボックス/解像度(既定は全世界):
#    GEO_LEFT GEO_BOTTOM GEO_RIGHT GEO_TOP   (既定 -180 -90 180 90)
#    GEO_WIDTH GEO_HEIGHT                    (既定 360 180)
#    TAGINFO_INDEX                ノード位置索引の種類(既定 SparseMemArray)
#                                 地域抽出は Sparse 系が必須。FlexMem は planet 全体向けで
#                                 抽出データだと巨大メモリを要求し OOM する。
#    MIN_TAG_COMBINATION_COUNT    タグ組み合わせの最小出現回数(既定 1000)
#
#-----------------------------------------------------------------------------

set -euo pipefail

readonly DATADIR=${DATADIR:-/data}
readonly DOWNLOAD_DIR=${DATADIR}/download
readonly TAGINFO_DIR=/opt/taginfo

log() {
    printf '%s | entrypoint | %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*"
}

mkdir -p "$DATADIR" "$DOWNLOAD_DIR"

#-----------------------------------------------------------------------------
#  入力 OSM ファイルを用意する
#-----------------------------------------------------------------------------
if [ -n "${OSM_PBF_FILE:-}" ]; then
    if [ ! -f "$OSM_PBF_FILE" ]; then
        log "ERROR: OSM_PBF_FILE '$OSM_PBF_FILE' が見つかりません"
        exit 1
    fi
    OSM_FILE=$OSM_PBF_FILE
    log "既存ファイルを使用: $OSM_FILE"
elif [ -n "${OSM_PBF_URL:-}" ]; then
    OSM_FILE=${DOWNLOAD_DIR}/region.osm.pbf
    # 過去の失敗で OSM_FILE がディレクトリになっていたら削除する
    if [ -d "$OSM_FILE" ]; then
        log "WARNING: $OSM_FILE がディレクトリになっています。削除して再ダウンロードします。"
        rm -rf "$OSM_FILE"
    fi
    log "ダウンロード開始: $OSM_PBF_URL"
    # --continue は -O と組み合わせると動作が不定なため使用しない。
    # 一旦 .part に落としてから atomic に rename する。
    wget --no-verbose -O "${OSM_FILE}.part" "$OSM_PBF_URL"
    mv -f "${OSM_FILE}.part" "$OSM_FILE"
    log "ダウンロード完了: $OSM_FILE ($(du -h "$OSM_FILE" | cut -f1))"
else
    log "ERROR: OSM_PBF_URL または OSM_PBF_FILE を指定してください"
    exit 1
fi

#-----------------------------------------------------------------------------
#  taginfo-config.json を生成する
#
#  bin/taginfo-config.rb は <repo>/../taginfo-config.json を読むので
#  /opt/taginfo-config.json に置く。paths.bin_dir は Dockerfile で配置した
#  バイナリの場所と一致させる。
#-----------------------------------------------------------------------------
cat >/opt/taginfo-config.json <<JSON
{
    "logging": {
        "directory": "${DATADIR}"
    },
    "paths": {
        "bin_dir": "/opt/taginfo-tools/build/src",
        "data_dir": "${DATADIR}",
        "download_dir": "${DOWNLOAD_DIR}"
    },
    "geodistribution": {
        "left":   ${GEO_LEFT:--180},
        "bottom": ${GEO_BOTTOM:--90},
        "right":  ${GEO_RIGHT:-180},
        "top":    ${GEO_TOP:-90},
        "width":  ${GEO_WIDTH:-360},
        "height": ${GEO_HEIGHT:-180}
    },
    "tagstats": {
        "geodistribution": "${TAGINFO_INDEX:-SparseMemArray}"
    },
    "sources": {
        "master": {
            "min_tag_combination_count": ${MIN_TAG_COMBINATION_COUNT:-1000}
        }
    }
}
JSON

log "taginfo-config.json を生成しました"

#-----------------------------------------------------------------------------
#  selection.db を update.sh が探す場所($DATADIR/../selection.db)に置く
#
#  sources/db/update.sh は SELECTION_DB=$DATADIR/../selection.db を参照する。
#  DATADIR=/data のとき /data/../selection.db = /selection.db になる。
#  web コンテナが作る selection.db は $DATADIR/selection.db にあるため、
#  シンボリックリンクで繋ぐ。selection.db がない場合(初回実行)は
#  tag_combinations は生成されない(2 回目以降の実行で正しく生成される)。
#-----------------------------------------------------------------------------
readonly SELECTION_SRC="${DATADIR}/selection.db"
readonly SELECTION_DST="${DATADIR}/../selection.db"
if [ -f "$SELECTION_SRC" ]; then
    ln -sf "$(realpath "$SELECTION_SRC")" "$SELECTION_DST"
    log "selection.db をリンク: $SELECTION_SRC -> $SELECTION_DST"
else
    log "selection.db が見つかりません(初回実行)。tag_combinations は生成されません。"
    log "  web を一度起動した後に再実行すると tag_combinations が生成されます。"
fi

#-----------------------------------------------------------------------------
#  db ソースを生成する(本家 taginfo の update.sh をそのまま使う)
#
#  update.sh DATADIR [OSM_FILE] -> $DATADIR/taginfo-db.db
#-----------------------------------------------------------------------------
log "db ソースの生成を開始..."
"${TAGINFO_DIR}/sources/db/update.sh" "$DATADIR" "$OSM_FILE"
log "db ソースの生成が完了: ${DATADIR}/taginfo-db.db"

#-----------------------------------------------------------------------------
#  後始末
#-----------------------------------------------------------------------------
if [ -z "${OSM_PBF_FILE:-}" ] && [ "${KEEP_PBF:-1}" != "1" ]; then
    log "ダウンロードした pbf を削除: $OSM_FILE"
    rm -f "$OSM_FILE"
fi

#-----------------------------------------------------------------------------
#  S3 にアップロードする(S3_BUCKET が指定されている場合のみ)
#-----------------------------------------------------------------------------
if [ -n "${S3_BUCKET:-}" ]; then
    S3_PREFIX="${S3_PREFIX:-taginfo/}"
    log "S3 アップロード開始: s3://${S3_BUCKET}/${S3_PREFIX}"
    aws s3 sync "$DATADIR" "s3://${S3_BUCKET}/${S3_PREFIX}" \
        --exclude "download/region.osm.pbf" \
        --exclude "download/region.osm.pbf.part" \
        --exclude "log/*" \
        --exclude "*.tmp"
    log "S3 アップロード完了"
else
    log "S3_BUCKET 未指定。アップロードをスキップ。"
fi

log "完了。生成物: ${DATADIR}/taginfo-db.db"
