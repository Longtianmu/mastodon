# Mastodon 自定义版升级至 v4.7.0

本文记录 2026-08-22 对本仓库的检查结果，以及生产服务器从现有自定义版升级到最新稳定发行版的操作步骤。

## 1. 已确认的版本与分支

- 本地升级前的源码：`mod2-v4.6.5`，提交 `a9de705b86`，基于官方 `v4.6.5`。
- 官方最新稳定版：`v4.7.0`，提交 `c5b3651e1f992baf87f478205c8f21fab662247e`，发布于 2026-08-20。
- 升级后的自定义源码分支：`mod2-v4.7.0`。
- 升级前的本地保护分支：`backup/mod2-v4.6.5-pre-v4.7.0-20260822`。
- 保留的修改：Mastodon Bird UI、Tangerine UI、主题/翻译注册、Cloudflare Web Analytics CSP 和安全升级脚本。

这里的“升级前源码版本”不一定等于生产数据库当前版本。服务器执行任何迁移前，先确认实际部署版本：

```bash
cd /home/mastodon/live
RAILS_ENV=production bundle exec tootctl version
git describe --tags --always
```

下文主路径假设服务器已经运行 `4.6.5`。如果服务器仍是 `4.3.8`，必须先阅读第 9 节并分两阶段操作。

## 2. 4.7.0 的关键迁移事项

最终运行环境至少需要：

- Ruby 3.3；本分支锁定 Ruby 4.0.6。
- PostgreSQL 14。
- Redis 7.0。
- Node.js 22；本分支使用 Node 24.19。
- libvips 8.13。4.7 不支持 ImageMagick 作为替代品。
- FFmpeg 5.1。
- 如启用全文搜索，Elasticsearch 7.x 或兼容的 OpenSearch。

4.7.0 的数据库迁移可能在大型实例上运行数小时。不要中断迁移进程。只有从 4.6 升级并将 pre-deployment 与 post-deployment 迁移分开执行时，官方才保证零停机迁移。4.7 还会使仍持有 4.2 或更早版本 cookie、且此后从未重新访问过站点的用户退出登录。

官方 4.7.0 指令以 4.6.6 为直接前一版本，而本仓库原先基于 4.6.5。被跳过的 4.6.6 要求重新编译资产并重启全部进程；第 5～7 节的流程已经包含这两步，不需要先单独部署官方 4.6.6。

## 3. 在服务器配置并获取自定义远程

约定远程名为 `mod`，远程分支名为 `mod2-v4.7.0`。第一次配置：

```bash
sudo -u mastodon -H /bin/bash
cd /home/mastodon/live
git remote -v
git remote add mod https://github.com/Longtianmu/mastodon.git
```

很多部署会把 `mastodon` 系统用户的登录 shell 设为 `/usr/sbin/nologin`，此时 `sudo -iu mastodon` 会显示 `This account is currently not available.`。上面的命令显式运行 `/bin/bash`，无需修改系统用户的登录 shell，也不应为此执行 `chsh` 或 `usermod --shell`。

如果 `mod` 已存在但 URL 不正确：

```bash
git remote set-url mod https://github.com/Longtianmu/mastodon.git
```

获取修改版：

```bash
git fetch mod --prune --tags
git show --no-patch --decorate mod/mod2-v4.7.0
```

`mod/mod2-v4.7.0` 是“远程跟踪引用”，用于 `git show`、`git diff` 和 `git switch`。Git fetch 的正确参数形式是 `git fetch <remote> <branch>`，因此若只抓取一个分支，应使用：

```bash
git fetch mod mod2-v4.7.0
```

不要写成 `git fetch mod/mod2-v4.7.0`；Git 会把它当成仓库路径，而不是远程加分支。

## 4. 升级前检查与备份

1. 确认没有未完成的 Git 操作，并保存本地修改：

   ```bash
   git status
   git stash push --include-untracked -m "pre-v4.7.0-server-upgrade"
   git branch "backup/server-pre-v4.7.0-$(date -u +%Y%m%dT%H%M%SZ)"
   ```

2. 记录当前版本、服务和依赖版本：

   ```bash
   git rev-parse HEAD
   ruby --version
   node --version
   psql --version
   redis-server --version
   vips --version
   ffmpeg -version | head -n 1
   systemctl status mastodon-web mastodon-sidekiq mastodon-streaming --no-pager
   ```

