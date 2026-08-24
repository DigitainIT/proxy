#!/usr/bin/env bash
# Build per-client URL JSON files for the current domain.
# Served at /api/game/url-extended/<client> (shared Basic Auth for all clients).

write_client_urls_json() {
  local client="$1"
  local domain="$2"
  local out="${URLS_DIR}/${client}.json"
  local casino_id json

  mkdir -p "${URLS_DIR}"
  chmod 755 "${URLS_DIR}" 2>/dev/null || true

  # Isolate client env (CASINO_ID, HOST_SUFFIX) without leaking into other clients.
  CASINO_ID=""
  HOST_SUFFIX="__default__"
  load_client_env "${client}"
  casino_id="${CASINO_ID:-${client}}"

  # Which naming form this brand answers to. EGT are migrating off "-bgsp" brand
  # by brand, so this has to be settable per client: DN_BAHISBEY routes only via
  # -bgsp, DN_PALACEBET only without it. Set HOST_SUFFIX="" in the client's .env
  # for a brand that has already been migrated.
  # The proxy serves both hostname forms either way; this only decides which one
  # is advertised to the platform.
  local suffix="${HOST_SUFFIX}"
  [[ "${suffix}" == "__default__" ]] && suffix="-bgsp"

  # player-history / tournaments are shared across clients and currently route
  # only via -bgsp for every brand. Override globally in credentials.env once EGT
  # register the bare names.
  local shared_suffix="${SHARED_HOST_SUFFIX--bgsp}"

  json="$(jq -n \
    --arg hostUrl "https://${client}-gc-prod${suffix}.${domain}" \
    --arg apiServerUrl "https://${client}-api-prod${suffix}.${domain}" \
    --arg casinoId "${casino_id}" \
    --arg campaignUrl "https://campaign-prod.${domain}" \
    --arg jackpotContributionUrl "https://timescale-service-prod.${domain}" \
    --arg reconciliationUrl "https://history-service-prod.${domain}" \
    --arg matchHistoryUrl "https://player-history-prod${shared_suffix}.${domain}" \
    --arg tournamentUrl "https://tournaments-prod${shared_suffix}.${domain}" \
    --arg status "OK" \
    '{
      hostUrl: $hostUrl,
      apiServerUrl: $apiServerUrl,
      casinoId: $casinoId,
      campaignUrl: $campaignUrl,
      jackpotContributionUrl: $jackpotContributionUrl,
      reconciliationUrl: $reconciliationUrl,
      matchHistoryUrl: $matchHistoryUrl,
      tournamentUrl: $tournamentUrl,
      status: $status
    }')"

  printf '%s\n' "${json}" >"${out}"
  chmod 644 "${out}"
  log "Wrote client URLs JSON: ${out}"
}

write_current_urls_json() {
  local domain="$1"
  local first=""

  ensure_prefix_files
  [[ ${#CLIENT_NAMES[@]} -gt 0 ]] || discover_clients

  local client
  for client in "${CLIENT_NAMES[@]}"; do
    write_client_urls_json "${client}" "${domain}"
    if [[ -z "${first}" ]]; then
      first="${client}"
    fi
  done

  [[ -n "${first}" ]] || die "No clients available to write URL JSON"

  # Keep current-urls.json as a copy of the first client.
  mkdir -p "$(dirname "${CURRENT_URLS_JSON}")"
  chmod 755 "${PROXIES_STATE}" 2>/dev/null || true
  cp "${URLS_DIR}/${first}.json" "${CURRENT_URLS_JSON}"
  chmod 644 "${CURRENT_URLS_JSON}"
  log "URL API paths: /api/game/url-extended/<client> (clients: ${CLIENT_NAMES[*]})"
}
