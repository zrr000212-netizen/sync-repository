#!/usr/bin/env python3
"""
GitCode→GitHub 同步日报监控脚本
每天检查同步状态，生成报告，发送邮件

用法:
  python3 sync_monitor.py                    # 检查并发送邮件
  python3 sync_monitor.py --no-mail          # 仅打印报告，不发邮件
  python3 sync_monitor.py --test-mail        # 测试邮件发送
"""
import json
import os
import subprocess
import sys
import argparse
from datetime import datetime, timedelta
from pathlib import Path

SYNC_REPO_DIR = Path("/root/sync-repository")
STATES_DIR = SYNC_REPO_DIR / "states"
CONF_FILE = SYNC_REPO_DIR / "sync-repos.conf"
SEND_MAIL_SCRIPT = SYNC_REPO_DIR / "scripts" / "send_mail.py"

def run_cmd(cmd: str, timeout: int = 30) -> str:
    """执行shell命令，返回输出"""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception as e:
        return f"[ERROR] {e}"

def load_state(state_dir: Path) -> dict:
    """读取 state.json"""
    sj = state_dir / "state.json"
    if sj.exists():
        return json.loads(sj.read_text())
    return {}

def get_remote_head(repo_url: str, branch: str) -> str:
    """用 git ls-remote 获取远程仓库分支的 HEAD SHA"""
    output = run_cmd(f"git ls-remote {repo_url} refs/heads/{branch}", timeout=20)
    if output and not output.startswith("[ERROR]"):
        parts = output.split()
        if parts:
            return parts[0]
    return ""

def load_active_configs() -> list:
    """从 sync-repos.conf 读取当前活跃配置，返回 [(gc_repo, gc_branch, gh_repo, gh_branch), ...]"""
    configs = []
    if not CONF_FILE.exists():
        return configs
    for line in CONF_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 4:
            configs.append((parts[0], parts[1], parts[2], parts[3]))
    return configs

def analyze_unsynced_commits(work_repo: str, last_synced: str, src_head: str) -> dict:
    """分析未同步的commit，评估风险等级"""
    result = {"count": 0, "risk": "unknown", "commits": [], "summary": ""}

    if not work_repo or not last_synced or not src_head:
        return result

    # 尝试从工作仓库获取 commit 列表
    work_dir = f"/tmp/gitcode-sync-work"
    # 找到匹配的工作仓库
    repo_path = None
    for d in Path(work_dir).iterdir():
        if not d.is_dir():
            continue
        r = d / "repo"
        if r.exists() and (r / ".git").exists():
            repo_path = str(r)
            break

    if not repo_path:
        result["summary"] = "无法访问工作仓库，无法分析风险"
        return result

    # fetch 最新
    run_cmd(f"cd {repo_path} && git fetch --all", timeout=30)

    # 获取 commit 列表
    log_fmt = "--format=%h|%s|%an|%ad"
    cmd = f'cd {repo_path} && git log {log_fmt} --date=short {last_synced}..{src_head} 2>/dev/null || git log {log_fmt} --date=short {src_head}..{last_synced} 2>/dev/null'
    output = run_cmd(cmd, timeout=15)

    if not output or output.startswith("[ERROR]"):
        result["summary"] = "无法获取 commit 差异"
        return result

    commits = []
    for line in output.splitlines():
        parts = line.split("|", 3)
        if len(parts) >= 4:
            commits.append({
                "hash": parts[0],
                "subject": parts[1],
                "author": parts[2],
                "date": parts[3]
            })

    result["count"] = len(commits)
    result["commits"] = commits[:20]  # 最多显示20条

    if not commits:
        result["risk"] = "none"
        result["summary"] = "无差异"
        return result

    # 风险评估：基于 commit message 关键词
    high_risk_keywords = ["drop", "delete", "remove table", "truncate", "reset", "force", "breaking", "migration", "flyway", "ddl", "alter table"]
    medium_risk_keywords = ["config", "env", "secret", "password", "token", "key", "permission", "auth", "deploy", "release"]

    risk_level = "low"
    risk_reasons = []

    for c in commits:
        subj_lower = c["subject"].lower()
        for kw in high_risk_keywords:
            if kw in subj_lower:
                risk_level = "high"
                risk_reasons.append(f"高风险关键词 '{kw}' 在 {c['hash']}: {c['subject']}")
                break
        if risk_level != "high":
            for kw in medium_risk_keywords:
                if kw in subj_lower:
                    if risk_level == "low":
                        risk_level = "medium"
                    risk_reasons.append(f"中风险关键词 '{kw}' 在 {c['hash']}: {c['subject']}")
                    break

    # 超过10个commit也提升风险
    if len(commits) > 10 and risk_level == "low":
        risk_level = "medium"
        risk_reasons.append(f"未同步 commit 数量较多 ({len(commits)}个)")

    result["risk"] = risk_level
    if risk_reasons:
        result["summary"] = "; ".join(risk_reasons[:5])
    else:
        result["summary"] = f"{len(commits)} 个常规 commit 未同步"

    return result

