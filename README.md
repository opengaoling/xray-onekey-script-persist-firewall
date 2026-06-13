# Xray-2go 一键安装脚本库

本仓库提供多种 Xray 安装方案，涵盖原生反代、Argo 隧道及常规部署，专为高速与安全设计。

---

## ⚡ 快速安装

根据您的需求选择对应的脚本：

### 1. 🚀 原生反代版 (推荐)
**特点**：专为套 CF 与直连 IP 设计，服务端/客户端隧道统一使用 VMess，支持多客户端映射、出口模式，并自动持久化放行直连和映射端口。
```bash
curl -Ls https://raw.githubusercontent.com/opengaoling/xray-onekey-script-persist-firewall/main/install_xray_reverse.sh -o install_xray_reverse.sh && bash install_xray_reverse.sh
```

### 2. ☁️ Argo 隧道版
**特点**：使用 Cloudflare Argo Tunnel 临时隧道，无需开放端口，适合内网无公网 IP 环境。
```bash
curl -Ls https://raw.githubusercontent.com/opengaoling/xray-onekey-script-persist-firewall/main/install_argo.sh -o install_argo.sh && bash install_argo.sh
```

### 3. 🛠️ 常规交互版
**特点**：全功能菜单，支持 VLESS Reality 与 VMess 常规部署，并自动持久化 iptables 端口放行规则。
```bash
curl -Ls https://raw.githubusercontent.com/opengaoling/xray-onekey-script-persist-firewall/main/install.sh -o install.sh && bash install.sh
```

---

## 🌟 原生反代版功能详解 (Native Reverse)

### 核心优势
- **可视化菜单**：集成安装、多客户端管理、映射管理。
- **VMess 反代隧道**：服务端 Portal 与客户端 Bridge 使用一致的 VMess 协议，避免协议不匹配导致反代失败。
- **Cloudflare 单路径回源**：CF 模式只需一个 VMess WS 路径，服务端通过反代识别域名分流。
- **出口模式**：可将内网客户端作为代理出口（访问 YouTube）。
- **直连/CF 双支持**：既可以套 CF 隐藏 IP，也可以直接通过 IP 高速连接；直连端口会自动持久化放行。

### 功能清单
- **服务端 (Portal)**：安装后支持动态添加多个内网客户端。
- **端口映射**：支持 `VPS:Port` -> `内网设备` 的精准转发。
- **客户端 (Bridge)**：支持转发模式（Web）和出口模式（上网）。

---

## 📖 部署示例 (套 CF)

1. **服务端**：安装 Portal，设置监听端口为随机高位端口，VMess WS 路径使用脚本生成的 `/vmess_xxx`。
2. **Cloudflare**：
   - 解析域名到 VPS IP。
   - 在 **Origin Rules** 中设置：如果请求路径等于脚本生成的 VMess WS 路径，则回源端口改为您的监听端口。
3. **客户端**：安装 Bridge，选择对应的识别域名。

## 🔥 防火墙持久化

- 常规交互版会把 VLESS/VMess 端口写入 `/etc/iptables/rules.v4`。
- 原生反代版会为直连模式端口和新增 VMess 映射端口同步运行时规则与 `/etc/iptables/rules.v4`。
- 如果服务器在 Oracle Cloud、AWS、GCP 等云平台，还需要在云控制台的安全组/安全列表中放行对应 TCP 端口。

---

## 📄 许可说明
本项目基于 Xray-core。请在遵守当地法律法规的前提下使用。
