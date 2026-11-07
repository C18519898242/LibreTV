# 部署说明（给服务器上的 AI / 运维操作者）

> 本文档面向执行部署的 AI 或人工操作者。请按顺序执行，不要跳过校验步骤。
> 目标：把**本仓库的移动端优化版**部署到服务器，替换当前运行的上游原版镜像。

---

## 0. 背景与约束（先读）

- 应用：LibreTV，一个 Next.js 15 应用（App Router），**无状态**。
  - 观看历史存在浏览器 IndexedDB，设置存在浏览器 localStorage；
  - 服务端**不挂载任何数据卷**，因此**重建镜像 / 重启容器不会丢用户数据**。
- 现有部署：使用上游镜像 `ghcr.io/librespark/libretv:latest`（docker compose）。
- 本次变更：代码里加入了移动端 UI 优化（见第 1 节），**不含任何后端/接口变更**，
  所有 API 路由、环境变量语义、端口、容器名都保持不变。
- 因此：**可以直接原地重建，无需数据迁移，无需改反向代理。**

---

## 1. 本次代码变更了什么（用于判断风险）

全部为前端样式与布局，涉及 9 个文件 + 3 个部署文件：

| 文件 | 变更 |
| --- | --- |
| `src/components/header.tsx` | 手机端顶栏改为「设置 + 汉堡菜单」，窄屏不再挤爆 |
| `src/components/icon.tsx` | 新增 `menu` 图标 |
| `src/components/drawer.tsx` | 新增 `mobileFull` 形态：手机端设置抽屉近全屏（92dvh） |
| `src/components/source-manager.tsx` | 设置抽屉启用 `mobileFull` |
| `src/components/detail-modal.tsx` | 手机端详情弹窗改为底部抽屉（贴底、圆角、安全区、内部滚动） |
| `src/components/dropdown.tsx` | 下拉面板限制最大宽度，防止撑出手机视口 |
| `src/app/globals.css` | 触屏窄屏输入框字号 16px（修 iOS 自动放大）；粗指针下放大点击热区 |
| `src/app/watch/page.tsx` | 分集列数自适应；手机端下载按钮只留图标 |
| `src/app/live/page.tsx` | 手机端隐藏完整流地址，频道分组换行显示 |

**后端无改动**。`src/app/api/**`、`src/lib/**` 均未修改。

部署新增文件（此次一并加入）：

- `docker-compose.local.yml` —— compose 覆盖文件，用于**用源码构建**而不是拉上游镜像
- `deploy-local.sh` —— 一键构建 + 启动 + 健康检查脚本
- `.gitattributes` —— 固定脚本为 LF 换行（Linux 上避免 `bad interpreter`）

---

## 2. 前置检查

在服务器上执行，逐条确认：

```bash
# 2.1 Docker 与 compose v2 可用
docker --version
docker compose version        # 需要 v2.x（输出 "Docker Compose version v2..."）

# 2.2 找到当前的部署目录（当前跑着原版的目录）
docker ps --filter name=libretv --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'
# 预期看到 container 名 libretv、镜像 ghcr.io/librespark/libretv:latest

# 2.3 确认该目录下有 .env 且含 PASSWORD
#     （compose 里 PASSWORD 是必填，缺了启动会直接失败）
ls -la .env && grep -E '^PASSWORD=' .env | sed 's/=.*/=<已设置>/'
```

如果 2.2 显示容器名不是 `libretv`，后续命令里的容器名请相应替换。

**资源检查**（Next.js 构建吃内存，**最少 2GB 可用内存**）：

```bash
free -h        # 或用 cat /proc/meminfo
nproc          # 构建会用到多核
```

若内存 < 2GB，先加 swap 再继续：

```bash
# 只做一次，已有 swap 则跳过
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## 3. 获取代码

把本仓库（移动端优化版）放到服务器上。任选一种：

### 方式 A：直接 clone 本仓库（推荐）

```bash
cd /opt                      # 或你惯用的目录
git clone <本仓库地址> libretv-mobile
cd libretv-mobile
```

### 方式 B：已有部署目录，切到本分支

```bash
cd <当前部署目录>
git remote -v                # 确认 origin 指向了本仓库
git fetch origin
git checkout <包含移动端优化的分支，如 feat/mobile-ui>
```

> ⚠️ 如果当前部署目录是**上游仓库**的 clone（origin 是 LibreSpark/LibreTV），
> 不要直接在那里 checkout —— 先按方式 A 新 clone 一份，避免污染上游工作区。

**校验代码版本**：

```bash
git log --oneline -5
# 应能看到形如 "feat(mobile): 移动端体验优化" 的提交

ls docker-compose.local.yml deploy-local.sh .gitattributes
# 三个文件都应存在

