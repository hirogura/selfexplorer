#!/usr/bin/env bash
# =============================================================================
#  OnlyOffice フォント追加スクリプト
#  - /opt/lxd-data/Fonts/ を /usr/share/fonts/custom にマウント追加
#  - docker-compose.yml を更新してコンテナ再作成
#  - OnlyOffice 内のフォントキャッシュを再生成
# =============================================================================
set -euo pipefail

OO_INSTALL_DIR="/opt/onlyoffice"
FONT_SRC="/opt/lxd-data/Fonts"
FONT_DST="/usr/share/fonts/custom"
COMPOSE_FILE="${OO_INSTALL_DIR}/docker-compose.yml"

# ── 色付きログ ─────────────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()   { echo -e "\033[1;31m[ERR ]\033[0m  $*" >&2; exit 1; }

# ── 前提チェック ───────────────────────────────────────────────────────────────
info "前提確認..."
[[ -f "${COMPOSE_FILE}" ]]  || die "compose ファイルが見つかりません: ${COMPOSE_FILE}"
[[ -d "${FONT_SRC}" ]]      || die "フォントディレクトリが見つかりません: ${FONT_SRC}"

FONT_COUNT=$(find "${FONT_SRC}" -maxdepth 2 -type f \( \
  -iname "*.ttf" -o -iname "*.otf" -o -iname "*.woff" -o -iname "*.woff2" \
\) | wc -l)
[[ "${FONT_COUNT}" -gt 0 ]] || die "フォントファイル（ttf/otf/woff）が ${FONT_SRC} に見つかりません"
ok "フォントファイル ${FONT_COUNT} 件を確認"

docker compose version >/dev/null 2>&1 || die "docker compose (v2) が見つかりません"
command -v python3 >/dev/null 2>&1 || die "python3 が見つかりません"
docker ps --format '{{.Names}}' | grep -q "^onlyoffice$" \
  || die "onlyoffice コンテナが起動していません（docker ps で確認してください）"
ok "前提 OK"

# ── compose.yml にマウントが既に存在するか確認 ─────────────────────────────────
if grep -q "${FONT_DST}" "${COMPOSE_FILE}"; then
  warn "すでに ${FONT_DST} のマウントが登録されています。"
  warn "フォントキャッシュの再生成のみ行います。"
  SKIP_COMPOSE_EDIT=true
else
  SKIP_COMPOSE_EDIT=false
fi

# ── バックアップ ───────────────────────────────────────────────────────────────
BACKUP="${COMPOSE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "${COMPOSE_FILE}" "${BACKUP}"
info "compose ファイルのバックアップ: ${BACKUP}"

# ── docker-compose.yml にマウント行を追加 ──────────────────────────────────────
if [[ "${SKIP_COMPOSE_EDIT}" == false ]]; then
  info "docker-compose.yml にフォントマウントを追加..."

  # volumes: ブロックの末尾に追記（既存の最後のボリューム行の直後に挿入）
  # sedで "volumes:" セクション内の最後のエントリの後に追加
  python3 - "${COMPOSE_FILE}" "${FONT_SRC}" "${FONT_DST}" <<'PYEOF'
import sys, re

compose_path = sys.argv[1]
font_src     = sys.argv[2]
font_dst     = sys.argv[3]
new_line     = f"      - {font_src}:{font_dst}:ro"

with open(compose_path) as f:
    content = f.read()

# volumes: ブロックを探して末尾に追記
# "    volumes:" の後に続く "      - ..." 行群の最後を特定
pattern = r'(    volumes:(?:\n      - [^\n]+)+)'

def append_volume(m):
    return m.group(0) + "\n" + new_line

new_content, n = re.subn(pattern, append_volume, content)
if n == 0:
    # volumes: セクションが無い場合は作って追加
    new_content = content.rstrip() + f"\n    volumes:\n{new_line}\n"

with open(compose_path, "w") as f:
    f.write(new_content)

print("OK")
PYEOF

  ok "docker-compose.yml を更新しました"
  info "追加内容: ${FONT_SRC} → ${FONT_DST} (read-only)"
fi

# ── コンテナ再作成 ─────────────────────────────────────────────────────────────
info "コンテナを再作成します（データは保持されます）..."
docker compose -f "${COMPOSE_FILE}" up -d --force-recreate
ok "コンテナ再作成完了"

# ── OnlyOffice 起動待ち ────────────────────────────────────────────────────────
info "OnlyOffice の起動を待機中..."
for i in $(seq 1 30); do
  if docker exec onlyoffice supervisorctl status ds:docservice 2>/dev/null \
      | grep -q "RUNNING"; then
    ok "OnlyOffice 起動確認（${i}秒）"
    break
  fi
  if [[ "${i}" -eq 30 ]]; then
    warn "30秒待機しましたが起動確認できませんでした。フォント生成を続行します。"
  fi
  sleep 1
done

# ── フォントキャッシュ再生成 ───────────────────────────────────────────────────
info "コンテナ内でフォントキャッシュを再生成します..."

docker exec onlyoffice bash -c "
  set -e
  echo '[1/4] fc-cache を実行...'
  fc-cache -f -v /usr/share/fonts/custom 2>&1 | tail -5

  echo '[2/4] AllFonts.js を生成...'
  cd /var/www/onlyoffice/documentserver
  (
    set -o pipefail
    node core/DocService/sources/AllFontsGen.js \
      --fonts-dir=/usr/share/fonts \
      --out=/var/www/onlyoffice/documentserver/core-fonts 2>&1 | tail -5 || \
    node tools/fontgen/allfonts.js 2>&1 | tail -5 || \
    /usr/bin/documentserver-generate-allfonts.sh 2>&1 | tail -5 || \
    true
  )

  echo '[3/4] プレゼンテーションテーマを再生成...'
  /usr/bin/documentserver-generate-all-themes.sh 2>&1 | tail -3 || true

  echo '[4/4] JS キャッシュを再生成...'
  /usr/bin/documentserver-pluginsmanager.sh 2>&1 | tail -3 || true
"

# ── nginx リロード ─────────────────────────────────────────────────────────────
info "nginx をリロード..."
docker exec onlyoffice nginx -s reload 2>/dev/null || true

# ── フォント認識確認 ───────────────────────────────────────────────────────────
echo ""
info "認識されたカスタムフォント一覧:"
docker exec onlyoffice fc-list /usr/share/fonts/custom 2>/dev/null \
  | awk -F: '{print "   ", $2}' | sort -u \
  || warn "fc-list での確認に失敗しました（フォント自体は追加されています）"

# ── 完了 ───────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "フォント追加完了！"
echo ""
echo "  フォントソース : ${FONT_SRC} (${FONT_COUNT} ファイル)"
echo "  コンテナ内パス : ${FONT_DST} (read-only マウント)"
echo "  compose ファイル: ${COMPOSE_FILE}"
echo "  バックアップ   : ${BACKUP}"
echo ""
echo "  ブラウザキャッシュをクリアしてから OnlyOffice でフォントを確認してください。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
