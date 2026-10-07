#!/usr/bin/env python3
"""Read actual GitHub Release assets, update one project, and render README."""
import argparse
import html
import json
from pathlib import Path
import subprocess
from urllib.parse import urlsplit


def gh(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True, encoding="utf-8"))


def text(value):
    return html.escape(str(value)).replace("|", "&#124;").replace("\n", " ").replace("\r", " ").replace("[", "&#91;").replace("]", "&#93;").replace("*", "&#42;").replace("`", "&#96;").replace("_", "&#95;")


def downloadable(files):
    return sorted(
        (f for f in (files or []) if f.get("name") != "sha256sums"
         and urlsplit(f.get("url") or "").scheme == "https"
         and urlsplit(f.get("url") or "").netloc),
        key=lambda f: f["name"],
    )


def render(data):
    lines = ["# ImmortalWrt 编译与下载", "",
             "使用 GitHub Actions 编译 ImmortalWrt，各项目的最新发布文件分别列在下方。",
             "编译产物暂存于 `/upload`，随后上传到 GitHub Releases。", "",
             "> 本文件由 `projects.json` 自动生成，请修改 JSON 中的项目名称和介绍后重新生成。", ""]
    visible = False
    for key, project in data["projects"].items():
        files = downloadable(project.get("files"))
        if not files:
            continue
        visible = True
        build = project.get("build", {})
        lines += [f"## {text(project['name'])}", "", project["description"], "",
                  f"项目：`{key}`  ",
                  f"源码分支：{text(build.get('branch', ''))}  ",
                  f"源码提交：{text(build.get('commit', ''))}", "",
                  "| 文件名 | 下载链接 |", "| --- | --- |"]
        for file in files:
            url = file["url"].replace("<", "%3C").replace(">", "%3E").replace("\n", "%0A").replace("\r", "%0D")
            lines.append(f"| {text(file['name'])} | [下载](<{url}>) |")
        lines.append("")
    if not visible:
        lines += ["暂无已发布的下载文件。", ""]
    lines += ["## 维护与扩展", "",
              "- 在 `projects.json` 的 `projects` 下以编译项目名称为键添加项目，填写 `name`、`description`、`build`（`branch` / `commit`）和 `files`（`name` / `url`）。",
              "- 发布成功后，workflow 从 Release 获取实际附件链接，仅替换当前项目的编译信息和文件列表，保留其他项目。",
              "- 没有有效下载链接的项目不显示；`sha256sums` 保留在 Release 和 JSON 中，但不显示在下载表格。",
              "- 新项目在发布后调用 `.github/workflows/update_catalog.yml`，传入项目键、源码分支、完整提交 SHA 和 Release 标签。",
              "- 本地重新生成：`python scripts/release_catalog.py render`。所有脚本均位于 `scripts/`。", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["render", "update"])
    parser.add_argument("--catalog", type=Path, default=Path("projects.json"))
    parser.add_argument("--readme", type=Path, default=Path("README.md"))
    parser.add_argument("--project")
    parser.add_argument("--branch")
    parser.add_argument("--commit")
    parser.add_argument("--tag")
    args = parser.parse_args()
    data = json.loads(args.catalog.read_text(encoding="utf-8"))
    if args.command == "update":
        if not all([args.project, args.branch, args.commit, args.tag]):
            parser.error("update requires --project, --branch, --commit and --tag")
        project = data["projects"][args.project]
        release = gh("release", "view", args.tag, "--json", "assets,isDraft")
        if release["isDraft"]:
            raise ValueError("Cannot catalog an unpublished draft release")
        project["build"] = {"branch": args.branch, "commit": args.commit}
        project["files"] = sorted(
            ({"name": a["name"], "url": a["url"]} for a in release["assets"]),
            key=lambda f: f["name"],
        )
        args.catalog.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    args.readme.write_text(render(data), encoding="utf-8")


if __name__ == "__main__":
    main()
