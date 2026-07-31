#!/usr/bin/env bash
# =============================================================================
#  SelfExplorer v11 セットアップスクリプト（GitHub版）
#  - https://github.com/hirogura/selfexplorer からクローン
#  - /opt/selfexplorer に配置、/opt/lxd-data をブラウズ対象
#  - ポート 3346 / systemd サービス / Tailscale Serve 対応
# =============================================================================
set -euo pipefail

# ── 固定設定 ──────────────────────────────────────────────────────────────────
INSTALL_DIR="/opt/selfexplorer"
BROWSE_ROOT="/opt/lxd-data"
PORT=3346
OO_PORT=3322
SERVICE_NAME="selfexplorer"
NODE_MIN_VERSION=18
NODE_VERSION_TO_INSTALL="22"
REPO_URL="https://github.com/hirogura/selfexplorer.git"

# ── 色付きログ ─────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*" >&2; exit 1; }

# ── Node.js 自動インストール ──────────────────────────────────────────────────
install_nodejs() {
  info "Node.js をインストール中..."
  if [ -f /etc/debian_version ]; then
    info "Debian/Ubuntu を検出。NodeSource からインストールします..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION_TO_INSTALL}.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq nodejs
  elif [ -f /etc/redhat-release ]; then
    info "RHEL/CentOS を検出。NodeSource からインストールします..."
    curl -fsSL https://rpm.nodesource.com/setup_${NODE_VERSION_TO_INSTALL}.x | bash -
    yum install -y nodejs
  elif command -v apk >/dev/null 2>&1; then
    info "Alpine Linux を検出。apk からインストールします..."
    apk add --no-cache nodejs npm
  elif command -v pacman >/dev/null 2>&1; then
    info "Arch Linux を検出。pacman からインストールします..."
    pacman -S --noconfirm nodejs npm
  elif command -v zypper >/dev/null 2>&1; then
    info "openSUSE を検出。zypper からインストールします..."
    zypper install -y nodejs npm
  else
    info "nvm でインストールします..."
    export NVM_DIR="/tmp/nvm_install"
    mkdir -p "$NVM_DIR"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    . "${NVM_DIR}/nvm.sh"
    nvm install "${NODE_VERSION_TO_INSTALL}"
    nvm use "${NODE_VERSION_TO_INSTALL}"
    NODE_BIN=$(which node)
    NPM_BIN=$(which npm)
    ln -sf "$NODE_BIN" /usr/local/bin/node
    ln -sf "$NPM_BIN" /usr/local/bin/npm
    rm -rf "$NVM_DIR"
  fi
  if ! command -v node >/dev/null 2>&1; then
    die "Node.js のインストールに失敗しました"
  fi
  ok "Node.js v$(node -v) のインストール完了"
}

# ── 前提チェック ───────────────────────────────────────────────────────────────
info "前提確認..."
if ! command -v node >/dev/null 2>&1; then
  warn "Node.js が見つかりません"
  install_nodejs
fi
NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
if [ "$NODE_VERSION" -lt "$NODE_MIN_VERSION" ]; then
  warn "Node.js v${NODE_VERSION} は古いです (必要: v${NODE_MIN_VERSION}以上)"
  install_nodejs
fi
command -v npm >/dev/null 2>&1 || die "npm が見つかりません"
command -v git >/dev/null 2>&1 || die "git が見つかりません"
ok "前提 OK (Node.js v$(node -v), git 利用可)"

# ── OnlyOffice インストール確認 ────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
REUSE_EXISTING_OO="n"
if [ -f /opt/onlyoffice/docker-compose.yml ]; then
  warn "既存の OnlyOffice 環境 (/opt/onlyoffice) を検出しました"
  read -rp "  既存の OnlyOffice 環境を再利用しますか？ [Y/n]: " reuse_oo
  reuse_oo="${reuse_oo:-Y}"
  if [[ "${reuse_oo}" =~ ^[Yy] ]]; then
    REUSE_EXISTING_OO="y"
    install_oo="Y"
  fi
