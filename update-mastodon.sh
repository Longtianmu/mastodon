#!/usr/bin/env bash
# Deploy versioned custom Mastodon branches under mod/*.
# Run --plan first on production.

set -Eeuo pipefail

REMOTE="origin"
TARGET=""
MOD_BRANCH_PREFIX="${MASTODON_MOD_BRANCH_PREFIX:-mod/mod2-v}"
FROM_VERSION="${MASTODON_FROM_VERSION:-v4.3.8}"
DEPLOY="source"
BACKUP_DIR=""
DO_FETCH=1
ASSUME_YES=0
WITH_SEARCH=0
PLAN_ONLY=0
SKIP_DB_BACKUP=0
STASH_REF=""
DOCKER_OVERRIDE=""
BACKUP_BRANCH=""
TARGET_VERSION=""
TARGET_BRANCH=""
SOURCE_REF=""

usage() {
  cat <<'EOF'
Usage: ./update-mastodon.sh [options]

Safely switches to the newest versioned custom branch under mod/*.
By default it updates source code only and does not touch the database or
running services. No official "upstream" remote is required.

Options:
  --plan                  Show the detected versions and migration plan only
  --target X.Y.Z          Deploy mod/mod2-vX.Y.Z instead of the newest branch
  --target mod/NAME       Deploy this exact custom branch
  --from-version X.Y.Z    Deployed/database version (default: 4.3.8)
  --remote NAME           Remote containing mod/* branches (default: origin)
  --no-fetch              Use existing local/remote-tracking mod/* branches
  --deploy source         Update source only (default)
  --deploy native         Also update a systemd/non-Docker installation
  --deploy docker         Also build custom images and update Docker Compose
  --backup-dir PATH       Database backup directory
  --with-search           Refresh the account search mapping after migration
  --skip-db-backup        Skip database backup (strongly discouraged)
  --yes                   Do not ask for confirmation
  -h, --help              Show this help

Examples:
  ./update-mastodon.sh --plan
  ./update-mastodon.sh --target 4.6.5 --yes
  ./update-mastodon.sh --deploy native --with-search
  ./update-mastodon.sh --deploy docker --backup-dir /srv/backups/mastodon

Environment overrides for native deployments:
  MASTODON_ENV_FILE       Path to .env.production
  MASTODON_RESTART_CMD    Command run between pre/post migrations
  MASTODON_YARN_CMD       Yarn command (default: yarn)
  MASTODON_MOD_BRANCH_PREFIX
                          Version-to-branch prefix (default: mod/mod2-v)
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

run() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
  "$@"
}

confirm() {
  if (( ASSUME_YES )); then
    return 0
  fi

  local answer
  read -r -p 'Continue? [y/N] ' answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Cancelled"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

version_at_least() {
  local actual="$1"
  local minimum="$2"
  [[ "$(printf '%s\n%s\n' "$minimum" "$actual" | sort -V | head -n 1)" == "$minimum" ]]
}

is_release_version() {
  [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

normalize_version() {
  printf '%s' "${1#v}"
}

extract_release_version() {
  local name="$1"
  if [[ "$name" =~ v?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    return 1
  fi
}

list_modified_branches() {
  local ref branch version

  while IFS= read -r ref; do
    branch="${ref#"$REMOTE/"}"
    version="$(extract_release_version "$branch")" || continue
    printf '%s\t%s\n' "$version" "$branch"
  done < <(git for-each-ref --format='%(refname:short)' "refs/remotes/$REMOTE/mod/*")

  while IFS= read -r ref; do
    version="$(extract_release_version "$ref")" || continue
    printf '%s\t%s\n' "$version" "$ref"
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/mod/*')
}

latest_modified_branch() {
  list_modified_branches \
    | sort -u -t $'\t' -k1,1V -k2,2 \
    | tail -n 1 \
    | cut -f2-
}

resolve_modified_ref() {
  local branch="$1"

  if git show-ref --verify --quiet "refs/remotes/$REMOTE/$branch"; then
    printf '%s' "$REMOTE/$branch"
  elif git show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s' "$branch"
  else
    return 1
  fi
}

read_env_value() {
  local key="$1"
  local file="$2"
  local value

  value="$(sed -n "s/^${key}=//p" "$file" | tail -n 1)"
  value="${value%$'\r'}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

check_release_requirements() {
  cat <<EOF

Release requirements for Mastodon 4.6.x:
  Ruby >= 3.3; PostgreSQL >= 14; Redis >= 7; Node >= 22
  libvips >= 8.13; FFmpeg >= 5.1
  ImageMagick is no longer supported.
EOF

  if [[ -f .env.production ]] && grep -qE '^REDIS_NAMESPACE=' .env.production; then
    die "REDIS_NAMESPACE must be migrated and removed before Mastodon 4.4+. See https://github.com/mastodon/redis_namespace_migration"
  fi

  if [[ "$DEPLOY" == "native" ]]; then
    require_cmd ruby
    require_cmd node
    require_cmd bundle
    require_cmd vips
    require_cmd ffmpeg
    require_cmd pg_dump
    require_cmd pg_restore

    local ruby_version node_version
    ruby_version="$(ruby -e 'print RUBY_VERSION')"
    node_version="$(node --version)"
    node_version="${node_version#v}"
    version_at_least "$ruby_version" "3.3" || die "Ruby $ruby_version is too old; Mastodon 4.6 needs Ruby >= 3.3"
    version_at_least "$node_version" "22" || die "Node $node_version is too old; Mastodon 4.6 needs Node >= 22"
  elif [[ "$DEPLOY" == "docker" ]]; then
    require_cmd docker
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
  fi
}

create_git_backup() {
  local branch="$1"
  local target="$2"
  local timestamp

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  branch="${branch//\//-}"
  branch="${branch//[^a-zA-Z0-9._-]/-}"
  BACKUP_BRANCH="backup/${branch}-pre-${target#v}-${timestamp}"
  run git branch "$BACKUP_BRANCH" HEAD
}

stash_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    local marker
    marker="mastodon-update-$(date -u +%Y%m%dT%H%M%SZ)"
    run git stash push --include-untracked --message "$marker"
    STASH_REF="$(git stash list --format='%gd %s' | awk -v marker="$marker" '$0 ~ marker { print $1; exit }')"
    [[ -n "$STASH_REF" ]] || die "Could not identify the safety stash"
  fi
}

restore_worktree() {
  if [[ -n "$STASH_REF" ]]; then
    log "Restoring uncommitted changes from $STASH_REF"
    if ! git stash pop "$STASH_REF"; then
      die "The update succeeded, but restoring uncommitted changes conflicted. Resolve the conflicts; the stash was kept."
    fi
    STASH_REF=""
  fi
}

checkout_modified_release() {
  local current_branch current_commit source_commit

  current_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  current_commit="$(git rev-parse HEAD)"
  source_commit="$(git rev-parse "$SOURCE_REF^{commit}")"

  if [[ "$current_branch" == "$TARGET_BRANCH" && "$current_commit" == "$source_commit" ]]; then
    log "Already on $TARGET_BRANCH at the requested revision"
    return 0
  fi

  stash_worktree
  create_git_backup "${current_branch:-detached-$(git rev-parse --short HEAD)}" "$TARGET_VERSION"

  if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
    run git switch "$TARGET_BRANCH"
    if [[ "$SOURCE_REF" != "$TARGET_BRANCH" ]]; then
      run git merge --ff-only "$SOURCE_REF"
    fi
  else
    run git switch --create "$TARGET_BRANCH" "$SOURCE_REF"
  fi

  restore_worktree
}

validate_custom_themes() {
  local theme path missing=0
  while IFS=':' read -r theme path; do
    theme="${theme//[[:space:]]/}"
    path="${path# }"
    [[ -z "$theme" || "$theme" == "default" ]] && continue
    if [[ ! -f "app/javascript/$path" ]]; then
      printf 'Missing theme entrypoint for %s: app/javascript/%s\n' "$theme" "$path" >&2
      missing=1
    fi
  done < config/themes.yml
  (( missing == 0 )) || die "Theme validation failed"
}

native_backup() {
  (( SKIP_DB_BACKUP )) && return 0

  local env_file db_host db_port db_name db_user db_pass db_sslmode backup_file
  env_file="${MASTODON_ENV_FILE:-.env.production}"
  [[ -f "$env_file" ]] || die "Native database backup needs $env_file or MASTODON_ENV_FILE"

  db_host="$(read_env_value DB_HOST "$env_file")"
  db_port="$(read_env_value DB_PORT "$env_file")"
  db_name="$(read_env_value DB_NAME "$env_file")"
  db_user="$(read_env_value DB_USER "$env_file")"
  db_pass="$(read_env_value DB_PASS "$env_file")"
  db_sslmode="$(read_env_value DB_SSLMODE "$env_file")"
  db_host="${db_host:-localhost}"
  db_port="${db_port:-5432}"
  db_name="${db_name:-mastodon_production}"
  db_user="${db_user:-mastodon}"
  db_sslmode="${db_sslmode:-prefer}"

  mkdir -p "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/mastodon-$FROM_VERSION-to-$TARGET_VERSION-$(date -u +%Y%m%dT%H%M%SZ).dump"
  log "Backing up PostgreSQL to $backup_file"
  PGPASSWORD="$db_pass" PGSSLMODE="$db_sslmode" \
    pg_dump -Fc -h "$db_host" -p "$db_port" -U "$db_user" "$db_name" > "$backup_file"
  [[ -s "$backup_file" ]] || die "Database backup is empty"
  pg_restore --list "$backup_file" >/dev/null || die "Database backup could not be read by pg_restore"
}

native_deploy() {
  local yarn_cmd restart_cmd
  yarn_cmd="${MASTODON_YARN_CMD:-yarn}"
  restart_cmd="${MASTODON_RESTART_CMD:-}"

  native_backup
  run bundle install
  # shellcheck disable=SC2086
  run $yarn_cmd install --immutable
  run env RAILS_ENV=production bundle exec rails assets:precompile
  run env SKIP_POST_DEPLOYMENT_MIGRATIONS=true RAILS_ENV=production bundle exec rails db:migrate

  if [[ -n "$restart_cmd" ]]; then
    log "Restarting Mastodon with MASTODON_RESTART_CMD"
    bash -lc "$restart_cmd"
  elif (( EUID == 0 )); then
    run systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
  elif command -v sudo >/dev/null 2>&1; then
    run sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
  else
    die "Set MASTODON_RESTART_CMD; services must restart before post-deployment migrations"
  fi

  run env RAILS_ENV=production bundle exec rails db:migrate
  if (( WITH_SEARCH )); then
    run env RAILS_ENV=production bin/tootctl search deploy --only-mapping --only=accounts
  fi
}

make_docker_override() {
  DOCKER_OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/mastodon-update-compose.XXXXXX.yml")"
  cat > "$DOCKER_OVERRIDE" <<EOF
services:
  web:
    image: mastodon-custom:$TARGET_VERSION
    build:
      context: "$PWD"
  sidekiq:
    image: mastodon-custom:$TARGET_VERSION
    build:
      context: "$PWD"
  streaming:
    image: mastodon-streaming-custom:$TARGET_VERSION
    build:
      context: "$PWD"
      dockerfile: streaming/Dockerfile
EOF
}

docker_compose() {
  docker compose -f docker-compose.yml -f "$DOCKER_OVERRIDE" "$@"
}

docker_backup() {
  (( SKIP_DB_BACKUP )) && return 0

  local env_file db_host db_port db_name db_user db_pass db_sslmode backup_file
  env_file="${MASTODON_ENV_FILE:-.env.production}"
  [[ -f "$env_file" ]] || die "Docker database backup needs $env_file or MASTODON_ENV_FILE"
  db_host="$(read_env_value DB_HOST "$env_file")"
  db_port="$(read_env_value DB_PORT "$env_file")"
  db_name="$(read_env_value DB_NAME "$env_file")"
  db_user="$(read_env_value DB_USER "$env_file")"
  db_pass="$(read_env_value DB_PASS "$env_file")"
  db_sslmode="$(read_env_value DB_SSLMODE "$env_file")"
  db_port="${db_port:-5432}"
  db_name="${db_name:-postgres}"
  db_user="${db_user:-postgres}"
  db_sslmode="${db_sslmode:-prefer}"

  mkdir -p "$BACKUP_DIR"
  backup_file="$BACKUP_DIR/mastodon-$FROM_VERSION-to-$TARGET_VERSION-$(date -u +%Y%m%dT%H%M%SZ).dump"
  log "Backing up PostgreSQL to $backup_file"

  if [[ -n "$db_host" && "$db_host" != "db" ]]; then
    require_cmd pg_dump
    require_cmd pg_restore
    PGPASSWORD="$db_pass" PGSSLMODE="$db_sslmode" \
      pg_dump -Fc -h "$db_host" -p "$db_port" -U "$db_user" "$db_name" > "$backup_file"
    pg_restore --list "$backup_file" >/dev/null \
      || die "Database backup could not be read by pg_restore"
  else
    docker_compose exec -T db pg_dump -Fc -U "$db_user" "$db_name" > "$backup_file"
  fi

  [[ -s "$backup_file" ]] || die "Database backup is empty"
}

docker_deploy() {
  make_docker_override
  docker_backup
  run docker_compose build web sidekiq streaming
  run docker_compose run --rm -e SKIP_POST_DEPLOYMENT_MIGRATIONS=true web bundle exec rails db:migrate
  run docker_compose up -d
  run docker_compose run --rm web bundle exec rails db:migrate
  if (( WITH_SEARCH )); then
    run docker_compose run --rm web bin/tootctl search deploy --only-mapping --only=accounts
  fi
}

cleanup() {
  if [[ -n "$DOCKER_OVERRIDE" && -f "$DOCKER_OVERRIDE" ]]; then
    rm -f -- "$DOCKER_OVERRIDE"
  fi
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --plan) PLAN_ONLY=1 ;;
    --target) shift; (($#)) || die "--target needs a version"; TARGET="$1" ;;
    --from-version) shift; (($#)) || die "--from-version needs a version"; FROM_VERSION="$1" ;;
    --remote) shift; (($#)) || die "--remote needs a name"; REMOTE="$1" ;;
    --no-fetch) DO_FETCH=0 ;;
    --deploy) shift; (($#)) || die "--deploy needs source, native, or docker"; DEPLOY="$1" ;;
    --backup-dir) shift; (($#)) || die "--backup-dir needs a path"; BACKUP_DIR="$1" ;;
    --with-search) WITH_SEARCH=1 ;;
    --skip-db-backup) SKIP_DB_BACKUP=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

[[ "$DEPLOY" == "source" || "$DEPLOY" == "native" || "$DEPLOY" == "docker" ]] \
  || die "--deploy must be source, native, or docker"

require_cmd git
require_cmd grep
require_cmd sort
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run this script inside the Mastodon repository"
git rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1 && die "A rebase is already in progress"
git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && die "A merge is already in progress"

BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
CURRENT_REF="${BRANCH:-detached@$(git rev-parse --short HEAD)}"

if (( DO_FETCH )); then
  git remote get-url "$REMOTE" >/dev/null 2>&1 || die "Git remote '$REMOTE' does not exist"
  run git fetch "$REMOTE" --prune --tags \
    "+refs/heads/mod/*:refs/remotes/$REMOTE/mod/*"
fi

if [[ -z "$TARGET" ]]; then
  TARGET_BRANCH="$(latest_modified_branch)"
  [[ -n "$TARGET_BRANCH" ]] || die "No versioned mod/* branches found for remote '$REMOTE'"
  TARGET_VERSION="$(extract_release_version "$TARGET_BRANCH")" \
    || die "Cannot extract a release version from $TARGET_BRANCH"
elif is_release_version "$TARGET"; then
  TARGET_VERSION="$(normalize_version "$TARGET")"
  TARGET_BRANCH="$MOD_BRANCH_PREFIX$TARGET_VERSION"
elif [[ "$TARGET" == mod/* ]]; then
  TARGET_BRANCH="$TARGET"
  TARGET_VERSION="$(extract_release_version "$TARGET_BRANCH")" \
    || die "Target branch must end in X.Y.Z or vX.Y.Z"
else
  die "Target must be X.Y.Z, vX.Y.Z, or a branch under mod/*"
fi
is_release_version "$FROM_VERSION" || die "--from-version must look like X.Y.Z or vX.Y.Z"
FROM_VERSION="$(normalize_version "$FROM_VERSION")"
SOURCE_REF="$(resolve_modified_ref "$TARGET_BRANCH")" \
  || die "Modified release branch not found: $TARGET_BRANCH (remote: $REMOTE)"
[[ "$TARGET_VERSION" =~ ^4\.6\.[0-9]+$ ]] \
  || die "This migration recipe has been reviewed through Mastodon 4.6.x only. Read the new minor/major release notes and update this script before targeting $TARGET_VERSION."

BACKUP_DIR="${BACKUP_DIR:-$(cd .. && pwd)/mastodon-backups}"

cat <<EOF
Current source:     $CURRENT_REF
Deployed/DB base:   v$FROM_VERSION
Target branch:      $TARGET_BRANCH
Source ref:         $SOURCE_REF
Deployment mode:    $DEPLOY
Database backup:    $([[ "$DEPLOY" == source ]] && printf 'not applicable' || { (( SKIP_DB_BACKUP )) && printf 'SKIPPED' || printf '%s' "$BACKUP_DIR"; })

Source switch: $CURRENT_REF -> $TARGET_BRANCH
Database path: v$FROM_VERSION -> 4.4 -> 4.5 -> 4.6 -> v$TARGET_VERSION
  1. Verify new runtime requirements and REDIS_NAMESPACE removal.
  2. Preserve uncommitted work and create a backup Git branch.
  3. Switch to the versioned custom branch without rebasing it.
  4. Back up PostgreSQL before any database migration.
  5. Install/build dependencies and compile all assets/themes.
  6. Run pre-deployment migrations, restart every Mastodon process,
     then run post-deployment migrations.
  7. Optionally refresh the Elasticsearch/OpenSearch account mapping.

Important: Mastodon 4.6 changed the theming system. This branch includes
Mastodon Bird UI 4.0.0 and Tangerine Neue 2.6.5, both intended for Mastodon 4.6+.
Their Sass entrypoints are validated before deployment, but visual QA is still advised.
The optional email-subscriptions feature may increase outbound email costs; set
DISABLE_EMAIL_SUBSCRIPTIONS=true if your operators should not enable it.

Release notes reviewed by this script:
  https://github.com/mastodon/mastodon/releases/tag/v4.4.0
  https://github.com/mastodon/mastodon/releases/tag/v4.5.0
  https://github.com/mastodon/mastodon/releases/tag/v4.6.0
  https://github.com/mastodon/mastodon/releases/tag/v$TARGET_VERSION
EOF

check_release_requirements
(( PLAN_ONLY )) && exit 0

confirm

checkout_modified_release

validate_custom_themes

case "$DEPLOY" in
  source) ;;
  native) native_deploy ;;
  docker) docker_deploy ;;
esac

log "Update complete: $TARGET_BRANCH at $(git rev-parse --short HEAD)"
if [[ "$DEPLOY" == "source" ]]; then
  cat <<'EOF'
Source-only mode did not migrate a production database or restart services.
Re-run with --deploy native or --deploy docker on the production host.
EOF
fi
