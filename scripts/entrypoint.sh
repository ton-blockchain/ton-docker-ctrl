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
DUMP_EXTRACT_THREADS=${DUMP_EXTRACT_THREADS:-1}
DUMP_DEBUG=${DUMP_DEBUG:-true}
DUMP_VALIDATE_BEFORE_EXTRACT=${DUMP_VALIDATE_BEFORE_EXTRACT:-true}
DUMP_DEBUG_SHA256=${DUMP_DEBUG_SHA256:-false}
DUMP_KEEP_FAILED_ARCHIVE=${DUMP_KEEP_FAILED_ARCHIVE:-false}
MODE=${MODE:-validator}
MYTONCTRL_VERSION=${MYTONCTRL_VERSION:-master}
TON_DB_DIR=/var/ton-work/db
MTC_DONE_FILE=${TON_DB_DIR}/mtc_done
DUMP_DOWNLOAD_FILE=${TON_DB_DIR}/latest.tar.lz
DUMP_ARIA2_CONTROL_FILE=${DUMP_DOWNLOAD_FILE}.aria2
INSTALL_LOG_FILE=/tmp/mytonctrl-install.log
SYSTEMD_UNITS_DIR=/var/ton-work/db/systemd-units
VALIDATOR_SERVICE=/etc/systemd/system/validator.service
MYTONCORE_SERVICE=/etc/systemd/system/mytoncore.service
VALIDATOR_SERVICE_CACHE=${SYSTEMD_UNITS_DIR}/validator.service
MYTONCORE_SERVICE_CACHE=${SYSTEMD_UNITS_DIR}/mytoncore.service
SYSTEMD_UNITS_FALLBACK_DIR=/usr/local/bin/mytoncore/systemd-units
VALIDATOR_SERVICE_FALLBACK_CACHE=${SYSTEMD_UNITS_FALLBACK_DIR}/validator.service
MYTONCORE_SERVICE_FALLBACK_CACHE=${SYSTEMD_UNITS_FALLBACK_DIR}/mytoncore.service
MYTONCTRL_CLI_FILE=/usr/bin/mytonctrl
CUSTOM_PARAMETERS_STATE_FILE=${TON_DB_DIR}/custom_parameters.applied
BOOTSTRAP_TRANSACTION_MARKER=/var/ton-work/.bootstrap-transaction-active
BOOTSTRAP_ROLLBACK_BASENAME=.bootstrap-rollback
BOOTSTRAP_SYSTEMD_ROLLBACK_BASENAME=.bootstrap-systemd-rollback
BOOTSTRAP_ROOT_METADATA_FILE=.bootstrap-root-metadata
TON_WORK_ROLLBACK_DIR=/var/ton-work/${BOOTSTRAP_ROLLBACK_BASENAME}
MYTONCORE_ROLLBACK_DIR=/usr/local/bin/mytoncore/${BOOTSTRAP_ROLLBACK_BASENAME}
BOOTSTRAP_SYSTEMD_ROLLBACK_DIR=/var/ton-work/${BOOTSTRAP_SYSTEMD_ROLLBACK_BASENAME}
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
echo DUMP_EXTRACT_THREADS $DUMP_EXTRACT_THREADS
echo DUMP_DEBUG $DUMP_DEBUG
echo DUMP_VALIDATE_BEFORE_EXTRACT $DUMP_VALIDATE_BEFORE_EXTRACT
echo DUMP_DEBUG_SHA256 $DUMP_DEBUG_SHA256
echo DUMP_KEEP_FAILED_ARCHIVE $DUMP_KEEP_FAILED_ARCHIVE
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
  if [ ! -f "${MTC_DONE_FILE}" ]; then
    return
  fi

  restore_service_units

  if [ -f "${MTC_DONE_FILE}" ] && ! systemd_units_available && ! systemd_units_cached; then
    echo "Detected ${MTC_DONE_FILE} but no persisted systemd unit files; forcing one bootstrap run."
    rm -f "${MTC_DONE_FILE}" || true
  fi
}