fi
if [ "${REUSE_EXISTING_OO}" != "y" ]; then
  read -rp "  OnlyOffice Document Server をインストールしますか？ [Y/n]: " install_oo
  install_oo="${install_oo:-Y}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── ディレクトリ作成 ──────────────────────────────────────────────────────────
info "ディレクトリ作成..."
mkdir -p "${INSTALL_DIR}"
mkdir -p "${BROWSE_ROOT}"
ok "ディレクトリ作成完了"

# ── GitHub からクローン ────────────────────────────────────────────────────────
info "GitHub からクローン中..."
TMP_CLONE="/tmp/selfexplorer-clone-$$"
git clone --depth 1 "${REPO_URL}" "${TMP_CLONE}"
rm -rf "${TMP_CLONE}/server/node_modules"
rsync -a "${TMP_CLONE}/" "${INSTALL_DIR}/"
rm -rf "${TMP_CLONE}"
ok "クローン完了"

# ── OnlyOffice シークレット生成 ───────────────────────────────────────────────
if [ "${REUSE_EXISTING_OO}" = "y" ]; then
  OO_SECRET=$(grep 'JWT_SECRET:' /opt/onlyoffice/docker-compose.yml | head -1 | sed 's/.*JWT_SECRET: *"\(.*\)"/\1/' 2>/dev/null || true)
  if [ -z "${OO_SECRET}" ]; then
    warn "既存のシークレットキーを取得できなかったため、新規に生成します"
    OO_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
    REUSE_EXISTING_OO="n"
  else
    ok "既存の OnlyOffice シークレットキーを再利用します"
  fi
else
  OO_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
fi

# ── 設定を反映 (sed で server.js / app.js の値を書き換え) ──────────────────────
info "設定を反映..."
sed -i "s,^const PORT = [0-9]*;,const PORT = ${PORT};," "${INSTALL_DIR}/server/server.js"
sed -i "s,^const ROOT_DIR = '.*';,const ROOT_DIR = '${BROWSE_ROOT}';," "${INSTALL_DIR}/server/server.js"
sed -i "s,process.env.ONLYOFFICE_URL || 'http://127.0.0.1:[0-9]*',process.env.ONLYOFFICE_URL || 'http://127.0.0.1:${OO_PORT}'," "${INSTALL_DIR}/server/server.js"
sed -i "s,process.env.ONLYOFFICE_SECRET || '[^']*',process.env.ONLYOFFICE_SECRET || '${OO_SECRET}'," "${INSTALL_DIR}/server/server.js"
sed -i "s,const ROOT_PREFIX='[^']*',const ROOT_PREFIX='${BROWSE_ROOT}'," "${INSTALL_DIR}/public/js/app.js"
ok "設定反映完了"

# ── OnlyOffice セットアップ ──────────────────────────────────────────────────
if [[ "${install_oo}" =~ ^[Yy] ]]; then
  if [ "${REUSE_EXISTING_OO}" = "y" ]; then
    info "既存の OnlyOffice 環境を再利用します..."
    cd /opt/onlyoffice
    docker compose up -d
    ok "OnlyOffice コンテナの起動を確認しました"
  else
    info "OnlyOffice のディレクトリを作成..."
    mkdir -p /opt/onlyoffice/{logs,data,lib}
    cat > /opt/onlyoffice/docker-compose.yml << OOCHEOF
# OnlyOffice Document Server for SelfExplorer
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

services:
  onlyoffice:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice
    restart: unless-stopped
    ports:
      - "127.0.0.1:${OO_PORT}:80"
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: "${OO_SECRET}"
    volumes:
      - /opt/onlyoffice/logs:/var/log/onlyoffice
      - /opt/onlyoffice/data:/var/www/onlyoffice/Data
      - /opt/onlyoffice/lib:/var/lib/onlyoffice
