# SelfExplorer

セルフホストして使うファイラーです。 /opt/lxd-data 配下のファイルをブラウザから閲覧・編集できます。

## インストール方法

### クイックインストール（推奨）

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/hirogura/selfexplorer/main/install-selfexplorer1.sh)"
```

### 手動インストール

```bash
# 1. リポジトリをクローン
git clone https://github.com/hirogura/selfexplorer.git /tmp/selfexplorer
sudo rsync -a /tmp/selfexplorer/ /opt/selfexplorer/
rm -rf /tmp/selfexplorer

# 2. 設定を編集 (必要に応じて)
# /opt/selfexplorer/server/server.js の PORT, ROOT_DIR を編集
# /opt/selfexplorer/public/js/app.js の ROOT_PREFIX を編集

# 3. npm 依存関係をインストール
cd /opt/selfexplorer/server
npm install --production

# 4. systemd サービスをセットアップ
sudo tee /etc/systemd/system/selfexplorer.service <<'EOF'
[Unit]
Description=SelfExplorer File Manager
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/selfexplorer/server
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable selfexplorer
sudo systemctl start selfexplorer
```

### インストールスクリプトを使用する場合

`install-selfexplorer1.sh` をダウンロードして実行するか、上記のクイックインストールコマンドを実行してください。

## 要件

- Node.js 18 以上
- git
- systemd (推奨)
- OnlyOffice 連携には Docker

## アクセス

SelfExplorer は `127.0.0.1` にのみバインドされているため、**Tailnet（Tailscale）内からしかアクセスできません**。LAN やインターネットからの直接アクセスはできません。

- サーバー上: http://localhost:3346
- Tailnet 内: https://`<hostname>.ts.net:3346` (Tailscale Serve が有効な場合)
- OnlyOffice: https://`<hostname>.ts.net:3322` (こちらも Tailnet 内のみ)

### ネットワーク構成

| サービス | バインド | 公開範囲 |
|---|---|---|
| SelfExplorer (3346) | `127.0.0.1` | Tailnet 内のみ |
| OnlyOffice (3322) | `127.0.0.1` | Tailnet 内のみ |

## 要件
