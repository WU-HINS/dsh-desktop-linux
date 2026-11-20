#!/usr/bin/env bash
# dsh-update — 从上游 release 直接升级 DeepSeek Harness Linux 桌面端。
#
# 默认源：https://github.com/ffyfox/dsh-desktop-linux（持续维护的 Linux 移植）。
# 用 DSH_UPDATE_REPO 可指向别的仓库（例如你自己签名的构建）。
#
#   dsh-update --check                 # 只看有没有新版本
#   dsh-update                         # 升级到最新（自动选格式，装前确认）
#   dsh-update --yes                   # 不问，直接装
#   dsh-update --format=appimage       # deb | rpm | appimage | arch
#   dsh-update --tag=v0.2.2rc5         # 指定版本（回滚也用它）
#   dsh-update --dry-run               # 只下载与校验，不安装
set -euo pipefail

REPO="${DSH_UPDATE_REPO:-ffyfox/dsh-desktop-linux}"
API="https://api.github.com/repos/$REPO"
TAG=""
FORMAT=""
CHECK_ONLY=0
ASSUME_YES=0
ALLOW_PRE=1
DRY_RUN=0
KEEP_DOWNLOAD=0
FORCE=0
DOWNLOAD_DIR="${DSH_UPDATE_DOWNLOAD_DIR:-}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsh-update"
APPIMAGE_HOME="${DSH_APPIMAGE_HOME:-$HOME/Applications}"
APPIMAGE_NAME="DeepSeek-Harness.AppImage"
# 国内直连 GitHub release 经常只有几十 KB/s；默认允许失败后自动走镜像前缀。
# 想固定镜像：--mirror=https://ghfast.top/ 或 DSH_UPDATE_MIRROR=...
MIRROR="${DSH_UPDATE_MIRROR:-}"
MIRROR_FALLBACKS=(https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/)

die() { printf 'dsh-update: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-pre) ALLOW_PRE=0 ;;
    --keep-download) KEEP_DOWNLOAD=1 ;;
    --force) FORCE=1 ;;
    --mirror=*) MIRROR="${arg#*=}" ;;
    --no-mirror) MIRROR="none" ;;
    --format=*) FORMAT="${arg#*=}" ;;
    --tag=*) TAG="${arg#*=}" ;;
    --repo=*) REPO="${arg#*=}"; API="https://api.github.com/repos/$REPO" ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$arg（--help 看用法）" ;;
  esac
done

case "$(uname -m)" in
  x86_64|amd64) DEB_ARCH=amd64; RPM_ARCH=x86_64; APPIMAGE_ARCH=x86_64; ARCH_PKG_ARCH=x86_64 ;;
  aarch64|arm64) DEB_ARCH=arm64; RPM_ARCH=aarch64; APPIMAGE_ARCH=arm64; ARCH_PKG_ARCH=aarch64 ;;
  *) die "不支持的架构：$(uname -m)" ;;
esac

installed_kind() {
  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' deepseek-harness 2>/dev/null | grep -q 'install ok installed'; then printf 'deb'; return; fi
  if command -v rpm >/dev/null 2>&1 && rpm -q dsh-desktop-linux >/dev/null 2>&1; then printf 'rpm'; return; fi
  if command -v pacman >/dev/null 2>&1 && pacman -Q dsh-desktop-linux >/dev/null 2>&1; then printf 'arch'; return; fi
  if [[ -x "$APPIMAGE_HOME/$APPIMAGE_NAME" ]]; then printf 'appimage'; return; fi
  printf 'none'
}

installed_version() {
  if command -v dpkg-query >/dev/null 2>&1; then
    local v
    v="$(dpkg-query -W -f='${Version}' deepseek-harness 2>/dev/null || true)"
    if [[ -n "$v" ]]; then printf '%s' "$v"; return; fi
  fi
  if [[ -f "$STATE_DIR/installed.json" ]]; then
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$STATE_DIR/installed.json" | head -1
    return
  fi
  [[ -x "$APPIMAGE_HOME/$APPIMAGE_NAME" ]] && printf 'appimage-unknown'
}

# 0.2.1~rc.2 -> 0.2.1-rc.2 ; 0.2.2rc5 -> 0.2.2-rc5
normalize_version() {
  local v="${1#v}"
  v="${v//\~/-}"
  v="$(printf '%s' "$v" | sed -E 's/^([0-9][^-]*[0-9])([A-Za-z].*)$/\1-\2/')"
  printf '%s' "$v"
}