copy_volume_snapshot() {
  local volume_root="$1"
  local snapshot_dir="$2"

  mkdir -p "${volume_root}"
  rm -rf "${snapshot_dir}"
  mkdir -p "${snapshot_dir}"
  stat -c '%u %g %a' "${volume_root}" > "${snapshot_dir}/${BOOTSTRAP_ROOT_METADATA_FILE}"

  find "${volume_root}" -mindepth 1 -maxdepth 1 \
    ! -name "${BOOTSTRAP_ROLLBACK_BASENAME}" \
    ! -name "${BOOTSTRAP_SYSTEMD_ROLLBACK_BASENAME}" \
    ! -name "$(basename "${BOOTSTRAP_TRANSACTION_MARKER}")" \
    -exec cp -a -t "${snapshot_dir}" -- {} +
}

clear_volume_current_state() {
  local volume_root="$1"

  mkdir -p "${volume_root}"

  find "${volume_root}" -mindepth 1 -maxdepth 1 \
    ! -name "${BOOTSTRAP_ROLLBACK_BASENAME}" \
    ! -name "${BOOTSTRAP_SYSTEMD_ROLLBACK_BASENAME}" \
    ! -name "$(basename "${BOOTSTRAP_TRANSACTION_MARKER}")" \
    -exec rm -rf -- {} +
}

restore_volume_snapshot() {
  local volume_root="$1"
  local snapshot_dir="$2"
  local owner_uid
  local owner_gid
  local root_mode

  if [ ! -d "${snapshot_dir}" ]; then
    echo "ERROR: bootstrap rollback snapshot is missing: ${snapshot_dir}"
    return 1
  fi

  clear_volume_current_state "${volume_root}"

  find "${snapshot_dir}" -mindepth 1 -maxdepth 1 \
    ! -name "${BOOTSTRAP_ROOT_METADATA_FILE}" \
    -exec cp -a -t "${volume_root}" -- {} +

  if [ -f "${snapshot_dir}/${BOOTSTRAP_ROOT_METADATA_FILE}" ]; then
    read -r owner_uid owner_gid root_mode < "${snapshot_dir}/${BOOTSTRAP_ROOT_METADATA_FILE}"
    chown "${owner_uid}:${owner_gid}" "${volume_root}" 2>/dev/null || true
    chmod "${root_mode}" "${volume_root}" 2>/dev/null || true
  fi
}

snapshot_systemd_unit_files() {
  local service_path
  local service_name

  rm -rf "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}"
  mkdir -p "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}"

  for service_path in "${VALIDATOR_SERVICE}" "${MYTONCORE_SERVICE}"; do
    service_name=$(basename "${service_path}")

    if [ -e "${service_path}" ]; then
      cp -a "${service_path}" "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}/${service_name}"
    else
      touch "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}/${service_name}.absent"
    fi
  done
}

restore_systemd_unit_files_snapshot() {
  local service_path
  local service_name

  if [ ! -d "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}" ]; then
    return
  fi

  for service_path in "${VALIDATOR_SERVICE}" "${MYTONCORE_SERVICE}"; do
    service_name=$(basename "${service_path}")

    if [ -e "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}/${service_name}" ]; then
      cp -a "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}/${service_name}" "${service_path}"
    elif [ -e "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}/${service_name}.absent" ]; then
      rm -f "${service_path}"
    fi
  done
}

cleanup_bootstrap_transaction_snapshots() {
  rm -rf \
    "${TON_WORK_ROLLBACK_DIR}" \
    "${MYTONCORE_ROLLBACK_DIR}" \
    "${BOOTSTRAP_SYSTEMD_ROLLBACK_DIR}" \
    "${BOOTSTRAP_TRANSACTION_MARKER}" \
    2>/dev/null || true
}

