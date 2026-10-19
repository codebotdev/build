# JDCloud AX3000 / ImmortalWrt v25.12.2

在 `.github/workflows/openwrt.yml` 的 **Run workflow** 中填写：

| 参数 | 值 |
| --- | --- |
| `source_repository` | `immortalwrt/immortalwrt` |
| `source_branch` | `0c4cd0f9920a420a2ac95b49c1b62130769c08ae` |
| `patches` | `jdcloud_ax3000_immortalwrt` |
| `overrides` | `jdcloud_ax3000_immortalwrt` |
| `config` | `jdcloud_ax3000.config` |
| `extra_config` | `kmods.config` |

源码补丁以该提交为基准，包含 JDCloud AX3000、IPQ5018 DWMAC、NSS 和本地配置修改。新增源码、内核补丁、固件及配置位于 `overrides/jdcloud_ax3000_immortalwrt`。原项目的开发说明和 `apply-feed-patches.sh` 不复制到构建树。

应用顺序：

1. `apply-openwrt-patches.sh` 应用本目录顶层的源码补丁。
2. `apply-openwrt-overrides.sh` 复制同名 overrides。
3. `build_openwrt.sh` 执行 `scripts/feeds update -a`。
4. 使用 `PATCH_PHASE=feeds` 调用通用补丁脚本，直接应用本目录 `feeds/*.patch`；路径已转换为源码根目录下的 `feeds/<feed>/...`。
5. 执行 `scripts/feeds install -a` 并继续配置和编译。

无需执行 `apply-feed-patches.sh`。旧补丁集没有 `feeds/` 目录时跳过此阶段；通用构建脚本保留对旧源码自带 helper 的兼容。

保留原项目 `feeds.conf.default` 中的版本锁定。`extra` 仍跟踪 `jdcloud_ax3000` 分支，若分支发生不兼容变化，直接补丁检查会失败；本次验证使用其提交 `5c56502966618bba778317bfdee806f477b5f613`。

验证：在指定提交的干净源码树上应用全部补丁和 overrides，核对 223 个源码文件的内容、权限及删除结果；在本地 feed HEAD 的干净副本中应用 5 个 feed 补丁并逐个反向检查。通用构建脚本的 17 项离线测试通过。未执行完整固件编译。
