#!/usr/bin/env bash
#-----------------------------------------------------------------------------
#
#  web-entrypoint.sh
#
#  1. ソース DB をフラット配置(指定があれば公式から取得、無ければ空スタブ)
#  2. db ソースに追加インデックス・FTS を付与
#  3. taginfo-master.db / taginfo-history.db を組み立て
#  4. Sinatra Web アプリを起動
#
#  環境変数:
#    DATADIR           データディレクトリ(既定 /taginfo-data)
#    DB_SOURCE         taginfo-db.db のパス(明示する場合)
#    PORT              待ち受けポート(既定 4567)
#    REBUILD_MASTER    1 で master を毎回作り直す(既定: 既存なら再利用)
#    DOWNLOAD_SOURCES  公式サーバから取得するソースを空白区切りで指定
#                      例: "wiki languages projects"。db は取得不可。
#                      取得したソースはスタブの代わりに使われ、master を再構築する。
#                      指定可能: wiki languages projects wikidata chronology sw
#    TAGINFO_DOWNLOAD_BASE  取得元のベース URL
#                           (既定 https://taginfo.openstreetmap.org/download)
#
#  レイアウト(DATADIR 直下にフラット配置):
#    taginfo-db.db               <- 別途生成した db ソース(必須)
#    taginfo-wiki.db             <- 取得 or 空スタブ
#    taginfo-languages.db / taginfo-projects.db
#    taginfo-master.db / taginfo-history.db / selection.db  <- 生成物
#
#-----------------------------------------------------------------------------

set -euo pipefail

DATADIR=${DATADIR:-/taginfo-data}
PORT=${PORT:-4567}
export DATADIR PORT
readonly DATADIR PORT
readonly TS=/opt/taginfo

