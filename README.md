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

4. setup.shでVMテンプレートをセットアップします
```bash
./setup.sh 9000 noble 4096
```

VM IDを自動割り当て（9000-9999の空きを自動検出）
```bash
./setup.sh auto noble 4096
```

ストレージを対話選択（利用可能なストレージ一覧から番号で選択）
```bash
./setup.sh auto noble 4096 select
```

diskを指定する場合(デフォルトはlocal-lvm)
```bash
./setup.sh 9000 noble 4096 HDDPool
```

テンプレートにせずVMとして作成する場合
```bash
./setup.sh 9000 noble 4096 --no-template
```

qemu-guest-agentを有効化する場合（初回は変換処理が実行されます）
```bash
./setup.sh 9000 noble 4096 --enable-agent
```

SHA256検証をスキップする場合
```bash
./setup.sh 9000 noble 4096 local-lvm --no-verify
```

複数のオプションを組み合わせる場合
```bash
./setup.sh auto noble 4096 select --no-template --enable-agent
```

5. VMをデプロイする
```bash
wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/deploy.sh
chmod +x deploy.sh
./deploy.sh 9000 100 test csenet password123 ip=192.168.200.10/24,gw=192.168.200.1 200
```

テンプレートを対話選択 + VM IDを自動割り当て
```bash
./deploy.sh select auto test csenet password123 ip=192.168.200.10/24,gw=192.168.200.1
```

## 便利機能

| 機能 | 使い方 |
|------|--------|
| **VM ID自動割り当て** | `setup.sh auto ...` で 9000-9999 の空き番号を自動検出 / `deploy.sh ... auto ...` で `pvesh get /cluster/nextid` から取得 |
| **ストレージ対話選択** | `setup.sh ... select` で `pvesm status -content images` の結果から番号で選択 |
| **テンプレート対話選択** | `deploy.sh select ...` で既存テンプレート一覧から番号で選択 |
| **SHA256検証** | デフォルトで Ubuntu公式 `SHA256SUMS` と照合。`--no-verify` でスキップ可 |
| **タグ自動付与** | テンプレ→`ubuntu;<codename>;template` / VM→`ubuntu;deployed;<codename>` でGUIフィルタしやすい |
| **説明文自動記入** | 作成日時、Ubuntuバージョン、SHA256、ソースURL、ネットワーク等をdescriptionに記録 |
| **VM ID重複チェック** | 既存IDが指定された場合は事前にエラー終了 |

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