3. 备份 `.env.production`、systemd 配置、反向代理配置和对象存储配置。不要把含密钥的备份提交到 Git。

4. 在运行任何数据库迁移前创建 PostgreSQL 自定义格式备份，并验证备份可读取：

   ```bash
   mkdir -p /srv/backups/mastodon
   pg_dump -Fc -h DB_HOST -U DB_USER DB_NAME > /srv/backups/mastodon/pre-v4.7.0.dump
   pg_restore --list /srv/backups/mastodon/pre-v4.7.0.dump >/dev/null
   ```

   将 `DB_HOST`、`DB_USER`、`DB_NAME` 替换为 `.env.production` 中的真实值。也可以让第 5 节的脚本自动完成并验证备份。

5. 若 `.env.production` 仍含 `REDIS_NAMESPACE`，先按 Mastodon 官方 `redis_namespace_migration` 工具完成迁移并删除该变量；4.4 及更高版本会拒绝带此设置启动。

6. 如自行维护 Sidekiq Docker healthcheck，确认其检查 Sidekiq 8，而不是 Sidekiq 7。如使用自定义 Sidekiq 队列列表，至少有一个进程应处理 `fasp` 队列。

## 5. 推荐方式：使用仓库内安全升级脚本（原生/systemd）

先只生成计划，不改变源码、数据库或服务：

```bash
cd /home/mastodon/live
./update-mastodon.sh \
  --plan \
  --remote mod \
  --from-version 4.6.5 \
  --target 4.7.0
```

核对目标显示为 `mod2-v4.7.0`、来源显示为 `mod/mod2-v4.7.0`。然后执行：

```bash
export MASTODON_RESTART_CMD='sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming'

./update-mastodon.sh \
  --remote mod \
  --from-version 4.6.5 \
  --target 4.7.0 \
  --deploy native \
  --backup-dir /srv/backups/mastodon \
  --yes
```

脚本会依次：抓取 `mod`、保存未提交修改、建立代码备份分支、切换自定义版本、备份数据库、安装依赖、编译全部资产、执行 pre-deployment 迁移、重启三个 Mastodon 服务，再执行可能很久的 post-deployment 迁移。

如启用了 Elasticsearch/OpenSearch，并且升级路径跨过 4.4，再添加 `--with-search`。它会刷新 accounts 索引 mapping。

## 6. 手动方式（原生/systemd）

只有在不使用脚本时才执行本节。

1. 切换到远程修改版。首次部署该分支：

   ```bash
   git switch --create mod2-v4.7.0 --track mod/mod2-v4.7.0
   ```

   如果本地分支已经存在：

   ```bash
   git switch mod2-v4.7.0
   git merge --ff-only mod/mod2-v4.7.0
   ```

2. 安装 Ruby 与 JavaScript 依赖：

   ```bash
   bundle install
   yarn install --immutable
   ```

   若 `charlock_holmes` 在较新 GCC 上编译失败：

   ```bash
   BUNDLE_BUILD__CHARLOCK_HOLMES="--with-cxxflags=-std=c++17" bundle install
   ```

3. 编译资产和自定义主题：

   ```bash
   RAILS_ENV=production bundle exec rails assets:precompile
   ```

4. 在旧服务仍运行时执行 pre-deployment 迁移：

   ```bash
   SKIP_POST_DEPLOYMENT_MIGRATIONS=true RAILS_ENV=production bundle exec rails db:migrate
   ```

5. 重启所有 Mastodon 进程，包括 streaming：

   ```bash
   sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
   ```

6. 执行 post-deployment 迁移。它可能数小时没有完成，保持终端/会话并等待，不要终止：

   ```bash
   RAILS_ENV=production bundle exec rails db:migrate
   ```

7. 仅当升级路径跨过 4.4 且使用 Elasticsearch/OpenSearch 时，更新 accounts mapping：

   ```bash
   RAILS_ENV=production bin/tootctl search deploy --only-mapping --only=accounts
   ```

## 7. Docker Compose 路径

先运行脚本计划：

```bash
./update-mastodon.sh --plan --remote mod --from-version 4.6.5 --target 4.7.0
```

确认无误后：

```bash
./update-mastodon.sh \
  --remote mod \
  --from-version 4.6.5 \
  --target 4.7.0 \
  --deploy docker \
  --backup-dir /srv/backups/mastodon \
  --yes
```

