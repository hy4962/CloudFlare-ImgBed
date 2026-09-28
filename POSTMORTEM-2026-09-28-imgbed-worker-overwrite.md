# 事故复盘：图床突然要求「认证码」· imgbed.9ll.uk 全站 API 404

- **日期**：2026-09-28
- **影响**：`https://imgbed.9ll.uk` 全站 API 不可用。前端静态页面正常打开，但每次访问都被弹到「请输入认证码」登录页，且**任何密码都无效**；上传、后台、文件读取全部不可用。
- **持续时间**：约从升级到 v2.7.7 起，至 2026-09-28 22:43 修复。
- **级别**：可用性全损（P1）。

---

## 1. 一句话结论

**这个站点从来没有设置过上传认证码。** 那个「请输入认证码」页面是假象 —— Cloudflare 的 Git 集成把 Worker 覆盖成了一个**只有静态资源、没有服务端脚本**的版本，导致全部 `/api/*` 返回 404，而前端路由守卫把「接口请求失败」也当成「未登录」，于是跳转到登录页。

---

## 2. 故障判据（下次直接照这个查）

对站点实测：

| 路径 | 正常 | 本次故障 |
|---|---|---|
| `/api/auth/sessionCheck` | `200 {"valid":false,"adminRequired":...,"userRequired":...}` | **`404` 且响应体 0 字节** |
| `/api/userConfig` | `200` | `404` |
| `/api/manage/sysConfig/page` | `401`（需管理员，属正常） | `404` |
| `/dashboard` | `200`（SPA 回退） | `404` |
| `/js/app.<hash>.js` | `200` | `200`（**静态一直是好的**） |
| `/index.html` | `307` → `/`（Workers Assets 特征；Cloudflare Pages 是 `308`） | 同左 |

一条命令判断：

```bash
curl -s -w "\n[%{http_code}]\n" https://imgbed.9ll.uk/api/auth/sessionCheck
```

- 返回 `200` + JSON → 后端存活。**注意看 `userRequired`**：
  - `false` → 没有上传认证码，不需要登录，登录页一定是别的原因
  - `true` → 确实设过认证码（见第 6 节）
- 返回 `404` 且 0 字节 → 后端没部署（本次故障）

> 关键认知：前端路由守卫的 `.catch()` 分支对**任何**接口失败都会跳登录页。所以「接口 404」和「认证码不对」在用户眼里长得一模一样，必须先用上面的命令区分。

---

## 3. 根因链

### 3.1 触发源：fork 每天自动同步上游

本仓库是 `MarSeventh/CloudFlare-ImgBed` 的 fork。`.github/workflows/sync-upstream.yml` 里有：

```yaml
on:
  schedule:
    - cron: "0 0 * * *"          # 每天 UTC 00:00（北京时间 08:00）自动执行
jobs:
  sync_latest_from_upstream:
    if: ${{ github.event.repository.fork }}
    steps:
      - uses: aormsby/Fork-Sync-With-Upstream-action@v3.4   # 把上游 merge 进 main
      - name: Trigger Worker deploy
        run: gh workflow run deploy-worker.yml --repo ... --ref main
```

也就是说：**每天早上 8 点，本仓库的 `main` 会自动多出提交，且会自动触发一次 Worker 部署，全程无需人工操作。**

### 3.2 致命点：两条部署链争抢同一个 Worker

同一个提交落到 `main` 后，会同时唤醒两条部署链：

| 链路 | 使用的配置 | 部署结果 | 速度 |
|---|---|---|---|
| GitHub Action `.github/workflows/deploy-worker.yml` | `deploy/worker/wrangler.toml`（含 `main = "index.js"`、`[assets]`、KV 绑定） | **完整 Worker**（API 齐全） | 快 |
| Cloudflare Dashboard 的 Git 集成 | 分支 `cloudflare/workers-autoconfig` 的根 `wrangler.jsonc` | **纯静态 Worker**（只有 assets） | 慢（要装依赖） |

