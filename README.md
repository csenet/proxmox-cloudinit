# Proxmox Cloudinit Setup

Proxmox上でCloudinitに対応したUbuntuイメージをセットアップするためのスクリプト

## 注意

大変申し訳ありません。スクリプトに誤りがあり、`sudo apt-get install cloud-init`をホスト上で実行するようになっておりました
大変お手数ですが、それより前のバージョンを利用した方は、`sudo apt purge cloud-init`で削除をお願いします
以下のフォーラムの用に再起動後にProxmox Clusterが破壊される可能性があります
https://forum.proxmox.com/threads/after-upgrade-from-5-2-5-my-server-is-now-named-cloudinit.49810/

## 使い方

1. ProxmoxのNodeにSSHでログイン(VMではない)して、作業用ディレクトリを作成します
```bash
mkdir -p ~/cloudinit-setup
cd ~/cloudinit-setup
```

2. cloud-imageをダウンロードします（setup.shが自動的にダウンロードすることもできます）
```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

3. setup.shをダウンロードして実行権限を付与します
```bash
wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/setup.sh
chmod +x setup.sh
```

4. setup.shでVMテンプレートをセットアップします（最小構成）
```bash
./setup.sh --ubuntu noble
# → VM ID自動 (9000台空き)、memory 2048MB、storage local-lvm、template化
```

ヘルプを表示
```bash
./setup.sh --help
```

オプション一覧

| オプション | 説明 | デフォルト |
|------------|------|------------|
| `--vm-id <id\|auto>` | VM ID。`auto` で 9000-9999 の空き自動検出 | `auto` |
| `--ubuntu <codename>` | Ubuntuコードネーム（必須） | — |
| `--memory <mb>` | メモリサイズ (MB) | `2048` |
| `--storage <name\|select>` | ストレージプール。`select` で対話選択 | `local-lvm` |
| `--cores <n>` | CPUコア数 | `2` |
| `--disk-size <size>` | 追加ディスクサイズ | `+20G` |
| `--no-template` | テンプレート化しない | — |
| `--enable-agent` | qemu-guest-agentを有効化 | — |
| `--no-verify` | SHA256検証をスキップ | — |

例

```bash
# VM ID指定 + メモリ4GB + ストレージ指定
./setup.sh --vm-id 9000 --ubuntu noble --memory 4096 --storage HDDPool

# ストレージ対話選択 + agent有効
./setup.sh --ubuntu noble --memory 4096 --storage select --enable-agent

# テンプレ化せずVMで作成（テスト用）
./setup.sh --ubuntu noble --no-template

# 全部入り
./setup.sh --vm-id 9001 --ubuntu jammy --memory 8192 --cores 4 \
  --disk-size +50G --storage select --enable-agent
```

5. VMをデプロイする
```bash
wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/deploy.sh
chmod +x deploy.sh

# テンプレ対話選択 + VM ID自動割り当て (最小構成)
./deploy.sh --name test --github csenet --password password123 \
  --network ip=192.168.200.10/24,gw=192.168.200.1
```

オプション一覧

| オプション | 説明 | デフォルト |
|------------|------|------------|
| `--template-id <id\|select>` | テンプレートVM ID。`select` で対話選択 | `select` |
| `--vm-id <id\|auto>` | 作成するVM ID | `auto` |
| `--name <vm-name>` | VM名（必須） | — |
| `--github <account>` | SSH鍵を取得するGitHubアカウント（必須） | — |
| `--password <password>` | cloud-init パスワード（必須） | — |
| `--network <ipconfig>` | ネットワーク設定（必須） | — |
| `--vlan <tag>` | VLANタグ | — |
| `--bridge <bridge>` | ブリッジ | `vmbr0` |

例

```bash
# 完全指定
./deploy.sh --template-id 9000 --vm-id 100 --name test --github csenet \
  --password password123 --network ip=192.168.200.10/24,gw=192.168.200.1 --vlan 200
```

## 便利機能

| 機能 | 使い方 |
|------|--------|
| **VM ID自動割り当て** | setup.sh→9000-9999から空き検出 / deploy.sh→`pvesh get /cluster/nextid` |
| **ストレージ対話選択** | `--storage select` で `pvesm status -content images` から番号選択 |
| **テンプレート対話選択** | `--template-id select` (default) で既存テンプレ一覧から番号選択 |
| **SHA256検証** | デフォルトで Ubuntu公式 `SHA256SUMS` と照合。`--no-verify` でスキップ |
| **タグ自動付与** | テンプレ→`ubuntu;<codename>;template` / VM→`ubuntu;deployed;<codename>` |
| **説明文自動記入** | 作成日時、Ubuntuバージョン、SHA256、ソースURL、ネットワーク等を記録 |
| **VM ID重複チェック** | `qm list` で一括取得して事前にエラー検出 |

## qemu-guest-agentについて

`--enable-agent`オプションを使用すると、以下の動作をします：

1. 初回実行時は、オリジナルイメージからqemu-guest-agent導入済みイメージ（`*-agent.img`）を作成し変換処理を行います
2. 2回目以降の実行時は、すでに変換済みの`*-agent.img`ファイルが存在する場合、そのファイルを使用して変換処理をスキップします
3. VMの設定でqemu-guest-agentが有効になります

## UbuntuのバージョンとCodeNameの指定対応

| Ubuntu Version | CodeName | 備考 |
|:--------------:|:--------:|:----:|
| 26.04 LTS | resolute | 最新（長期サポート） |
| 24.04 LTS | noble | 推奨（長期サポート） |
| 22.04 LTS | jammy | 長期サポート |
| 20.04 LTS | focal | 標準サポート終了 |
| 18.04 LTS | bionic | EOL（非推奨） |

> **注意**: 上記以外のコードネームでも、[cloud-images.ubuntu.com](https://cloud-images.ubuntu.com/) にイメージが存在すれば利用可能です。

## 参考
- https://pve.proxmox.com/wiki/Cloud-Init_Support