rollback_bootstrap_transaction() {
  echo "Rolling back incomplete MyTonCtrl bootstrap transaction."

  restore_systemd_unit_files_snapshot
  restore_volume_snapshot /var/ton-work "${TON_WORK_ROLLBACK_DIR}"
  restore_volume_snapshot /usr/local/bin/mytoncore "${MYTONCORE_ROLLBACK_DIR}"

  rm -f "${BOOTSTRAP_TRANSACTION_MARKER}"
  cleanup_bootstrap_transaction_snapshots
  bootstrap_transaction_active=false
}

recover_interrupted_bootstrap_transaction() {
  if [ -f "${BOOTSTRAP_TRANSACTION_MARKER}" ]; then
    echo "Detected interrupted MyTonCtrl bootstrap transaction from a previous start."
    rollback_bootstrap_transaction
  else
    cleanup_bootstrap_transaction_snapshots
  fi
}

begin_bootstrap_transaction() {
  echo "Starting atomic MyTonCtrl bootstrap transaction."

  cleanup_bootstrap_transaction_snapshots
  copy_volume_snapshot /var/ton-work "${TON_WORK_ROLLBACK_DIR}"
  copy_volume_snapshot /usr/local/bin/mytoncore "${MYTONCORE_ROLLBACK_DIR}"
  snapshot_systemd_unit_files

  {
    echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "pid=$$"
  } > "${BOOTSTRAP_TRANSACTION_MARKER}"

  bootstrap_transaction_active=true
}

commit_bootstrap_transaction() {
  if [ "${bootstrap_transaction_active}" != true ]; then
    return
  fi

  echo "Committing atomic MyTonCtrl bootstrap transaction."

  bootstrap_transaction_active=false
  rm -f "${BOOTSTRAP_TRANSACTION_MARKER}"
  cleanup_bootstrap_transaction_snapshots
}

rollback_bootstrap_transaction_on_exit() {
  local exit_code=$?

  if [ "${bootstrap_transaction_active}" = true ]; then
    echo "MyTonCtrl bootstrap did not reach commit point; rolling back persistent state."
    rollback_bootstrap_transaction
  fi

  return "${exit_code}"
}