compare_tokens() {
  local a="$1" b="$2"
  if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then
    if (( 10#$a < 10#$b )); then echo -1; elif (( 10#$a > 10#$b )); then echo 1; else echo 0; fi
    return
  fi
  [[ "$a" =~ ^[0-9]+$ ]] && { echo -1; return; }
  [[ "$b" =~ ^[0-9]+$ ]] && { echo 1; return; }
  if [[ "$a" < "$b" ]]; then echo -1; elif [[ "$a" > "$b" ]]; then echo 1; else echo 0; fi
}

version_cmp() {
  local a b amain apre bmain bpre
  a="$(normalize_version "$1")"; b="$(normalize_version "$2")"
  amain="${a%%-*}"; apre=""; [[ "$a" == *-* ]] && apre="${a#*-}"
  bmain="${b%%-*}"; bpre=""; [[ "$b" == *-* ]] && bpre="${b#*-}"
  local i x y
  for i in 1 2 3; do
    x="$(cut -d. -f"$i" <<<"$amain")"; y="$(cut -d. -f"$i" <<<"$bmain")"
    x="${x:-0}"; y="${y:-0}"
    if (( 10#$x < 10#$y )); then echo -1; return; fi
    if (( 10#$x > 10#$y )); then echo 1; return; fi
  done
  if [[ -z "$apre" && -z "$bpre" ]]; then echo 0; return; fi
  if [[ -z "$apre" ]]; then echo 1; return; fi
  if [[ -z "$bpre" ]]; then echo -1; return; fi
  local -a at bt
  IFS='.-' read -r -a at <<<"$apre"
  IFS='.-' read -r -a bt <<<"$bpre"
  local n=${#at[@]}
  (( ${#bt[@]} > n )) && n=${#bt[@]}
  for (( i = 0; i < n; i++ )); do
    x="${at[i]:-}"; y="${bt[i]:-}"
    if [[ -z "$x" && -z "$y" ]]; then break; fi
    if [[ -z "$x" ]]; then echo -1; return; fi
    if [[ -z "$y" ]]; then echo 1; return; fi
    local c; c="$(compare_tokens "$x" "$y")"
    if [[ "$c" != 0 ]]; then echo "$c"; return; fi
  done
  echo 0
}

api_get() {
  local url="$1"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "$url" 2>/dev/null && return 0
  fi
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github+json' "$url"
}

list_assets() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.assets[] | [.name, (.size|tostring), .browser_download_url] | @tsv'
  else
    python3 -c 'import json,sys
d=json.load(sys.stdin)
for a in d["assets"]: print("\t".join([a["name"], str(a["size"]), a["browser_download_url"]]))'
  fi
}

pick_asset() {
  awk -F'\t' -v a="$1" -v b="$2" 'index($1,a) && $1 ~ b"$" {print $1; exit}' <<<"$ASSETS_TSV"
}

command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || die "需要 jq 或 python3 之一"

say "==> 源：$REPO"
if [[ -n "$TAG" ]]; then
  RELEASE_JSON="$(api_get "repos/$REPO/releases/tags/$TAG")" || die "取不到 release $TAG"
else
  LIST_JSON="$(api_get "repos/$REPO/releases?per_page=30")" || die "取不到 release 列表"
  if command -v jq >/dev/null 2>&1; then
    if [[ "$ALLOW_PRE" == 1 ]]; then
      TAG="$(jq -r '[.[]|select(.draft|not)]|.[0].tag_name // empty' <<<"$LIST_JSON")"
    else
      TAG="$(jq -r '[.[]|select(.draft|not)|select(.prerelease|not)]|.[0].tag_name // empty' <<<"$LIST_JSON")"
    fi
  else
    TAG="$(python3 -c 'import json,sys
d=[r for r in json.load(sys.stdin) if not r.get("draft")]
if sys.argv[1] != "1": d=[r for r in d if not r.get("prerelease")]
print(d[0]["tag_name"] if d else "")' "$ALLOW_PRE" <<<"$LIST_JSON")"
  fi
  [[ -n "$TAG" ]] || die "没有找到可用 release"
  RELEASE_JSON="$(api_get "repos/$REPO/releases/tags/$TAG")" || die "取不到 release $TAG"
fi

LATEST_VERSION="$(normalize_version "${TAG#v}")"
CURRENT_KIND="$(installed_kind)"
CURRENT_RAW="$(installed_version)"
CURRENT_VERSION="$(normalize_version "${CURRENT_RAW:-0.0.0}")"

say "==> 当前安装：${CURRENT_RAW:-无}（格式：$CURRENT_KIND）"
say "==> 上游最新：$TAG"

if [[ -n "$CURRENT_RAW" && "$CURRENT_RAW" != appimage-unknown ]]; then
  cmp="$(version_cmp "$LATEST_VERSION" "$CURRENT_VERSION")"
  if [[ "$cmp" -le 0 ]]; then
    say "==> 已是最新，无需升级"
    exit 0
  fi
fi

ASSETS_TSV="$(list_assets <<<"$RELEASE_JSON")"

if [[ -z "$FORMAT" ]]; then
  case "$CURRENT_KIND" in
    deb|rpm|arch) FORMAT="$CURRENT_KIND" ;;
    appimage) FORMAT=appimage ;;
    *) if command -v dpkg-query >/dev/null 2>&1; then FORMAT=deb; else FORMAT=appimage; fi ;;
  esac
fi

case "$FORMAT" in
  deb) ASSET_NAME="$(pick_asset "linux-$DEB_ARCH-" ".deb")" ;;
  rpm) ASSET_NAME="$(pick_asset "linux-$RPM_ARCH-" ".rpm")" ;;
  appimage) ASSET_NAME="$(pick_asset "linux-$APPIMAGE_ARCH-" ".AppImage")" ;;
  arch) ASSET_NAME="$(pick_asset "-$ARCH_PKG_ARCH." ".pkg.tar.zst")" ;;
  *) die "未知格式：$FORMAT" ;;
esac

[[ -n "$ASSET_NAME" ]] || die "release $TAG 里没有 $FORMAT 格式的对应资产"

ASSET_LINE="$(awk -F'\t' -v n="$ASSET_NAME" '$1==n' <<<"$ASSETS_TSV")"
ASSET_URL="$(cut -f3 <<<"$ASSET_LINE")"
ASSET_SIZE="$(cut -f2 <<<"$ASSET_LINE")"

say "==> 选中：$ASSET_NAME（$(awk -v s="$ASSET_SIZE" 'BEGIN{printf "%.0f MB", s/1048576}')，$FORMAT）"

if [[ "$CHECK_ONLY" == 1 ]]; then
  say "==> --check：有更新"
  exit 0
fi

if pgrep -f 'deepseek-harness' >/dev/null 2>&1 && [[ "$FORCE" != 1 ]]; then
  warn "DeepSeek Harness 正在运行；装卸后需要重启应用（--force 可跳过此提示）"
fi

if [[ "$ASSUME_YES" != 1 && "$DRY_RUN" != 1 ]]; then
  read -r -p "继续升级到 $TAG？[y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { say "已取消"; exit 0; }
fi

if [[ -z "$DOWNLOAD_DIR" ]]; then DOWNLOAD_DIR="$(mktemp -d)"; fi
mkdir -p "$DOWNLOAD_DIR"
target="$DOWNLOAD_DIR/$ASSET_NAME"
say "==> 下载：$ASSET_URL"
download_asset() {
  local url="$1" out="$2" prefix
  say "    直连"
  if curl -fL --retry 1 --connect-timeout 15 --max-time 1800 --progress-bar -o "${out}.part" "$url"; then
    mv "${out}.part" "${out}"; return 0
  fi
  rm -f "${out}.part"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    say "    经 gh release download"
    if gh release download "$TAG" --repo "$REPO" --pattern "$ASSET_NAME" --dir "$(dirname "$out")" --clobber >/dev/null 2>&1; then
      return 0
    fi
  fi
  if [[ "$MIRROR" == "none" ]]; then return 1; fi
  local -a prefixes=()
  if [[ -n "$MIRROR" ]]; then prefixes=("$MIRROR"); else prefixes=("${MIRROR_FALLBACKS[@]}"); fi
  for prefix in "${prefixes[@]}"; do
    say "    经 ${prefix}"
    if curl -fL --retry 1 --connect-timeout 15 --max-time 1800 --progress-bar -o "${out}.part" "${prefix}${url}"; then
      mv "${out}.part" "${out}"; return 0
    fi
    rm -f "${out}.part"
  done
  return 1
}
download_asset "$ASSET_URL" "$target" || die "下载失败（可指定 --mirror=前缀 重试）"

base_url="${ASSET_URL%/*}"
say "==> 校验 SHA256"
SUMS_FILE=""
fetch_small() {
  local url="$1" out="$2" prefix
  if curl -fsSL --connect-timeout 10 --max-time 20 -o "$out" "$url" 2>/dev/null; then return 0; fi
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && [[ -n "${TAG:-}" ]]; then
    if gh release download "$TAG" --repo "$REPO" --pattern "$(basename "$url")" --dir "$(dirname "$out")" --clobber >/dev/null 2>&1; then
      return 0
    fi
  fi
  if [[ "$MIRROR" == "none" ]]; then return 1; fi
  local -a prefixes=()
  if [[ -n "$MIRROR" ]]; then prefixes=("$MIRROR"); else prefixes=("${MIRROR_FALLBACKS[@]}"); fi
  for prefix in "${prefixes[@]}"; do
    if curl -fsSL --connect-timeout 10 --max-time 25 -o "$out" "${prefix}${url}" 2>/dev/null; then return 0; fi
  done
  return 1
}
for candidate in SHA256SUMS SHA256SUMS.txt; do
  if fetch_small "$base_url/$candidate" "$DOWNLOAD_DIR/$candidate"; then SUMS_FILE="$DOWNLOAD_DIR/$candidate"; break; fi
done
if [[ -n "$SUMS_FILE" ]]; then
  expected="$(awk -v n="$ASSET_NAME" '($2==n)||($2=="*"n){print $1}' "$SUMS_FILE" | head -1)"
  if [[ -n "$expected" ]]; then
    actual="$(sha256sum "$target" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || die "SHA256 不匹配（期望 $expected 实际 $actual）"
    say "    sha256 匹配"
  else
    warn "校验和文件里未收录该资产"
  fi
else
  warn "取不到校验和文件，跳过字节校验"
fi

if fetch_small "$base_url/$ASSET_NAME.asc" "$target.asc"; then
  if fetch_small "$base_url/PUBKEY.asc" "$DOWNLOAD_DIR/PUBKEY.asc" && command -v gpg >/dev/null 2>&1; then
    tmpgnupg="$(mktemp -d)"; chmod 700 "$tmpgnupg"
    if GNUPGHOME="$tmpgnupg" gpg --batch --import "$DOWNLOAD_DIR/PUBKEY.asc" >/dev/null 2>&1; then
      if GNUPGHOME="$tmpgnupg" gpg --verify "$target.asc" "$target" >/dev/null 2>&1; then
        say "    GPG 签名有效"
      else
        warn "GPG 验签失败"
      fi
    fi
    rm -rf "$tmpgnupg"
  fi
fi

if [[ "$DRY_RUN" == 1 ]]; then
  say "==> --dry-run：下载与校验完成，未安装（$target）"
  exit 0
fi

mkdir -p "$STATE_DIR"
case "$FORMAT" in
  deb)
    if command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y "$target"; else sudo dpkg -i "$target"; fi ;;
  rpm) sudo dnf install -y "$target" || sudo rpm -Uvh --replacepkgs "$target" ;;
  arch) sudo pacman -U --noconfirm "$target" ;;
  appimage)
    mkdir -p "$APPIMAGE_HOME"
    [[ -f "$APPIMAGE_HOME/$APPIMAGE_NAME" ]] && cp -f "$APPIMAGE_HOME/$APPIMAGE_NAME" "$APPIMAGE_HOME/$APPIMAGE_NAME.prev"
    install -m 755 "$target" "$APPIMAGE_HOME/$APPIMAGE_NAME" ;;
esac

cat > "$STATE_DIR/installed.json" <<JSON
{
  "version": "${TAG#v}",
  "tag": "$TAG",
  "format": "$FORMAT",
  "asset": "$ASSET_NAME",
  "installedAt": "$(date -Is)"
}
JSON

[[ "$KEEP_DOWNLOAD" == 1 ]] || rm -rf "$DOWNLOAD_DIR"
say "==> 完成：${CURRENT_RAW:-未安装} → ${TAG#v}（$FORMAT）"
case "$FORMAT" in
  appimage) say "    可执行文件：$APPIMAGE_HOME/$APPIMAGE_NAME" ;;
  *) say "    重启 DeepSeek Harness 生效" ;;
esac
