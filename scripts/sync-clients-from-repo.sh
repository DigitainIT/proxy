#!/usr/bin/env bash
# Reconcile /etc/proxies/clients/ with the client manifest, then apply if changed.
#
#   sudo /opt/proxies/scripts/sync-clients-from-repo.sh
#   sudo MANIFEST_URL='https://raw.githubusercontent.com/OWNER/REPO/main/clients/clients.tsv' \
#        /opt/proxies/scripts/sync-clients-from-repo.sh
#   sudo /opt/proxies/scripts/sync-clients-from-repo.sh --dry-run
#
# Deliberately fetches only the manifest, never code. An auto-updating proxy that
# runs whatever lands on a branch is a supply-chain problem, and it would re-apply
# the toolkit over local state on every run. Updating the toolkit stays a
# deliberate act.
set -euo pipefail

PROXIES_ROOT="${PROXIES_ROOT:-/opt/proxies}"
PROXIES_ETC="${PROXIES_ETC:-/etc/proxies}"
CLIENTS_DIR="${CLIENTS_DIR:-${PROXIES_ETC}/clients}"
URLS_DIR="${URLS_DIR:-/var/lib/proxies/urls}"
MANIFEST="${MANIFEST:-${PROXIES_ROOT}/clients/clients.tsv}"
MANIFEST_URL="${MANIFEST_URL:-}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log() { printf '[sync-clients] %s\n' "$*"; }
die() { printf '[sync-clients] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 || ${DRY_RUN} -eq 1 ]] || die "run as root"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# ---------------------------------------------------------------- fetch
src="${MANIFEST}"
if [[ -n "${MANIFEST_URL}" ]]; then
    # A failed fetch must abort. Treating an empty or partial download as the
    # desired state would remove every client on the box.
    curl -fsS --max-time 30 -o "${tmp}/manifest" "${MANIFEST_URL}" \
        || die "could not fetch ${MANIFEST_URL} - leaving current clients untouched"
    src="${tmp}/manifest"
fi
[[ -s "${src}" ]] || die "manifest ${src} is missing or empty"

# ---------------------------------------------------------------- parse
declare -a want=()
lineno=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] || continue

    read -r client casino_id suffix enabled _rest <<<"${line}"
    [[ -n "${client}" && -n "${casino_id}" ]] || die "line ${lineno}: need at least client and casino_id"
    [[ "${client}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
        || die "line ${lineno}: '${client}' is not a valid DNS label - it becomes a hostname"

    case "${enabled:-yes}" in
        yes|true|1)  ;;
        no|false|0)  continue ;;
        *) die "line ${lineno}: enabled must be yes or no, got '${enabled}'" ;;
    esac

    case "${suffix:--bgsp}" in
        -bgsp) host_suffix="-bgsp" ;;
        none|"") host_suffix="" ;;
        *) die "line ${lineno}: host_suffix must be '-bgsp' or 'none', got '${suffix}'" ;;
    esac

    {
        printf 'CASINO_ID="%s"\n' "${casino_id}"
        printf 'HOST_SUFFIX="%s"\n' "${host_suffix}"
    } > "${tmp}/${client}.env"
    want+=("${client}")
done < "${src}"

[[ ${#want[@]} -gt 0 ]] || die "manifest enabled no clients - refusing to remove everything"
log "manifest lists ${#want[@]} enabled client(s)"

# ---------------------------------------------------------------- diff
declare -a added=() changed=() removed=()
mkdir -p "${CLIENTS_DIR}"

for c in "${want[@]}"; do
    if [[ ! -f "${CLIENTS_DIR}/${c}.env" ]]; then
        added+=("${c}")
    elif ! cmp -s "${tmp}/${c}.env" "${CLIENTS_DIR}/${c}.env"; then
        changed+=("${c}")
    fi
done

shopt -s nullglob
for f in "${CLIENTS_DIR}"/*.env; do
    name="$(basename "${f}" .env)"
    keep=0
    for c in "${want[@]}"; do [[ "${name}" == "${c}" ]] && { keep=1; break; }; done
    [[ ${keep} -eq 0 ]] && removed+=("${name}")
done
shopt -u nullglob

[[ ${#added[@]}   -gt 0 ]] && log "add:    ${added[*]}"
[[ ${#changed[@]} -gt 0 ]] && log "update: ${changed[*]}"
[[ ${#removed[@]} -gt 0 ]] && log "remove: ${removed[*]}"

if [[ ${#added[@]} -eq 0 && ${#changed[@]} -eq 0 && ${#removed[@]} -eq 0 ]]; then
    log "already in sync, nothing to do"
    exit 0
fi

if [[ ${DRY_RUN} -eq 1 ]]; then
    log "dry run - no changes written"
    exit 0
fi

# ---------------------------------------------------------------- apply
for c in "${want[@]}"; do
    install -m 644 "${tmp}/${c}.env" "${CLIENTS_DIR}/${c}.env"
done

for name in "${removed[@]:-}"; do
    [[ -n "${name}" ]] || continue
    rm -f "${CLIENTS_DIR}/${name}.env"
    # Drop the payload too. manage-clients.sh does not prune these, so a removed
    # client would keep serving stale hostnames from /api/game/url-extended.
    rm -f "${URLS_DIR}/${name}.json"
done

# sync re-renders nginx for every tracked domain, so it only runs on a real change.
"${PROXIES_ROOT}/scripts/manage-clients.sh" sync
log "applied: +${#added[@]} ~${#changed[@]} -${#removed[@]}"
