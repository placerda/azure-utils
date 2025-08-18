#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="${HOME}/.cleanup-nsgs-last"

prompt_context() {
  if [[ -f "${STATE_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
    echo "Last used:"
    echo "  Subscription: ${SUB:-<none>}"
    echo "  ResourceGroup: ${RG:-<none>}"
    read -r -p "Reuse these? [Y/n] " reuse
    reuse=${reuse:-Y}
    case "${reuse,,}" in
      n|no)
        read -r -p "Subscription ID or name: " SUB
        read -r -p "Resource group name: " RG
        ;;
      *) : ;;
    esac
  else
    read -r -p "Subscription ID or name: " SUB
    read -r -p "Resource group name: " RG
  fi
  if [[ -z "${SUB:-}" || -z "${RG:-}" ]]; then
    echo "Subscription and resource group are required."; exit 1
  fi
  printf 'SUB="%s"\nRG="%s"\n' "${SUB}" "${RG}" > "${STATE_FILE}"
}

# --- Helpers ---------------------------------------------------------------

unset_subnet_props() {
  local rg="$1" vnet="$2" subnet="$3"
  echo "   - Clearing associations on subnet ${rg}/${vnet}/${subnet}"
  # Remove NSG, routeTable, NAT, delegations, service endpoints
  az network vnet subnet update -g "${rg}" --vnet-name "${vnet}" -n "${subnet}" \
    --remove networkSecurityGroup >/dev/null || true
  az network vnet subnet update -g "${rg}" --vnet-name "${vnet}" -n "${subnet}" \
    --remove routeTable >/dev/null || true
  az network vnet subnet update -g "${rg}" --vnet-name "${vnet}" -n "${subnet}" \
    --remove natGateway >/dev/null || true
  az network vnet subnet update -g "${rg}" --vnet-name "${vnet}" -n "${subnet}" \
    --remove delegations >/dev/null || true
  az network vnet subnet update -g "${rg}" --vnet-name "${vnet}" -n "${subnet}" \
    --remove serviceEndpoints >/dev/null || true
}

delete_private_endpoints_for_subnet() {
  local subnet_id="$1"
  echo "   - Looking for Private Endpoints on this subnet…"
  mapfile -t PEs < <(az network private-endpoint list \
    --query "[?subnet.id=='${subnet_id}'].{id:id}" -o tsv)
  for pe in "${PEs[@]:-}"; do
    [[ -z "$pe" ]] && continue
    echo "     · Deleting Private Endpoint: ${pe}"
    az resource delete --ids "${pe}" || true
  done
}

delete_service_association_links() {
  local rg="$1" vnet="$2" subnet="$3"
  # Fetch SALs and linked resources
  mapfile -t LINKS < <(az network vnet subnet show -g "${rg}" --vnet-name "${vnet}" -n "${subnet}" \
    --query "serviceAssociationLinks[].link" -o tsv 2>/dev/null || true)
  for ln in "${LINKS[@]:-}"; do
    [[ -z "$ln" ]] && continue
    echo "   - Deleting SAL-linked resource: ${ln}"
    az resource delete --ids "${ln}" || true
  done
}

broad_disassociate_nsg() {
  local NSG_ID="$1"
  echo ">> Broad disassociation across subscription for NSG: ${NSG_ID}"

  # NICs anywhere
  mapfile -t NICS < <(az network nic list \
    --query "[?networkSecurityGroup && networkSecurityGroup.id=='${NSG_ID}'].{rg:resourceGroup,name:name}" -o tsv)
  for entry in "${NICS[@]:-}"; do
    [[ -z "${entry}" ]] && continue
    local RG_NIC NIC_NAME
    RG_NIC="$(cut -f1 <<< "${entry}")"
    NIC_NAME="$(cut -f2 <<< "${entry}")"
    echo "   - Removing NSG from NIC ${RG_NIC}/${NIC_NAME}"
    az network nic update -g "${RG_NIC}" -n "${NIC_NAME}" --remove networkSecurityGroup >/dev/null || true
  done

  # Subnets anywhere
  mapfile -t VNETS < <(az network vnet list --query "[].{rg:resourceGroup,name:name}" -o tsv)
  for v in "${VNETS[@]:-}"; do
    [[ -z "${v}" ]] && continue
    local VNET_RG VNET_NAME
    VNET_RG="$(cut -f1 <<< "${v}")"
    VNET_NAME="$(cut -f2 <<< "${v}")"
    mapfile -t SUBS < <(az network vnet subnet list -g "${VNET_RG}" --vnet-name "${VNET_NAME}" \
      --query "[?networkSecurityGroup && networkSecurityGroup.id=='${NSG_ID}'].name" -o tsv)
    for S in "${SUBS[@]:-}"; do
      [[ -z "${S}" ]] && continue
      echo "   - Disassociating NSG from subnet ${VNET_RG}/${VNET_NAME}/${S}"
      az network vnet subnet update -g "${VNET_RG}" --vnet-name "${VNET_NAME}" -n "${S}" \
        --remove networkSecurityGroup >/dev/null || true
    done
  done
}

