# S-UI 汉化版安装脚本

基于 [bulianglin/demo](https://github.com/bulianglin/demo) 的 S-UI 面板，提供**全中文安装体验**和**SSL 证书一键配置**。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/xyf0104/demo/main/s-ui-install.sh)
```

## 功能特性

- ✅ 安装脚本全中文交互
- ✅ 管理菜单全中文（输入 `s-ui` 查看）
- ✅ 安装时可选配置域名 + SSL 证书
- ✅ 自动检测本地已有证书，避免重复申请
- ✅ 自动释放 80 端口，申请完成后恢复服务
- ✅ 自动将域名和证书路径写入 S-UI 数据库
- ✅ 安装完成显示完整访问地址（含端口和路径）

## 安装流程

```
1. 检测系统 & CPU 架构
2. 安装基础依赖
3. 下载 S-UI 最新版
4. 自动覆盖汉化版管理脚本
5. 交互配置：面板端口 / 路径 / 订阅端口 / 路径 / 管理员凭据
6. 可选：域名 & SSL 证书配置
   ├─ 本地已有证书 → 直接使用
   ├─ acme.sh 缓存有证书 → 复制使用
   └─ 全新申请 → 自动安装 acme.sh → 申请 Let's Encrypt 证书
7. 启动服务，输出访问地址
```

## 管理命令

```bash
s-ui              # 打开管理菜单
s-ui start        # 启动
s-ui stop         # 停止
s-ui restart      # 重启
s-ui status       # 查看状态
s-ui log          # 查看日志
s-ui update       # 更新
s-ui uninstall    # 卸载
s-ui help         # 命令帮助
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `s-ui-install.sh` | 一键安装脚本（服务器上运行） |
| `s-ui.sh` | 汉化版管理脚本（安装后替换到 `/usr/bin/s-ui`） |

## 致谢

- [bulianglin/demo](https://github.com/bulianglin/demo) — 原版 S-UI
- [alireza0/s-ui](https://github.com/alireza0/s-ui) — S-UI 面板项目
- [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh) — SSL 证书工具
