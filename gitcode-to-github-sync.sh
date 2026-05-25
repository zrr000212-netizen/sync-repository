#!/bin/bash
#
# gitcode-to-github-sync.sh
# 跨仓库增量同步：GitCode → GitHub，隐藏原始提交人信息
# 基于 cherry-pick 逐个同步，支持断点续传、冲突暂停、映射记录
#
# 用法:
#   gitcode-to-github-sync.sh \
#     --gitcode-repo git@gitcode.com:group/repo.git \
#     --gitcode-branch master \
#     --github-repo git@github.com:user/repo.git \
#     --github-branch master \
#     --author-name "zrr000212-netizen" \
#     --author-email "zrr000212@gmail.com" \
#     [--state-dir /path/to/state]
#
# 冲突恢复:
#   手动解决冲突后:
#     git add -A
#     git commit --allow-empty
#   然后重新运行脚本即可从断点继续
#
# 定时任务示例 (每10分钟):
#   */10 * * * * /root/scripts/gitcode-to-github-sync.sh \
#     --gitcode-repo git@gitcode.com:developer-skill/huaweicloud-skills.git \
#     --gitcode-branch master \
#     --github-repo git@github.com:zrr000212-netizen/test-huaweicloud-skills.git \
#     --github-branch master \
#     --author-name "zrr000212-netizen" \
#     --author-email "zrr000212@gmail.com"
#

set -uo pipefail

# ==================== 参数默认值 ====================
GITCODE_REPO=""
GITCODE_BRANCH=""
GITHUB_REPO=""
GITHUB_BRANCH=""
AUTHOR_NAME=""
AUTHOR_EMAIL=""
STATE_DIR=""

# ==================== 参数解析 ====================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gitcode-repo)    GITCODE_REPO="$2";    shift 2 ;;
        --gitcode-branch)  GITCODE_BRANCH="$2";  shift 2 ;;
        --github-repo)     GITHUB_REPO="$2";     shift 2 ;;
        --github-branch)   GITHUB_BRANCH="$2";   shift 2 ;;
        --author-name)     AUTHOR_NAME="$2";     shift 2 ;;
        --author-email)    AUTHOR_EMAIL="$2";    shift 2 ;;
        --state-dir)       STATE_DIR="$2";       shift 2 ;;
        -h|--help)
            head -30 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# ==================== 参数校验 ====================
MISSING=""
for var_name in GITCODE_REPO GITCODE_BRANCH GITHUB_REPO GITHUB_BRANCH AUTHOR_NAME AUTHOR_EMAIL; do
    if [[ -z "${!var_name}" ]]; then
        MISSING="${MISSING} --${var_name//_/-}"
    fi
done
if [[ -n "${MISSING}" ]]; then
    echo "[ERROR] 缺少必要参数:${MISSING}"
    exit 1
fi

# ==================== 目录设置 ====================
REPO_ID="$(echo -n "${GITCODE_REPO}+${GITCODE_BRANCH}+${GITHUB_REPO}+${GITHUB_BRANCH}" | md5sum | cut -c1-12)"
STATE_DIR="${STATE_DIR:-/root/.gitcode-sync/state/${REPO_ID}}"
WORK_DIR="/tmp/gitcode-sync-work/${REPO_ID}"

mkdir -p "${STATE_DIR}" "${WORK_DIR}"

# ==================== 关键路径 ====================
LOCK_FILE="${STATE_DIR}/sync.lock"
LOG_FILE="${STATE_DIR}/sync.log"
MAPPING_FILE="${STATE_DIR}/mapping.log"        # 旧SHA -> 新SHA 映射
STATE_JSON="${STATE_DIR}/state.json"            # 状态摘要
LOCAL_REPO="${WORK_DIR}/repo"                   # 本地工作仓库

# ==================== 日志 ====================
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" | tee -a "${LOG_FILE}"
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ==================== 状态 JSON 操作 ====================
init_state_json() {
    if [[ ! -f "${STATE_JSON}" ]]; then
        cat > "${STATE_JSON}" <<EOF
{
  "gitcode_repo": "${GITCODE_REPO}",
  "gitcode_branch": "${GITCODE_BRANCH}",
  "github_repo": "${GITHUB_REPO}",
  "github_branch": "${GITHUB_BRANCH}",
  "author_name": "${AUTHOR_NAME}",
  "author_email": "${AUTHOR_EMAIL}",
  "last_synced_commit": "",
  "last_synced_time": "",
  "total_commits_synced": 0,
  "sync_count": 0,
  "status": "initialized"
}
EOF
    fi
}