validate_bootstrap_commit_ready() {
  local missing=false
  local required_service_file

  if [ ! -f "${MTC_DONE_FILE}" ]; then
    echo "Required bootstrap marker is missing: ${MTC_DONE_FILE}"
    missing=true
  fi

  for required_service_file in \
    "${VALIDATOR_SERVICE}" \
    "${MYTONCORE_SERVICE}" \
    "${VALIDATOR_SERVICE_CACHE}" \
    "${MYTONCORE_SERVICE_CACHE}" \
    "${VALIDATOR_SERVICE_FALLBACK_CACHE}" \
    "${MYTONCORE_SERVICE_FALLBACK_CACHE}"; do
    if ! service_file_present "${required_service_file}"; then
      echo "Required bootstrap service file is missing or empty: ${required_service_file}"
      missing=true
    fi
  done

  if [ "${missing}" = true ]; then
    return 1
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
  if [ -x "${MYTONCTRL_CLI_FILE}" ]; then
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

resolve_install_dump_arg() {
  INSTALL_DUMP_ARG=""

  if [ "${DUMP}" != true ]; then
    return
  fi

  INSTALL_DUMP_ARG="-d"
}

configure_dump_extract_threads() {
  if [ "${DUMP}" != true ]; then
    return
  fi

  if ! [[ "${DUMP_EXTRACT_THREADS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid DUMP_EXTRACT_THREADS=${DUMP_EXTRACT_THREADS}; expected positive integer."
    exit 2
  fi

  if [ "${DUMP_EXTRACT_THREADS}" = "8" ]; then
    return
  fi

  if [ ! -x /usr/bin/plzip ]; then
    return
  fi

  cat > /usr/local/bin/plzip <<'EOF'
#!/bin/bash
set -e
threads="${DUMP_EXTRACT_THREADS:-1}"
args=()
for arg in "$@"; do
  if [[ "$arg" =~ ^-n[0-9]+$ ]]; then
    args+=("-n${threads}")
  else
    args+=("$arg")
  fi
done
exec /usr/bin/plzip "${args[@]}"
EOF
  chmod +x /usr/local/bin/plzip
  echo "Configured plzip wrapper to use DUMP_EXTRACT_THREADS=${DUMP_EXTRACT_THREADS}"
}

patch_mytonctrl_install_script() {
  local install_script="$1"

  if [ "${DUMP}" != true ] || [ "${DUMP_DEBUG}" != true ]; then
    return
  fi

  if [ ! -x /scripts/mytonctrl_dump_debug_patch.py ]; then
    echo "Dump debug patch requested but /scripts/mytonctrl_dump_debug_patch.py is missing or not executable."
    exit 1
  fi

  python3 - "${install_script}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "# ton-docker-ctrl dump debug patch"
if marker in text:
    sys.exit(0)

insert = """\

# ton-docker-ctrl dump debug patch
if [ -x /scripts/mytonctrl_dump_debug_patch.py ]; then
    python3 /scripts/mytonctrl_dump_debug_patch.py
fi
"""

needle = "pip3 install -U .  # TODO: make installation from git directly\n"
if needle in text:
    text = text.replace(needle, needle + insert, 1)
else:
    fallback = "python3 -m mytoninstaller "
    index = text.find(fallback)
    if index == -1:
        raise SystemExit("failed to locate MyTonCtrl installer hook point")
    text = text[:index] + insert + text[index:]

path.write_text(text)
PY
  echo "Enabled MyTonCtrl dump diagnostics in ${install_script}"
}

dump_download_artifacts_present() {
  [ -f "${DUMP_DOWNLOAD_FILE}" ] || [ -f "${DUMP_ARIA2_CONTROL_FILE}" ]
}

clear_validator_config_for_dump_retry() {
  echo "Removing ${TON_DB_DIR}/config.json so MyTonCtrl runs DownloadDump on this bootstrap attempt."
  rm -f "${TON_DB_DIR}/config.json" 2>/dev/null || true
}

force_dump_download_retry_if_needed() {
  if [ "${DUMP}" != true ] || [ -f "${MTC_DONE_FILE}" ]; then
    return
  fi

  if ! dump_download_artifacts_present; then
    return
  fi

  echo "Detected incomplete dump download artifacts; preserving ${DUMP_DOWNLOAD_FILE} for aria2 resume."
  clear_validator_config_for_dump_retry
}

dump_download_failed_in_log() {
  [ -f "${INSTALL_LOG_FILE}" ] && grep -q "Dump download failed" "${INSTALL_LOG_FILE}"
}

dump_extraction_failed_in_log() {
  [ -f "${INSTALL_LOG_FILE}" ] && grep -Eq "Dump extraction failed|Data error in worker|Unexpected EOF in archive|tar: Error is not recoverable" "${INSTALL_LOG_FILE}"
}

clear_partial_dump_bootstrap_state() {
  echo "Clearing partial dump/bootstrap state before retry."
  rm -f "${MTC_DONE_FILE}" 2>/dev/null || true
  rm -f "${TON_DB_DIR}/config.json" 2>/dev/null || true
  rm -rf "${SYSTEMD_UNITS_DIR}" 2>/dev/null || true

  # A failed tar extraction can leave corrupt partial TON DB payload behind.
  rm -rf \
    "${TON_DB_DIR}/archive" \
    "${TON_DB_DIR}/celldb" \
    "${TON_DB_DIR}/files" \
    "${TON_DB_DIR}/state" \
    "${TON_DB_DIR}/keyring" \
    "${TON_DB_DIR}/error" \
    2>/dev/null || true

  if [ "${DUMP_KEEP_FAILED_ARCHIVE}" = true ]; then
    echo "Preserving dump archive artifacts because DUMP_KEEP_FAILED_ARCHIVE=true."
  else
    find "${TON_DB_DIR}" -maxdepth 1 -type f \( -name "*.tar.lz" -o -name "*.tar.lz.aria2" -o -name "latest.tar.lz" -o -name "latest.tar.lz.aria2" \) -delete 2>/dev/null || true
  fi
}

fail_if_dump_download_incomplete() {
  if [ "${DUMP}" != true ]; then
    return
  fi

  if dump_download_artifacts_present || dump_download_failed_in_log; then
    if dump_download_artifacts_present; then
      echo "Detected incomplete dump download artifacts."
      if [ "${bootstrap_transaction_active}" = true ]; then
        echo "Atomic bootstrap rollback will discard artifacts created by this attempt."
      else
        echo "Preserving ${DUMP_DOWNLOAD_FILE} for aria2 resume."
      fi
    fi
    clear_validator_config_for_dump_retry
    echo "Dump download did not finish; leaving bootstrap incomplete so the next pod start resumes it."
    exit 1
  fi
}

fail_if_dump_extraction_failed() {
  if [ "${DUMP}" != true ]; then
    return
  fi

  if dump_extraction_failed_in_log; then
    clear_partial_dump_bootstrap_state
    echo "Dump extraction failed; leaving bootstrap incomplete so the next pod start retries from a clean state."
    exit 1
  fi
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
bootstrap_transaction_active=false

trap rollback_bootstrap_transaction_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

recover_interrupted_bootstrap_transaction
configure_dump_extract_threads
prepare_bootstrap_marker_state

if [ ! -f "${MTC_DONE_FILE}" ]; then
  first_install=true
  echo "MyTonCtrl bootstrap required: ${MTC_DONE_FILE} not found"
  begin_bootstrap_transaction
else
  echo "MyTonCtrl already installed"
fi

restore_python_modules_from_cache
normalize_ton_permissions
force_dump_download_retry_if_needed

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
  patch_mytonctrl_install_script /tmp/install.sh
  if [ "$TELEMETRY" = false ]; then INSTALL_TELEMETRY_ARG="-t"; else INSTALL_TELEMETRY_ARG=""; fi
  if [ "$IGNORE_MINIMAL_REQS" = true ]; then INSTALL_IGNORE_MINIMAL_REQS_ARG="-i"; else INSTALL_IGNORE_MINIMAL_REQS_ARG=""; fi
  resolve_install_dump_arg
  if [ "$TON_BRANCH" != "latest" ]; then INSTALL_NETWORK_ARG="-n testnet"; else INSTALL_NETWORK_ARG=""; fi
  echo
  echo /bin/bash /tmp/install.sh ${INSTALL_TELEMETRY_ARG} ${INSTALL_IGNORE_MINIMAL_REQS_ARG} -b ${MYTONCTRL_VERSION} -m ${MODE} ${INSTALL_DUMP_ARG} ${INSTALL_NETWORK_ARG}
  echo
  rm -f "${INSTALL_LOG_FILE}" 2>/dev/null || true
  set +e
  /bin/bash /tmp/install.sh ${INSTALL_TELEMETRY_ARG} ${INSTALL_IGNORE_MINIMAL_REQS_ARG} -b ${MYTONCTRL_VERSION} -m ${MODE} ${INSTALL_DUMP_ARG} ${INSTALL_NETWORK_ARG} 2>&1 | tee "${INSTALL_LOG_FILE}"
  install_rc=${PIPESTATUS[0]}
  set -e
  fail_if_dump_download_incomplete
  fail_if_dump_extraction_failed

  if [ "${install_rc}" -ne 0 ]; then
    echo "MyTonCtrl installer failed with exit code ${install_rc}."
    echo "Container restart is caused by restart policy after this bootstrap failure."
    exit "${install_rc}"
  fi

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
  chown validator:validator "${MTC_DONE_FILE}" 2>/dev/null || true
  validate_bootstrap_commit_ready
  commit_bootstrap_transaction
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
