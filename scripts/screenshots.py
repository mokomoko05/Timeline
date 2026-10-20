import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent
REFERENCE = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc).timestamp()


def sample_data():
    today = datetime.datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)

    def timestamp(day=0, hour=0, minute=0):
        return (today + datetime.timedelta(days=day, hours=hour, minutes=minute)).timestamp() - REFERENCE

    def task(number, title, priority, day=0, completed=False, tags=None, minutes=0):
        return {
            "id": str(uuid.uuid4()).upper(), "number": number, "title": title,
            "priority": priority, "completed": completed, "dueDate": timestamp(day),
            "dueHasTime": False, "tags": tags or [], "focusSeconds": minutes * 60,
        }

    tasks = [
        task(1, "读一篇论文，整理方法与问题", "high", tags=["阅读"], minutes=50),
        task(2, "收集相关资料", "normal", completed=True, tags=["阅读"], minutes=25),
        task(3, "试着复现一个小实验", "normal", tags=["研究"], minutes=35),
        task(4, "整理这一周的阅读笔记", "lower", day=1, tags=["阅读"]),
        task(5, "给下一个项目画张草图", "low", day=3, tags=["想法"]),
    ]

    def log(hour, minute, text, kind="note", **extra):
        return {
            "id": str(uuid.uuid4()).upper(), "createdAt": timestamp(hour=hour, minute=minute),
            "kind": kind, "text": text, "taskID": tasks[0]["id"],
            "taskNumber": 1, "taskTitle": tasks[0]["title"], "taskTags": ["阅读"], **extra,
        }

    logs = [
        log(9, 0, "▶ 开始专注 · 计划 25 min", focus=True, focusEvent="start", focusGoal="看懂方法部分，留下两个问题", focusPlannedSeconds=1500),
        log(9, 12, "## 一个值得继续看的思路\n\n先用小规模实验验证假设，再考虑完整实现。\n\n- 记录对比条件\n- 解释结果的差异", focusEvent="note"),
        log(9, 25, "方法部分读完了。下一轮先验证边界条件。", focus=True, focusEvent="review"),
        log(9, 25, "■ 结束专注 · 用时 25 min · 累计 1 h 15 min · 阶段结束", focus=True, focusEvent="end", focusElapsedSeconds=1500, focusEndReason="阶段结束"),
        log(10, 5, "整理好参考资料，下午开始实验。", kind="done"),
    ]
    return {"version": 6, "nextTaskNumber": 6, "days": {
        today.strftime("%Y-%m-%d"): {
            "todos": tasks, "logs": logs, "summary": "", "deadlineDraft": "",
            "logDraft": "记下刚刚想到的一个问题…",
        },
    }}


def main():
    subprocess.run(["bash", "scripts/build.sh"], cwd=ROOT, check=True)
    output = ROOT / "docs" / "screenshots"
    output.mkdir(parents=True, exist_ok=True)
    domain = "local.timeline.screenshots." + uuid.uuid4().hex
    with tempfile.TemporaryDirectory(prefix="timeline-screenshots-") as temporary:
        temporary = Path(temporary)
        app = temporary / "Timeline.app"
        shutil.copytree(ROOT / "dist" / "Timeline.app", app, symlinks=True)
        info_path = app / "Contents" / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleIdentifier"] = domain
        info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
        data = temporary / "Data"
        data.mkdir()
        environment = {**os.environ, "TIMELINE_DATA_DIR": str(data)}
        try:
            for name in ["main", "capture", "focus", "daylog"]:
                (data / "journal.json").write_text(json.dumps(sample_data(), ensure_ascii=False), encoding="utf-8")
                destination = output / (name + ".png")
                subprocess.run([
                    str(app / "Contents" / "MacOS" / "Timeline"),
                    "--snapshot", str(destination), "--snapshot-window", name,
                    "--theme", "graphite", "--appearance", "dark",
                    "-appLanguage", "chinese", "-tasksPaneExpanded", "YES",
                    "-hideCompleted", "NO", "-uiScale", "1",
                ], env=environment, check=True, timeout=30)
                if name in ["main", "daylog"]:
                    subprocess.run(["sips", "-Z", "1440", str(destination)], check=True, stdout=subprocess.DEVNULL)
        finally:
            subprocess.run(["defaults", "delete", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
