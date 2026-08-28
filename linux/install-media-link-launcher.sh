#!/usr/bin/env bash
set -Eeuo pipefail

PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin'
export PATH
umask 077

readonly VERSION='0.2.0'
readonly PROJECT_ID='media-link-launcher'
readonly DESKTOP_ID='media-link-launcher.desktop'
readonly MIME_TYPE='x-scheme-handler/media-link-launcher'
readonly OLD_DESKTOP_ID='vlc-url-handler.desktop'
readonly OLD_MIME_TYPE='x-scheme-handler/vlc'
readonly OLD_HANDLER_TEMPLATE_SHA256='dab4bfe56328f7555bdaa03834673f1c3cc7cb9ea0f296adf3d9884fc1d0cc15'

program_name="${0##*/}"
operation='install'
if (($# > 1)); then
    printf 'Usage: %s [--uninstall]\n' "$program_name" >&2
    exit 2
elif (($# == 1)); then
    if [[ "$1" != '--uninstall' ]]; then
        printf 'Usage: %s [--uninstall]\n' "$program_name" >&2
        exit 2
    fi
    operation='uninstall'
fi

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

if ((EUID == 0)); then
    fail 'Do not run this per-user installer as root or with sudo.'
fi

validate_absolute_directory_setting() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" || "$value" != /* || "$value" =~ [[:cntrl:]] ]]; then
        fail "${name} must be a nonempty absolute path without control characters."
    fi
}

validate_absolute_directory_setting 'HOME' "${HOME:-}"

readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly handler_template="${script_dir}/media-link-launcher.py"
readonly desktop_template="${script_dir}/media-link-launcher.desktop.in"
readonly repository_root="$(cd -- "${script_dir}/.." && pwd -P)"
readonly repository_userscript="${repository_root}/userscript/media-link-launcher.user.js"
license_source="${script_dir}/LICENSE.md"
disclaimer_source="${script_dir}/DISCLAIMER.md"
if [[ "${script_dir##*/}" == 'linux' && -f "$repository_userscript" && ! -L "$repository_userscript" ]]; then
    if [[ ! -f "$license_source" && ! -L "$license_source" ]]; then
        license_source="${repository_root}/LICENSE.md"
    fi
    if [[ ! -f "$disclaimer_source" && ! -L "$disclaimer_source" ]]; then
        disclaimer_source="${repository_root}/DISCLAIMER.md"
    fi
fi
readonly license_source disclaimer_source

readonly bin_dir="${HOME}/.local/bin"
readonly data_root="${XDG_DATA_HOME:-${HOME}/.local/share}"
readonly app_dir="${data_root}/applications"
readonly config_root="${XDG_CONFIG_HOME:-${HOME}/.config}"
readonly state_root="${XDG_STATE_HOME:-${HOME}/.local/state}"
readonly config_dir="${config_root}/${PROJECT_ID}"
readonly state_dir="${state_root}/${PROJECT_ID}"
readonly backups_root="${state_dir}/backups"

validate_absolute_directory_setting 'XDG_DATA_HOME' "$data_root"
validate_absolute_directory_setting 'XDG_CONFIG_HOME' "$config_root"
validate_absolute_directory_setting 'XDG_STATE_HOME' "$state_root"

readonly handler="${bin_dir}/${PROJECT_ID}"
readonly desktop="${app_dir}/${DESKTOP_ID}"
readonly schemes_config="${config_dir}/allowed-schemes"
readonly logging_config="${config_dir}/logging"
readonly previous_handler_file="${state_dir}/previous-handler"
readonly manifest_file="${state_dir}/install-manifest"

readonly old_handler="${bin_dir}/vlc-url-handler"
readonly old_desktop="${app_dir}/${OLD_DESKTOP_ID}"
readonly old_config_dir="${config_root}/vlc-url-handler"
readonly old_state_dir="${state_root}/vlc-url-handler"
readonly old_previous_handler_file="${old_state_dir}/previous-handler"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_dir=''
tmp_handler=''
tmp_desktop=''
tmp_config=''
tmp_logging=''
tmp_previous=''
tmp_manifest=''

cleanup() {
    local path
    for path in "$tmp_handler" "$tmp_desktop" "$tmp_config" "$tmp_logging" "$tmp_previous" "$tmp_manifest"; do
        if [[ -n "$path" && -e "$path" && ! -L "$path" ]]; then
            rm -f -- "$path"
        fi
    done
}
trap cleanup EXIT

resolve_program() {
    local name="$1"
    local candidate
    local resolved
    candidate="$(type -P -- "$name" || true)"
    if [[ -z "$candidate" || "$candidate" != /* ]]; then
        fail "Required executable was not found in the fixed system PATH: ${name}"
    fi
    resolved="$(readlink -f -- "$candidate")"
    if [[ -z "$resolved" || ! -f "$resolved" || ! -x "$resolved" ]]; then
        fail "Required executable is not a regular executable: ${name}"
    fi
    printf '%s\n' "$candidate"
}

for required_command in bash chmod cp cut date install mktemp mv python3 readlink rm sed sha256sum stat; do
    resolve_program "$required_command" >/dev/null
done

readonly python_path="$(resolve_program python3)"
xdg_mime_path="$(type -P -- xdg-mime || true)"
gio_path="$(type -P -- gio || true)"
if [[ -z "$xdg_mime_path" && -z "$gio_path" ]]; then
    fail 'Either xdg-mime or gio is required to manage the per-user protocol association.'
fi
readonly xdg_mime_path gio_path

ensure_safe_regular_path() {
    local path="$1"
    if [[ -L "$path" ]]; then
        fail "Refusing symbolic-link path: ${path}"
    fi
    if [[ -e "$path" && ! -f "$path" ]]; then
        fail "Expected a regular file: ${path}"
    fi
}

ensure_directory() {
    local path="$1"
    local mode="$2"
    local private="${3:-false}"
    if [[ -L "$path" ]]; then
        fail "Refusing symbolic-link directory: ${path}"
    fi
    if [[ -e "$path" && ! -d "$path" ]]; then
        fail "Expected a directory: ${path}"
    fi
    if [[ ! -e "$path" ]]; then
        install -d -m "$mode" -- "$path"
    elif [[ "$private" == 'true' ]]; then
        if [[ "$(stat -c '%u' -- "$path")" != "$EUID" || "$(stat -c '%a' -- "$path")" != "$mode" ]]; then
            fail "Private directory must be owned by you and mode ${mode}: ${path}"
        fi
    fi
}

ensure_private_file() {
    local path="$1"
    ensure_safe_regular_path "$path"
    if [[ -e "$path" ]]; then
        if [[ "$(stat -c '%u' -- "$path")" != "$EUID" || "$(stat -c '%a' -- "$path")" != '600' ]]; then
            fail "Private file must be owned by you and mode 0600: ${path}"
        fi
    fi
}

ensure_private_layout() {
    ensure_directory "$bin_dir" '755'
    ensure_directory "$app_dir" '755'
    ensure_directory "$config_dir" '700' 'true'
    ensure_directory "$state_dir" '700' 'true'
    ensure_directory "$backups_root" '700' 'true'
}

create_backup_directory() {
    if [[ -z "$backup_dir" ]]; then
        backup_dir="$(mktemp -d "${backups_root}/${operation}-${timestamp}-XXXXXX")"
        chmod 0700 -- "$backup_dir"
    fi
}

backup_file() {
    local path="$1"
    local backup_name="$2"
    ensure_safe_regular_path "$path"
    if [[ ! -e "$path" ]]; then
        return
    fi
    create_backup_directory
    cp --archive --preserve=all --no-clobber -- "$path" "${backup_dir}/${backup_name}"
}

backup_mimeapps_files() {
    backup_file "${config_root}/mimeapps.list" 'config-mimeapps.list'
    backup_file "${app_dir}/mimeapps.list" 'applications-mimeapps.list'
}

query_default_handler() {
    local mime_type="$1"
    local output
    local first_line
    if [[ -n "$xdg_mime_path" ]]; then
        "$xdg_mime_path" query default "$mime_type" 2>/dev/null || true
        return
    fi
    output="$(LC_ALL=C "$gio_path" mime "$mime_type" 2>/dev/null || true)"
    first_line="${output%%$'\n'*}"
    if [[ "$first_line" == *': '* ]]; then
        printf '%s\n' "${first_line##*: }"
    fi
}

set_default_handler() {
    local desktop_id="$1"
    local mime_type="$2"
    if [[ ! "$desktop_id" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        fail 'Refusing an unsafe desktop-file identifier.'
    fi
    if [[ -n "$xdg_mime_path" ]]; then
        "$xdg_mime_path" default "$desktop_id" "$mime_type"
    else
        "$gio_path" mime "$mime_type" "$desktop_id" >/dev/null
    fi
}

remove_association_from_file() {
    local path="$1"
    local mime_type="$2"
    local desktop_id="$3"
    if [[ ! -e "$path" ]]; then
        return
    fi
    ensure_safe_regular_path "$path"
    "$python_path" - "$path" "$mime_type" "$desktop_id" <<'PYTHON'
import os
import pathlib
import shutil
import stat
import sys
import tempfile

path = pathlib.Path(sys.argv[1])
mime_type = sys.argv[2]
desktop_id = sys.argv[3]
metadata = path.stat()
lines = path.read_text(encoding="utf-8", errors="strict").splitlines(keepends=True)
section = ""
result = []

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        section = stripped[1:-1]
        result.append(line)
        continue
    if section != "Default Applications" or "=" not in line:
        result.append(line)
        continue
    key, value = line.split("=", 1)
    if key.strip() != mime_type:
        result.append(line)
        continue
    applications = [item for item in value.strip().split(";") if item]
    filtered = [item for item in applications if item != desktop_id]
    if filtered:
        newline = "\n" if line.endswith("\n") else ""
        result.append(f"{key}={';'.join(filtered)};{newline}")

if result == lines:
    raise SystemExit(0)

fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.tmp.", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.writelines(result)
        handle.flush()
        os.fsync(handle.fileno())
    shutil.copystat(path, temporary_name, follow_symlinks=False)
    for attribute in os.listxattr(path, follow_symlinks=False):
        os.setxattr(
            temporary_name,
            attribute,
            os.getxattr(path, attribute, follow_symlinks=False),
            follow_symlinks=False,
        )
    os.chmod(temporary_name, stat.S_IMODE(metadata.st_mode))
    os.replace(temporary_name, path)
finally:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
PYTHON
}

remove_default_association() {
    local mime_type="$1"
    local desktop_id="$2"
    remove_association_from_file "${config_root}/mimeapps.list" "$mime_type" "$desktop_id"
    remove_association_from_file "${app_dir}/mimeapps.list" "$mime_type" "$desktop_id"
}

validate_previous_handler_record() {
    local path="$1"
    local value
    ensure_private_file "$path"
    if [[ ! -e "$path" ]]; then
        printf 'NONE\n'
        return
    fi
    value="$(<"$path")"
    if [[ "$value" != 'NONE' && ! "$value" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        fail "Recorded previous handler is unsafe: ${path}"
    fi
    printf '%s\n' "$value"
}

write_default_configuration() {
    ensure_private_file "$schemes_config"
    ensure_private_file "$logging_config"
    if [[ ! -e "$schemes_config" ]]; then
        tmp_config="$(mktemp "${config_dir}/.allowed-schemes.tmp.XXXXXX")"
        printf '%s\n' '# One target protocol per line. Optional protocols require explicit review.' 'http' 'https' >"$tmp_config"
        chmod 0600 -- "$tmp_config"
        mv -T -- "$tmp_config" "$schemes_config"
        tmp_config=''
    fi
    if [[ ! -e "$logging_config" ]]; then
        tmp_logging="$(mktemp "${config_dir}/.logging.tmp.XXXXXX")"
        printf '%s\n' '# Set to enabled only if you want persistent redacted event logging.' 'disabled' >"$tmp_logging"
        chmod 0600 -- "$tmp_logging"
        mv -T -- "$tmp_logging" "$logging_config"
        tmp_logging=''
    fi
}

is_new_handler_marker() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    "$python_path" - "$path" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict")
markers = (
    'PROJECT_ID = "media-link-launcher"',
    'PROTOCOL_SCHEME = "media-link-launcher"',
    'def decode_invocation(',
    '[str(executable), "--", target.raw]',
)
raise SystemExit(0 if all(marker in source for marker in markers) else 1)
PYTHON
}

is_new_desktop_marker() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    "$python_path" - "$path" "$handler" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="strict")
handler = sys.argv[2]
escaped = (
    handler.replace("\\", "\\\\")
    .replace('"', '\\"')
    .replace('`', '\\`')
    .replace('$', '\\$')
    .replace('%', '%%')
)
required = {
    "Type": "Application",
    "Name": "Media Link Launcher",
    "Exec": f'"{escaped}" %u',
    "MimeType": "x-scheme-handler/media-link-launcher;",
    "X-Media-Link-Launcher-ID": "media-link-launcher",
}
values = {}
for line in source.splitlines():
    if "=" in line and not line.startswith("#"):
        key, value = line.split("=", 1)
        values[key] = value
raise SystemExit(0 if all(values.get(key) == value for key, value in required.items()) else 1)
PYTHON
}

manifest_is_valid() {
    [[ -f "$manifest_file" && ! -L "$manifest_file" ]] || return 1
    ensure_private_file "$manifest_file"
    [[ "$(sed -n '1p' "$manifest_file")" == 'media-link-launcher-manifest-v1' ]]
}

manifest_hash() {
    local key="$1"
    sed -n "s/^${key}=//p" "$manifest_file"
}

file_hash_matches_manifest() {
    local path="$1"
    local key="$2"
    local expected
    [[ -f "$path" && ! -L "$path" ]] || return 1
    manifest_is_valid || return 1
    expected="$(manifest_hash "$key")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$(sha256sum "$path" | cut -d' ' -f1)" == "$expected" ]]
}

preflight_new_destinations() {
    local current
    ensure_safe_regular_path "$handler"
    ensure_safe_regular_path "$desktop"
    ensure_private_file "$manifest_file"

    if manifest_is_valid; then
        if [[ -e "$handler" ]] && ! file_hash_matches_manifest "$handler" 'handler_sha256'; then
            fail "Installed handler differs from its manifest; refusing to overwrite it: ${handler}"
        fi
        if [[ -e "$desktop" ]] && ! file_hash_matches_manifest "$desktop" 'desktop_sha256'; then
            fail "Installed desktop file differs from its manifest; refusing to overwrite it: ${desktop}"
        fi
    else
        if [[ -e "$handler" ]] && ! is_new_handler_marker "$handler"; then
            fail "Refusing to overwrite an unrelated handler: ${handler}"
        fi
        if [[ -e "$desktop" ]] && ! is_new_desktop_marker "$desktop"; then
            fail "Refusing to overwrite an unrelated desktop file: ${desktop}"
        fi
    fi

    current="$(query_default_handler "$MIME_TYPE")"
    if [[ -n "$current" && "$current" != "$DESKTOP_ID" ]]; then
        fail "The ${MIME_TYPE} association already belongs to ${current}; refusing to replace it."
    fi
}

prepare_install_files() {
    local vlc_path="$1"
    if [[ ! -f "$handler_template" || -L "$handler_template" ]]; then
        fail "Missing or unsafe handler template: ${handler_template}"
    fi
    if [[ ! -f "$desktop_template" || -L "$desktop_template" ]]; then
        fail "Missing or unsafe desktop template: ${desktop_template}"
    fi

    tmp_handler="$(mktemp "${bin_dir}/.${PROJECT_ID}.tmp.XXXXXX")"
    tmp_desktop="$(mktemp "${app_dir}/.${DESKTOP_ID}.tmp.XXXXXX")"
    cp -- "$handler_template" "$tmp_handler"
    cp -- "$desktop_template" "$tmp_desktop"

    "$python_path" - "$tmp_handler" "$tmp_desktop" "$python_path" "$vlc_path" "$handler" <<'PYTHON'
import pathlib
import sys

handler_path = pathlib.Path(sys.argv[1])
desktop_path = pathlib.Path(sys.argv[2])
python_path = sys.argv[3]
vlc_path = sys.argv[4]
installed_handler = sys.argv[5]

source = handler_path.read_text(encoding="utf-8")
source = source.replace("#!/usr/bin/env python3", f"#!{python_path}", 1)
source = source.replace('"__VLC_EXECUTABLE__"', repr(vlc_path), 1)
if "__VLC_EXECUTABLE__" in source or not source.startswith(f"#!{python_path}\n"):
    raise SystemExit("Handler template substitution failed.")
compile(source, str(handler_path), "exec")
handler_path.write_text(source, encoding="utf-8")

escaped = (
    installed_handler.replace("\\", "\\\\")
    .replace('"', '\\"')
    .replace('`', '\\`')
    .replace('$', '\\$')
    .replace('%', '%%')
)
desktop_source = desktop_path.read_text(encoding="utf-8")
if desktop_source.count("@HANDLER_EXEC@") != 1:
    raise SystemExit("Desktop template substitution failed.")
desktop_path.write_text(desktop_source.replace("@HANDLER_EXEC@", escaped), encoding="utf-8")
PYTHON
    chmod 0755 -- "$tmp_handler"
    chmod 0644 -- "$tmp_desktop"
}

write_manifest() {
    local handler_hash="$1"
    local desktop_hash="$2"
    tmp_manifest="$(mktemp "${state_dir}/.install-manifest.tmp.XXXXXX")"
    printf '%s\n' \
        'media-link-launcher-manifest-v1' \
        "version=${VERSION}" \
        "handler_sha256=${handler_hash}" \
        "desktop_sha256=${desktop_hash}" >"$tmp_manifest"
    chmod 0600 -- "$tmp_manifest"
    mv -T -- "$tmp_manifest" "$manifest_file"
    tmp_manifest=''
}

old_handler_is_v010() {
    [[ -f "$old_handler" && ! -L "$old_handler" ]] || return 1
    "$python_path" - "$old_handler" "$OLD_HANDLER_TEMPLATE_SHA256" <<'PYTHON'
import hashlib
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
source = path.read_text(encoding="utf-8", errors="strict")
lines = source.splitlines(keepends=True)
if not lines:
    raise SystemExit(1)
lines[0] = "#!/usr/bin/env python3\n"
matches = 0
for index, line in enumerate(lines):
    if re.fullmatch(r"VLC_EXECUTABLE = .+\n", line):
        lines[index] = 'VLC_EXECUTABLE = "__VLC_EXECUTABLE__"\n'
        matches += 1
normalized = "".join(lines).encode("utf-8")
raise SystemExit(0 if matches == 1 and hashlib.sha256(normalized).hexdigest() == expected else 1)
PYTHON
}

old_desktop_is_v010() {
    [[ -f "$old_desktop" && ! -L "$old_desktop" ]] || return 1
    "$python_path" - "$old_desktop" "$old_handler" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
handler = sys.argv[2]
escaped = (
    handler.replace("\\", "\\\\")
    .replace('"', '\\"')
    .replace('`', '\\`')
    .replace('$', '\\$')
)
expected = "\n".join(
    (
        "[Desktop Entry]",
        "Type=Application",
        "Name=VLC URL Handler",
        "Comment=Confirm and open validated web media URLs in VLC",
        f'Exec="{escaped}" %u',
        "Terminal=false",
        "NoDisplay=true",
        "MimeType=x-scheme-handler/vlc;",
        "Categories=AudioVideo;Player;",
        "",
    )
)
raise SystemExit(0 if path.read_text(encoding="utf-8", errors="strict") == expected else 1)
PYTHON
}

migrate_v010_if_owned() {
    local current_old
    local old_previous='NONE'
    local handler_present='false'
    local desktop_present='false'

    [[ -e "$old_handler" || -L "$old_handler" ]] && handler_present='true'
    [[ -e "$old_desktop" || -L "$old_desktop" ]] && desktop_present='true'
    if [[ "$handler_present" == 'false' && "$desktop_present" == 'false' ]]; then
        printf 'Migration: no 0.1.0 operational files were found.\n'
        return
    fi

    if ! old_handler_is_v010 || ! old_desktop_is_v010; then
        printf 'Migration: legacy-looking files were found but did not exactly match this project\047s 0.1.0 files.\n'
        printf 'Migration: retained all old files and the old protocol association unchanged.\n'
        return
    fi

    backup_file "$old_handler" 'v0.1.0-vlc-url-handler'
    backup_file "$old_desktop" 'v0.1.0-vlc-url-handler.desktop'
    backup_mimeapps_files

    current_old="$(query_default_handler "$OLD_MIME_TYPE")"
    if [[ "$current_old" == "$OLD_DESKTOP_ID" ]]; then
        remove_default_association "$OLD_MIME_TYPE" "$OLD_DESKTOP_ID"
        if [[ -e "$old_previous_handler_file" && ! -L "$old_previous_handler_file" ]]; then
            if [[ "$(stat -c '%u' -- "$old_previous_handler_file")" == "$EUID" && "$(stat -c '%a' -- "$old_previous_handler_file")" == '600' ]]; then
                old_previous="$(<"$old_previous_handler_file")"
                if [[ "$old_previous" != 'NONE' && ! "$old_previous" =~ ^[A-Za-z0-9._+-]+$ ]]; then
                    old_previous='NONE'
                fi
            fi
        fi
        if [[ "$old_previous" != 'NONE' ]]; then
            set_default_handler "$old_previous" "$OLD_MIME_TYPE"
            printf 'Migration: restored the previously recorded old-scheme handler %s.\n' "$old_previous"
        else
            printf 'Migration: removed only the verified project-owned old default association; no safe prior default was available.\n'
        fi
    else
        printf 'Migration: the old default association is not this project (%s); it was left unchanged.\n' "${current_old:-none}"
    fi

    rm -- "$old_handler" "$old_desktop"
    printf 'Migration: backed up and removed the verified 0.1.0 handler and desktop file.\n'
    printf 'Migration: retained legacy configuration, state, logs, and backups under %s and %s.\n' "$old_config_dir" "$old_state_dir"
}

record_previous_new_handler() {
    local previous
    ensure_private_file "$previous_handler_file"
    if [[ -e "$previous_handler_file" ]]; then
        validate_previous_handler_record "$previous_handler_file" >/dev/null
        return
    fi
    previous="$(query_default_handler "$MIME_TYPE")"
    if [[ -z "$previous" || "$previous" == "$DESKTOP_ID" ]]; then
        previous='NONE'
    elif [[ ! "$previous" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        fail 'The existing protocol association has an unsafe desktop-file identifier.'
    fi
    tmp_previous="$(mktemp "${state_dir}/.previous-handler.tmp.XXXXXX")"
    printf '%s\n' "$previous" >"$tmp_previous"
    chmod 0600 -- "$tmp_previous"
    mv -T -- "$tmp_previous" "$previous_handler_file"
    tmp_previous=''
}

update_desktop_database_if_available() {
    local executable
    executable="$(type -P -- update-desktop-database || true)"
    if [[ -n "$executable" ]]; then
        "$executable" "$app_dir"
    fi
}

install_handler() {
    local vlc_path
    local handler_hash
    local desktop_hash
    local registered

    if [[ ! -f "$handler_template" || -L "$handler_template" ]]; then
        fail "Missing or unsafe handler template: ${handler_template}"
    fi
    if [[ ! -f "$desktop_template" || -L "$desktop_template" ]]; then
        fail "Missing or unsafe desktop template: ${desktop_template}"
    fi
    if [[ ! -f "$license_source" || -L "$license_source" ]]; then
        fail "Missing or unsafe license file: ${license_source}"
    fi
    if [[ ! -f "$disclaimer_source" || -L "$disclaimer_source" ]]; then
        fail "Missing or unsafe disclaimer file: ${disclaimer_source}"
    fi
    preflight_new_destinations
    vlc_path="$(resolve_program vlc)"
    ensure_private_layout
    create_backup_directory
    write_default_configuration
    record_previous_new_handler
    prepare_install_files "$vlc_path"

    handler_hash="$(sha256sum "$tmp_handler" | cut -d' ' -f1)"
    desktop_hash="$(sha256sum "$tmp_desktop" | cut -d' ' -f1)"
    backup_file "$handler" 'media-link-launcher'
    backup_file "$desktop" 'media-link-launcher.desktop'
    backup_file "$manifest_file" 'install-manifest'
    backup_mimeapps_files

    migrate_v010_if_owned

    mv -T -- "$tmp_handler" "$handler"
    tmp_handler=''
    mv -T -- "$tmp_desktop" "$desktop"
    tmp_desktop=''
    write_manifest "$handler_hash" "$desktop_hash"
    update_desktop_database_if_available
    set_default_handler "$DESKTOP_ID" "$MIME_TYPE"

    registered="$(query_default_handler "$MIME_TYPE")"
    if [[ "$registered" != "$DESKTOP_ID" ]]; then
        fail 'The files were installed, but protocol association verification failed. Re-run the installer after checking xdg-mime or gio.'
    fi

    printf '\nInstalled Media Link Launcher %s:\n  %s\n  %s\n' "$VERSION" "$handler" "$desktop"
    printf 'Registered: %s -> %s\n' "$MIME_TYPE" "$DESKTOP_ID"
    printf 'Allowed target protocols: %s\n' "$schemes_config"
    printf 'Persistent logging: disabled by default (%s)\n' "$logging_config"
    printf 'Backups: %s\n' "$backup_dir"
    printf 'Uninstall: bash %s --uninstall\n' "${script_dir}/install-media-link-launcher.sh"
}

uninstall_handler() {
    local current
    local previous='NONE'
    local handler_owned='false'
    local desktop_owned='false'
    local valid_manifest='false'
    local found_any='false'

    [[ -e "$handler" || -e "$desktop" || -e "$manifest_file" ]] && found_any='true'
    current="$(query_default_handler "$MIME_TYPE")"
    [[ "$current" == "$DESKTOP_ID" ]] && found_any='true'
    if [[ "$found_any" == 'false' ]]; then
        printf 'Media Link Launcher is already absent. No files or associations were changed.\n'
        return
    fi

    ensure_private_layout
    create_backup_directory
    if manifest_is_valid; then
        valid_manifest='true'
        file_hash_matches_manifest "$handler" 'handler_sha256' && handler_owned='true'
        file_hash_matches_manifest "$desktop" 'desktop_sha256' && desktop_owned='true'
    else
        is_new_handler_marker "$handler" && handler_owned='true'
        is_new_desktop_marker "$desktop" && desktop_owned='true'
    fi

    if [[ -e "$handler" && "$handler_owned" != 'true' ]]; then
        printf 'Uninstall: retained unverified or modified handler: %s\n' "$handler"
    fi
    if [[ -e "$desktop" && "$desktop_owned" != 'true' ]]; then
        printf 'Uninstall: retained unverified or modified desktop file: %s\n' "$desktop"
    fi

    [[ "$handler_owned" == 'true' ]] && backup_file "$handler" 'media-link-launcher'
    [[ "$desktop_owned" == 'true' ]] && backup_file "$desktop" 'media-link-launcher.desktop'
    [[ "$valid_manifest" == 'true' ]] && backup_file "$manifest_file" 'install-manifest'
    backup_file "$previous_handler_file" 'previous-handler'
    backup_mimeapps_files

    if [[ "$current" == "$DESKTOP_ID" && ( "$desktop_owned" == 'true' || "$valid_manifest" == 'true' ) ]]; then
        remove_default_association "$MIME_TYPE" "$DESKTOP_ID"
        previous="$(validate_previous_handler_record "$previous_handler_file")"
        if [[ "$previous" != 'NONE' ]]; then
            set_default_handler "$previous" "$MIME_TYPE"
            printf 'Uninstall: restored previous protocol handler %s.\n' "$previous"
        else
            printf 'Uninstall: removed only this project\047s protocol default; no prior handler was recorded.\n'
        fi
    elif [[ "$current" == "$DESKTOP_ID" ]]; then
        printf 'Uninstall: retained the protocol association because file ownership could not be verified.\n'
    else
        printf 'Uninstall: current protocol association is %s and was left unchanged.\n' "${current:-none}"
    fi

    [[ "$handler_owned" == 'true' ]] && rm -- "$handler"
    [[ "$desktop_owned" == 'true' ]] && rm -- "$desktop"
    if [[ "$valid_manifest" == 'true' && ! -e "$handler" && ! -e "$desktop" ]]; then
        rm -- "$manifest_file"
    fi
    update_desktop_database_if_available

    printf 'Uninstall backup: %s\n' "$backup_dir"
    printf 'Configuration, optional logs, legacy state, and all earlier backups were retained.\n'
    printf 'Remove or disable "Media Link Launcher" separately in Tampermonkey.\n'
}

if [[ "$operation" == 'uninstall' ]]; then
    uninstall_handler
else
    install_handler
fi