Cloudflare 自动生成的那份配置是罪魁祸首 —— 它**没有 `main`**：

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "cloudflare-imgbed",
  "compatibility_date": "2026-07-17",
  "observability": { "enabled": true },
  "assets": { "directory": "frontend-dist" },   // ← 只有静态资源
  "compatibility_flags": ["nodejs_compat"]      // ← 没有 main，也没有 not_found_handling
}
```

没有 `main` ⇒ Worker 里没有请求处理脚本 ⇒ 所有 `/api/*`、`/upload`、`/random`、`/file/`、`/dashboard` 一律 404 空响应。
没有 `not_found_handling` ⇒ 未知路径不回退 `index.html`，直接 404。

**两条链抢同一个 Worker，「谁后跑谁生效」。Cloudflare 那条要装依赖、更慢，通常它赢 —— 也就是通常把 API 覆盖掉。**

### 3.3 表象：前端把你踢到登录页

```
路由守卫 → GET /api/auth/sessionCheck → 404 → .catch() → 跳转 { name: 'login' }
```

于是「升级后突然要输入认证码」。**密码无论如何都输不对，因为根本没有任何代码在验证密码。**

---

## 4. 时间线

| 时间（2026-09-28） | 事件 |
|---|---|
| 之前某日 08:00 | 自动同步把上游从 v2.7.5 拉到 v2.7.6 / v2.7.7 |
| 同步后 | 两条部署链同时跑，Cloudflare Git 构建后收尾 → Worker 变成纯静态 → 本站开始显示登录页 |
| 22:26 | 向 `main` 推送 `bf60dfc`（部署助手脚本）→ 再次同时触发两条链 |
| ~22:28 | GitHub Action 先跑完 → **API 短暂恢复** |
| ~22:35 | Cloudflare Git 构建后跑完 → **API 再次消失**（竞态当场复现） |
| 22:43 | 断开 Cloudflare Git 集成；手动触发 `deploy-worker.yml`（`workflow_dispatch`） |
| 22:43:45 / 22:45:02 | 两次实测 `sessionCheck` 均返回 `200 {"valid":false,"adminRequired":true,"userRequired":false}`，`/dashboard` 200，**恢复且稳定** |

---

## 5. 修复动作

1. **断开 Cloudflare Git 集成（根治）**
   Cloudflare Dashboard → Workers & Pages → `cloudflare-imgbed` → **Settings → Builds → Disconnect**

2. **手动部署一次完整 Worker**
   GitHub → 本仓库 → Actions → *Deploy to Cloudflare Workers* → **Run workflow**（分支 `main`）
   > 用 `workflow_dispatch` 而不是 push：它不产生新提交，因此不会惊动 Cloudflare 的构建。

3. **验证**
   ```bash
   curl -s -w "\n[%{http_code}]\n" https://imgbed.9ll.uk/api/auth/sessionCheck
   # 期望：{"valid":false,"adminRequired":true,"userRequired":false} [200]
   ```

断开之后就是理想状态：每天 08:00 自动同步上游 → 自动触发 Action → 自动部署完整 Worker，**全自动且没有第二条链来覆盖**。

---

## 6. 认证机制速查（下次需要时）

- **是否强制用户端登录**：只看 `securityConfig.auth.user.authCode` 是否非空
- **读取顺序**：KV `manage@sysConfig@security` → 环境变量 `AUTH_CODE`；管理端同理回退 `BASIC_USER` / `BASIC_PASS`
- **存储格式**：`$pbkdf2$salt$hash`（兼容历史 `$sha256$` 与明文），后台接口只返回 `_hasPassword` 占位，**读不回原值**
- **后台入口**：系统设置 → 安全设置 → 认证管理 → 用户端认证 → 上传密码（旁边有「清除认证信息」）
- **忘记密码时的逃生口**：
  1. 配置环境变量 `RESET_KEY=<一串足够复杂的字符串>`
  2. 访问 `https://<域名>/api/auth/resetAuth?key=<该字符串>`
     （源码注释里写的 `/api/resetAuth` 已过时，真实路由带 `/auth/`）
  3. 全部认证被清空，重新进后台设置即可；用完请删除或更换 `RESET_KEY`
- **想彻底取消登录页**：把用户端密码清空即可（未配置时后端直接放行）

> 注意：由于上游代码限制，**明文认证码一旦保存就会被哈希，之后无法找回**，只能重置。

---

## 7. 遗留事项与下次升级 Checklist

- [ ] **【重要】升级后先跑第 2 节的 `curl` 判据**，不要凭「弹登录页」就去翻认证码
- [ ] 确认 Cloudflare 的 Git 集成处于 **Disconnected** 状态（否则每天 08:00 的自动同步都会把 API 覆盖掉）
- [ ] `[images] binding = "IMAGES"` 是 v2.7.6 新增项。**账号未开通 Images / Transformations 时 `wrangler deploy` 会直接报错**，此时删掉 `deploy/worker/wrangler.toml` 里 `[images]` 两行再部署
- [ ] 域名 DNS 目前是指向第三方「CF 优选」的 CNAME 链：
      `123.cf.090227.xyz → cf.hw.090227.xyz → ct.hw.090227.xyz → openai.com.cdn.cloudflare.net`
      该链路在国内部分运营商 DNS 上不稳定（表现为「找不到网页」），建议改用 Cloudflare 原生解析
- [ ] 本地部署助手 `deploy-worker.bat`（本仓库根目录）：双击即可完成「装依赖 → 检查登录 → 列出 KV → 填绑定 → 生成路由 → 部署 → 验证」全流程

---

## 8. 附：本次排查中用到的关键命令

```bash
# 判断后端是否存活
curl -s -w "\n[%{http_code}]\n" https://imgbed.9ll.uk/api/auth/sessionCheck

# 判断部署面（Pages 是 308，Workers 是 307）
curl -s -D - -o /dev/null https://imgbed.9ll.uk/index.html | grep -i location

# 看 fork 里有没有 Cloudflare 自动生成的配置（有 = 大概率开着 Git 集成）
git ls-remote --heads origin | grep workers-autoconfig

# 本地完整部署（在仓库根目录执行）
npm install --workspace=@cloudflare-imgbed/common --workspace=@cloudflare-imgbed/worker
node deploy/worker/generate-routes.js
npx wrangler deploy --config deploy/worker/wrangler.toml
```
