#!/bin/bash
set -e

TON_BRANCH=${TON_BRANCH:-latest}
GLOBAL_CONFIG_URL=${GLOBAL_CONFIG_URL:-https://ton.org/global.config.json}
ARCHIVE_TTL=${ARCHIVE_TTL:-86400}
STATE_TTL=${STATE_TTL:-86400}
VERBOSITY=${VERBOSITY:-1}
IGNORE_MINIMAL_REQS=${IGNORE_MINIMAL_REQS:-false}
TELEMETRY=${TELEMETRY:-true}
DUMP=${DUMP:-false}
MODE=${MODE:-validator}
MYTONCTRL_VERSION=${MYTONCTRL_VERSION:-master}

echo "Started with environment variables:"
echo
echo TON_BRANCH $TON_BRANCH
echo IGNORE_MINIMAL_REQS $IGNORE_MINIMAL_REQS
echo DUMP $DUMP
echo MYTONCTRL_VERSION $MYTONCTRL_VERSION
echo GLOBAL_CONFIG_URL $GLOBAL_CONFIG_URL
echo ARCHIVE_BLOCKS $ARCHIVE_BLOCKS
echo ARCHIVE_TTL $ARCHIVE_TTL
echo STATE_TTL $STATE_TTL
echo VERBOSITY $VERBOSITY
echo TELEMETRY $TELEMETRY
echo MODE $MODE
echo PUBLIC_IP $PUBLIC_IP
echo VALIDATOR_PORT $VALIDATOR_PORT
echo LITESERVER_PORT $LITESERVER_PORT
echo VALIDATOR_CONSOLE_PORT $VALIDATOR_CONSOLE_PORT

# check machine configuration
echo
echo -e "Checking system requirements"

cpus=$(nproc)
memory=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
CPUS=$(expr $(nproc) - 1)

if [[ -z "$PUBLIC_IP" ]]; then
  echo "PUBLIC_IP is not set!"
  exit 2
fi


echo "This machine has ${cpus} CPUs and ${memory}KB of Memory"
if [ "$IGNORE_MINIMAL_REQS" != true ] && ([ "${cpus}" -lt 16 ] || [ "${memory}" -lt 64000000 ]); then
	echo "Insufficient resources. Requires a minimum of 16 processors and 64Gb RAM."
	exit 1
fi


echo "Downloading global config from ${GLOBAL_CONFIG_URL}"
wget -q ${GLOBAL_CONFIG_URL} -O /usr/bin/ton/global.config.json

if [ ! -f /var/ton-work/db/mtc_done ]; then
  echo "Installing MyTonCtrl, version ${MYTONCTRL_VERSION}"
  wget -q https://raw.githubusercontent.com/ton-blockchain/mytonctrl/${MYTONCTRL_VERSION}/scripts/install.sh -O /tmp/install.sh
  if [ "$TELEMETRY" = false ]; then export TELEMETRY="-t"; else export TELEMETRY=""; fi
  if [ "$IGNORE_MINIMAL_REQS" = true ]; then export IGNORE_MINIMAL_REQS="-i"; else export IGNORE_MINIMAL_REQS=""; fi
  if [ "$DUMP" = true ]; then export DUMP="-d"; else export DUMP=""; fi
  if [ "$TON_BRANCH" != "latest" ]; then export NETWORK="-n testnet"; else export NETWORK=""; fi
  echo /bin/bash /tmp/install.sh ${TELEMETRY} ${IGNORE_MINIMAL_REQS} -b ${MYTONCTRL_VERSION} -m ${MODE} ${DUMP} ${NETWORK}
  /bin/bash /tmp/install.sh ${TELEMETRY} ${IGNORE_MINIMAL_REQS} -b ${MYTONCTRL_VERSION} -m ${MODE} ${DUMP} ${NETWORK}
  echo
  echo "Updating and restarting services"
  echo
  ln -sf /proc/$$/fd/1 /usr/local/bin/mytoncore/mytoncore.log
  ln -sf /proc/$$/fd/1 /var/log/syslog
  sed -i 's/--logname \/var\/ton-work\/log//g' /etc/systemd/system/validator.service
  # Ensure service logs go to container stdout/stderr via console
  sed -i '/^StandardOutput=/d;/^StandardError=/d' /etc/systemd/system/validator.service
  sed -i '/^StandardOutput=/d;/^StandardError=/d' /etc/systemd/system/mytoncore.service
  sed -i 's/\[Service\]/\[Service\]\nStandardOutput=journal+console\nStandardError=journal+console/' /etc/systemd/system/validator.service
  sed -i 's/\[Service\]/\[Service\]\nStandardOutput=journal+console\nStandardError=journal+console/' /etc/systemd/system/mytoncore.service
  sed -i -e "s/--verbosity\s[[:digit:]]\+/--verbosity ${VERBOSITY}/g" /etc/systemd/system/validator.service
  sed -i -e "s/--archive-ttl\s[[:digit:]]\+/--archive-ttl ${ARCHIVE_TTL}/g" /etc/systemd/system/validator.service

  # Add --state-ttl parameter if not already present
  if ! grep -q "\-\-state-ttl" /etc/systemd/system/validator.service; then
      sed -i -e "s/--archive-ttl ${ARCHIVE_TTL}/--archive-ttl ${ARCHIVE_TTL} --state-ttl ${STATE_TTL}/g" /etc/systemd/system/validator.service
  else
      # Replace existing --state-ttl value if already present
      sed -i -e "s/--state-ttl\s[[:digit:]]\+/--state-ttl ${STATE_TTL}/g" /etc/systemd/system/validator.service
  fi

  touch /var/ton-work/db/mtc_done

  systemctl daemon-reload
  echo "Restarting validator"
  systemctl restart validator
  echo "Restarting mytoncore"
  systemctl restart mytoncore
else
  echo "MyTonCtrl already installed"
  echo "Starting validator"
#  systemctl start validator
  echo "Starting mytoncore"
#  systemctl start mytoncore
fi

echo "Service started!"
exec /usr/bin/systemctl
