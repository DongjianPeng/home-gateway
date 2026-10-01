# Claude 协作规约（home-gateway）

- 本仓库是家里 w350t 上的局域网网关：Traefik（宿主机网络，按 Docker label 路由）+ 到云服务器的 SSH 隧道容器。只部署在 w350t 一台机器，`git pull && ./ctl.sh start` 即发布。
- 域名规则：`<服务>.w350t.sz` 本机服务，`<服务>.tx.w350t.sz` 腾讯云 continuum 上经隧道的服务；家里电脑靠 hosts 解析（hosts/r9000p-hosts.txt）。
- 转发规则唯一事实源是 ssh/config；远端真实地址在 ssh/hosts.conf（不进 git，由 `./ctl.sh init` 从本机 ssh 别名生成）；密钥不进仓库，挂宿主机 /root/.ssh 里的那把。
- 不做 TLS、不做鉴权、不引入共享网络；其他项目接入只加三行 label。
- 回答、注释用简体中文，禁用 emoji；新建脚本加 `@author DongjianPeng`；不写行尾注释。
- 远端 IP、密钥、密码不写进任何文件；需要时用占位符并在 README 说明来源。
