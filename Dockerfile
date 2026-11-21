# syntax=docker/dockerfile:1.7
# glibc 镜像支持构建工具的预编译二进制；生产环境建议固定镜像 digest。
ARG NODE_IMAGE=node:22-bookworm-slim
ARG NPM_REGISTRY=https://registry.npmjs.org

FROM ${NODE_IMAGE} AS deps
ARG NPM_REGISTRY
WORKDIR /app
ENV npm_config_registry=${NPM_REGISTRY} \
    npm_config_update_notifier=false \
    npm_config_fund=false \
    npm_config_audit=false
COPY . .
RUN --mount=type=cache,target=/root/.npm npm ci

FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY --from=deps /app /app
COPY . .
RUN npm run build \
 && test -f packages/cli/dist/cli.bundle.js \
 && test -f packages/cli/dist/models.json \
 && test -f packages/cli/dist/ui/index.html \
 && node packages/cli/dist/cli.bundle.js --version

FROM ${NODE_IMAGE} AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    MODELMUX_HOME=/data \
    MODELMUX_KEYRING=/keyring \
    MODELMUX_WEB_UI_ROOT=/app/dist/ui
RUN install -d -o node -g node -m 0700 /data /keyring
COPY --from=build --chown=node:node /app/packages/cli/dist/cli.bundle.js /app/dist/cli.bundle.js
COPY --from=build --chown=node:node /app/packages/cli/dist/models.json /app/dist/models.json
COPY --from=build --chown=node:node /app/packages/cli/dist/ui/ /app/dist/ui/
COPY --from=build --chown=node:node /app/packages/cli/package.json /app/package.json
RUN chmod 0755 /app/dist/cli.bundle.js \
 && ln -s /app/dist/cli.bundle.js /usr/local/bin/modelmux \
 && ln -s /app/dist/cli.bundle.js /usr/local/bin/mx
USER node
EXPOSE 4412
VOLUME ["/data", "/keyring"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["node","-e","fetch('http://127.0.0.1:4412/health').then(r=>{if(!r.ok)process.exit(1);return r.json()}).then(j=>process.exit(j&&j.ok&&j.service==='modelmux'?0:1)).catch(()=>process.exit(1))"]
ENTRYPOINT ["node", "/app/dist/cli.bundle.js"]
CMD ["serve", "--addr", "127.0.0.1:4412"]
