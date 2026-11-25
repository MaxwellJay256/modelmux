# Docker 部署

用 Compose 运行网关：模型接口经 nginx 入口提供给宿主机与可信容器，管理控制台只经宿主机回环接入。

## 前置条件

- Docker Engine 与 Compose v2；BuildKit 可用（Dockerfile 使用缓存挂载）。
- 可拉取 `node:22-bookworm-slim` 与 `nginxinc/nginx-unprivileged:stable`，或用 `NODE_IMAGE` / `PROXY_IMAGE` 指向镜像代理。
- 宿主机安装 Node.js 与 Docker Compose，并能访问 Docker，用于控制台通道。

## 构建与启动

在仓库根执行：

```bash
docker network create modelmux-net
cp deploy/docker/.env.example deploy/docker/.env
docker compose -f deploy/docker/docker-compose.yml up -d --build
```

Compose 项目目录是 `deploy/docker/`，`.env` 从该目录读取。`MODELMUX_TAG` 控制镜像标签，生产环境建议固定 digest。

入口容器把模型接口发布到 `${MODELMUX_BIND:-127.0.0.1}:${MODELMUX_PORT:-4412}`；加入外部网络 `modelmux-net` 的容器通过 `modelmux:4412` 访问。共享网络中的容器可以调用模型接口，只应加入可信容器。

## 架构与网络边界

- `gateway`：非 root 运行 `serve --addr 0.0.0.0:4412`，只接入内部 `backend` 网络，不发布端口。
- `modelmux`：`nginx-unprivileged` 入口，只转发 `/health`、`/v1/models`、`/v1/chat/completions`、`/v1/messages`、`/v1/messages/count_tokens`、`/v1/responses`，其他路径（含 `/web`）返回 404。
- 控制台依赖真实回环 socket 与 Host 校验；经代理转发会被识别为本机请求。控制台不进入共享入口，也不要在入口增加 `/web` 代理。

## 控制台通道

在宿主机运行：

```bash
node scripts/docker-console.mjs
```

脚本只监听 `127.0.0.1:4413`，通过 `docker compose exec -T gateway` 连接容器内回环。打开输出的 `/web/` 地址，创建 API key、登录渠道。`MODELMUX_CONSOLE_PORT` 改端口，`MODELMUX_COMPOSE_FILE` 指定其他 Compose 文件。

## 数据与密钥

- `modelmux-data` → `/data`（`MODELMUX_HOME`）：渠道凭据、账号、日志与 API key 数据。
- `modelmux-keyring` → `/keyring`（`MODELMUX_KEYRING`）：API key 加密密钥。

两个卷分别备份并限制访问。丢失 keyring 会导致已有加密 API key 无法解密。普通 `docker compose down` 不删除卷，不要使用 `down -v`。已有卷的属主或权限不兼容时，需在停用实例并备份后由管理员修正，不可覆盖已有数据。

## 容器内登录

控制台或 CLI 的登录动作在网关容器内执行。不同渠道对回调地址的要求不同。

### traecn

浏览器授权后回调到 `TRAECN_LOGIN_PORT`（默认 `18080`）。容器部署需同时设置 `TRAECN_LOGIN_HOST=0.0.0.0` 与浏览器可达的 `TRAECN_PUBLIC_HOST`，并把该端口发布到宿主机。协议细节见 [traecn 协议](./channels/traecn/PROTOCOL.md)。例如：

```bash
docker compose -f deploy/docker/docker-compose.yml run --rm \
  --entrypoint mx \
  -p 127.0.0.1:18080:18080 \
  -e TRAECN_LOGIN_HOST=0.0.0.0 \
  -e TRAECN_PUBLIC_HOST=127.0.0.1 \
  gateway login traecn
```

浏览器不在宿主机上时，把发布地址与 `TRAECN_PUBLIC_HOST` 换成浏览器可达的地址。只绑 `0.0.0.0` 而不给 `TRAECN_PUBLIC_HOST` 会立即报错。回调路径带每次登录的随机 nonce，不匹配返回 404；不要把 18080 暴露到不可信网络。

### raccoon

授权完成后地址栏变成 `office-raccoon://auth/callback?…`，把整条 URL 粘回控制台或 CLI 的输入框；不需要回调端口。协议细节见 [raccoon 协议](./channels/raccoon/PROTOCOL.md)。

### 其他渠道

按 [渠道协议文档](./channels/README.md) 的登录章节确认是否需要发布回调端口。

## 验证与运维

```bash
docker compose -f deploy/docker/docker-compose.yml config --quiet
curl http://127.0.0.1:4412/health
curl http://127.0.0.1:4412/v1/models
docker compose -f deploy/docker/docker-compose.yml ps
```

健康检查只表示进程可用，不表示渠道已登录或模型可调用。`/health` 与 `/v1/models` 不要求 API key，调用模型需要控制台创建的有效 key。

推送门禁与容器会争用 4412 端口：先跑 `npm test` 或推送，再启动容器；容器运行时若测试出现 `ECONNREFUSED`，先停止 Compose 栈。

## 升级

拉取新代码后重新执行 `up -d --build`；数据卷与密钥卷保持不变。镜像用 `MODELMUX_TAG` 区分版本，生产环境建议固定 digest 并在升级前备份两个卷。