get_state() {
    python3 -c "import json; d=json.load(open('${STATE_JSON}')); print(d.get('$1',''))"
}

set_state() {
    python3 <<PYEOF
import json
f = "${STATE_JSON}"
d = json.load(open(f))
d["$1"] = "$2"
json.dump(d, open(f, 'w'), indent=2, ensure_ascii=False)
PYEOF
}

# ==================== 映射文件操作 ====================
# 格式: <原始SHA> -> <新SHA>
# 首行: SRC_HEAD: <最新已同步的源commit SHA>

# 获取上次已同步到的源commit SHA
get_last_synced_from_mapping() {
    if [[ -f "${MAPPING_FILE}" ]]; then
        sed -n 's/^SRC_HEAD:[[:space:]]*//p' "${MAPPING_FILE}" | head -1
    fi
}

# 记录映射关系（去重）
append_mapping() {
    local old_sha="$1"
    local new_sha="$2"
    if ! grep -q "^${old_sha} -> " "${MAPPING_FILE}" 2>/dev/null; then
        echo "${old_sha} -> ${new_sha}" >> "${MAPPING_FILE}"
    fi
}

# 更新 SRC_HEAD（原子写入）
update_src_head() {
    local head_sha="$1"
    local sync_time
    sync_time=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp="${MAPPING_FILE}.tmp.$$"
    {
        echo "SRC_HEAD: ${head_sha}"
        echo "SYNC_TIME: ${sync_time}"
        grep -v -e '^SRC_HEAD:' -e '^SYNC_TIME:' "${MAPPING_FILE}" 2>/dev/null || true
    } > "${tmp}"
    mv "${tmp}" "${MAPPING_FILE}"
}

# ==================== 锁机制 ====================
acquire_lock() {
    if [[ -f "${LOCK_FILE}" ]]; then
        local pid
        pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            log_error "另一个同步进程正在运行 (PID=${pid})，退出"
            exit 1
        fi
        log_warn "发现残留锁文件 (PID=${pid} 已不存在)，清理"
        rm -f "${LOCK_FILE}"
    fi
    echo $$ > "${LOCK_FILE}"
}

release_lock() {
    rm -f "${LOCK_FILE}"
}

