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

def count_unsynced(gitcode_repo: str, gitcode_branch: str, last_synced: str) -> int:
    """估算未同步的commit数量（通过临时clone+rev-list）"""
    if not last_synced:
        return -1  # 未知
    # 用 git ls-remote 只能拿到HEAD，无法算差值
    # 改为检查 HEAD 是否与 last_synced 一致
    head = get_remote_head(gitcode_repo, gitcode_branch)
    if not head:
        return -1
    if head == last_synced:
        return 0
    return -2  # 有差异但无法精确计数（需clone才能算）

def generate_report() -> str:
    """生成同步日报"""
    now = datetime.now()
    lines = []
    lines.append("GitCode→GitHub 同步日报")
    lines.append(f"日期: {now.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")

    has_anomaly = False

    # 遍历所有状态目录
    if not STATES_DIR.exists():
        lines.append("[ERROR] 状态目录不存在")
        return "\n".join(lines), True

    state_dirs = sorted([d for d in STATES_DIR.iterdir() if d.is_dir()])

    for idx, sd in enumerate(state_dirs, 1):
        state = load_state(sd)
        if not state:
            continue

        gc_repo = state.get("gitcode_repo", "?")
        gc_branch = state.get("gitcode_branch", "?")
        gh_repo = state.get("github_repo", "?")
        gh_branch = state.get("github_branch", "?")
        status = state.get("status", "?")
        last_time = state.get("last_synced_time", "")
        last_commit = state.get("last_synced_commit", "")
        total_commits = state.get("total_commits_synced", 0)
        sync_count = state.get("sync_count", 0)

        # 判断状态是否正常
        is_ok = status in ("synced", "up_to_date")
        status_icon = "✓" if is_ok else "✗"
        if not is_ok:
            has_anomaly = True

        # 提取仓库名
        gc_name = gc_repo.split(":")[-1].replace(".git", "") if gc_repo != "?" else "?"
        gh_name = gh_repo.split(":")[-1].replace(".git", "") if gh_repo != "?" else "?"

        lines.append(f"[任务{idx}] {gc_name} ({gc_branch}) → {gh_name} ({gh_branch})")
        lines.append(f"  状态: {status_icon} {status}")

        # 计算距今天数
        if last_time:
            try:
                lt = datetime.strptime(last_time, "%Y-%m-%d %H:%M:%S")
                delta = now - lt
                lines.append(f"  最后同步: {last_time} ({delta.days}天前)")
                if delta.days > 1 and is_ok:
                    # 超过1天没同步也算异常
                    lines.append(f"  ⚠ 超过1天未同步")
                    has_anomaly = True
            except:
                lines.append(f"  最后同步: {last_time}")
        else:
            lines.append(f"  最后同步: (无)")

        lines.append(f"  累计commit: {total_commits}, 同步次数: {sync_count}")

        # 检查源HEAD是否与last_synced一致
        src_head = get_remote_head(gc_repo, gc_branch)
        if src_head:
            short_head = src_head[:12]
            short_synced = last_commit[:12] if last_commit else "N/A"
            if src_head == last_commit:
                lines.append(f"  源HEAD: {short_head} (已同步)")
            else:
                lines.append(f"  源HEAD: {short_head} ≠ 已同步: {short_synced}")
                lines.append(f"  ✗ 存在未同步的commit!")
                has_anomaly = True
        else:
            lines.append(f"  源HEAD: (无法获取)")

        lines.append("")

    # 总结
    lines.append("=" * 40)
    if has_anomaly:
        lines.append("总结: ✗ 存在异常，请关注!")
    else:
        lines.append("总结: ✓ 全部正常")

    return "\n".join(lines), has_anomaly

def send_email(subject: str, body: str) -> bool:
    """调用 send_mail.py 发送邮件"""
    cmd = f'python3 {SEND_MAIL_SCRIPT} --subject "{subject}" --body "{body}"'
    # 用subprocess避免shell注入
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
