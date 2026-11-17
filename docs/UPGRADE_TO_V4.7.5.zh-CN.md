# Mastodon 自定义版升级至 v4.7.5

`mod2-v4.7.5` 将官方稳定版 `v4.7.5`（2026-11-03 发布，提交 `24cd1c8`）合入 `mod2-v4.7.3` 的定制代码，保留 Bird UI、Tangerine Neue、主题翻译及 Cloudflare Web Analytics CSP 配置。

## 从 4.7.3 升级前需要了解的变化

- 4.7.4 修复 ActivityPub 标识校验，并为长期未登录的账号增加邮件验证。原生部署需更新依赖并重新编译静态资源。默认 Ruby 从 4.0.6 升至 4.0.9。[4.7.4 发布说明](https://github.com/mastodon/mastodon/releases/tag/v4.7.4)
- 4.7.5 修复长期未登录账号的密码认证绕过、JSON-LD 处理导致的拒绝服务，以及反向代理请求头的优先级问题。升级后，Mastodon 优先使用 `X-Forwarded-For` 判断客户端地址。[4.7.5 发布说明](https://github.com/mastodon/mastodon/releases/tag/v4.7.5)
- 如果反向代理使用 `Forwarded` 传递客户端地址，请在转发给 Mastodon 前丢弃客户端提供的 `X-Forwarded-For`。如果沿用项目的 Nginx 模板，新版在 Web 和 streaming 两处代理配置中加入了 `proxy_set_header Forwarded "";`。将这项改动合入线上配置后，运行 `nginx -t` 并在检查通过后重新加载 Nginx。[新版 Nginx 模板](../dist/nginx.conf)

## 在生产服务器上部署

以下命令在 Mastodon 源码目录运行，假定当前部署版本为 4.7.3，`mod` 指向 `https://github.com/Longtianmu/mastodon.git`。先从新分支取出部署脚本，预览目标分支和升级计划。

```bash
git fetch mod refs/heads/mod2-v4.7.5:refs/remotes/mod/mod2-v4.7.5
update_script=$(mktemp)
git show mod/mod2-v4.7.5:update-mastodon.sh > "$update_script"
bash "$update_script" --plan --no-fetch --remote mod --from-version 4.7.3 --target 4.7.5
```

**原生部署**使用 rbenv 时，请先让 ruby-build 支持 4.0.9，然后以部署用户运行以下命令。切换分支前，源码目录的 `.ruby-version` 仍指向 4.0.6，因此安装命令显式指定 4.0.9。手动切换到新分支后，也可在新源码目录用 `RUBY_CONFIGURE_OPTS=--with-jemalloc rbenv install -s` 安装当前目录指定的版本。

```bash
RUBY_CONFIGURE_OPTS=--with-jemalloc rbenv install -s 4.0.9
bash "$update_script" --no-fetch --remote mod --from-version 4.7.3 --target 4.7.5 \
  --deploy native --backup-dir /srv/backups/mastodon
```

脚本切换分支后备份数据库，运行 `bundle install`、`yarn install --immutable` 和资源预编译，并重启 Mastodon 的 Web、Sidekiq 和 streaming 进程。从已完成迁移的 4.7.3 直升时，这两个补丁版本没有新增数据库迁移，脚本仍会运行常规迁移检查。

**Docker Compose 部署**使用同一份脚本，从新分支重新构建包含自定义主题的镜像并启动服务。

```bash
bash "$update_script" --no-fetch --remote mod --from-version 4.7.3 --target 4.7.5 \
  --deploy docker --backup-dir /srv/backups/mastodon
```

从 4.6 或更早版本升级，请先核对跨版本迁移要求，并将 `--from-version` 改为实际部署版本。[4.7.0 升级指南](UPGRADE_TO_V4.7.0.zh-CN.md)
