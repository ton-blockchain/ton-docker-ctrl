#!/bin/bash
set -e

TON_BRANCH=${TON_BRANCH:-latest}
GLOBAL_CONFIG_URL=${GLOBAL_CONFIG_URL:-https://ton.org/global.config.json}
ARCHIVE_TTL=${ARCHIVE_TTL:-86400}
STATE_TTL=${STATE_TTL:-86400}
SYNC_BEFORE=${SYNC_BEFORE:-3600}
VERBOSITY=${VERBOSITY:-1}
IGNORE_MINIMAL_REQS=${IGNORE_MINIMAL_REQS:-false}
TELEMETRY=${TELEMETRY:-true}
DUMP=${DUMP:-false}
MODE=${MODE:-validator}
MYTONCTRL_VERSION=${MYTONCTRL_VERSION:-master}
MTC_DONE_FILE=/var/ton-work/db/mtc_done
SYSTEMD_UNITS_DIR=/var/ton-work/db/systemd-units
VALIDATOR_SERVICE=/etc/systemd/system/validator.service
MYTONCORE_SERVICE=/etc/systemd/system/mytoncore.service
VALIDATOR_SERVICE_CACHE=${SYSTEMD_UNITS_DIR}/validator.service
MYTONCORE_SERVICE_CACHE=${SYSTEMD_UNITS_DIR}/mytoncore.service

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
echo SYNC_BEFORE $SYNC_BEFORE
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

restore_service_units() {
  mkdir -p "${SYSTEMD_UNITS_DIR}"

  if [ ! -f "${VALIDATOR_SERVICE}" ] && [ -f "${VALIDATOR_SERVICE_CACHE}" ]; then
    cp "${VALIDATOR_SERVICE_CACHE}" "${VALIDATOR_SERVICE}"
    echo "Restored validator.service from ${VALIDATOR_SERVICE_CACHE}"
  fi

  if [ ! -f "${MYTONCORE_SERVICE}" ] && [ -f "${MYTONCORE_SERVICE_CACHE}" ]; then
    cp "${MYTONCORE_SERVICE_CACHE}" "${MYTONCORE_SERVICE}"
    echo "Restored mytoncore.service from ${MYTONCORE_SERVICE_CACHE}"
  fi
}

persist_service_units() {
  mkdir -p "${SYSTEMD_UNITS_DIR}"

  if [ -f "${VALIDATOR_SERVICE}" ]; then
    cp "${VALIDATOR_SERVICE}" "${VALIDATOR_SERVICE_CACHE}"
  fi

  if [ -f "${MYTONCORE_SERVICE}" ]; then
    cp "${MYTONCORE_SERVICE}" "${MYTONCORE_SERVICE_CACHE}"
  fi
}

restart_or_start_service() {
  local service_name="$1"

  echo "Restarting ${service_name}"
  if ! systemctl restart "${service_name}"; then
    echo "Restart failed for ${service_name}, trying start"
    if ! systemctl start "${service_name}"; then
      echo "Failed to start ${service_name}, continuing"
    fi
  fi
}

ensure_service_units() {
  if [ -f "${VALIDATOR_SERVICE}" ] && [ -f "${MYTONCORE_SERVICE}" ]; then
    return
  fi

  restore_service_units

  if [ -f "${VALIDATOR_SERVICE}" ] && [ -f "${MYTONCORE_SERVICE}" ]; then
    return
  fi

  echo "Systemd service files are missing and no persisted copies were found in ${SYSTEMD_UNITS_DIR}"
  echo "Run one bootstrap start (without ${MTC_DONE_FILE}) to regenerate them."
  exit 1
}

apply_service_overrides() {
  ln -sf /proc/$$/fd/1 /usr/local/bin/mytoncore/mytoncore.log
  ln -sf /proc/$$/fd/1 /var/log/syslog

  if [ -f "${VALIDATOR_SERVICE}" ]; then
    sed -i 's/--logname \/var\/ton-work\/log//g' "${VALIDATOR_SERVICE}"
    # Ensure service logs go to container stdout/stderr via console
    sed -i '/^StandardOutput=/d;/^StandardError=/d' "${VALIDATOR_SERVICE}"
    sed -i 's/\[Service\]/\[Service\]\nStandardOutput=journal+console\nStandardError=journal+console/' "${VALIDATOR_SERVICE}"
    sed -i -e "s/--verbosity\s[[:digit:]]\+/--verbosity ${VERBOSITY}/g" "${VALIDATOR_SERVICE}"
    sed -i -e "s/--archive-ttl\s[[:digit:]]\+/--archive-ttl ${ARCHIVE_TTL}/g" "${VALIDATOR_SERVICE}"

    # Add --state-ttl parameter if not already present
    if ! grep -q "\-\-state-ttl" "${VALIDATOR_SERVICE}"; then
      sed -i -e "s/--archive-ttl ${ARCHIVE_TTL}/--archive-ttl ${ARCHIVE_TTL} --state-ttl ${STATE_TTL}/g" "${VALIDATOR_SERVICE}"
    else
      # Replace existing --state-ttl value if already present
      sed -i -e "s/--state-ttl\s[[:digit:]]\+/--state-ttl ${STATE_TTL}/g" "${VALIDATOR_SERVICE}"
    fi

    # Add --sync-before parameter if not already present
    if ! grep -q "\-\-sync-before" "${VALIDATOR_SERVICE}"; then
      if grep -q "\-\-state-ttl" "${VALIDATOR_SERVICE}"; then
        sed -i -e "s/--state-ttl ${STATE_TTL}/--state-ttl ${STATE_TTL} --sync-before ${SYNC_BEFORE}/g" "${VALIDATOR_SERVICE}"
      elif grep -q "\-\-archive-ttl" "${VALIDATOR_SERVICE}"; then
        sed -i -e "s/--archive-ttl ${ARCHIVE_TTL}/--archive-ttl ${ARCHIVE_TTL} --sync-before ${SYNC_BEFORE}/g" "${VALIDATOR_SERVICE}"
      else
        sed -i -E "/^ExecStart=.*validator-engine/ s/$/ --sync-before ${SYNC_BEFORE}/" "${VALIDATOR_SERVICE}"
      fi
    else
      # Replace existing --sync-before value if already present
      sed -i -e "s/--sync-before\s[[:digit:]]\+/--sync-before ${SYNC_BEFORE}/g" "${VALIDATOR_SERVICE}"
    fi
  else
    echo "validator.service not found, skipping validator args update"
  fi

  if [ -f "${MYTONCORE_SERVICE}" ]; then
    sed -i '/^StandardOutput=/d;/^StandardError=/d' "${MYTONCORE_SERVICE}"
    sed -i 's/\[Service\]/\[Service\]\nStandardOutput=journal+console\nStandardError=journal+console/' "${MYTONCORE_SERVICE}"
  else
    echo "mytoncore.service not found, skipping mytoncore service update"
  fi
}

if [ ! -f "${MTC_DONE_FILE}" ]; then
  if [ "$TON_BRANCH" == "latest" ]; then
    branch="master"
  else
    branch="$TON_BRANCH"
  fi
  cd /usr/src/ton
  git checkout -B $branch
  rm -rf *
  git pull origin $branch

  echo "Installing MyTonCtrl, version ${MYTONCTRL_VERSION}"
  wget -q https://raw.githubusercontent.com/ton-blockchain/mytonctrl/${MYTONCTRL_VERSION}/scripts/install.sh -O /tmp/install.sh
  if [ "$TELEMETRY" = false ]; then export TELEMETRY="-t"; else export TELEMETRY=""; fi
  if [ "$IGNORE_MINIMAL_REQS" = true ]; then export IGNORE_MINIMAL_REQS="-i"; else export IGNORE_MINIMAL_REQS=""; fi
  if [ "$DUMP" = true ]; then export DUMP="-d"; else export DUMP=""; fi
  if [ "$TON_BRANCH" != "latest" ]; then export NETWORK="-n testnet"; else export NETWORK=""; fi
  echo
  echo /bin/bash /tmp/install.sh ${TELEMETRY} ${IGNORE_MINIMAL_REQS} -b ${MYTONCTRL_VERSION} -m ${MODE} ${DUMP} ${NETWORK}
  echo
  /bin/bash /tmp/install.sh ${TELEMETRY} ${IGNORE_MINIMAL_REQS} -b ${MYTONCTRL_VERSION} -m ${MODE} ${DUMP} ${NETWORK}

  touch "${MTC_DONE_FILE}"
else
  echo "MyTonCtrl already installed"
fi

ensure_service_units

echo
echo "Applying service overrides from environment"
echo
apply_service_overrides
persist_service_units
if ! systemctl daemon-reload; then
  echo "systemctl daemon-reload failed, continuing"
fi
restart_or_start_service validator
restart_or_start_service mytoncore

echo "Service started!"
exec /usr/bin/systemctl
