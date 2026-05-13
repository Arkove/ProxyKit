# ProxyKit 一键静态化 ScriptHub 模块

## 适用场景

这个工具用于把 Egern 配置中的 `script.hub/file/_start_/.../_end_/...` 动态转译链接改成你自己 GitHub 仓库里的静态 Raw 链接，并把图标写入模块文件内部。

你的原系统已经有 `icons`、`incoming`、`qx`、`loon`、`surge`、`egern`、`scripts` 这些目录。这个工具沿用该结构，不破坏原脚本。

## 文件放置

把本压缩包里的内容复制到：

```text
D:\onedrive\Desktop\Code\ProxyKit
```

复制后应有：

```text
scripts\Staticize-EgernModules.ps1
scripts\staticize-modules.example.csv
一键静态化并上传.cmd
```

## 一键执行

确认你的主配置路径是：

```text
D:\onedrive\Desktop\Code\ProxyKit\egern.yaml
```

然后双击：

```text
一键静态化并上传.cmd
```

脚本会自动完成：

1. 扫描 egern.yaml 的 modules 区域。
2. 找出 ScriptHub 动态转译链接。
3. 对 `.lpx`、`.plugin`、`.sgmodule`、`.yaml` 这类完整模块直接镜像。
4. 对 JS/QX 类资源尝试下载 ScriptHub 转译结果。
5. 写入 `#!name`、`#!desc`、`#!icon` 或 YAML 顶层 `icon`。
6. 替换 egern.yaml 里的旧 URL。
7. `git add`、`git commit`、`git push`。

## 为什么能解决图标问题

Egern 对主配置里 modules 条目的 `icon` 支持不稳定，最稳的是把图标写进模块文件内部。

Loon / Surge 模块写入：

```ini
#!name=模块名
#!desc=模块名
#!icon=https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/xxx.png
```

Egern YAML 模块写入：

```yaml
name: 模块名
description: 模块名
icon: https://raw.githubusercontent.com/Arkove/ProxyKit/main/icons/xxx.png
```

## 关于 JS/QX 资源

`forest.js`、`elsa.js`、`mubu.js` 这类只有 JS 的资源不是完整模块。它们需要 ScriptHub 转换后才能变成完整插件。

脚本会尝试下载 ScriptHub 转译链接。如果你的 Windows 环境不能访问本地 `script.hub` 转换服务，这类资源会记录到：

```text
scripts\logs\staticize-failed-时间.csv
```

这类失败不是仓库问题，而是缺少 ScriptHub 转换运行环境。解决方式是先在 Egern 里单独转译成功，再把转译后的模块文件保存下来，放入仓库后再用本脚本或 auto-publish 发布。

## 推荐工作流

长期稳定方案：

```text
ScriptHub 只负责一次性转换
ProxyKit 负责长期静态托管
Egern 只引用 ProxyKit 的 raw 链接
```

不要长期在 Egern 配置里保留大量 `script.hub/file/_start_` 动态链接。
