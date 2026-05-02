#!/bin/bash
# VM TemplateからVMを作成するスクリプト
# ./deploy.sh <TEMPLATE_VM_ID|select> <VM_ID|auto> <VM_NAME> <GITHUB_ACCOUNT> <PASSWORD> <NETWORK> [<VLAN_TAG>]

set -uo pipefail

# Check arguments and show usage
if [ "$#" -lt 6 ]; then
  echo "Invalid number of arguments"
  echo "Usage: ./deploy.sh <TEMPLATE_VM_ID|select> <VM_ID|auto> <VM_NAME> <GITHUB_ACCOUNT> <PASSWORD> <NETWORK> [<VLAN_TAG>]"
  echo ""
  echo "Examples:"
  echo "  ./deploy.sh 9000 100 test csenet password123 ip=192.168.200.10/24,gw=192.168.200.1 200"
  echo "  ./deploy.sh select auto test csenet password123 ip=192.168.200.10/24,gw=192.168.200.1"
  echo "  ./deploy.sh 9000 auto test csenet password123 ip=192.168.200.10/24,gw=192.168.200.1"
  exit 1
fi

TEMPLATE_VM_ID=$1
VM_ID=$2
VM_NAME=$3
GITHUB_ACCOUNT=$4
PASSWORD=$5
NETWORK=$6
VLAN_TAG=${7:-}

handle_error() {
  echo "エラーが発生しました: $1" >&2
  exit 1
}

# テンプレート対話選択
select_template() {
  echo "利用可能なテンプレート一覧:" >&2
  local templates=()
  while IFS= read -r line; do
    local id name
    id=$(echo "${line}" | awk '{print $1}')
    name=$(echo "${line}" | awk '{print $2}')
    if qm config "${id}" 2>/dev/null | grep -q "^template: 1"; then
      templates+=("${id}|${name}")
    fi
  done < <(qm list 2>/dev/null | awk 'NR>1')

  if [ "${#templates[@]}" -eq 0 ]; then
    echo "テンプレートが見つかりません" >&2
    return 1
  fi
  local i=1
  for t in "${templates[@]}"; do
    local tid tname
    tid="${t%%|*}"
    tname="${t##*|}"
    echo "  [${i}] VM ID ${tid} - ${tname}" >&2
    i=$((i+1))
  done
  local choice
  while true; do
    read -r -p "番号を選択してください [1-${#templates[@]}]: " choice </dev/tty
    if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#templates[@]}" ]; then
      echo "${templates[$((choice-1))]%%|*}"
      return 0
    fi
    echo "無効な選択です" >&2
  done
}

# テンプレートID解決
if [ "${TEMPLATE_VM_ID}" = "select" ]; then
  TEMPLATE_VM_ID=$(select_template) || handle_error "テンプレート選択に失敗しました"
  echo "  → テンプレート ${TEMPLATE_VM_ID} を使用します"
fi

if ! [[ "${TEMPLATE_VM_ID}" =~ ^[0-9]+$ ]]; then
  handle_error "TEMPLATE_VM_IDは数値もしくは 'select' を指定してください: ${TEMPLATE_VM_ID}"
fi

if ! qm status "${TEMPLATE_VM_ID}" >/dev/null 2>&1; then
  handle_error "テンプレートVM ${TEMPLATE_VM_ID} が存在しません"
fi

if ! qm config "${TEMPLATE_VM_ID}" 2>/dev/null | grep -q "^template: 1"; then
  echo "警告: VM ${TEMPLATE_VM_ID} はテンプレート化されていません"
fi

# VM ID自動割り当て
if [ "${VM_ID}" = "auto" ]; then
  echo "VM IDを自動割り当てしています..."
  VM_ID=$(pvesh get /cluster/nextid 2>/dev/null) || handle_error "次のVM IDの取得に失敗しました"
  echo "  → VM ID ${VM_ID} を使用します"
fi

if ! [[ "${VM_ID}" =~ ^[0-9]+$ ]]; then
  handle_error "VM IDは数値もしくは 'auto' を指定してください: ${VM_ID}"
fi

if qm status "${VM_ID}" >/dev/null 2>&1; then
  handle_error "VM ID ${VM_ID} は既に使用されています"
fi

apply_ssh_keys() {
  wget "https://github.com/${GITHUB_ACCOUNT}.keys" -O "${GITHUB_ACCOUNT}.keys" || handle_error "GitHubから公開鍵の取得に失敗しました"
  if [ ! -s "./${GITHUB_ACCOUNT}.keys" ]; then
    handle_error "GitHubから取得した公開鍵が空です"
  fi
  qm set "${VM_ID}" --sshkey "./${GITHUB_ACCOUNT}.keys" || handle_error "公開鍵の設定に失敗しました"
}

# Create a new VM from the template
echo "テンプレート ${TEMPLATE_VM_ID} から VM ${VM_ID} (${VM_NAME}) を作成しています..."
qm clone "${TEMPLATE_VM_ID}" "${VM_ID}" --name "${VM_NAME}" --full true || handle_error "VMのクローンに失敗しました"

# Set password
qm set "${VM_ID}" --cipassword "${PASSWORD}" || handle_error "パスワードの設定に失敗しました"

# Set network
qm set "${VM_ID}" --ipconfig0 "${NETWORK}" || handle_error "ネットワークの設定に失敗しました"

# add vlan tag if VLAN_TAG is set
if [ -n "${VLAN_TAG}" ]; then
  qm set "${VM_ID}" --net0 "virtio,bridge=vmbr0,tag=${VLAN_TAG}" || handle_error "VLANタグの設定に失敗しました"
fi

# Apply SSH keys
apply_ssh_keys

# テンプレートのコードネームを推測してタグを引き継ぐ
TEMPLATE_NAME=$(qm config "${TEMPLATE_VM_ID}" 2>/dev/null | awk -F': ' '/^name:/ {print $2}')
TAGS="ubuntu;deployed"
if [[ "${TEMPLATE_NAME}" =~ ubuntu-([a-z]+)-template ]]; then
  TAGS="${TAGS};${BASH_REMATCH[1]}"
fi
qm set "${VM_ID}" --tags "${TAGS}" || echo "警告: タグ設定に失敗しました (継続します)"

# Descriptionを設定
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DESCRIPTION="Deployed VM
Name: ${VM_NAME}
Source template: ${TEMPLATE_VM_ID} (${TEMPLATE_NAME})
Created: ${CREATED_AT}
SSH keys from: github.com/${GITHUB_ACCOUNT}
Network: ${NETWORK}${VLAN_TAG:+ (VLAN ${VLAN_TAG})}"
qm set "${VM_ID}" --description "${DESCRIPTION}" || echo "警告: 説明文の設定に失敗しました (継続します)"

echo "VM ${VM_ID} (${VM_NAME}) is ready to start"
