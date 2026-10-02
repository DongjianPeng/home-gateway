#!/usr/bin/env bash
# 用家里的自签 CA 给网关签发 / 续签通配证书，干的是 K3S 里 cert-manager 的活。
#   ./certs/renew.sh            证书不存在、或剩余有效期不足 CERT_RENEW_BEFORE_DAYS 天时重签，否则什么都不做
#   ./certs/renew.sh --force    立即重签（改了 CERT_REMOTE_PREFIXES 之后用）
# 签出的 certs/wildcard.crt / .key 由 Traefik 的 file provider 自动热加载，不用重启。
# 配合 /etc/cron.d 每周跑一次（./ctl.sh cert-cron 安装），到期前 30 天自动换新。
#
# @author DongjianPeng
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

env_value() {
  local value
  value="$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  echo "${value:-$2}"
}

CA_CERT="$(env_value CA_CERT /root/ca/ca.crt)"
CA_KEY="$(env_value CA_KEY /root/ca/ca.key)"
SUFFIX="$(env_value DOMAIN_SUFFIX w350t.sz)"
DAYS="$(env_value CERT_DAYS 397)"
RENEW_BEFORE_DAYS="$(env_value CERT_RENEW_BEFORE_DAYS 30)"
REMOTE_PREFIXES="$(env_value CERT_REMOTE_PREFIXES tx)"
CRT=certs/wildcard.crt
KEY=certs/wildcard.key

[[ -f "$CA_CERT" && -f "$CA_KEY" ]] || { echo "错误：找不到 CA：$CA_CERT / $CA_KEY，改 .env 的 CA_CERT / CA_KEY" >&2; exit 1; }

if [[ "${1:-}" != "--force" && -f "$CRT" ]] \
  && openssl x509 -in "$CRT" -checkend $((RENEW_BEFORE_DAYS * 86400)) >/dev/null; then
  echo "证书剩余有效期超过 ${RENEW_BEFORE_DAYS} 天，不续签：$(openssl x509 -in "$CRT" -noout -enddate)"
  exit 0
fi

# 通配符只匹配一层子域，每个远端前缀（tx 等）都要单独列一条 *.<前缀>.<后缀>
sans="DNS:${SUFFIX},DNS:*.${SUFFIX}"
for prefix in $REMOTE_PREFIXES; do
  sans+=",DNS:*.${prefix}.${SUFFIX}"
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\nbasicConstraints=CA:FALSE\n' \
  "$sans" > "$tmp/ext.cnf"
openssl req -new -newkey rsa:2048 -nodes -keyout "$tmp/key" -subj "/CN=*.${SUFFIX}" -out "$tmp/csr" 2>/dev/null
# 序列号文件放临时目录，不往 CA 目录写东西
openssl x509 -req -in "$tmp/csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial -CAserial "$tmp/srl" \
  -days "$DAYS" -sha256 -extfile "$tmp/ext.cnf" -out "$tmp/crt" 2>/dev/null

# 先落临时文件再 mv，Traefik 的目录监听不会读到写了一半的文件
install -m 600 "$tmp/key" "$KEY.new" && mv "$KEY.new" "$KEY"
install -m 644 "$tmp/crt" "$CRT.new" && mv "$CRT.new" "$CRT"
echo "已签发：$(openssl x509 -in "$CRT" -noout -enddate)"
echo "SAN：$sans"
