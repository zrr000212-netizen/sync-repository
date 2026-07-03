#!/bin/bash
#
# gitcode-to-github-sync.sh
# 跨仓库增量同步：GitCode → GitHub，隐藏原始提交人信息
# 基于 cherry-pick 逐个同步，支持断点续传、冲突暂停、映射记录
# 支持将同步状态持久化到 Git 仓库，实现跨机器断点续传
#
# 用法:
#   gitcode-to-github-sync.sh \
#     --gitcode-repo git@gitcode.com:group/repo.git \
#     --gitcode-branch master \
#     --github-repo git@github.com:user/repo.git \
#     --github-branch master \
#     --author-name "zrr000212-netizen" \
#     --author-email "zrr000212@gmail.com" \
#     [--state-dir /path/to/state] \
#     [--state-repo git@github.com:user/sync-state.git]
#
# 冲突恢复:
#   手动解决冲突后:
#     git add -A
#     git commit --allow-empty
#   然后重新运行脚本即可从断点继续
#
# 跨机器恢复:
#   新机器只需指定相同的 --state-repo，脚本会自动拉取历史状态继续增量同步
#
# 定时任务示例 (每10分钟):
#   */10 * * * * /root/scripts/gitcode-to-github-sync.sh \
#     --gitcode-repo git@gitcode.com:developer-skill/huaweicloud-skills.git \
#     --gitcode-branch master \
#     --github-repo git@github.com:zrr000212-netizen/test-huaweicloud-skills.git \
#     --github-branch master \
#     --author-name "zrr000212-netizen" \
#     --author-email "zrr000212@gmail.com" \
#     --state-repo git@github.com:zrr000212-netizen/sync-repository.git
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
STATE_REPO="git@github.com:zrr000212-netizen/sync-repository.git"

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
        --state-repo)      STATE_REPO="$2";      shift 2 ;;
        -h|--help)
            head -35 "$0" | grep '^#' | sed 's/^# \?//'
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
WORK_DIR="/tmp/gitcode-sync-work/${REPO_ID}"

# 临时默认值（init_state_repo 后会更新为最终路径）
STATE_DIR="/root/.gitcode-sync/state/${REPO_ID}"
LOCK_FILE="${STATE_DIR}/sync.lock"
LOG_FILE="${STATE_DIR}/sync.log"
MAPPING_FILE="${STATE_DIR}/mapping.log"
STATE_JSON="${STATE_DIR}/state.json"
LOCAL_REPO="${WORK_DIR}/repo"

# ==================== 状态仓库（跨机器持久化） ====================
STATE_REPO_DIR=""   # 状态仓库本地clone路径
STATE_REPO_SUBDIR="states/${REPO_ID}"  # 仓库内子目录

# 初始化状态仓库本地clone
init_state_repo() {
    if [[ -z "${STATE_REPO}" ]]; then
        # 无状态仓库，回退到本地目录
        STATE_DIR="${STATE_DIR:-/root/.gitcode-sync/state/${REPO_ID}}"
        mkdir -p "${STATE_DIR}" "${WORK_DIR}"
        return 0
    fi

    # 使用脚本自身所在目录作为状态仓库（脚本和states平级）
    STATE_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "${STATE_REPO_DIR}/.git" ]]; then
        cd "${STATE_REPO_DIR}"
        git remote set-url origin "${STATE_REPO}" 2>/dev/null || git remote add origin "${STATE_REPO}"
        git pull --ff-only origin 2>&1 | tee -a "${LOG_FILE}" || true
    else
        # 当前目录不是git仓库，clone到脚本所在目录
        git clone "${STATE_REPO}" "${STATE_REPO_DIR}" 2>&1 | tee -a "${LOG_FILE}" || {
            # 仓库可能为空，init一个
            mkdir -p "${STATE_REPO_DIR}"
            cd "${STATE_REPO_DIR}"
            git init
            git remote add origin "${STATE_REPO}"
        }
    fi

    # 状态目录直接指向仓库内子目录，不再用 /root/.gitcode-sync/
    STATE_DIR="${STATE_REPO_DIR}/${STATE_REPO_SUBDIR}"
    mkdir -p "${STATE_DIR}" "${WORK_DIR}"
    cd "${WORK_DIR}"  # 回到工作目录
}

# 滚动压缩：文件超过阈值则重命名加日期后缀并gzip压缩
# 用法: rotate_and_compress <目录> <文件名> <阈值字节>
ROTATE_THRESHOLD=$((10 * 1024 * 1024))  # 10MB