def generate_report() -> tuple:
    """生成同步日报（仅活跃配置）"""
    now = datetime.now()
    lines = []
    has_anomaly = False

    # 读取活跃配置
    active_configs = load_active_configs()
    if not active_configs:
        lines.append("❌ 无活跃同步配置")
        return "\n".join(lines), True

    # 遍历所有状态目录，只报告匹配活跃配置的
    if not STATES_DIR.exists():
        lines.append("❌ 状态目录不存在")
        return "\n".join(lines), True

    state_dirs = sorted([d for d in STATES_DIR.iterdir() if d.is_dir()])
    reported = []

    for sd in state_dirs:
        state = load_state(sd)
        if not state:
            continue

        gc_repo = state.get("gitcode_repo", "")
        gc_branch = state.get("gitcode_branch", "")
        gh_repo = state.get("github_repo", "")
        gh_branch = state.get("github_branch", "")

        # 只报告匹配活跃配置的任务
        matched = False
        for ac in active_configs:
            if gc_repo == ac[0] and gc_branch == ac[1] and gh_repo == ac[2] and gh_branch == ac[3]:
                matched = True
                break
        if not matched:
            continue

        reported.append((sd, state))

    if not reported:
        lines.append("⚠ 未找到匹配活跃配置的同步状态")
        return "\n".join(lines), True

    # ── 报告头 ──
    lines.append("╔══════════════════════════════════════════╗")
    lines.append("║       GitCode → GitHub 同步日报           ║")
    lines.append("╚══════════════════════════════════════════╝")
    lines.append(f"📅 日期: {now.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"📊 活跃任务: {len(reported)} 个")
    lines.append("")

    for idx, (sd, state) in enumerate(reported, 1):
        gc_repo = state.get("gitcode_repo", "?")
        gc_branch = state.get("gitcode_branch", "?")
        gh_repo = state.get("github_repo", "?")
        gh_branch = state.get("github_branch", "?")
        status = state.get("status", "?")
        last_time = state.get("last_synced_time", "")
        last_commit = state.get("last_synced_commit", "")
        total_commits = state.get("total_commits_synced", 0)
        sync_count = state.get("sync_count", 0)

        # 提取仓库名（含 host 区分）
        gc_name = gc_repo.split(":")[-1].replace(".git", "") if gc_repo != "?" else "?"
        gh_name = gh_repo.split(":")[-1].replace(".git", "") if gh_repo != "?" else "?"
        gh_host = ""
        if gh_repo != "?" and "@" in gh_repo and ":" in gh_repo:
            gh_host = gh_repo.split("@")[1].split(":")[0]
        elif gh_repo != "?" and gh_repo.startswith("https://"):
            gh_host = gh_repo.split("/")[2]
        gh_display = f"{gh_name} [{gh_host}]" if gh_host else gh_name

        # 检查源HEAD
        src_head = get_remote_head(gc_repo, gc_branch)
        is_synced = (src_head == last_commit) if src_head and last_commit else False
        is_stale = False

        # 计算距今天数
        days_ago = -1
        if last_time:
            try:
                lt = datetime.strptime(last_time, "%Y-%m-%d %H:%M:%S")
                days_ago = (now - lt).days
                if days_ago > 1:
                    is_stale = True
            except:
                pass

        # ── 判断整体状态 ──
        if is_synced and not is_stale:
            overall = "✅ 正常"
            is_ok = True
        elif is_synced and is_stale:
            overall = "⚠️  已同步但超时未刷新"
            is_ok = False
            has_anomaly = True
        elif not is_synced and not is_stale:
            overall = "🔴 有未同步的commit"
            is_ok = False
            has_anomaly = True
        else:
            overall = "🔴 有未同步的commit + 超时未刷新"
            is_ok = False
            has_anomaly = True

        # ── 任务块 ──
        lines.append(f"┌─ 任务 {idx} ─────────────────────────────")
        lines.append(f"│ {gc_name} ({gc_branch})")
        lines.append(f"│   → {gh_display} ({gh_branch})")
        lines.append(f"│")
        lines.append(f"│ 状态: {overall}")
        lines.append(f"│ 最后同步: {last_time}" + (f" ({days_ago}天前)" if days_ago >= 0 else ""))
        lines.append(f"│ 累计commit: {total_commits}  |  同步次数: {sync_count}")

        # HEAD 对比
        if src_head:
            short_head = src_head[:12]
            short_synced = last_commit[:12] if last_commit else "N/A"
            if is_synced:
                lines.append(f"│ HEAD: {short_head} ✓ 源与已同步一致")
            else:
                lines.append(f"│ 源HEAD:   {short_head}")
                lines.append(f"│ 已同步:   {short_synced}")

                # ── 风险分析 ──
                analysis = analyze_unsynced_commits(
                    str(sd), last_commit, src_head
                )
                risk = analysis["risk"]
                commit_count = analysis["count"]

                if risk == "high":
                    risk_icon = "🔴 高风险"
                elif risk == "medium":
                    risk_icon = "🟡 中风险"
                elif risk == "low":
                    risk_icon = "🟢 低风险"
                else:
                    risk_icon = "⚪ 未知"

                lines.append(f"│")
                lines.append(f"│ ⚠ 风险评估: {risk_icon}")
                lines.append(f"│ 未同步commit: {commit_count} 个")
                if analysis["summary"]:
                    lines.append(f"│ 说明: {analysis['summary']}")

                # 列出具体 commit（最多10条）
                if analysis["commits"]:
                    lines.append(f"│")
                    lines.append(f"│ 未同步commit列表:")
                    for c in analysis["commits"][:10]:
                        lines.append(f"│   {c['hash']}  {c['subject'][:60]}  ({c['author']}, {c['date']})")
                    if commit_count > 10:
                        lines.append(f"│   ... 还有 {commit_count - 10} 个")
        else:
            lines.append(f"│ HEAD: (无法获取)")

        lines.append(f"└──────────────────────────────────────────")
        lines.append("")

    # ── 总结 ──
    lines.append("━" * 44)
    if has_anomaly:
        lines.append("📌 总结: 存在异常，请关注上方风险评估")
    else:
        lines.append("📌 总结: ✅ 所有同步任务正常，无风险")

    return "\n".join(lines), has_anomaly

def send_email(subject: str, body: str) -> bool:
    """调用 send_mail.py 发送邮件"""
    r = subprocess.run(
        [sys.executable, str(SEND_MAIL_SCRIPT), "--subject", subject, "--body", body],
        capture_output=True, text=True, timeout=30
    )
    if r.returncode == 0:
        print(f"[OK] 邮件已发送")
        return True
    else:
        print(f"[WARN] 邮件发送失败: {r.stderr.strip() or r.stdout.strip()}")
        return False

def main():
    parser = argparse.ArgumentParser(description="GitCode→GitHub 同步日报监控")
    parser.add_argument("--no-mail", action="store_true", help="仅打印报告，不发邮件")
    parser.add_argument("--test-mail", action="store_true", help="测试邮件发送")
    args = parser.parse_args()

    if args.test_mail:
        ok = send_email("同步监控测试", "这是一封测试邮件，验证SMTP配置是否正常。")
        sys.exit(0 if ok else 1)

    report, has_anomaly = generate_report()
    print(report)

    if not args.no_mail:
        today = datetime.now().strftime("%Y-%m-%d")
        subject = f"GitCode→GitHub 同步日报 {today}"
        if has_anomaly:
            subject = f"【异常】GitCode→GitHub 同步日报 {today}"
        send_email(subject, report)

if __name__ == "__main__":
    main()
