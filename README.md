# ImmortalWrt 编译与下载

使用 GitHub Actions 编译 ImmortalWrt，各项目的最新发布文件分别列在下方。
编译产物暂存于 `/upload`，随后上传到 GitHub Releases。

> 本文件由 `projects.json` 自动生成，请修改 JSON 中的项目名称和介绍后重新生成。

暂无已发布的下载文件。

## 维护与扩展

- 在 `projects.json` 的 `projects` 下以编译项目名称为键添加项目，填写 `name`、`description`、`build`（`branch` / `commit`）和 `files`（`name` / `url`）。
- 发布成功后，workflow 从 Release 获取实际附件链接，仅替换当前项目的编译信息和文件列表，保留其他项目。
- 没有有效下载链接的项目不显示；`sha256sums` 保留在 Release 和 JSON 中，但不显示在下载表格。
- 新项目在发布后调用 `.github/workflows/update_catalog.yml`，传入项目键、源码分支、完整提交 SHA 和 Release 标签。
- 本地重新生成：`python scripts/release_catalog.py render`。所有脚本均位于 `scripts/`。