grep -n 'menu' src/components/icon.tsx | head -3
# 应能看到新增的 menu 图标
```

---

## 4. 准备 .env

把**原部署目录的 `.env` 原样复制过来**（密码、源配置、PROXY_SECRET 等都不要变）：

```bash
cp <原部署目录>/.env .env
chmod 600 .env
```

如果要保留原镜像名行为不变，也确认 `.env` 里**没有** `LIBRETV_IMAGE` 这行
（覆盖文件里已把镜像改为 `libretv-local:latest`，不受它影响，但避免混淆）。

检查 `.env` 至少有：

```dotenv
PASSWORD=你的访问密码
```

---

## 5. 部署（两种方式二选一）

### 方式一：使用脚本（最简单，推荐）

```bash
chmod +x deploy-local.sh
./deploy-local.sh
```

脚本会依次：检查 docker compose → 校验 `.env` → 构建镜像 → 启动容器 →
轮询 `/api/status` 健康检查 → 打印状态。

看实时日志：

```bash
./deploy-local.sh logs
```

停止服务（不动镜像）：

```bash
./deploy-local.sh down
```

### 方式二：直接用 docker compose

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

> 想以后少打这串命令，可以在 `.env` 里加一行：
> `COMPOSE_FILE=docker-compose.yml:docker-compose.local.yml`
> 之后直接 `docker compose up -d --build` 即可。

---

## 6. 部署后校验（必须全部通过）

### 6.1 容器状态

```bash
docker compose -f docker-compose.yml -f docker-compose.local.yml ps
# 期望：libretv 状态为 Up，镜像列为 libretv-local:latest

docker images | grep libretv-local
# 期望：存在 libretv-local:latest
```

### 6.2 版本号（关键，用于确认跑的是新代码）

```bash
curl -s http://127.0.0.1:8080/api/status
```

返回 JSON 里 `version` 字段来自 `package.json`。**注意**：本次改动没有升版本号，
所以它仍会显示 `2.21.2` —— 这**不能**用来区分新旧代码。请用 6.3 验证。

### 6.3 确认是新代码（关键）

```bash
# 构建产物里应包含汉堡菜单图标对应的 SVG path（24×24 中三条横线）
docker exec libretv sh -c "grep -rl 'M3.75 6.75h16.5M3.75 12h16.5' /app/.next/static 2>/dev/null | head -1"
# 有输出 → 新代码已生效；无输出 → 镜像还是旧的，回到第 5 步重建

# 也可以直接看前端 JS 里是否有 mobileFull 的样式类
docker exec libretv sh -c "grep -rl 'max-lg:rounded-t-xl' /app/.next/static 2>/dev/null | head -3"
```

### 6.4 从外部访问（经过反向代理）

```bash
curl -sI https://tv.xyz365.tech/ | head -5
# 期望 200/302（登录页重定向正常）
```

### 6.5 手机端实测（人工）

手机浏览器打开 `https://tv.xyz365.tech/`，确认：

1. 顶栏只剩「Logo + 齿轮 + 汉堡」，不再挤成一团；
2. 点汉堡能展开菜单（直播 / 关于 / 观看历史 / 下载管理 / 主题）；
3. 点齿轮打开设置——**面板应接近全屏**（不是原来的一半屏）；
4. 点搜索框 → 键盘**弹出时页面不应自动放大**；
5. 搜索一次，点任意结果 → 详情弹窗**从底部滑出、占满宽度**，剧集网格可滚动；
6. 进播放页，「下载本集」显示为图标按钮，顶栏不换行。

---

## 7. 回滚（出问题时）

**方式一：切回上游镜像（最快，30 秒）**

```bash
# 不带覆盖文件，直接拉上游镜像
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml ps
```

**方式二：代码回退**

```bash
git log --oneline -5
git checkout 722e86f          # 上游 2.21.2 的原始提交
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --build
```

**方式三：保留镜像回滚**

```bash
# 重新部署前先给当前镜像打 tag
docker tag libretv-local:latest libretv-local:backup-$(date +%Y%m%d)
# 出问题时
docker tag libretv-local:backup-<日期> libretv-local:latest
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --force-recreate
```

> 因为应用无状态，回滚不需要恢复任何数据。

---

## 8. 以后更新代码

```bash
cd <部署目录>
git pull
./deploy-local.sh
```

镜像层缓存会让第二次构建明显快于首次（通常 1–2 分钟）。

---

## 9. 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `PASSWORD is missing a value` | 没有 `.env` 或没写 PASSWORD | 按第 4 节补齐 |
| 构建时 `Killed` / OOM | 内存不足 | 按第 2 节加 swap，或 `NODE_OPTIONS=--max-old-space-size=2048` 后重试 |
| `npm ci` 报 lockfile 不匹配 | `package.json` 被改过但 `package-lock.json` 没更新 | 本地跑 `npm install` 提交更新的 lockfile |
| `deploy-local.sh: bad interpreter` | 文件是 CRLF 换行 | `sed -i 's/\r$//' deploy-local.sh` |
| 构建完但页面没变化 | 浏览器缓存 / Service Worker | 手机端强制刷新，或清站点数据 |
| 8080 端口被占用 | 旧容器还在跑 | `docker compose down` 后再起，或确认只有一套 compose 项目 |
| 构建很慢 | 首次全量构建（拉 npm 包 + Next 编译） | 正常，首次 3–8 分钟；后续走缓存 |

---

## 10. 补充说明

- 本项目的 Docker 构建是标准 Next.js standalone 多阶段构建（`Dockerfile`），
  构建期设 `DOCKER_BUILD=1` 让 `next.config.ts` 输出 standalone 产物。
- 覆盖文件只改了两件事：`build` 指向当前目录、镜像名改为 `libretv-local:latest`。
  其余（端口 8080、容器名、restart 策略、环境变量）全部沿用 `docker-compose.yml`。
- 反向代理（Nginx/Caddy）无需改动：容器仍监听 8080，行为不变。
- 若服务器还需要对外提供不同的域名/端口，改 `docker-compose.yml` 的 `ports` 即可，
  不要改 `docker-compose.local.yml`。