脚本会用本仓库构建自定义 `web`、`sidekiq` 和 `streaming` 镜像，分开执行 pre/post migrations，并通过 Compose 重建服务。不要改成直接拉取官方镜像，否则本仓库主题与 CSP 修改不会进入镜像。

## 8. 升级后验证

1. 检查版本和迁移状态：

   ```bash
   RAILS_ENV=production bundle exec tootctl version
   RAILS_ENV=production bundle exec rails db:migrate:status
   git describe --tags --always
   ```

2. 检查服务与最近日志：

   ```bash
   systemctl is-active mastodon-web mastodon-sidekiq mastodon-streaming
   journalctl -u mastodon-web -u mastodon-sidekiq -u mastodon-streaming --since "15 minutes ago" --no-pager
   ```

3. 浏览器执行冒烟测试：登录、首页/本地时间线、发帖、上传图片、通知、搜索、用户资料页、管理员页和 streaming 实时更新。

4. 逐一选择 `config/themes.yml` 中的主题，重点检查浅色/深色、高对比度、移动端、资料页、通知和弹窗。4.7 新增了 `bg-blend`、`bg-highlight`、`border-strong` 设计 token；自定义主题先加载官方 `application` token，再覆盖自身颜色，因此这些 token 有有效的默认值，但仍需视觉验收。

5. 检查 Cloudflare Web Analytics 请求未被 CSP 拦截，并确认 Rocket Loader 仍关闭。

6. 如不希望管理员启用 4.6 引入的邮件订阅功能，在 `.env.production` 设置 `DISABLE_EMAIL_SUBSCRIPTIONS=true` 后重启服务。

## 9. 如果生产服务器实际仍是 4.3.8

不要把“本地源码已在 4.6.5”误认为生产数据库也已在 4.6。推荐分两阶段升级，以进入官方保证的 4.6 → 4.7 零停机路径：

1. `4.3.8 → mod/mod2-v4.6.5`：阅读并执行 4.4.0、4.5.0、4.6.0 的全部升级要求。特别处理 Redis namespace、PostgreSQL 14、Redis 7、Node 22、Ruby 3.3、libvips、FFmpeg 5.1、Sidekiq 8 healthcheck、4.4 accounts 搜索 mapping 和 4.6 主题变化。

   ```bash
   ./update-mastodon.sh --plan --remote mod --from-version 4.3.8 --target 4.6.5
   ./update-mastodon.sh --remote mod --from-version 4.3.8 --target 4.6.5 \
     --deploy native --backup-dir /srv/backups/mastodon --with-search --yes
   ```

2. 完成冒烟测试并确认 Sidekiq 队列恢复正常后，再执行 `4.6.5 → mod/mod2-v4.7.0`：

   ```bash
   ./update-mastodon.sh --plan --remote mod --from-version 4.6.5 --target 4.7.0
   ./update-mastodon.sh --remote mod --from-version 4.6.5 --target 4.7.0 \
     --deploy native --backup-dir /srv/backups/mastodon --yes
   ```

每一阶段都单独备份数据库。若无法分阶段，直接跨版本升级前应安排完整维护窗口并停止所有 Mastodon 进程；不要把它当作零停机升级。

## 10. 回滚边界

- 在数据库迁移前，可切回脚本创建的 `backup/*` 代码分支。
- pre-deployment 迁移后、post-deployment 迁移前，是否能安全切回取决于具体 migration；不要仅凭 Git 回退判断数据库兼容性。
- post-deployment 迁移完成后，不应只把源码切回 4.6。可靠回滚方式是恢复升级前的数据库备份，并同时恢复对应源码、环境配置和服务定义。
- 发生迁移错误时先保存完整日志和数据库状态，不要反复执行破坏性命令，也不要删除 migration 记录。

## 官方升级说明

- <https://github.com/mastodon/mastodon/releases/tag/v4.4.0>
- <https://github.com/mastodon/mastodon/releases/tag/v4.5.0>
- <https://github.com/mastodon/mastodon/releases/tag/v4.6.0>
- <https://github.com/mastodon/mastodon/releases/tag/v4.6.6>
- <https://github.com/mastodon/mastodon/releases/tag/v4.7.0>
- <https://github.com/mastodon/redis_namespace_migration>
