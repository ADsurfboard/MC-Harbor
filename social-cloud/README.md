# 免费层好友同步服务

Cloudflare Workers + D1，原生客户端协议与 Python 服务一致。游戏网络通过 Terracotta / EasyTier 点对点连接；本服务只处理好友关系、主动共享的皮肤与最近游戏资料，不代理 Minecraft 游戏流量。

使用 Workers Free 和 D1 Free。不要开通付费 Workers 或绑定付费产品。当前官方免费额度为每日 100,000 次 Worker 请求、D1 每日 500 万行读取 / 10 万行写入及总计 5 GB 存储。免费套餐超限会拒绝请求，不以升级付费作为自动回退；平台政策与配额由平台决定，无法承诺第三方永久无限免费。

## 部署

在已登录的 Cloudflare 免费账号内创建 D1 数据库 `mc-harbor-friends`，将其 ID 填入 wrangler.jsonc。导入 schema.sql，再部署 worker.mjs：

```sh
npx wrangler d1 create mc-harbor-friends
npx wrangler d1 execute mc-harbor-friends --remote --file=schema.sql
npx wrangler deploy
```

使用返回的 HTTPS `workers.dev` 地址，无需购买域名。发布前检查 `/health` 和双向好友、皮肤及撤权流程。上线地址只写进启动器公开服务配置，不将 Cloudflare 令牌打包进 App 或源码。运行 `node test-worker.mjs` 使用内存 SQLite 执行生产请求处理器检查，所需 Node 版本为支持 node:sqlite 的 22.13+。

客户端按内容摘要增量同步，只上传变化条目，每批最多 25 条。服务使用索引、批量事务和最多 1000 条历史保留，仅在新会话加入时清理旧历史，减少免费行读写消耗。所有历史访问需要双向好友与对方共享授权；皮肤也需主动共享。关闭共享删除历史，取消皮肤共享立即停止提供纹理，删除好友立即收回访问权。好友备注与游戏路径保存在本机。

官方资料：[Workers 价格](https://developers.cloudflare.com/workers/platform/pricing/)、[D1 价格](https://developers.cloudflare.com/d1/platform/pricing/)、[D1 API](https://developers.cloudflare.com/d1/worker-api/d1-database/)。