break_vnet_blockers_in_rg() {
  local rg="$1"
  echo ">> Breaking VNet/Subnet blockers in '${rg}'…"
  mapfile -t VNETS_IN_RG < <(az network vnet list -g "${rg}" --query "[].name" -o tsv)
  for VNET in "${VNETS_IN_RG[@]:-}"; do
    [[ -z "${VNET}" ]] && continue
    mapfile -t SUBNETS < <(az network vnet subnet list -g "${rg}" --vnet-name "${VNET}" --query "[].name" -o tsv)
    for S in "${SUBNETS[@]:-}"; do
      [[ -z "${S}" ]] && continue
      unset_subnet_props "${rg}" "${VNET}" "${S}"
      # Build subnet id for searches
      SUBNET_ID="/subscriptions/$(az account show --query id -o tsv)/resourceGroups/${rg}/providers/Microsoft.Network/virtualNetworks/${VNET}/subnets/${S}"
      delete_private_endpoints_for_subnet "${SUBNET_ID}"
      delete_service_association_links "${rg}" "${VNET}" "${S}"
    done
  done
}

# --- Main ------------------------------------------------------------------

main() {
  prompt_context

  echo ">> Using subscription: ${SUB}"
  az account set --subscription "${SUB}"

  echo ">> Verifying resource group '${RG}' exists…"
  az group show -n "${RG}" >/dev/null

  echo ">> Removing locks in RG (if any)…"
  for LOCK_ID in $(az lock list --resource-group "${RG}" --query "[].id" -o tsv || true); do
    az lock delete --ids "${LOCK_ID}" || true
  done

  echo ">> Enumerating NSGs in '${RG}'…"
  mapfile -t NSG_IDS < <(az network nsg list -g "${RG}" --query "[].id" -o tsv)

  for NSG_ID in "${NSG_IDS[@]:-}"; do
    [[ -z "${NSG_ID}" ]] && continue
    NSG_NAME="${NSG_ID##*/}"
    echo ">> Processing NSG: ${NSG_NAME}"

    # Disassociate from NICs in this RG
    mapfile -t RG_NICS < <(az network nic list -g "${RG}" \
      --query "[?networkSecurityGroup && networkSecurityGroup.id=='${NSG_ID}'].name" -o tsv)
    for NIC in "${RG_NICS[@]:-}"; do
      [[ -z "${NIC}" ]] && continue
      echo "   - Removing NSG from NIC ${RG}/${NIC}"
      az network nic update -g "${RG}" -n "${NIC}" --remove networkSecurityGroup >/dev/null || true
    done

    # Disassociate from subnets in VNets of this RG
    mapfile -t VNETS_IN_RG < <(az network vnet list -g "${RG}" --query "[].name" -o tsv)
    for VNET in "${VNETS_IN_RG[@]:-}"; do
      [[ -z "${VNET}" ]] && continue
      mapfile -t SUBS < <(az network vnet subnet list -g "${RG}" --vnet-name "${VNET}" \
        --query "[?networkSecurityGroup && networkSecurityGroup.id=='${NSG_ID}'].name" -o tsv)
      for S in "${SUBS[@]:-}"; do
        [[ -z "${S}" ]] && continue
        echo "   - Disassociating NSG from subnet ${RG}/${VNET}/${S}"
        az network vnet subnet update -g "${RG}" --vnet-name "${VNET}" -n "${S}" \
          --remove networkSecurityGroup >/dev/null || true
      done
    done

    # Try delete; if fails, broaden search and retry
    if ! az network nsg delete --ids "${NSG_ID}"; then
      echo "!! NSG delete failed; performing broad disassociation & retrying…"
      broad_disassociate_nsg "${NSG_ID}"
      az network nsg delete --ids "${NSG_ID}" || true
    fi
  done

  # Break VNet blockers before we try to delete the RG
  break_vnet_blockers_in_rg "${RG}"

  echo ">> Final lock cleanup at RG level…"
  for LOCK_ID in $(az lock list --resource-group "${RG}" --query "[].id" -o tsv || true); do
    az lock delete --ids "${LOCK_ID}" || true
  done

  echo
  read -r -p "About to DELETE resource group '${RG}'. Are you sure? [y/N] " sure
  if [[ "${sure,,}" != "y" && "${sure,,}" != "yes" ]]; then
    echo "Aborted before deleting the resource group."
    exit 0
  fi

  echo ">> Deleting resource group '${RG}'…"
  az group delete -n "${RG}" --yes
  echo "✅ Done."
}

main "$@"