log() { printf '%s | web-entrypoint | %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$*"; }

mkdir -p "$DATADIR"/{db,wiki,languages,projects}

#-----------------------------------------------------------------------------
#  独自画像(ヘッダアイコン / 地図背景)をマウントから取り込む(任意)
#
#  *_FILE で渡されたファイルを web/public/img/custom/ にコピーし、その公開パスを
#  INSTANCE_ICON / MAP_BACKGROUND に設定する(後段の config 生成で反映)。
#-----------------------------------------------------------------------------
mkdir -p "$TS/web/public/img/custom"
if [ -n "${INSTANCE_ICON_FILE:-}" ] && [ -f "$INSTANCE_ICON_FILE" ]; then
    bn=$(basename "$INSTANCE_ICON_FILE")
    cp -f "$INSTANCE_ICON_FILE" "$TS/web/public/img/custom/$bn"
    INSTANCE_ICON="/img/custom/$bn"; export INSTANCE_ICON
    log "ヘッダアイコン: $INSTANCE_ICON_FILE → $INSTANCE_ICON"
fi
if [ -n "${MAP_BACKGROUND_FILE:-}" ] && [ -f "$MAP_BACKGROUND_FILE" ]; then
    bn=$(basename "$MAP_BACKGROUND_FILE")
    cp -f "$MAP_BACKGROUND_FILE" "$TS/web/public/img/custom/$bn"
    MAP_BACKGROUND="/img/custom/$bn"; export MAP_BACKGROUND
    log "地図背景: $MAP_BACKGROUND_FILE → $MAP_BACKGROUND"
fi

#-----------------------------------------------------------------------------
#  taginfo-config.json を用意する(例設定を土台に環境変数で上書き)
#
#  web/config.ru も bin/taginfo-config.rb も <repo>/../taginfo-config.json を
#  読むので、repo が /opt/taginfo なら /opt/taginfo-config.json。
#
#  上書き可能な環境変数:
#    INSTANCE_NAME / INSTANCE_DESCRIPTION / INSTANCE_ABOUT / INSTANCE_CONTACT
#    INSTANCE_AREA / INSTANCE_ICON            -> instance.*
#    MAP_BACKGROUND / MAP_ATTRIBUTION         -> geodistribution.background_image / image_attribution
#    GEO_LEFT/GEO_BOTTOM/GEO_RIGHT/GEO_TOP/GEO_WIDTH/GEO_HEIGHT -> geodistribution.*
#      ※ GEO_* は db 生成時(taginfo-stats)の値と一致させること。ずれると密度マップが
#      　 背景とズレる。地域に最適化する場合は db ソースの再生成も必要。
#    MIN_TAG_COMBINATION_COUNT                -> sources.master.min_tag_combination_count
#      タグ組み合わせの最小出現回数(既定 1000)。地域抽出では件数が少ないため
#      小さな値(例: 10)にすると組み合わせが表示されるようになる。
#      変更後は REBUILD_MASTER=1 での再起動が必要。
#-----------------------------------------------------------------------------
ruby -rjson -e '
  c = JSON.parse(File.read("/opt/taginfo/taginfo-config-example.json"))
  d = ENV["DATADIR"]
  c["paths"] ||= {}
  c["paths"]["data_dir"] = d
  c["paths"]["download_dir"] = d
  c["logging"] ||= {}
  c["logging"]["directory"] = ""        # 空: ログはstderrへ(ログファイルを作らない)

  set = lambda { |h, key, env| v = ENV[env]; h[key] = v unless v.nil? || v.empty? }
  num = lambda { |h, key, env|
    v = ENV[env]
    next if v.nil? || v.empty?
    h[key] = (v =~ /\A-?\d+\z/ ? v.to_i : (v =~ /\A-?\d+\.\d+\z/ ? v.to_f : v))
  }

  inst = c["instance"] ||= {}
  set.call(inst, "name",        "INSTANCE_NAME")
  set.call(inst, "description", "INSTANCE_DESCRIPTION")
  set.call(inst, "about",       "INSTANCE_ABOUT")
  set.call(inst, "contact",     "INSTANCE_CONTACT")
  set.call(inst, "area",        "INSTANCE_AREA")
  set.call(inst, "icon",        "INSTANCE_ICON")
  inst["name"] = "Taginfo (local)" if inst["name"].to_s.empty?

  geo = c["geodistribution"] ||= {}
  set.call(geo, "background_image",  "MAP_BACKGROUND")
  set.call(geo, "image_attribution", "MAP_ATTRIBUTION")
  num.call(geo, "left",   "GEO_LEFT")
  num.call(geo, "bottom", "GEO_BOTTOM")
  num.call(geo, "right",  "GEO_RIGHT")
  num.call(geo, "top",    "GEO_TOP")
  num.call(geo, "width",  "GEO_WIDTH")
  num.call(geo, "height", "GEO_HEIGHT")

  master = (c["sources"] ||= {})["master"] ||= {}
  num.call(master, "min_tag_combination_count", "MIN_TAG_COMBINATION_COUNT")

  File.write("/opt/taginfo-config.json", JSON.pretty_generate(c))
'
log "taginfo-config.json を生成(data_dir=$DATADIR)"

#-----------------------------------------------------------------------------
#  ソース DB をフラット配置する(Web は data_dir/taginfo-<id>.db を attach)
#
#  - db ソース: data_dir/taginfo-db.db
#  - wiki/languages/projects: 空スタブ(スキーマのみ)を自動生成
#-----------------------------------------------------------------------------
if [ -f "$DATADIR/taginfo-db.db" ]; then
    log "db ソース: $DATADIR/taginfo-db.db を使用"
elif [ -n "${DB_SOURCE:-}" ] && [ -f "$DB_SOURCE" ]; then
    cp -f "$DB_SOURCE" "$DATADIR/taginfo-db.db"
    log "db ソース: $DB_SOURCE をコピー"
elif [ -f "$DATADIR/db/taginfo-db.db" ]; then
    cp -f "$DATADIR/db/taginfo-db.db" "$DATADIR/taginfo-db.db"
    log "db ソース: $DATADIR/db/taginfo-db.db を直下にコピー"
else
    log "ERROR: taginfo-db.db が見つかりません。"
    log "  $DATADIR/taginfo-db.db を置くか、DB_SOURCE を指定してください。"
    exit 1
fi

#-----------------------------------------------------------------------------
#  指定ソースを公式サーバから取得する(任意)
#
#  DOWNLOAD_SOURCES に列挙したソースの構築済み DB を取得・展開してフラット配置
#  する。取得に失敗/未指定のソースは後段で空スタブになる。
#  db ソースはダウンロード不可(自分の OSM データに対応し master で書き換わるため)。
#-----------------------------------------------------------------------------
sources_changed=0
readonly DL_BASE=${TAGINFO_DOWNLOAD_BASE:-https://taginfo.openstreetmap.org/download}
mkdir -p "$DATADIR/download"
for s in ${DOWNLOAD_SOURCES:-}; do
    if [ "$s" = db ]; then
        log "注意: db ソースはダウンロードできません($s をスキップ)"
        continue
    fi
    bz="$DATADIR/download/taginfo-$s.db.bz2"
    log "ダウンロード: $DL_BASE/taginfo-$s.db.bz2"
    if curl --silent --show-error --fail --location \
            --time-cond "$bz" --output "$bz" "$DL_BASE/taginfo-$s.db.bz2"; then
        if [ ! -f "$DATADIR/taginfo-$s.db" ] || [ "$bz" -nt "$DATADIR/taginfo-$s.db" ]; then
            bzip2 -dc "$bz" > "$DATADIR/taginfo-$s.db"
            sources_changed=1
            log "展開: $DATADIR/taginfo-$s.db ($(du -h "$DATADIR/taginfo-$s.db" | cut -f1))"
        else
            log "$s は最新(再展開しません)"
        fi
    else
        log "WARNING: $s のダウンロードに失敗。空スタブにフォールバックします。"
    fi
done

#-----------------------------------------------------------------------------
#  取得しなかった wiki/languages/projects は空スタブ(スキーマのみ)で補う
#-----------------------------------------------------------------------------
for s in wiki languages projects; do
    db="$DATADIR/taginfo-$s.db"
    if [ ! -f "$db" ]; then
        sqlite3 "$db" < "$TS/sources/init.sql"
        sqlite3 "$db" < "$TS/sources/$s/pre.sql"
        log "スタブ生成: $db"
    fi
done

#-----------------------------------------------------------------------------
#  master ビルド用のサブディレクトリ symlink を張る
#
#  master.sql は __DIR__/<source>/taginfo-<source>.db を ATTACH するため、
#  フラット配置のファイルへサブディレクトリ経由で参照できるようにする。
#-----------------------------------------------------------------------------
# db/wiki/languages/projects に加え、取得した chronology/wikidata/sw も対象にする
# (master/update.sh は __DIR__/<source>/taginfo-<source>.db の有無で取り込みを判断)
for s in db wiki languages projects ${DOWNLOAD_SOURCES:-}; do
    [ -f "$DATADIR/taginfo-$s.db" ] || continue
    mkdir -p "$DATADIR/$s"
    ln -sf "../taginfo-$s.db" "$DATADIR/$s/taginfo-$s.db"
done

#-----------------------------------------------------------------------------
#  master / history / selection を組み立てる
#-----------------------------------------------------------------------------
if [ ! -f "$DATADIR/taginfo-master.db" ] || [ "${REBUILD_MASTER:-0}" = 1 ] || [ "$sources_changed" = 1 ]; then
    # Web の性能・検索用の追加インデックスを db ソースに付与(本番の update_all と同じ)
    if ! sqlite3 "$DATADIR/taginfo-db.db" \
            "SELECT name FROM sqlite_master WHERE name='tags_key_value_idx';" | grep -q .; then
        sqlite3 "$DATADIR/taginfo-db.db" < "$TS/sources/db/add_extra_indexes.sql"
        log "db ソースに追加インデックスを付与"
    fi
    sqlite3 "$DATADIR/taginfo-db.db" < "$TS/sources/db/add_ftsearch.sql"
    log "db ソースに全文検索インデックス(FTS)を付与"

    log "master DB を組み立て中..."
    "$TS/sources/master/update.sh" "$DATADIR"
    log "master DB の組み立て完了"
else
    log "既存の taginfo-master.db を再利用(作り直すには REBUILD_MASTER=1)"
fi

#-----------------------------------------------------------------------------
#  ダウンロード用 symlink を修正
#
#  web/public/download は本家リポジトリで ../../../download を指す相対 symlink
#  だが、Docker 環境ではデータディレクトリが異なるため実ファイルに届かない。
#  $DATADIR/download に向け直す。
#-----------------------------------------------------------------------------
if [ -d "$DATADIR/download" ]; then
    ln -sfn "$DATADIR/download" "$TS/web/public/download"
    log "download symlink を修正: $DATADIR/download"
fi

#-----------------------------------------------------------------------------
#  Web アプリ起動
#-----------------------------------------------------------------------------
log "Web を起動: http://0.0.0.0:${PORT}"
cd "$TS/web"
exec bundle exec rackup --host 0.0.0.0 --port "$PORT" config.ru
