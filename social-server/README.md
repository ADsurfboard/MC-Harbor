# MC Harbor 好友服务

Python 3.10+ 标准库实现，SQLite 存储，无付费服务依赖。它提供 MC Harbor 好友身份、双向确认、皮肤共享与最近游戏同步。游戏账号登录仍由启动器原有系统完成，好友昵称不是正版所有权证明。

## 部署

```sh
HARBOR_SOCIAL_DATA=/srv/mc-harbor-social/data PORT=8787 python3 server.py
```

默认只监听 127.0.0.1。生产环境使用 Caddy 或 Nginx 反向代理，并启用 HTTPS。示例 Caddyfile：

```caddy
friends.example.com {
    reverse_proxy 127.0.0.1:8787
    request_body {
        max_size 6MB
    }
}
```

启动器“好友 → 连接好友服务”填写 `https://friends.example.com`，创建身份后交换好友码。好友码用于添加，恢复密钥用于登录，请分开保管。密钥存 macOS 钥匙串，服务端只存其 SHA256。密钥熵为 384 位，不使用游戏密码。若代理需要按真实 IP 限流，应自行清除客户端传入的 X-Real-IP 后设置该头，再启用 `HARBOR_TRUST_PROXY=1`；默认不信任代理头。

## 共享规则

最近游戏默认不上传。打开共享后同步实例名称、版本、加载器、保存过的存档目录名、时长与用户选择的同行好友。不上传游戏文件、服务器地址、路径、正版账号令牌或好友备注。同行信息由玩家选择，不代表服务自动证实双方在同一服务器。关闭共享会立即清除服务端历史，移除好友会立即收回历史和皮肤访问权。皮肤需要玩家主动点击“共享当前账号皮肤”。

最近记录仅来自 MC Harbor 启动的游戏；不会凭空生成过去的时长。客户端最多保存 1000 条，本次同步最近 100 条。服务端为每位用户保留最多 1000 条。请为数据目录设置权限、定期备份 SQLite，并为实际公共部署增加监控、容量和注册控制。运行 `python3 test_server.py` 可在临时目录执行隔离接口测试，无外部账号与玩家数据。

## 接口

所有 `/v1` 接口除注册外都使用 `Authorization: Bearer <恢复密钥>`。`POST /register` 创建身份；`GET /friends` 获取好友与请求；`POST /friends/request` 发送好友码；`POST /friends/respond` 接受或拒绝；`DELETE /friends/{id}` 移除；`PUT /me` 修改共享或皮肤；`PUT /history` 批量上传；`GET /history/{id}` 读取本人或好友动态；`GET /skin/{id}` 读取授权皮肤；`DELETE /me` 删除服务端身份及关联数据。`GET /health` 用于部署健康检查。

源码按项目 GPL-3.0 分发。此目录不含线上服务器、数据库或任何凭据。当前没有替作者或用户部署公共好友服务。
