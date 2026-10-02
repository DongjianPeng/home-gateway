# home-gateway：家里局域网的域名入口

把家里电脑访问服务的方式统一成「浏览器开域名」：w350t 本机的服务、以及云服务器上只绑回环的管理页（经 SSH 隧道拉回来），
都走 w350t 上的 Traefik 按域名分流。家里电脑只需在 hosts 里把 `*.w350t.sz` 指到 w350t，不记端口、不开隧道。
局域网内不做鉴权，安全边界就是家里的网络。HTTPS 是有的：Chrome 会把 http 强制升级成 https，不给它 443 就打不开，
所以用家里现成的自签 CA 签一张通配证书，80 一律跳 443；家里电脑早已导入这个根证书。

```
r9000p 浏览器   https://mihomo.tx.w350t.sz
   │  hosts：*.w350t.sz -> 192.168.0.231（hosts/r9000p-hosts.txt）
   ▼
w350t（Docker，本仓库）
   ├─ traefik             宿主机网络，监听 80/443（80 跳 443），按 Host 转到对应容器（Docker label 声明路由）
   ├─ certs/              ~/ca 的根证书签出的 *.w350t.sz 通配证书，脚本按周续签（cert-manager 的活）
   ├─ tunnel-continuum    alpine + ssh -N，把云上 127.0.0.1:9091 转到容器的 9091（ssh/config）
   ├─ mihomo-stack manager 本机服务，compose 里带 label 即被路由（mihomo.w350t.sz）
   └─ 以后的局域网项目      各自 compose 加三行 label 即接入，网关不用改
                                   │ 用 w350t root 登 continuum 的现有密钥
                                   ▼
                            continuum（腾讯云）mihomo-stack manager，只绑 127.0.0.1:9091
```

## 一、域名规则

| 形式 | 含义 | 例子 |
|---|---|---|
| `<服务>.w350t.sz` | w350t 本机上跑的服务 | `mihomo.w350t.sz`（本机 mihomo-stack 管理页）、`traefik.w350t.sz`（网关面板） |
| `<服务>.tx.w350t.sz` | 腾讯云 continuum 上经隧道拉回来的服务 | `mihomo.tx.w350t.sz`（云上 mihomo-stack 管理页）；TCP 类带端口：`pg.tx.w350t.sz:15432`（云上 Continuum 的 PostgreSQL） |

后缀在 `.env` 的 `DOMAIN_SUFFIX`。hosts 不支持泛解析，每加一个域名要在 [hosts/r9000p-hosts.txt](hosts/r9000p-hosts.txt) 加一行并同步到家里电脑；
嫌麻烦见第九节的 dnsmasq 方案。

证书的通配符只管一层：`*.w350t.sz` 覆盖不了 `mihomo.tx.w350t.sz`，所以每个远端前缀（`tx` 等）要登记在 `.env` 的 `CERT_REMOTE_PREFIXES`，
签证书时逐个加进 SAN。新增一台远端就加一个前缀，再 `./ctl.sh cert --force`。

## 二、w350t 部署（只做一次）

前提：Docker CE、`ssh continuum` 能免密登上云服务器（Continuum 的部署文档里配过）、家里的自签 CA 在 `~/ca/ca.crt` 与 `~/ca/ca.key`（路径可在 `.env` 改）。

```bash
git clone git@github.com:DongjianPeng/home-gateway.git ~/home-gateway && cd ~/home-gateway && chmod +x ctl.sh
./ctl.sh init          # 生成 .env、ssh/hosts.conf（从本机 ssh -G continuum 取地址 / 用户 / 端口），用 CA 签出证书，检查密钥、80/443 端口、firewalld
./ctl.sh ssh-check     # 用容器里的配置登一次远端，验证密钥与指纹；看到「隧道可连」再往下
./ctl.sh start         # 拉 traefik 镜像、构建隧道镜像、起容器
./ctl.sh status        # 两个容器 Up（隧道 healthy），证书到期日，每个域名的 HTTPS 状态码
./ctl.sh cert-cron     # 装上每周自动续签
```

`status` 里 `mihomo.tx.w350t.sz` 应为 200（云上管理页），`traefik.w350t.sz` 为 302（面板跳转到 /dashboard/）。
这一步不依赖 hosts，`status` 是在 w350t 本机带 Host 头探的；任一域名 404 看第八节。

init 的提示要处理：80 / 443 被占用（看是谁，K3S 已卸载的话不该有）；firewalld 未放行 http / https 时执行提示里的命令。

## 三、家里电脑（r9000p）

