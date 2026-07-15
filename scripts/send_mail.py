#!/usr/bin/env python3
"""
通用邮件发送脚本 — 供同步监控使用
用法: python3 send_mail.py --subject "标题" --body "正文"
"""
import smtplib
import argparse
import os
from pathlib import Path
from email.mime.text import MIMEText
from email.utils import formatdate

# ── 自动加载 .env.smtp（与脚本同级的 env 文件） ──
_ENV_FILE = Path(__file__).resolve().parent.parent / ".env.smtp"
if _ENV_FILE.exists():
    for line in _ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k not in os.environ:
            os.environ[k] = v

# ── SMTP 配置（从环境变量读取） ──
SMTP_HOST = os.getenv("SMTP_HOST", "")
SMTP_PORT = int(os.getenv("SMTP_PORT", "465"))
SMTP_USER = os.getenv("SMTP_USER", "")
SMTP_PASS = os.getenv("SMTP_PASS", "")
MAIL_FROM = os.getenv("MAIL_FROM", SMTP_USER)
MAIL_TO   = os.getenv("MAIL_TO", "")
# 支持逗号分隔多收件人
MAIL_TO_LIST = [addr.strip() for addr in MAIL_TO.split(",") if addr.strip()]

def send(subject: str, body: str):
    if not all([SMTP_HOST, SMTP_USER, SMTP_PASS, MAIL_TO_LIST]):
        missing = []
        if not SMTP_USER: missing.append("SMTP_USER")
        if not SMTP_PASS: missing.append("SMTP_PASS")
        if not MAIL_TO_LIST: missing.append("MAIL_TO")
        print(f"[ERROR] 缺少邮件配置: {', '.join(missing)}")
        print("请设置环境变量或在脚本中填入默认值")
        return False

    msg = MIMEText(body, "plain", "utf-8")
    msg["From"] = MAIL_FROM
    msg["To"] = ", ".join(MAIL_TO_LIST)
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=True)

    try:
        if SMTP_PORT == 465:
            server = smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=15)
        else:
            server = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15)
            server.starttls()
        server.login(SMTP_USER, SMTP_PASS)
        server.sendmail(MAIL_FROM, MAIL_TO_LIST, msg.as_string())
        server.quit()
        print(f"[OK] 邮件已发送: {subject}")
        return True
    except Exception as e:
        print(f"[ERROR] 邮件发送失败: {e}")
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--subject", required=True)
    parser.add_argument("--body", required=True)
    args = parser.parse_args()
    ok = send(args.subject, args.body)
    exit(0 if ok else 1)