rotate_and_compress() {
    local dir="$1"
    local filename="$2"
    local threshold="${3:-${ROTATE_THRESHOLD}}"
    local filepath="${dir}/${filename}"

    [[ -f "${filepath}" ]] || return 0

    local filesize
    filesize=$(stat -c%s "${filepath}" 2>/dev/null || echo 0)
    if [[ ${filesize} -ge ${threshold} ]]; then
        local date_suffix
        date_suffix=$(date '+%Y%m%d')
        local base="${filename%.*}"
        local ext="${filename##*.}"
        local rotated="${dir}/${base}-${date_suffix}.${ext}.gz"
        # 同一天已有压缩文件则加序号
        local idx=1
        while [[ -f "${rotated}" ]]; do
            rotated="${dir}/${base}-${date_suffix}-${idx}.${ext}.gz"
            idx=$((idx + 1))
        done
        gzip -c "${filepath}" > "${rotated}"
        rm -f "${filepath}"
        log_info "滚动压缩: ${filename} (${filesize} bytes) -> ${base}-${date_suffix}.${ext}.gz"
    fi
}

# 将状态推送到状态仓库（持久化）
push_state_to_repo() {
    if [[ -z "${STATE_REPO}" ]]; then
        return 0
    fi

    log_info "持久化状态到仓库: ${STATE_REPO}"
    cd "${STATE_REPO_DIR}"

    # 滚动压缩：超过10MB的文件压缩归档
    rotate_and_compress "${STATE_REPO_SUBDIR}" "mapping.log"
    rotate_and_compress "${STATE_REPO_SUBDIR}" "state.json"
    rotate_and_compress "${STATE_REPO_SUBDIR}" "sync.log"

    # 压缩后如果当前文件被归档删除，重新生成
    if [[ ! -f "${STATE_REPO_SUBDIR}/state.json" ]]; then
        init_state_json
    fi
    if [[ ! -f "${STATE_REPO_SUBDIR}/mapping.log" ]]; then
        echo "SRC_HEAD: $(get_state 'last_synced_commit')" > "${STATE_REPO_SUBDIR}/mapping.log"
        echo "SYNC_TIME: $(date '+%Y-%m-%d %H:%M:%S')" >> "${STATE_REPO_SUBDIR}/mapping.log"
    fi

    # sync.log 截断到最近5000行，防止无限增长
    if [[ -f "${STATE_REPO_SUBDIR}/sync.log" ]]; then
        local log_lines
        log_lines=$(wc -l < "${STATE_REPO_SUBDIR}/sync.log")
        if [[ ${log_lines} -gt 5000 ]]; then
            tail -5000 "${STATE_REPO_SUBDIR}/sync.log" > "${STATE_REPO_SUBDIR}/sync.log.tmp"
            mv "${STATE_REPO_SUBDIR}/sync.log.tmp" "${STATE_REPO_SUBDIR}/sync.log"
        fi
    fi

    git add -A
    local changed=0
    if git diff --cached --quiet 2>/dev/null; then
        changed=0
    else
        changed=1
    fi

    if [[ ${changed} -eq 1 ]]; then
        local commit_msg="sync-state: ${REPO_ID} — $(get_state 'status') at $(date '+%Y-%m-%d %H:%M:%S')"
        git -c user.name="${AUTHOR_NAME}" -c user.email="${AUTHOR_EMAIL}" \
            commit -m "${commit_msg}" 2>&1 | tee -a "${LOG_FILE}"
        git push origin HEAD 2>&1 | tee -a "${LOG_FILE}"
        log_info "状态已推送到仓库"
    else
        log_info "状态无变化，跳过推送"
    fi

    cd "${WORK_DIR}"
}

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

