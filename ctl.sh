#!/usr/bin/env bash
# home-gateway 日常操作（在仓库根目录执行）：
#   ./ctl.sh init                  生成 .env 与 ssh/hosts.conf（从本机 ssh 别名取远端地址），检查密钥 / 80 端口 / 防火墙
#   ./ctl.sh ssh-check             用容器里的配置试登一次远端，验证密钥与指纹
#   ./ctl.sh start|stop|restart [服务]
#   ./ctl.sh status                容器状态 + 每个域名的 HTTP 探测
#   ./ctl.sh routes                Traefik 当前全部路由（规则 -> 后端）
#   ./ctl.sh logs [服务]           默认 traefik；隧道看 logs tunnel-continuum（ssh -N 正常时无输出）
#   ./ctl.sh build                 重建隧道镜像
#
# @author DongjianPeng
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

compose() { docker compose "$@"; }
die() { echo "错误：$*" >&2; exit 1; }
# 读 .env 里的一个键，没有就返回第二个参数
env_value() {
  local value
  value="$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  echo "${value:-$2}"
}

# 从 Traefik API 的 routers 列表里提取「域名 后端」
PY_HOSTS='
import json, re, sys
for r in json.load(sys.stdin):
    for host in re.findall(r"Host\(`([^`]+)`\)", r.get("rule", "")):
        print(host, r.get("service", ""))
'
PY_ROUTES='
import json, sys
rows = [r for r in json.load(sys.stdin) if r.get("provider") == "docker"]
for r in sorted(rows, key=lambda r: r.get("rule", "")):
    print("%-44s -> %-28s %s" % (r.get("rule", ""), r.get("service", ""), r.get("status", "")))
'

traefik_api() {
  curl -sS -m 5 -H "Host: traefik.$(env_value DOMAIN_SUFFIX w350t.sz)" "http://127.0.0.1/api/$1"
}

# 生成 ssh/hosts.conf：本机 ~/.ssh/config 里有这个别名就用 ssh -G 解析出的真值，没有就复制样例
generate_hosts_conf() {
  local alias="$1" hostname
  hostname="$(ssh -G "$alias" 2>/dev/null | awk '$1 == "hostname" {print $2}')"
  if [[ -n "$hostname" && "$hostname" != "$alias" ]]; then
    {
      echo "# 由 ./ctl.sh init 从本机 ssh -G $alias 生成；远端换了地址直接改这里再 ./ctl.sh restart tunnel-continuum"
      echo "Host continuum"
      ssh -G "$alias" | awk '
        $1 == "hostname" {print "    HostName " $2}
        $1 == "user"     {print "    User " $2}
        $1 == "port"     {print "    Port " $2}'
    } > ssh/hosts.conf
    echo "已生成 ssh/hosts.conf（来自 ssh -G $alias）"
  else
    cp ssh/hosts.conf.example ssh/hosts.conf
    echo "本机没有 ssh 别名 $alias，已复制样例到 ssh/hosts.conf，请填远端地址"
  fi
}

cmd_init() {
  [[ -f .env ]] || { cp .env.example .env; echo "已生成 .env"; }
  [[ -f ssh/hosts.conf ]] || generate_hosts_conf "$(env_value TUNNEL_SSH_ALIAS continuum)"
  local key known
  key="$(env_value TUNNEL_KEY /root/.ssh/id_rsa)"
  known="$(env_value TUNNEL_KNOWN_HOSTS /root/.ssh/known_hosts)"
  [[ -f "$key" ]] || echo "提示：找不到私钥 $key，改 .env 的 TUNNEL_KEY"
  [[ -f "$known" ]] || echo "提示：找不到 $known，先在本机 ssh 一次远端让它记录指纹"
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
    echo "提示：80 端口已被占用：$(ss -lntp | awk '$4 ~ /[:.]80$/ {print $NF}' | head -1)"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --query-service=http >/dev/null 2>&1 \
      || echo "提示：firewalld 未放行 80：firewall-cmd --permanent --add-service=http && firewall-cmd --reload"
  fi
  echo "下一步：./ctl.sh ssh-check 验证隧道能连，然后 ./ctl.sh start"
}

cmd_ssh_check() {
  [[ -f ssh/hosts.conf ]] || die "缺少 ssh/hosts.conf，先 ./ctl.sh init"
  compose build -q tunnel-continuum
  # 不带 -N，只跑一条 exit：登得上并立即退出说明密钥与指纹都对；转发端口在 start 后由 healthcheck 验证
  compose run --rm --no-deps tunnel-continuum ssh continuum exit && echo "隧道可连：密钥与指纹正确"
}

cmd_status() {
  compose ps
  echo
  local routers
  routers="$(traefik_api http/routers 2>/dev/null)" || { echo "Traefik API 不可达（容器没起或 80 没通）"; return 1; }
  echo "$routers" | python3 -c "$PY_HOSTS" | while read -r host service; do
    local code
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Host: $host" http://127.0.0.1/ || true)"
    printf '%-36s HTTP %-4s %s\n' "http://$host" "$code" "$service"
  done
}

case "${1:-}" in
  init) cmd_init ;;
  ssh-check) cmd_ssh_check ;;
  start) compose up -d --build "${@:2}" ;;
  stop) compose stop "${@:2}" ;;
  restart) compose restart "${@:2}" ;;
  status) cmd_status ;;
  routes) traefik_api http/routers | python3 -c "$PY_ROUTES" ;;
  logs) compose logs -f --tail 200 "${2:-traefik}" ;;
  build) compose build tunnel-continuum ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
