#!/bin/bash
# VM TemplateからVMを作成するスクリプト

set -uo pipefail

show_help() {
  cat <<'EOF'
Usage: ./deploy.sh [options]

Options:
  --template-id <id|select>  テンプレートVM ID (default: select = 対話選択)
  --vm-id <id|auto>          作成するVM ID (default: auto)
  --name <vm-name>           VM名 (required)
  --github <account>         SSH鍵を取得するGitHubアカウント (required)
  --password <password>      cloud-init パスワード (required)
  --network <ipconfig>       ネットワーク設定 (required, e.g. ip=192.168.1.10/24,gw=192.168.1.1)
  --vlan <tag>               VLANタグ (optional)
  --bridge <bridge>          ブリッジ (default: vmbr0)
  -h, --help                 このヘルプを表示

Examples:
  ./deploy.sh --template-id 9000 --vm-id 100 --name test --github csenet \
    --password password123 --network ip=192.168.200.10/24,gw=192.168.200.1 --vlan 200

  ./deploy.sh --name test --github csenet --password password123 \
    --network ip=192.168.200.10/24,gw=192.168.200.1
  # → テンプレ対話選択 + VM ID自動割り当て
EOF
}

handle_error() {
  echo "エラーが発生しました: $1" >&2
  exit 1
}

# デフォルト値
TEMPLATE_VM_ID="select"
VM_ID="auto"
VM_NAME=""
GITHUB_ACCOUNT=""
PASSWORD=""
NETWORK=""
VLAN_TAG=""
BRIDGE="vmbr0"

# 引数パース
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template-id) [ -z "${2:-}" ] && handle_error "--template-id に値がありません"; TEMPLATE_VM_ID="$2"; shift 2 ;;
    --vm-id)       [ -z "${2:-}" ] && handle_error "--vm-id に値がありません"; VM_ID="$2"; shift 2 ;;
    --name)        [ -z "${2:-}" ] && handle_error "--name に値がありません"; VM_NAME="$2"; shift 2 ;;
    --github)      [ -z "${2:-}" ] && handle_error "--github に値がありません"; GITHUB_ACCOUNT="$2"; shift 2 ;;
    --password)    [ -z "${2:-}" ] && handle_error "--password に値がありません"; PASSWORD="$2"; shift 2 ;;
    --network)     [ -z "${2:-}" ] && handle_error "--network に値がありません"; NETWORK="$2"; shift 2 ;;
    --vlan)        [ -z "${2:-}" ] && handle_error "--vlan に値がありません"; VLAN_TAG="$2"; shift 2 ;;
    --bridge)      [ -z "${2:-}" ] && handle_error "--bridge に値がありません"; BRIDGE="$2"; shift 2 ;;
    -h|--help)     show_help; exit 0 ;;
    *) handle_error "不明なオプション: $1 (--help でヘルプ表示)" ;;
  esac
done

# 必須引数チェック
[ -z "${VM_NAME}" ]        && { show_help >&2; echo "" >&2; handle_error "--name は必須です"; }
[ -z "${GITHUB_ACCOUNT}" ] && handle_error "--github は必須です"
[ -z "${PASSWORD}" ]       && handle_error "--password は必須です"
[ -z "${NETWORK}" ]        && handle_error "--network は必須です"

# 既存VM一覧を一括取得 (qm statusの個別呼び出しを避ける)
EXISTING_VMS=$(qm list 2>/dev/null | awk 'NR>1')
EXISTING_IDS=$(echo "${EXISTING_VMS}" | awk '{print $1}')

# テンプレート対話選択
select_template() {
  echo "利用可能なテンプレート一覧:" >&2
  local templates=()
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    local id name
    id=$(echo "${line}" | awk '{print $1}')
    name=$(echo "${line}" | awk '{print $2}')
    if qm config "${id}" 2>/dev/null | grep -q "^template: 1"; then
      templates+=("${id}|${name}")
    fi
  done <<< "${EXISTING_VMS}"

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
  handle_error "--template-id は数値もしくは 'select' を指定してください: ${TEMPLATE_VM_ID}"
fi

if ! grep -qx "${TEMPLATE_VM_ID}" <<< "${EXISTING_IDS}"; then
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
  handle_error "--vm-id は数値もしくは 'auto' を指定してください: ${VM_ID}"
fi

if grep -qx "${VM_ID}" <<< "${EXISTING_IDS}"; then
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

# bridge / vlan
if [ -n "${VLAN_TAG}" ]; then
  qm set "${VM_ID}" --net0 "virtio,bridge=${BRIDGE},tag=${VLAN_TAG}" || handle_error "ネットワーク設定に失敗しました"
elif [ "${BRIDGE}" != "vmbr0" ]; then
  qm set "${VM_ID}" --net0 "virtio,bridge=${BRIDGE}" || handle_error "ネットワーク設定に失敗しました"
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
