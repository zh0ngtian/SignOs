"""Chinese changes shared by SignOs preparation, CI, GitHub and OTA."""
import json
from pathlib import Path
import re

PLACEHOLDERS = {"更新", "优化", "修复", "修复问题", "修复已知问题", "性能优化", "体验优化",
                "优化体验", "更新应用", "发布新版本", "功能改进", "常规更新", "更新说明",
                "中文更新日志", "发布批次", "暂无", "无", "测试", "待补充", "稍后补充"}


def changes(value):
    if not isinstance(value, list) or not value:
        raise ValueError("发布必须提供具体中文更新日志：changes 不能为空")
    result = []
    for item in value:
        if not isinstance(item, str):
            raise ValueError("发布必须提供具体中文更新日志：每条变更必须是文本")
        item = " ".join(item.split())
        plain = re.sub(r"[\W_]+", "", item)
        if len(re.findall(r"[\u3400-\u9fff]", item)) < 4 or plain in PLACEHOLDERS:
            raise ValueError("发布必须提供具体中文更新日志，不能使用纯英文或笼统占位说明")
        if re.search(r"\b(TODO|TBD)\b", item, re.I) or item.startswith(("待补充", "稍后补充", "SignOs coordinated release batch", "SignOs 发布批次")):
            raise ValueError("发布必须提供具体中文更新日志，不能使用发布批次或待补充说明")
        result.append(item)
    return result


def task_notes(tasks):
    if not isinstance(tasks, list) or not tasks:
        raise ValueError("发布必须提供具体中文更新日志：没有参与任务")
    result = []
    ids = set()
    for task in tasks:
        if not isinstance(task, dict) or not isinstance(task.get("validation"), dict):
            raise ValueError("发布必须提供具体中文更新日志：任务记录格式无效")
        task_id, sha = task.get("id"), task.get("sha")
        if not isinstance(task_id, str) or not task_id or task_id in ids or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise ValueError("中文更新日志的任务身份或 SHA 无效")
        ids.add(task_id)
        note = task.get("validation", {}).get("releaseNotes")
        if not isinstance(note, dict) or note.get("language") != "zh-Hans":
            raise ValueError(f"任务 {task_id} 必须提供具体中文更新日志 releaseNotes")
        result.append({"id": task_id, "sha": sha, "changes": changes(note.get("changes"))})
    return result


def make_notes(tasks, batch_id, version, build):
    record = {"schemaVersion": 1, "batchId": batch_id, "language": "zh-Hans",
              "version": version, "buildNumber": str(build), "tasks": task_notes(tasks)}
    validate_notes(record)
    return record


def validate_notes(record, manifest=None):
    if not isinstance(record, dict) or record.get("schemaVersion") != 1 or record.get("language") != "zh-Hans":
        raise ValueError("冻结的具体中文更新日志格式无效")
    if not isinstance(record.get("batchId"), str) or not re.fullmatch(r"[0-9a-f-]{36}", record["batchId"]):
        raise ValueError("中文更新日志的批次身份无效")
    if not isinstance(record.get("version"), str) or not isinstance(record.get("buildNumber"), str):
        raise ValueError("中文更新日志的版本或构建号格式无效")
    if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", record["version"]) or not re.fullmatch(r"[1-9]\d*", record["buildNumber"]):
        raise ValueError("中文更新日志的版本或构建号无效")
    tasks = record.get("tasks")
    if not isinstance(tasks, list) or not tasks or any(not isinstance(t, dict) for t in tasks):
        raise ValueError("缺少或格式无效的冻结中文更新日志")
    task_notes([{"id": t.get("id"), "sha": t.get("sha"),
                 "validation": {"releaseNotes": {"language": "zh-Hans", "changes": t.get("changes")}}}
                for t in tasks])
    if manifest is not None:
        prepared = manifest["prepared"]
        if record["batchId"] != manifest["batchId"] or record["version"] != prepared["version"] or record["buildNumber"] != prepared["buildNumber"]:
            raise ValueError("中文更新日志不属于该冻结批次或版本")
        expected = [(t["id"], t["sha"]) for t in manifest["tasks"]]
        if [(t["id"], t["sha"]) for t in tasks] != expected:
            raise ValueError("中文更新日志与冻结任务身份不一致")
    return record


def load_notes(path, manifest):
    try:
        record = json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise ValueError("缺少或损坏的冻结中文更新日志") from error
    return validate_notes(record, manifest)


def changelog(record):
    validate_notes(record)
    ordered = dict.fromkeys(item for task in record["tasks"] for item in changes(task["changes"]))
    return f"SignOs {record['version']}（构建 {record['buildNumber']}）\n\n" + "\n".join("- " + item for item in ordered)


def verify_log(text, record, exact=False):
    expected = changelog(record)
    if not isinstance(text, str) or (text.strip() != expected if exact else
                                     not (text.strip() == expected or text.strip().startswith(expected + "\n\n"))):
        raise ValueError("已发布的中文更新日志与冻结变更不一致")
