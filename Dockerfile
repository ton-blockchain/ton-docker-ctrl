ARG TON_BRANCH=latest
FROM ghcr.io/ton-blockchain/ton:${TON_BRANCH} AS ton
ENV DEBIAN_FRONTEND=noninteractive

FROM ubuntu:24.04
RUN set -eux; \
    apt update; \
    apt install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/llvm.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/llvm.gpg] http://apt.llvm.org/noble/ llvm-toolchain-noble-21 main" \
        > /etc/apt/sources.list.d/llvm.list; \
    apt update; \
    apt-get install -y --no-install-recommends \
        libc-bin clang-21 build-essential software-properties-common \
        gperf make cmake libblas-dev wget gcc libgsl-dev \
        python3-dev python3-pip sudo git fio iproute2 \
        plzip pv aria2 ninja-build rocksdb-tools \
        autoconf automake libtool iputils-ping nload jq bc xxd htop \
        libsecp256k1-dev libsodium-dev liblz4-dev libjemalloc2; \
    ln -sf /usr/bin/clang-21 /usr/bin/clang; \
    ln -sf /usr/bin/clang++-21 /usr/bin/clang++; \
    curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal; \
    /root/.cargo/bin/rustup toolchain install stable; \
    /root/.cargo/bin/rustup default stable; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p \
        /var/ton-work/db/static \
        /var/ton-work/db/import \
        /var/ton-work/db/keyring \
        /usr/src/ton; \
    cd /usr/src/ton; \
    git init; \
    git remote add origin https://github.com/ton-blockchain/ton.git; \
    wget -nv https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py \
        -O /usr/bin/systemctl; \
    chmod +x /usr/bin/systemctl; \
    useradd -ms /bin/bash validator

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
RUN echo 'alias sync="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c last 2>&1 | sed -nE \"s/.*\\(([0-9]+) second(s)? ago\\).*/\\1/p\" | tail -n1"' >> ~/.bashrc
RUN echo 'alias config32="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"getconfig 32\""' >> ~/.bashrc
RUN echo 'alias config34="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"getconfig 34\""' >> ~/.bashrc
RUN echo 'alias config36="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"getconfig 36\""' >> ~/.bashrc
RUN echo 'alias elid="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"runmethod -1:3333333333333333333333333333333333333333333333333333333333333333 active_election_id\""' >> ~/.bashrc
RUN echo 'alias participants="/usr/bin/ton/lite-client/lite-client -p /var/ton-work/keys/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -t 3 -c \"runmethod -1:3333333333333333333333333333333333333333333333333333333333333333 participant_list\""' >> ~/.bashrc

ENTRYPOINT ["/scripts/entrypoint.sh"]
