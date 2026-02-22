ARG TON_BRANCH=latest
FROM ghcr.io/ton-blockchain/ton:${TON_BRANCH} AS ton
ENV DEBIAN_FRONTEND=noninteractive

FROM ubuntu:24.04
RUN apt update \
    && apt install -y curl gnupg2 \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | apt-key add - \
    && curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal \
    && . /root/.cargo/env \
    && echo "deb http://apt.llvm.org/noble/ llvm-toolchain-noble-21 main" | tee /etc/apt/sources.list.d/llvm.list \
    && apt update \
    && apt-get install --no-install-recommends -y libc-bin clang-21 lsb-release build-essential software-properties-common gnupg gperf make cmake \
    libblas-dev wget gcc libgsl-dev python3-dev python3-pip sudo git fio iproute2 plzip pv curl libjemalloc-dev \
    ninja-build rocksdb-tools autoconf automake libtool iputils-ping nload libsecp256k1-dev libsodium-dev liblz4-dev \
    && ln /usr/bin/clang-21 /usr/bin/clang  \
    && ln /usr/bin/clang++-21 /usr/bin/clang++ \
    && rm -rf /var/lib/apt/lists/* \
    && rustup toolchain install stable && rustup default stable \
    && mkdir -p /var/ton-work/db/static /var/ton-work/db/import /var/ton-work/db/keyring \
    /usr/bin/ton /usr/bin/ton/lite-client /usr/bin/ton/validator-engine /usr/bin/ton/validator-engine-console \
    /usr/bin/ton/utils /usr/bin/ton/crypto /usr/src/ton \
    && cd /usr/src/ton && git init && git remote add origin https://github.com/ton-blockchain/ton.git \
    && wget -nv https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py -O /usr/bin/systemctl \
    && chmod +x /usr/bin/systemctl \
    && useradd -ms /bin/bash validator

COPY --from=ton /usr/local/bin/validator-engine /usr/bin/ton/validator-engine/
COPY --from=ton /usr/local/bin/validator-engine-console /usr/bin/ton/validator-engine-console/
COPY --from=ton /usr/local/bin/lite-client /usr/bin/ton/lite-client/
COPY --from=ton /usr/local/bin/generate-random-id /usr/bin/ton/utils/
COPY --from=ton /usr/local/bin/fift /usr/bin/ton/crypto/
COPY --from=ton /usr/local/bin/func /usr/bin/ton/crypto/

VOLUME ["/var/ton-work", "/usr/local/bin/mytoncore"]

COPY --chmod=755 scripts/entrypoint.sh/ /scripts/entrypoint.sh

ENTRYPOINT ["/scripts/entrypoint.sh"]