# 记录映射关系（去重，含同步时间）
append_mapping() {
    local old_sha="$1"
    local new_sha="$2"
    local sync_time
    sync_time=$(date '+%Y-%m-%d %H:%M:%S')
    if ! grep -q "^${old_sha} -> " "${MAPPING_FILE}" 2>/dev/null; then
        echo "${old_sha} -> ${new_sha}  ${sync_time}" >> "${MAPPING_FILE}"
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
    local FETCH_RC=${PIPESTATUS[0]}

    # fetch 失败时自动重建工作仓库（常见原因：本地对象损坏导致 delta 无法解析）
    if [[ ${FETCH_RC} -ne 0 ]]; then
        log_warn "fetch gitcode 失败 (rc=${FETCH_RC})，可能工作仓库对象损坏"
        log_warn "重建工作仓库: 删除 ${LOCAL_REPO} 并重新 clone"
        cd "${WORK_DIR}"
        rm -rf "${LOCAL_REPO}"

        # 重新 clone GitHub 目标（保留已同步的历史）
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

        # 重试 fetch
        log_info "重建后重试 fetch gitcode: ${GITCODE_BRANCH}"
        git fetch gitcode "${GITCODE_BRANCH}" 2>&1 | tee -a "${LOG_FILE}"
        if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
            log_error "重建后 fetch 仍然失败，放弃本次同步"
            set_state "status" "fetch_failed"
            push_state_to_repo
            exit 1
        fi
        log_info "重建工作仓库成功，继续同步"
    fi

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
    local GITHUB_BRANCH_EXISTS=0
    if git rev-parse --verify "${GITHUB_REF}" >/dev/null 2>&1; then
        GITHUB_BRANCH_EXISTS=1
        log_info "切换到目标分支: ${GITHUB_BRANCH}"
        git checkout -B "${GITHUB_BRANCH}" "${GITHUB_REF}" 2>&1 | tee -a "${LOG_FILE}"
    else
        # GitHub 上没有该分支，创建孤儿分支（无历史无文件），避免与源分支根commit冲突
        log_info "GitHub 上无目标分支，创建孤儿分支 ${GITHUB_BRANCH}"
        # 先删除本地残留的同名分支（否则 checkout --orphan 会基于旧分支HEAD）
        git branch -D "${GITHUB_BRANCH}" 2>/dev/null || true
        git checkout --orphan "${GITHUB_BRANCH}" 2>&1 | tee -a "${LOG_FILE}"
        # 清空工作目录所有文件和index，保持完全空状态
        # 不做空commit占位——cherry-pick根commit时会自然成为第一个commit
        git ls-files | xargs -r rm -f
        git rm --cached -r . 2>/dev/null || true
        git clean -fd 2>/dev/null || true
    fi

    # ---- Step 4: 确定增量起始点 ----
    local LAST_SYNCED
    LAST_SYNCED=$(get_last_synced_from_mapping)

    local START_COMMIT=""
    local COMMITS_TO_SYNC=()

    if [[ -n "${LAST_SYNCED}" ]]; then
        # 校验：mapping.log说已同步，但GitHub上目标分支不存在 → 状态过期，重置
        if [[ ${GITHUB_BRANCH_EXISTS} -eq 0 ]]; then
            log_warn "mapping.log记录已同步到 ${LAST_SYNCED}，但GitHub上无目标分支，状态过期，重新全量同步"
            LAST_SYNCED=""
        else
            log_info "上次同步到: ${LAST_SYNCED}"

        # 验证该commit仍存在于源分支历史中
        if git merge-base --is-ancestor "${LAST_SYNCED}" "${SRC_REF}" 2>/dev/null; then
            if [[ "${LAST_SYNCED}" == "${SRC_HEAD}" ]]; then
                log_info "没有新 commit，已是最新"
                set_state "status" "up_to_date"
                set_state "last_synced_time" "$(date '+%Y-%m-%d %H:%M:%S')"
                push_state_to_repo
                return 0
            fi
            # 增量: LAST_SYNCED 的下一个commit开始
            START_COMMIT="${LAST_SYNCED}"
            log_info "增量同步: ${LAST_SYNCED} 之后的新 commit"
        else
            log_warn "上次同步的 commit 已不在源分支历史中，从头开始"
            LAST_SYNCED=""
        fi
        fi  # GITHUB_BRANCH_EXISTS check
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
        set_state "last_synced_time" "$(date '+%Y-%m-%d %H:%M:%S')"
        push_state_to_repo
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
            # 持久化冲突状态到仓库
            push_state_to_repo
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

    # 持久化状态到仓库
    push_state_to_repo
}

# ==================== 入口 ====================
trap release_lock EXIT

log_info "脚本启动"

# 初始化状态仓库（确定 STATE_DIR）
init_state_repo

# 更新关键路径（init_state_repo 可能改变了 STATE_DIR）
LOCK_FILE="${STATE_DIR}/sync.lock"
LOG_FILE="${STATE_DIR}/sync.log"
MAPPING_FILE="${STATE_DIR}/mapping.log"
STATE_JSON="${STATE_DIR}/state.json"
LOCAL_REPO="${WORK_DIR}/repo"
mkdir -p "${STATE_DIR}" "${WORK_DIR}"

init_state_json
acquire_lock

sync_repo
log_info "脚本结束"
