ARG TON_BRANCH=latest
FROM ghcr.io/ton-blockchain/ton:${TON_BRANCH}
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --no-install-recommends -y lsb-release software-properties-common gnupg gperf make cmake libblas-dev wget gcc libgsl-dev python3-dev python3-pip sudo git fio iproute2 plzip pv curl libjemalloc-dev ninja-build rocksdb-tools autoconf automake libtool iputils-ping \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/ton-work/db/static /var/ton-work/db/import /var/ton-work/db/keyring /usr/bin/ton /usr/bin/ton/lite-client /usr/bin/ton/validator-engine /usr/bin/ton/validator-engine-console /usr/bin/ton/utils /usr/src/ton/crypto/fift/lib/ /usr/src/ton/crypto/smartcont /usr/bin/ton/crypto \
    && cd /usr/src/ton && git init && git remote add origin https://github.com/ton-blockchain/ton.git \
    && wget --tries=10 --retry-connrefused --waitretry=3 https://apt.llvm.org/llvm.sh  \
    && chmod +x llvm.sh \
    && ./llvm.sh 21 clang  \
    && ln /usr/bin/clang-21 /usr/bin/clang  \
    && ln /usr/bin/clang++-21 /usr/bin/clang++ \
    && cp /usr/local/bin/lite-client /usr/bin/ton/lite-client/ \
    && cp /usr/local/bin/validator-engine /usr/bin/ton/validator-engine \
    && cp /usr/local/bin/validator-engine-console /usr/bin/ton/validator-engine-console/ \
    && cp /usr/local/bin/generate-random-id /usr/bin/ton/utils/ \
    && cp /usr/local/bin/fift /usr/bin/ton/crypto/ \
    && cp /usr/local/bin/func /usr/bin/ton/crypto/ \
    && cp /usr/lib/fift/* /usr/src/ton/crypto/fift/lib/ \
    && cp -r /usr/share/ton/smartcont/* /usr/src/ton/crypto/smartcont/ \
    && wget -nv https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py -O /usr/bin/systemctl \
    && chmod +x /usr/bin/systemctl

RUN useradd -ms /bin/bash validator


VOLUME ["/var/ton-work", "/usr/local/bin/mytoncore"]

COPY --chmod=755 scripts/entrypoint.sh/ /scripts/entrypoint.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]