OOCHEOF
    ok "OnlyOffice docker-compose.yml 生成完了"
    info "OnlyOffice コンテナを起動..."
    cd /opt/onlyoffice
    docker compose pull
    docker compose up -d
    ok "OnlyOffice コンテナ起動完了（初回起動は2〜3分かかります）"
  fi
  if command -v tailscale >/dev/null 2>&1; then
    EXISTING_SERVE=$(tailscale serve status 2>/dev/null || true)
    if echo "${EXISTING_SERVE}" | grep -q ":${OO_PORT}"; then
      warn "ポート ${OO_PORT} はすでに Tailscale Serve に登録されています。スキップします。"
    else
      info "Tailscale Serve にポート ${OO_PORT} を追加..."
      tailscale serve --bg --https="${OO_PORT}" "http://127.0.0.1:${OO_PORT}"
      ok "OnlyOffice の Tailscale Serve 設定追加完了"
    fi
  fi
else
  info "OnlyOffice のインストールをスキップします"
fi

# ── npm install ───────────────────────────────────────────────────────────────
info "npm install 実行中..."
cd "${INSTALL_DIR}/server"
npm install --production 2>&1 | tail -3
ok "npm install 完了"

# ── systemd サービス作成 ─────────────────────────────────────────────────────
NODE_BIN=$(command -v node)
info "systemd サービスを作成 (Node: ${NODE_BIN})..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << SVCEOF
[Unit]
Description=SelfExplorer File Manager
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/server
ExecStart=${NODE_BIN} server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
SVCEOF
ok "サービスファイル作成完了"

# ── 古いプロセスを停止 ─────────────────────────────────────────────────────────
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
  info "既存の ${SERVICE_NAME} サービスを停止中..."
  systemctl stop "${SERVICE_NAME}"
  systemctl kill "${SERVICE_NAME}" 2>/dev/null || true
fi
# ポートを占有している全プロセスを強制停止
# 注意: パターンは自分自身 (bash -c "$(curl...)") にマッチしないように
# [.] の文字クラスで自己マッチを回避する
pkill -f "node server[.]js" 2>/dev/null || true
sleep 2

# ── サービス起動 ─────────────────────────────────────────────────────────────
info "サービスを有効化・起動..."
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}" 2>/dev/null || true
systemctl restart "${SERVICE_NAME}"
sleep 2

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  ok "サービス起動完了"
else
  warn "サービスの起動に失敗しました。詳細を確認中..."
  journalctl -u "${SERVICE_NAME}" --no-pager -n 20 2>/dev/null || true
  die "サービスの起動に失敗しました（上記のログを参照）"
fi

# ── Tailscale Serve 設定 ──────────────────────────────────────────────────────
if command -v tailscale >/dev/null 2>&1; then
  EXISTING_SERVE=$(tailscale serve status 2>/dev/null || true)
  if echo "${EXISTING_SERVE}" | grep -q ":${PORT}"; then
    warn "ポート ${PORT} はすでに Tailscale Serve に登録されています。スキップします。"
  else
    info "Tailscale Serve にポート ${PORT} を追加..."
    tailscale serve --bg --https="${PORT}" "http://127.0.0.1:${PORT}"
    ok "SelfExplorer の Tailscale Serve 設定追加完了"
  fi
fi

# ── Tailscale 情報取得 ────────────────────────────────────────────────────────
TS_HOSTNAME=""
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  TS_HOSTNAME=$(tailscale status --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || true)
fi

# ── 完了サマリー ──────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "SelfExplorer v11 セットアップ完了！"
echo ""
if [ -n "${TS_HOSTNAME}" ]; then
  echo "  SelfExplorer : https://${TS_HOSTNAME}:${PORT}"
  if [[ "${install_oo}" =~ ^[Yy] ]]; then
    if [ "${REUSE_EXISTING_OO}" = "y" ]; then
      echo "  OnlyOffice   : https://${TS_HOSTNAME}:${OO_PORT}  (既存環境を再利用)"
    else
      echo "  OnlyOffice   : https://${TS_HOSTNAME}:${OO_PORT}"
    fi
  fi
else
  warn "Tailscale Serve の設定情報を取得できませんでした（tailscale未起動の可能性があります）"
  echo "  SelfExplorer : http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'localhost'):${PORT}  (ローカルアクセスのみ)"
fi
echo ""
echo "  インストール先: ${INSTALL_DIR}"
echo "  ブラウズ対象  : ${BROWSE_ROOT}"
echo "  ポート        : ${PORT}"
echo "  サービス      : systemctl status ${SERVICE_NAME}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
