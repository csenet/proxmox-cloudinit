#!/bin/bash
# VM Templateをセットアップするスクリプト
# wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/setup.sh
# ./setup.sh <VM_ID|auto> <UBUNTU_CODE_NAME> <MEMORY_SIZE> [<DISK_POOL|select>] [--no-template] [--enable-agent] [--no-verify]

set -uo pipefail

# Check arguments
if [ "$#" -lt 3 ]; then
  echo "Invalid number of arguments"
  echo "Usage: ./setup.sh <VM_ID|auto> <UBUNTU_CODE_NAME> <MEMORY_SIZE> [<DISK_POOL|select>] [--no-template] [--enable-agent] [--no-verify]"
  echo ""
  echo "Examples:"
  echo "  ./setup.sh 9000 noble 4096"
  echo "  ./setup.sh auto noble 4096                                  # VM IDを自動割り当て (9000番台から空きを探す)"
  echo "  ./setup.sh auto noble 4096 select                           # ストレージを対話選択"
  echo "  ./setup.sh 9000 noble 4096 HDDPool                          # ストレージ指定"
  echo "  ./setup.sh 9000 noble 4096 local-lvm --no-template          # テンプレート化しない"
  echo "  ./setup.sh auto noble 4096 select --enable-agent            # qemu-guest-agent有効"
  echo "  ./setup.sh 9000 noble 4096 local-lvm --no-verify            # SHA256検証スキップ"
  exit 1
fi

# エラーが発生したら処理を終了する関数
handle_error() {
  echo "エラーが発生しました: $1" >&2
  exit 1
}

VM_ID=$1            # QEMU VM ID もしくは "auto"
UBUNTU_CODE_NAME=$2 # Ubuntu Code Name
MEMORY_SIZE=$3      # Memory Size
DISK_POOL=${4:-}    # Disk Pool optional もしくは "select"
NO_TEMPLATE=false
ENABLE_AGENT=false
VERIFY_CHECKSUM=true

# カレントディレクトリの絶対パスを取得
CURRENT_DIR="$(pwd)"
IMAGE_FILE="${CURRENT_DIR}/${UBUNTU_CODE_NAME}-server-cloudimg-amd64.img"
AGENT_ENABLED_IMAGE="${CURRENT_DIR}/${UBUNTU_CODE_NAME}-server-cloudimg-amd64-agent.img"
SOURCE_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODE_NAME}/current/${UBUNTU_CODE_NAME}-server-cloudimg-amd64.img"
CHECKSUM_URL="https://cloud-images.ubuntu.com/${UBUNTU_CODE_NAME}/current/SHA256SUMS"

# フラグオプションをパース
for arg in "$@"; do
  case "$arg" in
    --no-template)  NO_TEMPLATE=true ;;
    --enable-agent) ENABLE_AGENT=true ;;
    --no-verify)    VERIFY_CHECKSUM=false ;;
  esac
done

# DISK_POOLがフラグ文字列だった場合は未指定扱い
case "$DISK_POOL" in
  --no-template|--enable-agent|--no-verify|"")
    DISK_POOL=""
    ;;
esac

# VM IDの自動割り当て
# テンプレート用は9000番台、それ以外はpvesh nextidに任せる
get_next_template_id() {
  for id in $(seq 9000 9999); do
    if ! qm status "${id}" >/dev/null 2>&1; then
      echo "${id}"
      return 0
    fi
  done
  return 1
}

if [ "${VM_ID}" = "auto" ]; then
  echo "VM IDを自動割り当てしています..."
  VM_ID=$(get_next_template_id) || handle_error "9000-9999の範囲に空きVM IDがありません"
  echo "  → VM ID ${VM_ID} を使用します"
fi

# 数値チェック
if ! [[ "${VM_ID}" =~ ^[0-9]+$ ]]; then
  handle_error "VM IDは数値もしくは 'auto' を指定してください: ${VM_ID}"
fi