# ==================== 主同步逻辑 ====================
sync_repo() {
    log_info "========== 开始增量同步 =========="
    log_info "GitCode: ${GITCODE_REPO} (${GITCODE_BRANCH})"
    log_info "GitHub:  ${GITHUB_REPO} (${GITHUB_BRANCH})"
    log_info "作者:    ${AUTHOR_NAME} <${AUTHOR_EMAIL}>"

    # ---- Step 1: 准备本地仓库 ----
    if [[ -d "${LOCAL_REPO}/.git" ]]; then
        log_info "复用已有工作仓库: ${LOCAL_REPO}"
        cd "${LOCAL_REPO}"

        # 确保 remotes 正确
        if ! git remote | grep -q '^gitcode$'; then
            git remote add gitcode "${GITCODE_REPO}"
        else
            git remote set-url gitcode "${GITCODE_REPO}"
        fi
        if ! git remote | grep -q '^github$'; then
            git remote add github "${GITHUB_REPO}"
        else
            git remote set-url github "${GITHUB_REPO}"
        fi
    else
        log_info "初始化工作仓库"
        # 先从 GitHub clone（保留目标分支历史），如果为空则 init
        if git clone "${GITHUB_REPO}" "${LOCAL_REPO}" 2>/dev/null; then
            cd "${LOCAL_REPO}"
            git remote rename origin github
        else
            mkdir -p "${LOCAL_REPO}"
            cd "${LOCAL_REPO}"
            git init
        fi
        git remote add gitcode "${GITCODE_REPO}"
        if ! git remote | grep -q '^github$'; then
            git remote add github "${GITHUB_REPO}"
        fi
    fi

    # ---- Step 2: Fetch 源和目标 ----
    log_info "拉取 GitCode 源分支: ${GITCODE_BRANCH}"
    git fetch gitcode "${GITCODE_BRANCH}" 2>&1 | tee -a "${LOG_FILE}"

    log_info "拉取 GitHub 目标分支: ${GITHUB_BRANCH}"
    git fetch github "${GITHUB_BRANCH}" 2>&1 | tee -a "${LOG_FILE}" || true

    # 确保 FETCH_REF 指向源分支
    local SRC_REF="gitcode/${GITCODE_BRANCH}"
    if ! git rev-parse --verify "${SRC_REF}" >/dev/null 2>&1; then
        log_error "找不到源分支引用: ${SRC_REF}"
        exit 1
    fi

    local SRC_HEAD
    SRC_HEAD=$(git rev-parse "${SRC_REF}")
    log_info "源分支 HEAD: ${SRC_HEAD}"

    # ---- Step 3: 确保目标分支存在 ----
    local GITHUB_REF="github/${GITHUB_BRANCH}"
    if git rev-parse --verify "${GITHUB_REF}" >/dev/null 2>&1; then
        log_info "切换到目标分支: ${GITHUB_BRANCH}"
        git checkout -B "${GITHUB_BRANCH}" "${GITHUB_REF}" 2>&1 | tee -a "${LOG_FILE}"
    else
        # GitHub 上没有该分支，从源分支的根commit开始
        log_info "GitHub 上无目标分支，将从源分支根commit开始创建"
        git checkout -B "${GITHUB_BRANCH}" 2>&1 | tee -a "${LOG_FILE}"
    fi

    # ---- Step 4: 确定增量起始点 ----
    local LAST_SYNCED
    LAST_SYNCED=$(get_last_synced_from_mapping)

    local START_COMMIT=""
    local COMMITS_TO_SYNC=()

    if [[ -n "${LAST_SYNCED}" ]]; then
        log_info "上次同步到: ${LAST_SYNCED}"

        # 验证该commit仍存在于源分支历史中
        if git merge-base --is-ancestor "${LAST_SYNCED}" "${SRC_REF}" 2>/dev/null; then
            if [[ "${LAST_SYNCED}" == "${SRC_HEAD}" ]]; then
                log_info "没有新 commit，已是最新"
                set_state "status" "up_to_date"
                return 0
            fi
            # 增量: LAST_SYNCED 的下一个commit开始
            START_COMMIT="${LAST_SYNCED}"
            log_info "增量同步: ${LAST_SYNCED} 之后的新 commit"
        else
            log_warn "上次同步的 commit 已不在源分支历史中，从头开始"
            LAST_SYNCED=""
        fi
    fi

    if [[ -z "${LAST_SYNCED}" ]]; then
        # 首次同步：从源分支根commit开始
        START_COMMIT=$(git rev-list --max-parents=0 "${SRC_REF}" | tail -1)
        log_info "首次同步，从根 commit 开始: ${START_COMMIT}"
    fi

    # ---- Step 5: 获取待同步的 commit 列表 ----
    # 使用 --ancestry-path 确保只取源分支上的直系commit，不取merge进来的旁支
    local COMMIT_LIST
    if [[ "${START_COMMIT}" == "$(git rev-list --max-parents=0 "${SRC_REF}" | tail -1)" ]]; then
        # 包含根commit：先列出根commit，再列出根之后到HEAD的所有commit
        COMMIT_LIST=$(echo "${START_COMMIT}"; git rev-list --reverse "${START_COMMIT}..${SRC_REF}")
    else
        # 增量：START 之后的commit（不含START自身）
        COMMIT_LIST=$(git rev-list --reverse --ancestry-path "${START_COMMIT}..${SRC_REF}")
    fi

    if [[ -z "${COMMIT_LIST}" ]]; then
        log_info "没有待同步的 commit"
        set_state "status" "up_to_date"
        return 0
    fi

    local COMMIT_COUNT
    COMMIT_COUNT=$(echo "${COMMIT_LIST}" | wc -l)
    log_info "待同步 commit 数: ${COMMIT_COUNT}"

    # ---- Step 6: 逐个 cherry-pick ----
    local SUCCESS_COUNT=0
    local CURRENT_IDX=0

    for commit in ${COMMIT_LIST}; do
        CURRENT_IDX=$((CURRENT_IDX + 1))
        local SHORT_SHA="${commit:0:8}"
        local COMMIT_MSG
        COMMIT_MSG=$(git log -1 --format="%s" "${commit}")
        log_info "[${CURRENT_IDX}/${COMMIT_COUNT}] cherry-pick: ${SHORT_SHA} ${COMMIT_MSG}"

        # cherry-pick 不自动提交，让我们控制 author + committer
        # 判断是否为 merge commit
        local IS_MERGE=0
        local PARENT_COUNT
        PARENT_COUNT=$(git cat-file -p "${commit}" | grep -c '^parent ')
        local CHERRY_ARGS=("${commit}" --no-commit)
        if [[ ${PARENT_COUNT} -gt 1 ]]; then
            IS_MERGE=1
            CHERRY_ARGS=("${commit}" --no-commit -m 1)
            log_info "  merge commit，使用 -m 1 选取第一父节点"
        fi

        git cherry-pick "${CHERRY_ARGS[@]}" 2>&1 | tee -a "${LOG_FILE}"
        local CHERRY_RC=${PIPESTATUS[0]}

        if [[ ${CHERRY_RC} -ne 0 ]]; then
            log_error "冲突! commit ${commit} cherry-pick 失败"
            log_error "请手动解决冲突后执行:"
            log_error "  cd ${LOCAL_REPO}"
            log_error "  git add -A"
            log_error "  git commit --allow-empty"
            log_error "  然后重新运行本脚本即可从断点继续"
            # 记录冲突commit到状态
            set_state "status" "conflict"
            set_state "last_synced_commit" "${commit}"
            exit 1
        fi

        # 提交：替换 author 和 committer
        local ORIG_DATE
        ORIG_DATE=$(git log -1 --format="%ai" "${commit}")
        local ORIG_MSG
        ORIG_MSG=$(git log -1 --format="%B" "${commit}")

        GIT_COMMITTER_NAME="${AUTHOR_NAME}" \
        GIT_COMMITTER_EMAIL="${AUTHOR_EMAIL}" \
        GIT_COMMITTER_DATE="${ORIG_DATE}" \
        git commit \
            --author="${AUTHOR_NAME} <${AUTHOR_EMAIL}>" \
            --date="${ORIG_DATE}" \
            -m "${ORIG_MSG}" \
            --allow-empty 2>&1 | tee -a "${LOG_FILE}"

        local NEW_SHA
        NEW_SHA=$(git rev-parse HEAD)

        # 记录映射
        append_mapping "${commit}" "${NEW_SHA}"

        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    done

    # ---- Step 7: 推送到 GitHub ----
    log_info "推送到 GitHub: ${GITHUB_BRANCH}"
    git push github "${GITHUB_BRANCH}:${GITHUB_BRANCH}" 2>&1 | tee -a "${LOG_FILE}"

    # ---- Step 8: 更新状态 ----
    update_src_head "${SRC_HEAD}"

    local SYNC_COUNT
    SYNC_COUNT=$(($(get_state "sync_count") + 1))
    local TOTAL_SYNCED
    TOTAL_SYNCED=$(($(get_state "total_commits_synced") + SUCCESS_COUNT))

    set_state "last_synced_commit" "${SRC_HEAD}"
    set_state "last_synced_time" "$(date '+%Y-%m-%d %H:%M:%S')"
    set_state "total_commits_synced" "${TOTAL_SYNCED}"
    set_state "sync_count" "${SYNC_COUNT}"
    set_state "status" "synced"

    log_info "========== 同步完成 =========="
    log_info "本次同步 ${SUCCESS_COUNT} 个 commit"
    log_info "累计同步 ${SYNC_COUNT} 次，共 ${TOTAL_SYNCED} 个 commit"
    log_info "源分支 HEAD: ${SRC_HEAD}"
}

# ==================== 入口 ====================
trap release_lock EXIT

log_info "脚本启动"
init_state_json
acquire_lock
sync_repo
log_info "脚本结束"
