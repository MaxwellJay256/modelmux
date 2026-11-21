#!/usr/bin/env node
/** 本机回环控制台通道；通过 docker exec 接入容器回环，不公开管理接口。 */
import { createServer } from "node:net";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const port = Number(process.env.MODELMUX_CONSOLE_PORT ?? "4413");
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error("MODELMUX_CONSOLE_PORT 必须为 1 至 65535 的整数");
  process.exit(1);
}

const composeFile = process.env.MODELMUX_COMPOSE_FILE ?? resolve(dirname(fileURLToPath(import.meta.url)), "../deploy/docker/docker-compose.yml");
const bridge = "const net=require('node:net');const s=net.connect(4412,'127.0.0.1');process.stdin.pipe(s);s.pipe(process.stdout);s.on('error',()=>process.exit(1));s.on('end',()=>process.exit(0));";
const server = createServer((client) => {
  const child = spawn("docker", ["compose", "-f", composeFile, "exec", "-T", "gateway", "node", "-e", bridge], {
    stdio: ["pipe", "pipe", "inherit"],
    windowsHide: true,
  });
  client.on("error", () => child.kill());
  child.on("error", (error) => {
    console.error(`无法启动 docker compose exec：${error.message}`);
    client.destroy();
  });
  child.stdin.on("error", () => client.destroy());
  child.stdout.on("error", () => client.destroy());
  child.on("close", () => client.destroy());
  client.on("close", () => child.kill());
  client.pipe(child.stdin);
  child.stdout.pipe(client);
});
server.on("error", (error) => {
  console.error(`无法启动本机控制台通道：${error.message}`);
  process.exitCode = 1;
});
server.listen(port, "127.0.0.1", () => {
  console.log(`控制台：http://127.0.0.1:${port}/web/（按 Ctrl+C 关闭）`);
});
