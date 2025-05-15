# Proxmox Cloudinit Setup

Proxmox上でCloudinitに対応したUbuntuイメージをセットアップするためのスクリプト

## 注意

大変申し訳ありません。スクリプトに誤りがあり、`sudo apt-get install cloud-init`をホスト上で実行するようになっておりました
大変お手数ですが、それより前のバージョンを利用した方は、`sudo apt purge cloud-init`で削除をお願いします
以下のフォーラムの用に再起動後にProxmox Clusterが破壊される可能性があります
https://forum.proxmox.com/threads/after-upgrade-from-5-2-5-my-server-is-now-named-cloudinit.49810/

## 使い方

1. ProxmoxのNodeにSSHでログイン(VMではない)して、cloud-imageをダウンロードする
```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

2. convert.shでqemu-guest-agentを追加する
```bash
./convert.sh noble-server-cloudimg-amd64.img
```

3. setup.shでVMテンプレートをセットアップする
```bash
wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/setup.sh
chmod +x setup.sh
./setup.sh 9000 noble 4096
```

diskを指定する場合(デフォルトはlocal-lvm)
```bash
./setup.sh 9000 noble 4096 HDDPool
```

テンプレートにせずVMとして作成する場合
```bash
./setup.sh 9000 noble 4096 --no-template
```

qemu-guest-agentを有効化する場合（convert.shの手順を自動的に実行）
```bash
./setup.sh 9000 noble 4096 --enable-agent
```

diskとテンプレートオプションを指定する場合
```bash
./setup.sh 9000 noble 4096 HDDPool --no-template
```

複数のオプションを組み合わせる場合
```bash
./setup.sh 9000 noble 4096 HDDPool --no-template --enable-agent
```

4. VMをデプロイする
```bash
wget https://raw.githubusercontent.com/csenet/proxmox-cloudinit/refs/heads/main/deploy.sh
chmod +x deploy.sh
./deploy.sh 9000 100 test csenet password123 ip=192.168.200.10/24,gw=192.168.200.1 200
```

## UbuntuのバージョンとCodeNameの指定対応

| Ubuntu Version | CodeName |
|:--------------:|:--------:|
| 24.04.1 LTS | noble |
| 22.04.5 LTS | jammy |
| 20.04.6 LTS | focal |
| 18.04.6 LTS | bionic |

## 参考
- https://pve.proxmox.com/wiki/Cloud-Init_Support
