#!/bin/bash
set -e

TON_BRANCH=${TON_BRANCH:-latest}
GLOBAL_CONFIG_URL=${GLOBAL_CONFIG_URL:-https://ton.org/global.config.json}
ARCHIVE_TTL=${ARCHIVE_TTL:-86400}
STATE_TTL=${STATE_TTL:-86400}
VERBOSITY=${VERBOSITY:-1}
CUSTOM_PARAMETERS=${CUSTOM_PARAMETERS:-}
IGNORE_MINIMAL_REQS=${IGNORE_MINIMAL_REQS:-false}
TELEMETRY=${TELEMETRY:-true}
DUMP=${DUMP:-false}
MODE=${MODE:-validator}
MYTONCTRL_VERSION=${MYTONCTRL_VERSION:-master}
TON_DB_DIR=/var/ton-work/db
MTC_DONE_FILE=${TON_DB_DIR}/mtc_done
SYSTEMD_UNITS_DIR=/var/ton-work/db/systemd-units
VALIDATOR_SERVICE=/etc/systemd/system/validator.service
MYTONCORE_SERVICE=/etc/systemd/system/mytoncore.service
VALIDATOR_SERVICE_CACHE=${SYSTEMD_UNITS_DIR}/validator.service
MYTONCORE_SERVICE_CACHE=${SYSTEMD_UNITS_DIR}/mytoncore.service
SYSTEMD_UNITS_FALLBACK_DIR=/usr/local/bin/mytoncore/systemd-units
VALIDATOR_SERVICE_FALLBACK_CACHE=${SYSTEMD_UNITS_FALLBACK_DIR}/validator.service
MYTONCORE_SERVICE_FALLBACK_CACHE=${SYSTEMD_UNITS_FALLBACK_DIR}/mytoncore.service
MYTONCTRL_CLI_FILE=/usr/bin/mytonctrl
DUMP_MARKER_FILE=${TON_DB_DIR}/.dump_ready
DUMP_INCOMPLETE_MARKER_FILE=${TON_DB_DIR}/.dump_incomplete
DUMP_CACHE_FILE=${TON_DB_DIR}/latest.tar.lz
DUMP_CACHE_LINK=/tmp/latest.tar.lz
DUMP_ARIA2_CONTROL_FILE=${DUMP_CACHE_FILE}.aria2
DUMP_DATA_THRESHOLD_MB=${DUMP_DATA_THRESHOLD_MB:-102400}
DUMP_LOG_SUMMARY_LINES=${DUMP_LOG_SUMMARY_LINES:-120}
INSTALL_LOG_FILE=/tmp/mytonctrl-install.log
INCOMPLETE_DUMP_LOG_PATTERN='Download .* not complete: .*latest.*\.tar\.lz|errorCode=[0-9]+ URI=https://dump\.ton\.org/dumps/latest.*\.tar\.lz|Name resolution for dump\.ton\.org failed|aria2 will resume download if the transfer is restarted\.'
INVALID_RANGE_DUMP_LOG_PATTERN='errorCode=8 URI=https://dump\.ton\.org/dumps/latest.*\.tar\.lz|Invalid range header\.'
SKIPPED_DUMP_LOG_PATTERN='start FirstNodeSettings fuction|Validators config .+ already exist\. Break FirstNodeSettings fuction'
CUSTOM_PARAMETERS_STATE_FILE=${TON_DB_DIR}/custom_parameters.applied
SYSTEMCTL_BIN=/usr/bin/systemctl
PYTHON_SITE_DIR=$(python3 -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")
PYTHON_MODULES_CACHE_DIR=/usr/local/bin/mytoncore/python-site-packages
MYTONCTRL_PYTHON_PATTERNS=(
  myton*
  mypylib*
  mypyconsole*
  modules*
  crc16*
  fastcrc*
  psutil*
  nacl*
  PyNaCl*
  requests*
  cffi*
  charset_normalizer*
  idna*
  urllib3*
  certifi*
  pycparser*
)

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
echo CUSTOM_PARAMETERS "$CUSTOM_PARAMETERS"
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

service_file_present() {
  local file_path="$1"
  [ -s "${file_path}" ]
}

systemd_units_available() {
  service_file_present "${VALIDATOR_SERVICE}" && service_file_present "${MYTONCORE_SERVICE}"
}

systemd_units_cached() {
  (service_file_present "${VALIDATOR_SERVICE_CACHE}" || service_file_present "${VALIDATOR_SERVICE_FALLBACK_CACHE}") &&
    (service_file_present "${MYTONCORE_SERVICE_CACHE}" || service_file_present "${MYTONCORE_SERVICE_FALLBACK_CACHE}")
}

normalize_ton_permissions() {
  mkdir -p /var/ton-work /var/ton-work/db /var/ton-work/db/systemd-units /usr/local/bin/mytoncore /usr/local/bin/mytoncore/wallets
  mkdir -p /var/ton-work/db/error 2>/dev/null || true

  for path in \
    /var/ton-work \
    /var/ton-work/db \
    /var/ton-work/db/keyring \
    /var/ton-work/db/systemd-units \
    /var/ton-work/db/error \
    /var/ton-work/keys \
    /usr/local/bin/mytoncore \
    /usr/local/bin/mytoncore/wallets; do
    [ -e "${path}" ] || continue
    chown validator:validator "${path}" 2>/dev/null || true
  done

  if [ -f "${TON_DB_DIR}/config.json" ]; then
    chown validator:validator "${TON_DB_DIR}/config.json" 2>/dev/null || true
  fi
}

restore_service_units() {
  mkdir -p "${SYSTEMD_UNITS_DIR}" "${SYSTEMD_UNITS_FALLBACK_DIR}"

  if [ ! -f "${VALIDATOR_SERVICE}" ] && [ -s "${VALIDATOR_SERVICE_CACHE}" ]; then
    cp "${VALIDATOR_SERVICE_CACHE}" "${VALIDATOR_SERVICE}"
    echo "Restored validator.service from ${VALIDATOR_SERVICE_CACHE}"
  elif [ ! -f "${VALIDATOR_SERVICE}" ] && [ -s "${VALIDATOR_SERVICE_FALLBACK_CACHE}" ]; then
    cp "${VALIDATOR_SERVICE_FALLBACK_CACHE}" "${VALIDATOR_SERVICE}"
    cp "${VALIDATOR_SERVICE_FALLBACK_CACHE}" "${VALIDATOR_SERVICE_CACHE}" 2>/dev/null || true
    echo "Restored validator.service from ${VALIDATOR_SERVICE_FALLBACK_CACHE}"
  fi

  if [ ! -f "${MYTONCORE_SERVICE}" ] && [ -s "${MYTONCORE_SERVICE_CACHE}" ]; then
    cp "${MYTONCORE_SERVICE_CACHE}" "${MYTONCORE_SERVICE}"
    echo "Restored mytoncore.service from ${MYTONCORE_SERVICE_CACHE}"
  elif [ ! -f "${MYTONCORE_SERVICE}" ] && [ -s "${MYTONCORE_SERVICE_FALLBACK_CACHE}" ]; then
    cp "${MYTONCORE_SERVICE_FALLBACK_CACHE}" "${MYTONCORE_SERVICE}"
    cp "${MYTONCORE_SERVICE_FALLBACK_CACHE}" "${MYTONCORE_SERVICE_CACHE}" 2>/dev/null || true
    echo "Restored mytoncore.service from ${MYTONCORE_SERVICE_FALLBACK_CACHE}"
  fi
}

persist_service_units() {
  mkdir -p "${SYSTEMD_UNITS_DIR}" "${SYSTEMD_UNITS_FALLBACK_DIR}"

  if [ -f "${VALIDATOR_SERVICE}" ]; then
    cp "${VALIDATOR_SERVICE}" "${VALIDATOR_SERVICE_CACHE}"
    cp "${VALIDATOR_SERVICE}" "${VALIDATOR_SERVICE_FALLBACK_CACHE}"
  fi

  if [ -f "${MYTONCORE_SERVICE}" ]; then
    cp "${MYTONCORE_SERVICE}" "${MYTONCORE_SERVICE_CACHE}"
    cp "${MYTONCORE_SERVICE}" "${MYTONCORE_SERVICE_FALLBACK_CACHE}"
  fi
}

prepare_bootstrap_marker_state() {
  restore_service_units

  if [ -f "${MTC_DONE_FILE}" ] && ! systemd_units_available && ! systemd_units_cached; then
    echo "Detected ${MTC_DONE_FILE} but no persisted systemd unit files; forcing one bootstrap run."
    rm -f "${MTC_DONE_FILE}" || true
  fi
}

restore_python_modules_from_cache() {
  mkdir -p "${PYTHON_MODULES_CACHE_DIR}" "${PYTHON_SITE_DIR}"

  if python3 -c "import mytoncore" >/dev/null 2>&1; then
    return
  fi

  local restored=false

  for pattern in "${MYTONCTRL_PYTHON_PATTERNS[@]}"; do
    for cached_path in "${PYTHON_MODULES_CACHE_DIR}"/${pattern}; do
      if [ -e "${cached_path}" ]; then
        cp -a "${cached_path}" "${PYTHON_SITE_DIR}/"
        restored=true
      fi
    done
  done

  if [ "${restored}" = true ]; then
    echo "Restored MyTonCtrl python packages from ${PYTHON_MODULES_CACHE_DIR}"
  fi
}

persist_python_modules_to_cache() {
  if ! python3 -c "import mytoncore" >/dev/null 2>&1; then
    return
  fi

  mkdir -p "${PYTHON_MODULES_CACHE_DIR}"
  for pattern in "${MYTONCTRL_PYTHON_PATTERNS[@]}"; do
    rm -rf "${PYTHON_MODULES_CACHE_DIR}"/${pattern} 2>/dev/null || true
  done

  local copied=false

  for pattern in "${MYTONCTRL_PYTHON_PATTERNS[@]}"; do
    for module_path in "${PYTHON_SITE_DIR}"/${pattern}; do
      if [ -e "${module_path}" ]; then
        cp -a "${module_path}" "${PYTHON_MODULES_CACHE_DIR}/"
        copied=true
      fi
    done
  done

  if [ "${copied}" = true ]; then
    echo "Persisted MyTonCtrl python packages to ${PYTHON_MODULES_CACHE_DIR}"
  fi
}

ensure_mytonctrl_cli() {
  local needs_restore=true

  if [ -x "${MYTONCTRL_CLI_FILE}" ]; then
    if head -n 1 "${MYTONCTRL_CLI_FILE}" 2>/dev/null | grep -q '^#!'; then
      if grep -q 'python3 -m mytonctrl' "${MYTONCTRL_CLI_FILE}" 2>/dev/null; then
        needs_restore=false
      else
        echo "Existing ${MYTONCTRL_CLI_FILE} does not use python mytonctrl module wrapper, recreating."
      fi
    else
      echo "Existing ${MYTONCTRL_CLI_FILE} is not a script wrapper, recreating."
    fi
  fi

  if [ "${needs_restore}" != true ]; then
    return
  fi

  if ! python3 -c "import mytonctrl" >/dev/null 2>&1; then
    echo "WARNING: mytonctrl python module is missing, ${MYTONCTRL_CLI_FILE} cannot be restored."
    return
  fi

  cat > "${MYTONCTRL_CLI_FILE}" <<'EOF'
#!/bin/bash
exec /usr/bin/python3 -m mytonctrl "$@"
EOF
  chmod +x "${MYTONCTRL_CLI_FILE}"
  echo "Restored ${MYTONCTRL_CLI_FILE}"
}

ensure_dump_cache_link() {
  mkdir -p "${TON_DB_DIR}"
  if [ -e "${DUMP_CACHE_LINK}" ] && [ ! -L "${DUMP_CACHE_LINK}" ]; then
    rm -f "${DUMP_CACHE_LINK}"
  fi
  ln -sf "${DUMP_CACHE_FILE}" "${DUMP_CACHE_LINK}"
}

dump_db_size_mb() {
  du -sm "${TON_DB_DIR}" 2>/dev/null | awk '{print $1}'
}

dump_file_size_bytes() {
  local file_path="$1"
  if [ -f "${file_path}" ]; then
    stat -c '%s' "${file_path}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

dump_payload_size_mb() {
  local total_bytes
  local cache_bytes
  local aria2_bytes
  local payload_bytes

  total_bytes=$(du -sb "${TON_DB_DIR}" 2>/dev/null | awk '{print $1}')
  if [ -z "${total_bytes}" ]; then
    echo ""
    return
  fi

  cache_bytes=$(dump_file_size_bytes "${DUMP_CACHE_FILE}")
  aria2_bytes=$(dump_file_size_bytes "${DUMP_ARIA2_CONTROL_FILE}")

  payload_bytes=$(( total_bytes - cache_bytes - aria2_bytes ))
  if [ "${payload_bytes}" -lt 0 ]; then
    payload_bytes=0
  fi

  echo $(( payload_bytes / 1024 / 1024 ))
}

is_dump_payload_ready() {
  local payload_mb

  payload_mb=$(dump_payload_size_mb)
  if [ -f "${DUMP_ARIA2_CONTROL_FILE}" ]; then
    return 1
  fi

  if [ -n "${payload_mb}" ] && [ "${payload_mb}" -ge "${DUMP_DATA_THRESHOLD_MB}" ]; then
    return 0
  fi

  return 1
}

force_dump_retry_bootstrap_reset() {
  local config_file="${TON_DB_DIR}/config.json"

  if [ -f "${config_file}" ]; then
    rm -f "${config_file}" || true
    echo "Removed ${config_file} to force mytoninstaller FirstNodeSettings and dump retry."
  fi

  rm -f "${VALIDATOR_SERVICE}" "${MYTONCORE_SERVICE}" 2>/dev/null || true
  rm -f "${VALIDATOR_SERVICE_CACHE}" "${MYTONCORE_SERVICE_CACHE}" \
    "${VALIDATOR_SERVICE_FALLBACK_CACHE}" "${MYTONCORE_SERVICE_FALLBACK_CACHE}" 2>/dev/null || true
  echo "Removed validator/mytoncore unit files and caches to force service regeneration on dump retry."
}

log_dump_diagnostics() {
  if [ "${DUMP}" != true ]; then
    return
  fi

  local stage="$1"
  local db_size_mb
  local payload_size_mb
  db_size_mb=$(dump_db_size_mb)
  payload_size_mb=$(dump_payload_size_mb)

  echo "==== Dump diagnostics: ${stage} ===="
  echo "Dump markers: ready=$([ -f "${DUMP_MARKER_FILE}" ] && echo yes || echo no), incomplete=$([ -f "${DUMP_INCOMPLETE_MARKER_FILE}" ] && echo yes || echo no)"
  echo "Dump DB size (total): ${db_size_mb:-unknown}MB"
  echo "Dump payload size (excluding cache/control): ${payload_size_mb:-unknown}MB (threshold ${DUMP_DATA_THRESHOLD_MB}MB)"

  if [ -f "${DUMP_CACHE_FILE}" ]; then
    stat -c "Dump cache file: %n size=%s mtime=%y" "${DUMP_CACHE_FILE}" 2>/dev/null || true
  else
    echo "Dump cache file: ${DUMP_CACHE_FILE} missing"
  fi

  if [ -f "${DUMP_ARIA2_CONTROL_FILE}" ]; then
    stat -c "Dump aria2 control file: %n size=%s mtime=%y" "${DUMP_ARIA2_CONTROL_FILE}" 2>/dev/null || true
  else
    echo "Dump aria2 control file: ${DUMP_ARIA2_CONTROL_FILE} missing"
  fi

  for path in config.json state archive files celldb; do
    if [ -e "${TON_DB_DIR}/${path}" ]; then
      echo "DB entry present: ${TON_DB_DIR}/${path}"
    else
      echo "DB entry missing: ${TON_DB_DIR}/${path}"
    fi
  done

  echo "==== End dump diagnostics: ${stage} ===="
}

summarize_dump_install_log() {
  if [ ! -f "${INSTALL_LOG_FILE}" ]; then
    echo "Dump install log is missing: ${INSTALL_LOG_FILE}"
    return
  fi

  echo "==== Dump-related lines from ${INSTALL_LOG_FILE} (last ${DUMP_LOG_SUMMARY_LINES}) ===="
  grep -Ei 'dump|latest\.tar\.lz|aria2|download (results|aborted)|errorCode=' "${INSTALL_LOG_FILE}" | tail -n "${DUMP_LOG_SUMMARY_LINES}" || true
  echo "==== End dump install log summary ===="
}

dump_payload_present() {
  if [ -f "${DUMP_ARIA2_CONTROL_FILE}" ]; then
    echo "Dump payload check: ${DUMP_ARIA2_CONTROL_FILE} exists, treating payload as incomplete"
    return 1
  fi

  is_dump_payload_ready
}

dump_install_log_has_download_activity() {
  if [ ! -f "${INSTALL_LOG_FILE}" ]; then
    return 1
  fi

  if grep -Eq 'start DownloadDump function|dumpSize:|latest(_testnet)?\.tar\.lz|aria2c -x' "${INSTALL_LOG_FILE}"; then
    return 0
  fi

  return 1
}

reconcile_dump_markers() {
  if [ "${DUMP}" != true ]; then
    return
  fi

  if [ -f "${DUMP_MARKER_FILE}" ] && ! is_dump_payload_ready; then
    echo "Removing stale ${DUMP_MARKER_FILE}: payload is not ready yet"
    rm -f "${DUMP_MARKER_FILE}" || true
  fi

  if [ -f "${DUMP_MARKER_FILE}" ] && [ -f "${DUMP_INCOMPLETE_MARKER_FILE}" ]; then
    echo "Found both ${DUMP_MARKER_FILE} and ${DUMP_INCOMPLETE_MARKER_FILE}; removing ready marker and retrying dump"
    rm -f "${DUMP_MARKER_FILE}" || true
  fi

  if [ -f "${DUMP_INCOMPLETE_MARKER_FILE}" ] && is_dump_payload_ready; then
    echo "Removing stale ${DUMP_INCOMPLETE_MARKER_FILE}: payload is already ready"
    rm -f "${DUMP_INCOMPLETE_MARKER_FILE}" || true
  fi
}

mark_dump_as_ready_if_present() {
  if [ "${DUMP}" != true ]; then
    return
  fi

  if [ "${DUMP_DOWNLOAD_INCOMPLETE}" = true ]; then
    echo "Skipping ${DUMP_MARKER_FILE} creation: dump download did not complete"
    return
  fi

  if dump_payload_present && [ ! -f "${DUMP_MARKER_FILE}" ]; then
    touch "${DUMP_MARKER_FILE}"
    rm -f "${DUMP_INCOMPLETE_MARKER_FILE}" 2>/dev/null || true
    echo "Detected existing TON DB payload and created ${DUMP_MARKER_FILE}"
  fi
}

resolve_install_dump_arg() {
  INSTALL_DUMP_ARG=""
  DUMP_DOWNLOAD_REQUESTED=false
  DUMP_DOWNLOAD_INCOMPLETE=false

  if [ "${DUMP}" != true ]; then
    return
  fi

  ensure_dump_cache_link
  reconcile_dump_markers
  log_dump_diagnostics "before dump decision"

  if [ -f "${DUMP_MARKER_FILE}" ]; then
    echo "Skipping dump download: marker ${DUMP_MARKER_FILE} already exists"
    return
  fi

  if [ -f "${DUMP_INCOMPLETE_MARKER_FILE}" ]; then
    DUMP_RETRY_FROM_INCOMPLETE=true
    if [ -f "${DUMP_CACHE_FILE}" ] && [ ! -f "${DUMP_ARIA2_CONTROL_FILE}" ]; then
      rm -f "${DUMP_CACHE_FILE}" || true
      echo "Removed stale ${DUMP_CACHE_FILE}: incomplete marker exists but aria2 control file is missing."
    fi
    force_dump_retry_bootstrap_reset
    echo "Retrying dump download: previous attempt was incomplete"
    INSTALL_DUMP_ARG="-d"
    DUMP_DOWNLOAD_REQUESTED=true
    return
  fi

  if dump_payload_present; then
    echo "Skipping dump download: existing TON DB payload detected in ${TON_DB_DIR}"
    log_dump_diagnostics "skip download due to existing payload"
    return
  fi

  INSTALL_DUMP_ARG="-d"
  DUMP_DOWNLOAD_REQUESTED=true
  echo "Dump download requested: payload marker missing and DB size below threshold"
  log_dump_diagnostics "download requested"
}

detect_incomplete_dump_download() {
  if [ "${DUMP_DOWNLOAD_REQUESTED}" != true ]; then
    return 1
  fi

  DUMP_DOWNLOAD_NEEDS_CLEAN_START=false
  DUMP_DOWNLOAD_NEEDS_BOOTSTRAP_RESET=false

  if [ ! -f "${INSTALL_LOG_FILE}" ]; then
    if [ "${DUMP_RETRY_FROM_INCOMPLETE}" = true ]; then
      echo "Dump retry was requested but installer log ${INSTALL_LOG_FILE} is missing."
      DUMP_DOWNLOAD_NEEDS_BOOTSTRAP_RESET=true
      return 0
    fi
    return 1
  fi

  if grep -Eq "${INCOMPLETE_DUMP_LOG_PATTERN}" "${INSTALL_LOG_FILE}"; then
    echo "Detected dump download failure pattern in ${INSTALL_LOG_FILE}"
    if grep -Eq "${INVALID_RANGE_DUMP_LOG_PATTERN}" "${INSTALL_LOG_FILE}"; then
      DUMP_DOWNLOAD_NEEDS_CLEAN_START=true
      echo "Detected invalid range during dump download. Next retry will start from scratch."
    fi
    summarize_dump_install_log
    return 0
  fi

  if [ "${DUMP_RETRY_FROM_INCOMPLETE}" = true ] && ! dump_install_log_has_download_activity; then
    if grep -Eq "${SKIPPED_DUMP_LOG_PATTERN}" "${INSTALL_LOG_FILE}"; then
      echo "Detected dump retry skip: FirstNodeSettings was skipped because validator config already exists."
    else
      echo "Dump retry was requested but no download activity was detected in installer output."
    fi
    DUMP_DOWNLOAD_NEEDS_BOOTSTRAP_RESET=true
    summarize_dump_install_log
    return 0
  fi

  if [ -f "${DUMP_ARIA2_CONTROL_FILE}" ]; then
    echo "Detected ${DUMP_ARIA2_CONTROL_FILE} after installer run, dump download is incomplete"
    summarize_dump_install_log
    return 0
  fi

  return 1
}

cleanup_dump_cache_if_ready() {
  if [ ! -f "${DUMP_MARKER_FILE}" ]; then
    return
  fi

  rm -f "${DUMP_CACHE_FILE}"
}

restart_or_start_service() {
  local service_name="$1"

  echo "Restarting ${service_name}"
  if ! run_systemctl restart "${service_name}"; then
    echo "Restart failed for ${service_name}, trying start"
    if ! run_systemctl start "${service_name}"; then
      echo "Failed to start ${service_name}, continuing"
    fi
  fi
}

run_systemctl() {
  "${SYSTEMCTL_BIN}" "$@"
}

enable_managed_services() {
  if ! run_systemctl enable validator.service mytoncore.service; then
    echo "Failed to enable validator/mytoncore, continuing"
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

sanitize_engine_config_ports() {
  local config_file="${TON_DB_DIR}/config.json"

  if [ ! -s "${config_file}" ]; then
    return
  fi

  if ! python3 - "${config_file}" <<'PY'
import json
import os
import sys
import tempfile

path = sys.argv[1]

def dedupe_by_port(entries):
    if not isinstance(entries, list):
        return entries, 0

    kept = []
    seen_ports = set()
    removed = 0

    for item in reversed(entries):
        if isinstance(item, dict) and "port" in item:
            port = item.get("port")
            if port in seen_ports:
                removed += 1
                continue
            seen_ports.add(port)
        kept.append(item)

    kept.reverse()
    return kept, removed

with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict):
    raise SystemExit(0)

removed_total = 0
for key in ("control", "liteservers"):
    deduped, removed = dedupe_by_port(data.get(key))
    if removed > 0:
        data[key] = deduped
        removed_total += removed

if removed_total == 0:
    raise SystemExit(0)

fd, tmp_path = tempfile.mkstemp(
    prefix=".config.",
    suffix=".tmp",
    dir=os.path.dirname(path) or ".",
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    os.replace(tmp_path, path)
finally:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass

print(f"Sanitized {removed_total} duplicate validator port entries in {path}")
PY
  then
    chown validator:validator "${config_file}" 2>/dev/null || true
  else
    echo "WARNING: Failed to sanitize duplicate ports in ${config_file}"
  fi
}

apply_custom_parameters_override() {
  if [ ! -f "${VALIDATOR_SERVICE}" ]; then
    return
  fi

  local previous_custom_parameters=""
  if [ -f "${CUSTOM_PARAMETERS_STATE_FILE}" ]; then
    previous_custom_parameters=$(cat "${CUSTOM_PARAMETERS_STATE_FILE}")
  fi

  if python3 - "${VALIDATOR_SERVICE}" "${previous_custom_parameters}" "${CUSTOM_PARAMETERS}" <<'PY'
import pathlib
import re
import sys

service_path = pathlib.Path(sys.argv[1])
previous_parameters = sys.argv[2]
current_parameters = sys.argv[3]

lines = service_path.read_text(encoding="utf-8").splitlines(keepends=True)
updated = False
matched = False

for index, line in enumerate(lines):
    match = re.match(r"^(ExecStart\s*=\s*)(.*?)(\r?\n?)$", line)
    if not match:
        continue

    prefix, command, line_ending = match.groups()
    if "validator-engine" not in command:
        continue

    matched = True
    command = command.rstrip()

    if previous_parameters:
        previous_suffix = " " + previous_parameters
        if command.endswith(previous_suffix):
            command = command[: -len(previous_suffix)].rstrip()
            updated = True

    if current_parameters:
        current_suffix = " " + current_parameters
        if not command.endswith(current_suffix):
            command = f"{command}{current_suffix}"
            updated = True

    lines[index] = f"{prefix}{command}{line_ending}"
    break

if not matched:
    raise SystemExit(2)

if updated:
    service_path.write_text("".join(lines), encoding="utf-8")
PY
  then
    printf '%s' "${CUSTOM_PARAMETERS}" > "${CUSTOM_PARAMETERS_STATE_FILE}"
  else
    echo "WARNING: Failed to apply CUSTOM_PARAMETERS to ${VALIDATOR_SERVICE}"
  fi
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

    apply_custom_parameters_override
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

first_install=false
bootstrap_completed=false
DUMP_DOWNLOAD_REQUESTED=false
DUMP_DOWNLOAD_INCOMPLETE=false
DUMP_DOWNLOAD_NEEDS_CLEAN_START=false
DUMP_DOWNLOAD_NEEDS_BOOTSTRAP_RESET=false
DUMP_RETRY_FROM_INCOMPLETE=false

restore_python_modules_from_cache
prepare_bootstrap_marker_state
normalize_ton_permissions

if [ ! -f "${MTC_DONE_FILE}" ]; then
  first_install=true
  echo "MyTonCtrl bootstrap required: ${MTC_DONE_FILE} not found"
else
  echo "MyTonCtrl already installed"
fi

if [ "${first_install}" = true ]; then

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
  if [ "$TELEMETRY" = false ]; then INSTALL_TELEMETRY_ARG="-t"; else INSTALL_TELEMETRY_ARG=""; fi
  if [ "$IGNORE_MINIMAL_REQS" = true ]; then INSTALL_IGNORE_MINIMAL_REQS_ARG="-i"; else INSTALL_IGNORE_MINIMAL_REQS_ARG=""; fi
  resolve_install_dump_arg
  if [ "$TON_BRANCH" != "latest" ]; then INSTALL_NETWORK_ARG="-n testnet"; else INSTALL_NETWORK_ARG=""; fi
  echo
  echo /bin/bash /tmp/install.sh ${INSTALL_TELEMETRY_ARG} ${INSTALL_IGNORE_MINIMAL_REQS_ARG} -b ${MYTONCTRL_VERSION} -m ${MODE} ${INSTALL_DUMP_ARG} ${INSTALL_NETWORK_ARG}
  echo
  log_dump_diagnostics "before installer run"
  rm -f "${INSTALL_LOG_FILE}" 2>/dev/null || true
  set +e
  /bin/bash /tmp/install.sh ${INSTALL_TELEMETRY_ARG} ${INSTALL_IGNORE_MINIMAL_REQS_ARG} -b ${MYTONCTRL_VERSION} -m ${MODE} ${INSTALL_DUMP_ARG} ${INSTALL_NETWORK_ARG} 2>&1 | tee "${INSTALL_LOG_FILE}"
  install_rc=${PIPESTATUS[0]}
  set -e
  log_dump_diagnostics "after installer run"
  summarize_dump_install_log

  if detect_incomplete_dump_download; then
    DUMP_DOWNLOAD_INCOMPLETE=true
    touch "${DUMP_INCOMPLETE_MARKER_FILE}"
    rm -f "${DUMP_MARKER_FILE}" 2>/dev/null || true
    if [ "${DUMP_DOWNLOAD_NEEDS_BOOTSTRAP_RESET}" = true ]; then
      force_dump_retry_bootstrap_reset
    fi
    if [ "${DUMP_DOWNLOAD_NEEDS_CLEAN_START}" = true ]; then
      rm -f "${DUMP_CACHE_FILE}" "${DUMP_ARIA2_CONTROL_FILE}" 2>/dev/null || true
      echo "Removed stale dump cache/control files after invalid range error to force clean re-download."
    fi
    echo "Detected interrupted dump download in installer output; leaving ${DUMP_MARKER_FILE} absent"
    if [ -f "${MTC_DONE_FILE}" ]; then
      rm -f "${MTC_DONE_FILE}" || true
    fi
    echo "Dump download was requested but did not complete; failing bootstrap to retry on next start."
    exit 1
  fi

  if [ "${install_rc}" -ne 0 ]; then
    cleanup_dump_cache_if_ready
    echo "MyTonCtrl installer failed with exit code ${install_rc}."
    echo "Container restart is caused by restart policy after this bootstrap failure."
    exit "${install_rc}"
  fi

  mark_dump_as_ready_if_present
  log_dump_diagnostics "after dump marker evaluation"
  cleanup_dump_cache_if_ready

  bootstrap_completed=true
  persist_python_modules_to_cache
elif ! python3 -c "import mytoncore" >/dev/null 2>&1; then
  echo "WARNING: mytoncore python module is missing after restore."
  echo "Skipping reinstall by policy. To reinstall manually, remove ${MTC_DONE_FILE} and restart."
fi

ensure_mytonctrl_cli
ensure_service_units

echo
echo "Applying service overrides from environment"
echo
apply_service_overrides
sanitize_engine_config_ports
persist_service_units
normalize_ton_permissions

if [ "${bootstrap_completed}" = true ]; then
  touch "${MTC_DONE_FILE}"
fi

if ! run_systemctl daemon-reload; then
  echo "systemctl daemon-reload failed, continuing"
fi
enable_managed_services

if [ "${first_install}" = true ]; then
  restart_or_start_service validator
  restart_or_start_service mytoncore
fi

echo "Service started!"
exec "${SYSTEMCTL_BIN}"
