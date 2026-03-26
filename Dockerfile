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
    ninja-build rocksdb-tools autoconf automake libtool iputils-ping nload jq bc xxd htop libsecp256k1-dev libsodium-dev liblz4-dev \
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

RUN echo 'alias getstats="/usr/bin/ton/validator-engine-console/validator-engine-console -k /var/ton-work/keys/client -p /var/ton-work/keys/server.pub -a $(hostname -I | tr -d " "):$(jq .control[].port <<< cat /var/ton-work/db/config.json) -c getstats"' >> ~/.bashrc
RUN echo 'alias last="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c last"' >> ~/.bashrc
RUN echo 'alias sync="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c last 2>&1 |  grep created | sed -E \"s/.*\(([^()]*)\)\s*$/\1/\" | tail -n1"' >> ~/.bashrc
RUN echo 'alias config32="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"getconfig 32\""' >> ~/.bashrc
RUN echo 'alias config34="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"getconfig 34\""' >> ~/.bashrc
RUN echo 'alias config36="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"getconfig 36\""' >> ~/.bashrc
RUN echo 'alias elid="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"runmethod -1:3333333333333333333333333333333333333333333333333333333333333333 active_election_id\""' >> ~/.bashrc
RUN echo 'alias participants="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"runmethod -1:3333333333333333333333333333333333333333333333333333333333333333 participant_list\""' >> ~/.bashrc

ENTRYPOINT ["/scripts/entrypoint.sh"]