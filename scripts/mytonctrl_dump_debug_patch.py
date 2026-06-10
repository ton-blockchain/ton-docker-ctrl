#!/usr/bin/env python3
"""Patch MyTonCtrl dump bootstrap with integrity diagnostics.

The container installs MyTonCtrl from the branch selected by MYTONCTRL_VERSION at
startup. This script runs after that pip install and replaces the dump helper
functions in mytoninstaller.settings, keeping the patch local to the container
image and independent of the selected upstream branch.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys


PATCH_MARKER = "# ton-docker-ctrl dump diagnostics v1"


REPLACEMENT = r'''
# ton-docker-ctrl dump diagnostics v1
def DumpBoolEnv(name, default=False):
    value = os.getenv(name)
    if value is None:
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")
#end define


def DumpLog(local, message, mode="info"):
    text = str(message)
    print(text, flush=True)
    try:
        local.add_log(text, mode)
    except Exception:
        pass
#end define


def DumpExtractThreads():
    value = os.getenv("DUMP_EXTRACT_THREADS", "8")
    try:
        threads = int(value)
    except ValueError:
        return 8
    if threads < 1:
        return 8
    return threads
#end define


def DumpRunDiagnosticCommand(local, label, args, timeout=120):
    try:
        process = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
        output = process.stdout or ""
        DumpLog(local, f"{label}: exit={process.returncode}")
        lines = output.splitlines()
        if len(lines) > 120:
            lines = lines[:80] + [f"... truncated {len(output.splitlines()) - 120} lines ..."] + lines[-40:]
        for line in lines:
            DumpLog(local, f"{label}: {line}")
        return process.returncode
    except FileNotFoundError:
        DumpLog(local, f"{label}: command not found: {args[0]}", "warning")
        return 127
    except subprocess.TimeoutExpired:
        DumpLog(local, f"{label}: timed out after {timeout}s", "warning")
        return 124
    except Exception as e:
        DumpLog(local, f"{label}: failed: {e}", "warning")
        return 1
#end define


def DumpPathUsage(path):
    usage = psutil.disk_usage(path)
    statvfs = os.statvfs(path)
    return (
        f"path={path} total={usage.total} used={usage.used} free={usage.free} "
        f"percent={usage.percent} inodes_total={statvfs.f_files} "
        f"inodes_free={statvfs.f_favail}"
    )
#end define


def DumpDebugSnapshot(local, stage, temp_file=None, dump_dir="/var/ton-work/db", metadata=None):
    if not DumpBoolEnv("DUMP_DEBUG", True):
        return

    DumpLog(local, f"Dump debug snapshot: stage={stage}")
    DumpLog(local, f"Dump debug env: DUMP_EXTRACT_THREADS={os.getenv('DUMP_EXTRACT_THREADS', '')} "
                   f"DUMP_VALIDATE_BEFORE_EXTRACT={os.getenv('DUMP_VALIDATE_BEFORE_EXTRACT', '')} "
                   f"DUMP_DEBUG_SHA256={os.getenv('DUMP_DEBUG_SHA256', '')} "
                   f"DUMP_KEEP_FAILED_ARCHIVE={os.getenv('DUMP_KEEP_FAILED_ARCHIVE', '')}")

    if metadata:
        DumpLog(
            local,
            "Dump metadata: "
            f"archive_name={metadata.get('archive_name')} "
            f"archive_size={metadata.get('archive_size')} "
            f"disk_size={metadata.get('disk_size')} "
            f"sha256={metadata.get('sha256')}",
        )

    for path in ["/", "/var", "/tmp", "/var/ton-work", dump_dir]:
        if os.path.exists(path):
            try:
                DumpLog(local, "Filesystem usage: " + DumpPathUsage(path))
            except Exception as e:
                DumpLog(local, f"Filesystem usage failed for {path}: {e}", "warning")

    if temp_file:
        if os.path.exists(temp_file):
            try:
                stat_result = os.stat(temp_file)
                DumpLog(
                    local,
                    f"Dump file stat: path={temp_file} size={stat_result.st_size} "
                    f"mtime={int(stat_result.st_mtime)} mode={oct(stat_result.st_mode & 0o777)}",
                )
            except Exception as e:
                DumpLog(local, f"Dump file stat failed for {temp_file}: {e}", "warning")
        else:
            DumpLog(local, f"Dump file missing: path={temp_file}", "warning")

    DumpRunDiagnosticCommand(local, "df-bytes", ["df", "-hP", "/", "/var", "/tmp", "/var/ton-work", dump_dir], timeout=30)
    DumpRunDiagnosticCommand(local, "df-inodes", ["df", "-ihP", "/", "/var", "/tmp", "/var/ton-work", dump_dir], timeout=30)
    DumpRunDiagnosticCommand(local, "findmnt-dump-dir", ["findmnt", "-T", dump_dir], timeout=30)
    DumpRunDiagnosticCommand(local, "findmnt-tmp", ["findmnt", "-T", "/tmp"], timeout=30)
    DumpRunDiagnosticCommand(local, "cgroup-memory", ["sh", "-c", "cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.current 2>/dev/null || true"], timeout=30)
    DumpRunDiagnosticCommand(local, "ulimit", ["sh", "-c", "ulimit -a"], timeout=30)
    DumpRunDiagnosticCommand(local, "plzip-version", ["plzip", "--version"], timeout=30)
    DumpRunDiagnosticCommand(local, "tar-version", ["tar", "--version"], timeout=30)
    if temp_file and os.path.exists(temp_file):
        DumpRunDiagnosticCommand(local, "dump-file-du", ["du", "-h", temp_file], timeout=60)
        DumpRunDiagnosticCommand(local, "dump-file-head-tail", [
            "sh",
            "-c",
            'printf "head32="; head -c 32 "$1" | xxd -p -c 32; '
            'printf "tail32="; tail -c 32 "$1" | xxd -p -c 32',
            "dump-file-head-tail",
            temp_file,
        ], timeout=60)
#end define


def DumpFetchText(url, timeout=10):
    response = requests.get(url, timeout=timeout)
    response.raise_for_status()
    return response.text.strip()
#end define


def DownloadDump(local):
    dump = local.buffer.dump
    if dump is False:
        return
    #end if

    local.add_log("start DownloadDump function", "debug")
    base_url = "https://dump.ton.org/dumps"
    dump_name = "latest"
    if is_testnet(local):
        dump_name += '_testnet'
    #end if
    dump_dir = "/var/ton-work/db"
    os.makedirs(dump_dir, exist_ok=True)
    CleanupDumpTempFiles(local, os.path.join(dump_dir, "latest.tar.lz"), force=True)

    try:
        dump_metadata = GetDumpMetadata(base_url, dump_name)
    except Exception as e:
        local.add_log(f"Failed to get dump metadata: {e}", "error")
        return
    #end try

    archive_name = dump_metadata["archive_name"]
    archive_url = f"{base_url}/{archive_name}"
    temp_file = os.path.join(dump_dir, archive_name)
    CleanupDumpTempFiles(local, temp_file, force=True)
    dumpSize = dump_metadata["archive_size"]
    print("dumpName:", archive_name)
    print("dumpSize:", dumpSize)
    print("dumpDiskSize:", dump_metadata["disk_size"])
    print("dumpSha256:", dump_metadata["sha256"])

    try:
        head = requests.head(archive_url, allow_redirects=True, timeout=15)
        DumpLog(
            local,
            f"Dump archive HEAD: status={head.status_code} content_length={head.headers.get('content-length')} "
            f"etag={head.headers.get('etag')} last_modified={head.headers.get('last-modified')} "
            f"accept_ranges={head.headers.get('accept-ranges')} url={head.url}",
        )
        if head.status_code >= 400:
            local.add_log(f"Dump archive HEAD failed with status {head.status_code}: {archive_url}", "error")
            return
        #end if
        content_length = head.headers.get("content-length")
        if content_length and int(content_length) != dump_metadata["archive_size"]:
            local.add_log(
                f"Dump archive HEAD size mismatch: metadata={dump_metadata['archive_size']} "
                f"content_length={content_length}",
                "error",
            )
            return
        #end if
    except Exception as e:
        DumpLog(local, f"Dump archive HEAD failed: {e}", "warning")
    #end try

    needSpace = dump_metadata["archive_size"] + dump_metadata["disk_size"]
    diskSpace = psutil.disk_usage(dump_dir)
    DumpLog(local, f"Dump space check: need={needSpace} free={diskSpace.free} dir={dump_dir}")
    if needSpace > diskSpace.free:
        local.add_log(f"Not enough disk space in {dump_dir}: need {needSpace}, free {diskSpace.free}", "error")
        DumpDebugSnapshot(local, "not-enough-space", temp_file=temp_file, dump_dir=dump_dir, metadata=dump_metadata)
        return
    #end if

    DumpDebugSnapshot(local, "before-download", temp_file=temp_file, dump_dir=dump_dir, metadata=dump_metadata)

    apt_result = subprocess.run(["apt", "install", "plzip", "pv", "aria2", "curl", "-y"]).returncode
    if apt_result != 0:
        local.add_log(f"Failed to install dump tools with exit code {apt_result}", "error")
        return
    #end if

    cmd = [
        "aria2c",
        "-x", "8",
        "-s", "8",
        "--enable-http-keep-alive=false",
        "--retry-wait=5",
        "--max-tries=20",
        "--connect-timeout=60",
        "--timeout=120",
        "--auto-file-renaming=false",
        "--allow-overwrite=true",
        "--check-integrity=true",
        f"--checksum=sha-256={dump_metadata['sha256']}",
        "--summary-interval=60",
        "-c",
        f"{archive_url}",
        "-d", dump_dir,
        "-o", archive_name,
    ]
    download_started_at = time.monotonic()
    download_result = subprocess.run(cmd).returncode
    download_elapsed = FormatElapsedTime(time.monotonic() - download_started_at)
    if download_result != 0 or not os.path.exists(temp_file):
        local.add_log(f"Dump download failed after {download_elapsed}: {temp_file}", "error")
        DumpDebugSnapshot(local, "download-failed", temp_file=temp_file, dump_dir=dump_dir, metadata=dump_metadata)
        CleanupDumpTempFiles(local, temp_file)
        return
    #end if
    actual_size = os.path.getsize(temp_file)
    if actual_size != dump_metadata["archive_size"]:
        local.add_log(
            f"Dump download size mismatch after {download_elapsed}: expected={dump_metadata['archive_size']} "
            f"actual={actual_size} file={temp_file}",
            "error",
        )
        DumpDebugSnapshot(local, "download-size-mismatch", temp_file=temp_file, dump_dir=dump_dir, metadata=dump_metadata)
        CleanupDumpTempFiles(local, temp_file)
        return
    #end if

    DumpDebugSnapshot(local, "after-download", temp_file=temp_file, dump_dir=dump_dir, metadata=dump_metadata)

    if DumpBoolEnv("DUMP_DEBUG_SHA256", False):
        sha_result = DumpRunDiagnosticCommand(local, "dump-sha256sum", ["sha256sum", temp_file], timeout=3600)
        if sha_result != 0:
            local.add_log(f"sha256sum failed for {temp_file}", "error")
            CleanupDumpTempFiles(local, temp_file)
            return
        #end if
    #end if

    if DumpBoolEnv("DUMP_VALIDATE_BEFORE_EXTRACT", True):
        validation_started_at = time.monotonic()
        validation_result = ValidateDumpArchive(local, temp_file)
        validation_elapsed = FormatElapsedTime(time.monotonic() - validation_started_at)
        if validation_result != 0:
            local.add_log(f"Dump lzip validation failed after {validation_elapsed}: {temp_file}", "error")
            DumpDebugSnapshot(local, "validation-failed", temp_file=temp_file, dump_dir=dump_dir, metadata=dump_metadata)
            CleanupDumpTempFiles(local, temp_file)
            return
        #end if
        DumpLog(local, f"Dump lzip validation succeeded in {validation_elapsed}: {temp_file}")
    #end if

    archive_size = os.path.getsize(temp_file)
    msg = f"Dump downloaded to {temp_file} in {download_elapsed}. Starting extraction to {dump_dir}"
    print(msg, flush=True)
    local.add_log(msg, "info")
    extraction_started_at = time.monotonic()
    extraction_result = ExtractDump(local, archive_size, temp_file, dump_dir)
    extraction_elapsed = FormatElapsedTime(time.monotonic() - extraction_started_at)
    if extraction_result != 0:
        local.add_log(f"Dump extraction failed after {extraction_elapsed}", "error")
        DumpDebugSnapshot(local, "extraction-failed", temp_file=temp_file, dump_dir=dump_dir, metadata=dump_metadata)
        CleanupDumpTempFiles(local, temp_file)
        return
    #end if
    msg = f"Dump extracted to {dump_dir} in {extraction_elapsed}"
    print(msg, flush=True)
    local.add_log(msg, "info")

    CleanupDumpTempFiles(local, temp_file)
#end define


def CleanupDumpTempFiles(local, temp_file, force=False):
    if not force and DumpBoolEnv("DUMP_KEEP_FAILED_ARCHIVE", False) and os.path.exists(temp_file):
        local.add_log(f"Preserving temporary dump file {temp_file}", "debug")
        return
    #end if
    for path in [temp_file, temp_file + ".aria2"]:
        if os.path.exists(path):
            os.remove(path)
            local.add_log(f"Temporary file {path} removed", "debug")
        #end if
    #end for
#end define


def GetDumpMetadata(base_url, dump_name):
    latest_name = DumpFetchText(f"{base_url}/{dump_name}.tar.name.txt", timeout=10)
    if not latest_name:
        raise RuntimeError(f"empty dump name for {dump_name}")
    #end if

    metadata_name = os.path.basename(latest_name)
    archive_name = metadata_name
    if not archive_name.endswith(".lz"):
        archive_name += ".lz"
    else:
        metadata_name = archive_name[:-3]
    #end if

    sha_text = DumpFetchText(f"{base_url}/{metadata_name}.sha256sum.txt", timeout=10)
    sha_parts = sha_text.split()
    if not sha_parts:
        raise RuntimeError(f"empty dump sha256 for {metadata_name}")
    #end if
    sha256 = sha_parts[0]
    if len(sha256) != 64:
        raise RuntimeError(f"invalid dump sha256 for {metadata_name}: {sha256}")
    #end if
    if len(sha_parts) > 1 and os.path.basename(sha_parts[1]) != archive_name:
        raise RuntimeError(f"dump sha256 file does not match archive {archive_name}: {sha_parts[1]}")
    #end if

    archive_size = int(DumpFetchText(f"{base_url}/{metadata_name}.size.archive.txt", timeout=10))
    disk_size = int(DumpFetchText(f"{base_url}/{metadata_name}.size.disk.txt", timeout=10))
    return {
        "archive_name": archive_name,
        "sha256": sha256,
        "archive_size": archive_size,
        "disk_size": disk_size,
    }
#end define


def FormatElapsedTime(elapsed):
    total_seconds = int(elapsed)
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    #end if
    if minutes:
        return f"{minutes}m {seconds}s"
    #end if
    return f"{seconds}s"
#end define


def UseInteractiveExtractionProgress():
    if not sys.stderr.isatty():
        return False
    # Container log collectors usually need newline-delimited output, even if a TTY is allocated.
    if os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv"):
        return False
    if os.getenv("KUBERNETES_SERVICE_HOST") or os.path.exists("/var/run/secrets/kubernetes.io/serviceaccount"):
        return False
    return True
#end define


def ValidateDumpArchive(local, temp_file):
    threads = DumpExtractThreads()
    DumpLog(local, f"Validating lzip archive before extraction: file={temp_file} threads={threads}")
    return DumpRunDiagnosticCommand(
        local,
        "plzip-test",
        ["plzip", "-tvv", f"-n{threads}", temp_file],
        timeout=86400,
    )
#end define


def ExtractDump(local, archive_size, temp_file, dump_dir):
    threads = DumpExtractThreads()
    if UseInteractiveExtractionProgress():
        extract_cmd = 'pv -f -i 60 -p -t -e -r -b -s "$1" "$2" | plzip -d -n"$4" | tar -xC "$3"'
    else:
        extract_cmd = (
            'pv -n -i 60 -s "$1" "$2" '
            '2> >(while IFS= read -r progress; do echo "Dump extraction progress: ${progress}%"; done) '
            '| plzip -d -n"$4" | tar -xC "$3"'
        )
    # Use bash for pipefail and process substitution in log-friendly progress mode.
    result = subprocess.run([
        "bash", "-o", "pipefail", "-c", extract_cmd,
        "extract-dump", str(archive_size), temp_file, dump_dir, str(threads)
    ])
    if result.returncode != 0:
        local.add_log(f"Dump extraction failed with exit code {result.returncode}", "error")
    return result.returncode
#end define
'''


def discover_settings_paths() -> list[Path]:
    paths: list[Path] = []
    spec = importlib.util.find_spec("mytoninstaller.settings")
    if spec and spec.origin:
        paths.append(Path(spec.origin))

    source_path = Path("/usr/src/mytonctrl/mytoninstaller/settings.py")
    if source_path.exists():
        paths.append(source_path)

    unique: list[Path] = []
    for path in paths:
        if path not in unique:
            unique.append(path)
    return unique


def patch_settings(path: Path) -> bool:
    text = path.read_text()
    if PATCH_MARKER in text:
        return False

    start_token = "\ndef DownloadDump(local):"
    end_token = "\ndef FirstMytoncoreSettings(local):"
    try:
        start = text.index(start_token)
        end = text.index(end_token, start)
    except ValueError as exc:
        raise RuntimeError(f"failed to locate dump function block in {path}") from exc

    patched = text[:start] + "\n" + REPLACEMENT + text[end:]
    path.write_text(patched)
    return True


def main() -> int:
    if len(sys.argv) > 1:
        paths = [Path(arg) for arg in sys.argv[1:]]
    else:
        paths = discover_settings_paths()

    if not paths:
        print("mytonctrl dump diagnostics patch: no settings.py path found", file=sys.stderr)
        return 1

    changed = []
    unchanged = []
    for path in paths:
        if not path.exists():
            print(f"mytonctrl dump diagnostics patch: missing {path}", file=sys.stderr)
            return 1
        if patch_settings(path):
            changed.append(str(path))
        else:
            unchanged.append(str(path))

    if changed:
        print("mytonctrl dump diagnostics patch: patched " + ", ".join(changed), flush=True)
    if unchanged:
        print("mytonctrl dump diagnostics patch: already patched " + ", ".join(unchanged), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
