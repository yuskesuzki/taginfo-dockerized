#-----------------------------------------------------------------------------
#
#  docker/web/Dockerfile - taginfo Web フロントエンドを動かす(動作確認用)
#
#  別途生成した db ソース(taginfo-db.db)から master DB を組み立て、
#  taginfo/taginfo の Sinatra Web アプリを起動する。
#
#  wiki / languages / projects の各ソースは「スキーマだけの空 DB(スタブ)」を
#  自動生成して master 組み立てを通す。よって db ソース由来のタグ統計は表示
#  できるが、wiki 説明・プロジェクト利用状況・言語名などは空になる。
#  (本物の wiki/projects/languages を使いたい場合は別途それらのソースを生成して
#   同じデータディレクトリの wiki/ languages/ projects/ 配下に置けばよい)
#
#  使い方は docker/web/README にあたる説明をこのファイル冒頭と entrypoint に記載。
#
#-----------------------------------------------------------------------------

FROM ruby:3.3-slim-bookworm

ARG TAGINFO_REF=osmorg-taginfo-live
ARG TAGINFO_REPO=https://github.com/taginfo/taginfo

# git: taginfo の clone / build-essential + libsqlite3-dev: sqlite3・puma 等の
# ネイティブ拡張ビルド / sqlite3: master 組み立ての run_sql が使用
RUN apt-get update -qq && \
    apt-get install -yq --no-install-suggests --no-install-recommends \
        build-essential \
        bzip2 \
        ca-certificates \
        curl \
        git \
        libsqlite3-dev \
        sqlite3 && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${TAGINFO_REF}" "${TAGINFO_REPO}" /opt/taginfo

# Gemfile / Gemfile.lock はリポジトリのルート。web/ はそのサブディレクトリ。
WORKDIR /opt/taginfo
RUN gem install bundler:2.7.1 && \
    bundle install --jobs "$(nproc)" --retry 3

COPY entrypoint.sh /usr/local/bin/web-entrypoint.sh
RUN chmod +x /usr/local/bin/web-entrypoint.sh

# util.sh の ruby_command_line は `env -` で環境を消すため ruby を絶対パス指定。
ENV TAGINFO_RUBY=/usr/local/bin/ruby
ENV DATADIR=/taginfo-data
ENV PORT=4567

VOLUME ["/taginfo-data"]
EXPOSE 4567

ENTRYPOINT ["/usr/local/bin/web-entrypoint.sh"]
