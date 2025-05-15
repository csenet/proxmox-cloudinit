# VM Templateをセットアップするスクリプト
# wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/setup-template.sh
# ./setup.sh <VM_ID> <UBUNTU_CODE_NAME>

# Check arguments should be 3, 4, 5, or 6
if [ "$#" -lt 3 ]; then
  echo "Invalid number of arguments"
  echo "Usage: ./setup.sh <VM_ID> <UBUNTU_CODE_NAME> <MEMORY_SIZE> [<DISK_POOL>] [--no-template] [--enable-agent]"
  echo "Example: ./setup.sh 9000 noble 4096"
  echo "Example with custom disk pool: ./setup.sh 9000 noble 4096 HDDPool"
  echo "Example without template conversion: ./setup.sh 9000 noble 4096 local-lvm --no-template"
  echo "Example with qemu-guest-agent enabled: ./setup.sh 9000 noble 4096 --enable-agent"
  exit 1
fi

# エラーが発生したら処理を終了する関数
handle_error() {
  echo "エラーが発生しました: $1"
  exit 1
}

VM_ID=$1 # QEMU VM ID
UBUNTU_CODE_NAME=$2 # Ubuntu Code Name
MEMORY_SIZE=$3 # Memory Size
DISK_POOL=$4 # Disk Pool optional
NO_TEMPLATE=false # Default is to create a template
ENABLE_AGENT=false # Default is not to enable qemu-guest-agent

# カレントディレクトリの絶対パスを取得
CURRENT_DIR="$(pwd)"
IMAGE_FILE="${CURRENT_DIR}/${UBUNTU_CODE_NAME}-server-cloudimg-amd64.img" # イメージファイルの絶対パス

# パラメータをチェック: --no-template と --enable-agent オプションの位置を特定
for arg in "$@"; do
  if [ "$arg" = "--no-template" ]; then
    NO_TEMPLATE=true
  elif [ "$arg" = "--enable-agent" ]; then
    ENABLE_AGENT=true
  fi
done

# Check if the fourth parameter is --no-template or --enable-agent
if [ "$4" = "--no-template" ] || [ "$4" = "--enable-agent" ]; then
  DISK_POOL="local-lvm" # Use default disk pool
fi

# If DISK_POOL is not set or is any of the option flags
if [ -z "$DISK_POOL" ] || [ "$DISK_POOL" = "--no-template" ] || [ "$DISK_POOL" = "--enable-agent" ]; then
  DISK_POOL="local-lvm"
fi

# Check if image exists in the current directory
if [ ! -f "${IMAGE_FILE}" ]; then
  echo "イメージが見つかりません。ダウンロードします..."
  # download the latest Ubuntu Cloud Image
  wget https://cloud-images.ubuntu.com/${UBUNTU_CODE_NAME}/current/${UBUNTU_CODE_NAME}-server-cloudimg-amd64.img -O "${IMAGE_FILE}" || handle_error "イメージのダウンロードに失敗しました"
fi

# Enable qemu-guest-agent if specified
if [ "$ENABLE_AGENT" = true ]; then
  echo "qemu-guest-agentを有効化するためにイメージを変換しています..."
  
  # Check if convert.sh exists
  if [ ! -f ./convert.sh ]; then
    echo "convert.sh がありません。ダウンロードします..."
    wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/convert.sh || handle_error "convert.shのダウンロードに失敗しました"
    chmod +x ./convert.sh || handle_error "convert.shの実行権限付与に失敗しました"
  fi
  
  # Create a backup of the original image
  cp "${IMAGE_FILE}" "${IMAGE_FILE}.backup" || handle_error "イメージのバックアップに失敗しました"
  
  # Convert the image
  ./convert.sh "${IMAGE_FILE}" || handle_error "イメージの変換に失敗しました"
  echo "イメージの変換が完了しました"
fi

# create a new VM with VirtIO SCSI controller
echo "VMを作成しています..."
qm create ${VM_ID} --memory ${MEMORY_SIZE} --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --cores 2 --sockets 1 --name ubuntu-${UBUNTU_CODE_NAME}-template || handle_error "VM作成に失敗しました"

# import the downloaded disk to the DISK_POOL storage, attaching it as a SCSI drive
echo "ディスクをインポートしています..."
echo "インポートするイメージのパス: ${IMAGE_FILE}"
qm importdisk ${VM_ID} "${IMAGE_FILE}" ${DISK_POOL} || handle_error "ディスクのインポートに失敗しました"

# ディスクをVMにアタッチ
echo "ディスクをVMにアタッチしています..."
qm set ${VM_ID} --scsi0 ${DISK_POOL}:vm-${VM_ID}-disk-0 || handle_error "ディスクのアタッチに失敗しました"

# Add Cloud init CD-ROM
echo "CloudInitを設定しています..."
qm set ${VM_ID} --ide2 ${DISK_POOL}:cloudinit || handle_error "CloudInit設定に失敗しました"

# Add disk size
echo "ディスクサイズを調整しています..."
qm resize ${VM_ID} scsi0 +20G || handle_error "ディスクサイズの変更に失敗しました"

# Set boot order
echo "ブート順序を設定しています..."
qm set ${VM_ID} --boot order=scsi0 || handle_error "ブート順序の設定に失敗しました"

# add serial
echo "シリアルポートを設定しています..."
qm set ${VM_ID} --serial0 socket --vga serial0 || handle_error "シリアルポートの設定に失敗しました"

# Enable qemu-guest-agent in VM configuration if specified
if [ "$ENABLE_AGENT" = true ]; then
  echo "VM設定でqemu-guest-agentを有効化しています..."
  qm set ${VM_ID} --agent enabled=1 || handle_error "qemu-guest-agentの有効化に失敗しました"
else
  # Always set agent setting
  echo "エージェントを設定しています..."
  qm set ${VM_ID} --agent enabled=1 || handle_error "エージェントの設定に失敗しました"
fi

# convert to template if NO_TEMPLATE is false
if [ "$NO_TEMPLATE" = false ]; then
  echo "テンプレートに変換しています..."
  qm template ${VM_ID} || handle_error "テンプレート変換に失敗しました"
  echo "VMテンプレートの準備が完了しました"
else
  echo "VMの準備が完了しました (テンプレート変換は行いません)"
fi

echo "すべての処理が正常に完了しました"
