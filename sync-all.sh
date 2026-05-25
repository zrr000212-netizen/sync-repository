#!/bin/bash
#
# sync-all.sh — 批量增量同步入口
# 读取 sync-repos.conf，逐行调用 gitcode-to-github-sync.sh
#
# 用法:
#   ./sync-all.sh                    # 同步所有仓库
#   ./sync-all.sh --dry-run          # 仅打印要同步的仓库，不执行
#
# 定时任务 (每小时):
#   0 * * * * /root/sync-repository/sync-all.sh >> /root/sync-repository/sync-all.log 2>&1
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/gitcode-to-github-sync.sh"
CONF_FILE="${SCRIPT_DIR}/sync-repos.conf"
LOG_FILE="${SCRIPT_DIR}/sync-all.log"

AUTHOR_NAME="zrr000212-netizen"
AUTHOR_EMAIL="zrr000212@gmail.com"
STATE_REPO="git@github.com:zrr000212-netizen/sync-repository.git"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# 检查配置文件
if [[ ! -f "${CONF_FILE}" ]]; then
    log "[ERROR] 配置文件不存在: ${CONF_FILE}"
    exit 1
fi

# 检查同步脚本
if [[ ! -x "${SYNC_SCRIPT}" ]]; then
    log "[ERROR] 同步脚本不存在或不可执行: ${SYNC_SCRIPT}"
    exit 1
fi

TOTAL=0
SUCCESS=0
FAIL=0

log "========== 批量同步开始 =========="

while IFS= read -r line; do
    # 跳过空行和注释
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    # 去除前后空格
    line="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # 解析: gitcode_repo | gitcode_branch | github_repo | github_branch
    IFS='|' read -r GC_REPO GC_BRANCH GH_REPO GH_BRANCH <<< "${line}"
    GC_REPO="$(echo "${GC_REPO}" | xargs)"
    GC_BRANCH="$(echo "${GC_BRANCH}" | xargs)"
    GH_REPO="$(echo "${GH_REPO}" | xargs)"
    GH_BRANCH="$(echo "${GH_BRANCH}" | xargs)"

    TOTAL=$((TOTAL + 1))

    # 提取仓库名用于日志
    GC_NAME="$(basename "${GC_REPO}" .git)"
    log "[${TOTAL}] 同步: ${GC_NAME} (${GC_BRANCH}) → $(basename "${GH_REPO}" .git) (${GH_BRANCH})"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "  [DRY-RUN] 跳过执行"
        continue
    fi

    # 调用同步脚本
    if bash "${SYNC_SCRIPT}" \
        --gitcode-repo "${GC_REPO}" \
        --gitcode-branch "${GC_BRANCH}" \
        --github-repo "${GH_REPO}" \
        --github-branch "${GH_BRANCH}" \
        --author-name "${AUTHOR_NAME}" \
        --author-email "${AUTHOR_EMAIL}" \
        --state-repo "${STATE_REPO}"; then
        SUCCESS=$((SUCCESS + 1))
        log "[${TOTAL}] ✓ ${GC_NAME} 同步成功"
    else
        FAIL=$((FAIL + 1))
        log "[${TOTAL}] ✗ ${GC_NAME} 同步失败 (exit: $?)"
    fi

    # 仓库间间隔2秒，避免API限流
    sleep 2

done < "${CONF_FILE}"

log "========== 批量同步结束 =========="
log "总计: ${TOTAL}, 成功: ${SUCCESS}, 失败: ${FAIL}"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