管理员 PowerShell 追加 hosts 并刷新缓存：

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "`n192.168.0.231 traefik.w350t.sz`n192.168.0.231 mihomo.w350t.sz`n192.168.0.231 mihomo.tx.w350t.sz"
ipconfig /flushdns
```

然后浏览器开 https://mihomo.tx.w350t.sz 、 https://mihomo.w350t.sz 、 https://traefik.w350t.sz 。
新电脑要先导入 w350t 上 `~/ca/ca.crt` 这个根证书（管理员 PowerShell：`certutil -addstore -f Root ca.crt`），否则浏览器报证书不受信任。

## 四、加一条云上服务（经隧道）

以后云上又有一个只绑回环的管理页（例如 Continuum 的某个内部页，端口 9200）：

1. [ssh/config](ssh/config) 的 `Host continuum` 段加一行 `LocalForward 0.0.0.0:9200 127.0.0.1:9200`；
2. [docker-compose.yml](docker-compose.yml) 的 `tunnel-continuum` 加两行 label（router 名要唯一）：
   `traefik.http.routers.<名>.rule=Host(\`<服务>.tx.${DOMAIN_SUFFIX}\`)` 与 `traefik.http.services.<名>.loadbalancer.server.port=9200`；
3. [hosts/r9000p-hosts.txt](hosts/r9000p-hosts.txt) 加一行，家里电脑同步；
4. `./ctl.sh restart tunnel-continuum`，`./ctl.sh status` 看新域名的 HTTP 码。

数据库之类非 HTTP 的服务不走 Traefik：同样加 `LocalForward`，再给 `tunnel-continuum` 加 `ports` 直接发布端口，
客户端连 `域名:端口`，域名只是好记的别名。已有的例子是云上 Continuum 的 PostgreSQL：ssh/config 里 `LocalForward 0.0.0.0:5432 127.0.0.1:5432`，
compose 里发布为 `.env` 的 `PG_TX_PORT`（默认 15432，w350t 自带的 PG 占着 5432），家里电脑的 DBeaver / DataGrip 连
主机 `pg.tx.w350t.sz`、端口 `15432`、库 `continuum`、用户 `continuum`，密码是云服务器 `~/continuum/deploy/compose/.env` 里的 `POSTGRES_PASSWORD`。
`./ctl.sh status` 会探这个端口是否在听。

加一台远端机器：照 `tunnel-continuum` 复制一个服务，ssh/config 加一个 `Host` 段，hosts.conf 加对应地址，
`.env` 的 `CERT_REMOTE_PREFIXES` 加上它的前缀后 `./ctl.sh cert --force`。

## 五、接入一个 w350t 本机项目

在那个项目自己的 compose 里给要暴露的服务加三行 label，`up -d` 后路由自动出现，网关这边什么都不用改：

```yaml
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<唯一名>.rule=Host(`<服务>.w350t.sz`)"
      - "traefik.http.services.<唯一名>.loadbalancer.server.port=<容器内端口>"
```

不需要加入任何共享网络：Traefik 跑在宿主机网络，按容器在自己 bridge 网络里的 IP 直达。
容器同时挂了多个网络时再加一行 `traefik.docker.network=<网络名>` 指定走哪个。
hosts 文件照例加一行。mihomo-stack 的 manager 已经带了这组 label（域名由它的 `.env` 里 `MANAGER_HOST` 决定）。

## 六、证书

干的是 K3S 里 cert-manager 的活，只是换成一个脚本加一条 cron：

- `certs/renew.sh` 用 `.env` 里 `CA_CERT` / `CA_KEY` 指向的根证书签一张通配证书到 `certs/wildcard.crt` / `.key`，
  SAN 含 `w350t.sz`、`*.w350t.sz` 和每个远端前缀的 `*.<前缀>.w350t.sz`，有效期 `CERT_DAYS`（默认 397 天）。
- 不带参数运行时，剩余有效期超过 `CERT_RENEW_BEFORE_DAYS`（默认 30 天）就什么都不做，否则重签；`--force` 立即重签。
- `./ctl.sh cert-cron` 写一条 `/etc/cron.d/home-gateway`，每周一凌晨跑一次，相当于 cert-manager 的 renewBefore。
- Traefik 的 file provider 监听 `traefik/dynamic/` 与证书文件，换了证书自动热加载，不重启、不断连接。
- 根证书本身到期要自己盯：`openssl x509 -in ~/ca/ca.crt -noout -enddate`。换根证书意味着所有电脑重新导入，尽量别换。

## 七、日常

```bash
./ctl.sh status                    # 容器状态 + 域名探测
./ctl.sh routes                    # Traefik 看到的全部路由（规则 -> 后端 -> 状态）
./ctl.sh logs                      # traefik 访问日志与错误
./ctl.sh logs tunnel-continuum     # ssh -N 正常时无输出，有输出就是断因（认证失败 / 指纹不符 / 网络不通）
./ctl.sh restart tunnel-continuum  # 改了 ssh/config 之后
./ctl.sh cert                      # 手动检查 / 续签证书；加了远端前缀用 ./ctl.sh cert --force
git pull && ./ctl.sh start         # 升级：仓库改了 compose / 配置 / 镜像版本后
```

隧道断了会自动重连：ssh 退出即被 docker 拉起，`ServerAliveInterval 30` 让半死的连接在一分半内被判死。
云服务器重装系统换了主机指纹时隧道会一直拒连（故意的），在 w350t 上 `ssh continuum` 一次更新 known_hosts 再 restart。

## 八、排障

| 现象 | 看什么 | 处理 |
|---|---|---|
| 浏览器打不开、ping 域名不通 | `ping mihomo.tx.w350t.sz` 应回 192.168.0.231 | hosts 没加或没刷新 DNS 缓存 |
| 404 page not found | `./ctl.sh routes` 有没有这条域名 | label 写错或容器没起；Traefik 只认 `traefik.enable=true` 的容器 |
| 502 Bad Gateway | `./ctl.sh status` 隧道是否 healthy；`logs tunnel-continuum` | 隧道断了 / 转发端口不对 / 目标容器重建中 |
| 隧道反复重启 | `logs tunnel-continuum` | 认证失败：`.env` 的 TUNNEL_KEY 指向的钥匙不对；指纹不符：见第七节；`ssh-check` 可单独验 |
| status 说 Traefik 不可达 | `docker ps`、`ss -lntp \| grep ':443 '` | 容器没起或 443 被别的占了；证书没签出来 traefik 也起不了 443（`./ctl.sh cert`） |
| 浏览器报证书不受信任 | 证书详情里的颁发者 | 这台电脑没导入 `~/ca/ca.crt`，见第三节 |
| 浏览器报证书域名不匹配 | `./ctl.sh status` 的证书行、`openssl x509 -in certs/wildcard.crt -noout -ext subjectAltName` | 新远端前缀没登记进 `CERT_REMOTE_PREFIXES`，加上后 `./ctl.sh cert --force` |
| 证书过期 | `./ctl.sh status` 的证书行 | cron 没装或没跑：`./ctl.sh cert --force` 救急，再 `./ctl.sh cert-cron`，看 /var/log/home-gateway-cert.log |
| Chrome 报 ERR_CONNECTION_REFUSED 而 Edge 正常 | 地址栏是不是变成了 https | Chrome 把 http 升级成 https 连 443；现在网关提供 https，出现这个说明 443 没在听，看上面「Traefik 不可达」 |
| 所有域名 404，traefik 日志反复 `client version 1.24 is too old` | `./ctl.sh logs` | Docker 29 要求 API 1.44 以上，Traefik 3.7 之前写死 1.24；`.env` 的 `TRAEFIK_IMAGE` 用 3.7 及以上，`./ctl.sh start` 重建 |
| 从 r9000p 连不上但 w350t 本机 status 正常 | `firewall-cmd --list-services` | 放行 http 与 https：`firewall-cmd --permanent --add-service=http --add-service=https && firewall-cmd --reload` |

## 九、可选：dnsmasq 泛解析

现在靠每台电脑的 hosts，加服务要改 hosts。改成 w350t 跑一个 dnsmasq 容器、`address=/w350t.sz/192.168.0.231` 一行泛解析，
家里电脑网卡的 DNS 填 192.168.0.231 即可，之后加服务不再碰 hosts。这里不需要改路由器，所以随时可以切。
缺点是 w350t 一停家里电脑就不能上网，除非再配一个备用 DNS。等域名多到烦了再做。

## 十、为什么这样设计

- **Traefik 而不是 nginx**：路由由各项目自己的 label 声明，接入新服务不用回网关改配置、不用 reload；容器重建换 IP 自动跟随（nginx 会缓存旧 IP 直到 reload）；自带面板看当前暴露了什么。
- **宿主机网络而不是共享网络**：避免「别的项目必须先起网关」的依赖，接入只需 label。代价是 80 端口直接占宿主机，这台机器上没别的东西要 80。
- **一个远端一个隧道容器**：转发规则集中在 ssh/config 一处，断线靠 docker restart 重连；和原来 K3S 里的 tunnel Deployment 一个模式。
- **HTTPS 用自签 CA 加脚本续签，而不是 ACME**：本来想纯 http 省事，但 Chrome 强制升级 https，不提供 443 就打不开。家里已有根证书且各电脑导入过，签一张通配证书加一条 cron 就够，不值得为此跑一个 step-ca 走 ACME。
- **用现有密钥、远端不建受限用户**：家里环境不值得为此多一套用户与 PermitOpen 白名单。要收紧时按 Continuum 隧道那套在远端建 nologin 的 tunnel 用户即可，本仓库只需改 `.env` 的 TUNNEL_KEY。
