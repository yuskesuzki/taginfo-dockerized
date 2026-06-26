#-----------------------------------------------------------------------------
#
#  Dockerfile - taginfo "db" データソース(taginfo-db.db)生成用
#
#  使い方は docker/generator/README.md を参照。
#
#  - ビルド段: taginfo-tools リポジトリ(既定で osmorg-taginfo-live タグ)を
#    abseil サブモジュールごと再帰 clone し、taginfo-stats /
#    taginfo-similarity をビルドする。
#  - 実行段: 本家 taginfo リポジトリ(既定で osmorg-taginfo-live タグ)を
#    clone し、その sources/db/update.sh を使って完全な db ソースを生成する。
#
#  ローカルからは entrypoint.sh のみ使うため、ビルドコンテキストは
#  docker/generator を指定する:
#    docker build -f docker/generator/Dockerfile -t taginfo-db docker/generator
#
#-----------------------------------------------------------------------------

# CI と同じく Debian bookworm を使う(libosmium2-dev が 2.14.2 以上)。
ARG DEBIAN_RELEASE=bookworm

#-----------------------------------------------------------------------------
#  ビルド段: taginfo-tools のバイナリを作る
#-----------------------------------------------------------------------------
FROM debian:${DEBIAN_RELEASE}-slim AS builder

RUN apt-get update -qq && \
    apt-get install -yq --no-install-suggests --no-install-recommends \
        ca-certificates \
        cmake \
        g++ \
        git \
        libbz2-dev \
        libexpat1-dev \
        libgd-dev \
        libicu-dev \
        libosmium2-dev \
        libprotozero-dev \
        libsqlite3-dev \
        make \
        zlib1g-dev && \
    rm -rf /var/lib/apt/lists/*

# taginfo-tools のソース参照(タグ/ブランチ/コミット)。本家 taginfo と同じく
# osmorg-taginfo-live を既定とする(両リポジトリは同じタグで同期させる方針)。
# abseil はサブモジュールなので --recurse-submodules で一緒に取得する。
ARG TAGINFO_TOOLS_REPO=https://github.com/taginfo/taginfo-tools
ARG TAGINFO_TOOLS_REF=osmorg-taginfo-live

RUN git clone --depth 1 --recurse-submodules --shallow-submodules \
        --branch "${TAGINFO_TOOLS_REF}" "${TAGINFO_TOOLS_REPO}" /src

WORKDIR /src
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j "$(nproc)" --target taginfo-stats taginfo-similarity

#-----------------------------------------------------------------------------
#  実行段
#-----------------------------------------------------------------------------
FROM debian:${DEBIAN_RELEASE}-slim AS runtime

# 本家 taginfo の参照(タグ/ブランチ/コミット)。README にあるとおり公式は
# osmorg-taginfo-live を使うため、これを既定とする。
ARG TAGINFO_REF=osmorg-taginfo-live
ARG TAGINFO_REPO=https://github.com/taginfo/taginfo

# 実行に必要なものだけ入れる:
#  - sqlite3 CLI: util.sh の run_sql が使用
#  - ruby + ruby-sqlite3: update_characters.rb / taginfo-config.rb が使用
#    (bundler 不要・sqlite3 gem は Debian パッケージで入れてコンパイルを避ける)
#  - wget/ca-certificates: pbf のダウンロード
#  - git: 本家 taginfo の clone
#  - バイナリの共有ライブラリ実行時依存(libosmium/protozero はヘッダオンリー)
RUN apt-get update -qq && \
    apt-get install -yq --no-install-suggests --no-install-recommends \
        ca-certificates \
        curl \
        git \
        libbz2-1.0 \
        libexpat1 \
        libgd3 \
        libsqlite3-0 \
        ruby \
        ruby-sqlite3 \
        sqlite3 \
        unzip \
        wget \
        zlib1g && \
    rm -rf /var/lib/apt/lists/*

# AWS CLI v2(S3 アップロード用。S3_BUCKET 未指定時は使われない)
RUN arch=$(dpkg --print-architecture) && \
    if [ "$arch" = "amd64" ]; then \
        curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip; \
    else \
        curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscli.zip; \
    fi && \
    unzip -q /tmp/awscli.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscli.zip /tmp/aws

# 本家 taginfo を浅く clone(SQL・update.sh・util.sh・lib 一式のため)。
# bin/taginfo-config.rb は <repo>/../taginfo-config.json を読むので、
# repo を /opt/taginfo に置くと設定ファイルは /opt/taginfo-config.json になる。
RUN git clone --depth 1 --branch "${TAGINFO_REF}" "${TAGINFO_REPO}" /opt/taginfo

# ビルドしたバイナリを配置(taginfo-config.json の paths.bin_dir と一致させる)。
COPY --from=builder /src/build/src/taginfo-stats /src/build/src/taginfo-similarity \
     /opt/taginfo-tools/build/src/

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# util.sh の ruby_command_line は `env -` で環境を消すため、ruby を絶対パスで指定。
ENV TAGINFO_RUBY=/usr/bin/ruby
ENV DATADIR=/data

VOLUME ["/data"]
WORKDIR /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
