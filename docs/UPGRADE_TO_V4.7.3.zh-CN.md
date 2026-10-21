# Mastodon 自定义版升级至 v4.7.3

本次于 2026-10-21 将 `mod2-v4.7.0` 的定制合入官方稳定版 `v4.7.3`（2026-10-01 发布，提交 `8ff11c2`），新分支为 `mod2-v4.7.3`。

保留 Mastodon Bird UI 4.0.0、Tangerine UI 2.6.5 的全部配色、主题翻译、Cloudflare Web Analytics CSP 配置和 `update-mastodon.sh`。原 `mod2-v4.7.0` 分支保留，便于对照历史源码。

## 更新内容

- 包含 4.7.1 的身份认证、管理 API 权限和 JSON-LD 拒绝服务安全修复。
- 包含 4.7.2 的临时禁用 HEIF 支持，以及账号删除、导入和通知清理修复。
- 包含 4.7.3 的依赖更新、注册与邮箱限流修复、账号删除清理改进和界面修复。Yarn 更新为 4.18.1。

官方说明：

- https://github.com/mastodon/mastodon/releases/tag/v4.7.1
- https://github.com/mastodon/mastodon/releases/tag/v4.7.2
- https://github.com/mastodon/mastodon/releases/tag/v4.7.3

## 从已经部署的 4.7.0 升级

这三个补丁版本没有新增数据库迁移文件；4.7.1 修正了已有迁移被中断后重跑的问题。从已完成迁移的 4.7.0 升级，需安装更新后的依赖、重新编译资源并重启全部 Mastodon 进程。外部依赖的最低版本要求没有变化。

先确认生产服务器的实际版本并备份数据库、`.env.production` 和部署配置。以下命令在服务器的 Mastodon 源码目录运行，假定修改版远程名为 `mod`，且 URL 为 `https://github.com/Longtianmu/mastodon.git`：

```bash
git fetch mod --prune --tags
git show mod/mod2-v4.7.3:update-mastodon.sh > /tmp/mastodon-update-v4.7.3.sh

bash /tmp/mastodon-update-v4.7.3.sh \
  --plan --remote mod --from-version 4.7.0 --target 4.7.3
```

核对计划后，原生/systemd 部署可以执行：

```bash
export MASTODON_RESTART_CMD='sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming'

bash /tmp/mastodon-update-v4.7.3.sh \
  --remote mod --from-version 4.7.0 --target 4.7.3 \
  --deploy native --backup-dir /srv/backups/mastodon --yes
```

脚本会备份代码和数据库、切换自定义分支、安装依赖、编译资源、执行迁移检查并重启服务。如使用 Docker，把 `--deploy native` 换成 `--deploy docker`；脚本会从本分支构建包含自定义主题的镜像。

如果手动部署，在保存本地修改、完成备份并切换至 `mod2-v4.7.3` 后执行：

```bash
bundle install
yarn install --immutable
RAILS_ENV=production bundle exec rails assets:precompile
sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
```

若 `charlock_holmes` 在较新 GCC 上编译失败，可按官方说明使用 `BUNDLE_BUILD__CHARLOCK_HOLMES="--with-cxxflags=-std=c++17" bundle install`。

部署后检查三个服务的状态、日志和站点版本，并检查登录、发帖、媒体上传及各自定义主题的显示。由于上游临时禁用 HEIF，上传该格式不在预期支持范围内。

## 从 4.6 或更早版本升级

先阅读 [4.7.0 升级指南](UPGRADE_TO_V4.7.0.zh-CN.md) 中的运行环境要求、Redis namespace 迁移、数据库备份及 pre/post-deployment 迁移说明，再以 `--target 4.7.3` 执行升级。`--from-version` 必须填写实际部署的版本；跨入 4.7 的大型数据库迁移可能耗时数小时。

本次仓库更新和 Git 推送不等于生产服务器已经完成部署。

## 本地验证

- 使用仓库指定的 Sass 1.102.0 编译全部 7 个已注册主题，通过。
- 解析本次更新的 101 个 YAML 和 37 个 JSON 文件，通过。
- 核对 129 个未改动的定制文件及合并后的英、中主题名称，均保留。
- 检查升级脚本 Bash 语法和源码差异空白错误，通过。
- 本机没有 Ruby/Rails、PostgreSQL 和 Redis 测试环境，未运行 Rails 测试或生产环境部署验证。