# VM ID重複チェック
if qm status "${VM_ID}" >/dev/null 2>&1; then
  handle_error "VM ID ${VM_ID} は既に使用されています"
fi

# Storageの対話選択
select_storage() {
  echo "利用可能なストレージ一覧:" >&2
  local storages
  mapfile -t storages < <(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
  if [ "${#storages[@]}" -eq 0 ]; then
    echo "imagesコンテンツに対応したactiveなストレージが見つかりません" >&2
    return 1
  fi
  local i=1
  for s in "${storages[@]}"; do
    echo "  [${i}] ${s}" >&2
    i=$((i+1))
  done
  local choice
  while true; do
    read -r -p "番号を選択してください [1-${#storages[@]}]: " choice </dev/tty
    if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#storages[@]}" ]; then
      echo "${storages[$((choice-1))]}"
      return 0
    fi
    echo "無効な選択です" >&2
  done
}

if [ "${DISK_POOL}" = "select" ]; then
  DISK_POOL=$(select_storage) || handle_error "ストレージ選択に失敗しました"
  echo "  → ストレージ ${DISK_POOL} を使用します"
elif [ -z "${DISK_POOL}" ]; then
  DISK_POOL="local-lvm"
fi

# qemu-guest-agentキャッシュイメージが使える場合はそれを使う
if [ "${ENABLE_AGENT}" = true ] && [ -f "${AGENT_ENABLED_IMAGE}" ]; then
  echo "qemu-guest-agent導入済みのキャッシュイメージが見つかりました: ${AGENT_ENABLED_IMAGE}"
  IMAGE_FILE="${AGENT_ENABLED_IMAGE}"
else
  # オリジナルイメージが存在するか確認
  if [ ! -f "${IMAGE_FILE}" ]; then
    echo "イメージが見つかりません。ダウンロードします..."
    wget "${SOURCE_URL}" -O "${IMAGE_FILE}" || handle_error "イメージのダウンロードに失敗しました"
  fi

  # SHA256検証
  if [ "${VERIFY_CHECKSUM}" = true ]; then
    echo "SHA256チェックサムを検証しています..."
    CHECKSUM_FILE="${CURRENT_DIR}/SHA256SUMS-${UBUNTU_CODE_NAME}"
    wget -q "${CHECKSUM_URL}" -O "${CHECKSUM_FILE}" || handle_error "SHA256SUMSの取得に失敗しました"
    EXPECTED_SHA256=$(grep " \*${UBUNTU_CODE_NAME}-server-cloudimg-amd64\.img$" "${CHECKSUM_FILE}" | awk '{print $1}' | head -n1)
    if [ -z "${EXPECTED_SHA256}" ]; then
      handle_error "SHA256SUMSに該当イメージのエントリが見つかりません"
    fi
    ACTUAL_SHA256=$(sha256sum "${IMAGE_FILE}" | awk '{print $1}')
    if [ "${EXPECTED_SHA256}" != "${ACTUAL_SHA256}" ]; then
      handle_error "SHA256検証失敗 期待値=${EXPECTED_SHA256} 実際=${ACTUAL_SHA256}"
    fi
    echo "  → SHA256検証OK (${ACTUAL_SHA256})"
    rm -f "${CHECKSUM_FILE}"
  else
    ACTUAL_SHA256=$(sha256sum "${IMAGE_FILE}" | awk '{print $1}')
  fi

  # qemu-guest-agentを有効化する場合
  if [ "${ENABLE_AGENT}" = true ]; then
    echo "qemu-guest-agentを有効化するためにイメージを変換しています..."

    if [ ! -f ./convert.sh ]; then
      echo "convert.sh がありません。ダウンロードします..."
      wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/convert.sh || handle_error "convert.shのダウンロードに失敗しました"
      chmod +x ./convert.sh || handle_error "convert.shの実行権限付与に失敗しました"
    fi

    echo "agent導入済みイメージを作成しています: ${AGENT_ENABLED_IMAGE}"
    cp "${IMAGE_FILE}" "${AGENT_ENABLED_IMAGE}" || handle_error "イメージのコピーに失敗しました"

    ./convert.sh "${AGENT_ENABLED_IMAGE}" || handle_error "イメージの変換に失敗しました"
    echo "イメージの変換が完了しました"

    IMAGE_FILE="${AGENT_ENABLED_IMAGE}"
  fi
fi

# ACTUAL_SHA256が未設定だった場合 (キャッシュイメージ使用時) に算出
if [ -z "${ACTUAL_SHA256:-}" ]; then
  ACTUAL_SHA256=$(sha256sum "${IMAGE_FILE}" | awk '{print $1}')
fi

# create a new VM with VirtIO SCSI controller
echo "VMを作成しています..."
qm create "${VM_ID}" \
  --memory "${MEMORY_SIZE}" \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-pci \
  --cores 2 \
  --sockets 1 \
  --name "ubuntu-${UBUNTU_CODE_NAME}-template" \
  || handle_error "VM作成に失敗しました"

# import the downloaded disk to the DISK_POOL storage
echo "ディスクをインポートしています..."
echo "インポートするイメージのパス: ${IMAGE_FILE}"
qm importdisk "${VM_ID}" "${IMAGE_FILE}" "${DISK_POOL}" || handle_error "ディスクのインポートに失敗しました"

# ディスクをVMにアタッチ
echo "ディスクをVMにアタッチしています..."
qm set "${VM_ID}" --scsi0 "${DISK_POOL}:vm-${VM_ID}-disk-0" || handle_error "ディスクのアタッチに失敗しました"

# Add Cloud init CD-ROM
echo "CloudInitを設定しています..."
qm set "${VM_ID}" --ide2 "${DISK_POOL}:cloudinit" || handle_error "CloudInit設定に失敗しました"

# Add disk size
echo "ディスクサイズを調整しています..."
qm resize "${VM_ID}" scsi0 +20G || handle_error "ディスクサイズの変更に失敗しました"

# Set boot order
echo "ブート順序を設定しています..."
qm set "${VM_ID}" --boot order=scsi0 || handle_error "ブート順序の設定に失敗しました"

# add serial
echo "シリアルポートを設定しています..."
qm set "${VM_ID}" --serial0 socket --vga serial0 || handle_error "シリアルポートの設定に失敗しました"

# qemu-guest-agentを設定
echo "エージェントを設定しています..."
qm set "${VM_ID}" --agent enabled=1 || handle_error "エージェントの設定に失敗しました"

# Tagsを付与
TAGS="ubuntu;${UBUNTU_CODE_NAME}"
if [ "${NO_TEMPLATE}" = false ]; then
  TAGS="${TAGS};template"
fi
if [ "${ENABLE_AGENT}" = true ]; then
  TAGS="${TAGS};qemu-agent"
fi
echo "タグを設定しています: ${TAGS}"
qm set "${VM_ID}" --tags "${TAGS}" || echo "警告: タグ設定に失敗しました (継続します)"

# Descriptionを設定
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DESCRIPTION="Ubuntu ${UBUNTU_CODE_NAME} cloud image template
Created: ${CREATED_AT}
Source: ${SOURCE_URL}
SHA256: ${ACTUAL_SHA256}
qemu-guest-agent: ${ENABLE_AGENT}
Storage: ${DISK_POOL}"
echo "説明文を設定しています..."
qm set "${VM_ID}" --description "${DESCRIPTION}" || echo "警告: 説明文の設定に失敗しました (継続します)"

# convert to template if NO_TEMPLATE is false
if [ "${NO_TEMPLATE}" = false ]; then
  echo "テンプレートに変換しています..."
  qm template "${VM_ID}" || handle_error "テンプレート変換に失敗しました"
  echo "VMテンプレートの準備が完了しました (VM ID: ${VM_ID})"
else
  echo "VMの準備が完了しました (VM ID: ${VM_ID}, テンプレート変換は行いません)"
fi

echo "すべての処理が正常に完了しました"
