# Volcano Performance Guard v4

这个项目用两个 Bash 脚本完成 Volcano Candidate 的依赖打包和一键验证：

- `volcano-v4-package.sh`：在外网 CentOS 8 服务器上拉取少量基础/运行镜像和精确版本工具，生成可传输的依赖包。
- `volcano-v4-deploy.sh`：在内网 CentOS 7 服务器上校验并加载镜像和工具，拉取精确 Candidate 源码，构建并运行 E2E、Benchmark 或两者。
- `README.md`：项目用法说明。它不是运行时依赖，也不会被放进生成的依赖包。

项目没有 Python、Go 辅助程序、私有 registry、适配器或额外配置框架。外网使用 `docker pull` 和 `docker save`，内网使用 `docker load`，导入的内容就是普通的本地 Docker 镜像。版本敏感的 Linux 工具以普通文件放在 `tools.tar.gz`，不会安装或覆盖服务器的系统工具。

## 外网与内网的明确职责

外网服务器只做以下事情：

1. 根据命令行选择维护列表中的几个镜像。
2. 用 `docker pull --platform linux/amd64` 下载这些镜像。
3. 用 `docker save` 把这些镜像保存成 `images.tar.gz`。
4. 从精确 Candidate commit 的单个 `go.mod` 读取 Go/Ginkgo 版本；公开 GitHub 仓库直接读取 commit-addressed raw 文件，其他仓库才回退到临时浅 fetch，二者都不进入交付包。
5. 下载并校验 Kind、kubectl、Helm、jq、Go，构建 Candidate 锁定版本的 Ginkgo，保存为 `tools.tar.gz`。
6. 记录所选版本、Candidate commit、镜像 ID 和每个工具的 SHA256，生成最终压缩包。
7. 根据需要把压缩包上传到 GitHub Release，或交给其他文件传输渠道。

外网打包脚本会把分支/tag 解析成精确 commit，并读取该 commit 的 `go.mod`、构建匹配版本的 Ginkgo。公开 GitHub 仓库不需要为此 fetch 整个 commit；非 GitHub/无法读取 raw 文件时才使用临时浅 fetch。临时文件和构建缓存完成后会删除；它不会把 Volcano 源码、E2E/Benchmark 源码、Go module cache 或已经构建好的 Candidate 组件镜像放入依赖包。

内网服务器才做以下事情：

1. 校验依赖包，用 `docker load` 把镜像导入普通的本地 Docker 镜像列表，并把包内工具解压到本次工作目录。
2. 根据 `bundle.meta` 中固定的 40 位 commit，从所选 Volcano 仓库重新拉取 Candidate 源码并核对 `HEAD`。
3. 使用 Candidate 自己的 Dockerfile、Makefile、Helm Chart、E2E 和 Benchmark 代码。
4. 使用外网导入的基础镜像，在本地构建 `vc-scheduler`、`vc-controller-manager`、`vc-webhook-manager` 等 Candidate 组件运行镜像。
5. 把刚构建的 Candidate 组件镜像，以及外网导入的 E2E/Benchmark 运行镜像，一起加载到新建的 Kind 集群并执行验证。

也就是说，传输包负责“少量基础/测试镜像和精确工具”，精确 Candidate 源码与 Candidate 组件运行镜像负责“内网重新拉取和本地组合构建”。整个过程不启动额外 registry，也不会把外网机器上的源码快照混入 Candidate。

## 默认镜像及精确版本

当前脚本内置的默认维护列表如下。`kind-node` 的版本由必填参数 `--k8s-version` 决定，其余项目都是脚本中的明确默认值：

| key | 默认镜像引用 | 使用模式 | 用途 |
| --- | --- | --- | --- |
| `kind-node` | `kindest/node:${K8S_VERSION}` | `e2e`、`benchmark`、`both` | Kind Kubernetes 节点镜像；例如传入 `--k8s-version v1.36.1` 时为 `kindest/node:v1.36.1` |
| `go-builder` | `golang:1.26.2` | 全部模式 | Candidate 组件 Dockerfile 的 Go 构建基础镜像 |
| `runtime-base` | `alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b` | 全部模式 | Candidate 组件运行基础镜像 |
| `e2e-busybox` | `busybox:1.36` | `e2e`、`both` | 基本 E2E 工作负载镜像 |
| `e2e-nginx` | `nginx:1.29.3-alpine` | `e2e`、`both` | 基本 E2E 工作负载镜像 |
| `benchmark-busybox` | `busybox:1.36` | `benchmark`、`both` | Benchmark 工作负载镜像 |
| `kwok` | `registry.k8s.io/kwok/kwok:v0.7.0` | `benchmark`、`both` | Benchmark 的 KWOK 节点模拟镜像 |

因此，默认 `both` 是 7 个逻辑项，但两个 busybox 项指向同一个镜像，实际只保存 6 个唯一镜像。执行 `--list-images` 可以在下载前看到本次选择的最终列表。未来 Candidate 基础镜像或测试依赖变化时，应通过 `--set-image`/`--add-image` 调整，或者直接更新脚本顶部的这份小列表。

## 包内工具及版本规则

以下版本敏感工具会进入 `tools.tar.gz`，内网不再从官方下载站点重新下载：

| 工具 | 版本来源 |
| --- | --- |
| Kind | `--kind-version`，默认 `v0.32.0` |
| kubectl | 跟随必填的 `--k8s-version` |
| Helm | `--helm-version`，默认 `v3.21.4` |
| jq | 脚本锁定 `jq-1.8.2` |
| Go | 从精确 Candidate 的 `go.mod` 读取；缺少 patch 时与精确 `go-builder` 镜像版本对齐 |
| Ginkgo | 从精确 Candidate 的 `go.mod` 读取并在外网构建 |

这些工具只会解压到本次 `--work-dir` 下并临时加入 `PATH`，不会写入 `/usr/bin`，也不会覆盖服务器已经安装的同名程序。Bash、Git、Docker/Buildx、curl、tar、gzip、sha256sum、make 等宿主基础能力不会放进包，部署脚本只检查并复用服务器现有版本。

## 最短使用方式

### 1. 外网服务器：一条命令打包

在项目目录执行：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.36.1 \
  --volcano-ref master \
  --mode both \
  --output ./release
```

脚本会把 `master`、分支或 tag 解析成一个固定的 40 位 Git commit，并把该 commit 写入包内。因此，即使分支后来继续变化，内网仍会检出打包时选定的精确 Candidate。

执行成功后，`release/` 中会出现类似文件：

```text
volcano-v4-1.36.1-5a15213d8ebb-both.tar.gz
volcano-v4-1.36.1-5a15213d8ebb-both.tar.gz.sha256
```

把这两个文件传到内网服务器即可。

### 2. 内网服务器：一条命令验证

```bash
bash volcano-v4-deploy.sh \
  --bundle ./volcano-v4-1.36.1-5a15213d8ebb-both.tar.gz
```

如果旧的 v4.1.0 包在 CentOS 7 上报 `loaded image ID mismatch`，不需要重新传输大包：只把仓库中最新的 `volcano-v4-deploy.sh` 作为包外入口传到同一台服务器，再用上面的 `--bundle` 命令指向原 `.tar.gz`。不要覆盖已解压包内受 `SHA256SUMS` 保护的旧脚本；新版入口会校验并使用原包内容。

也可以直接给出可访问的下载地址：

```bash
bash volcano-v4-deploy.sh \
  --bundle-url 'https://github.com/OWNER/REPOSITORY/releases/download/TAG/volcano-v4-1.36.1-5a15213d8ebb-both.tar.gz'
```

如果已经解压依赖包，可进入包内顶层目录直接运行，不需要再传 `--bundle`：

```bash
bash volcano-v4-deploy.sh
```

脚本成功后会打印结果目录。默认目录名类似 `volcano-v4-results-20260817-070000`，其中包含 Candidate commit、工具版本、构建日志、集群日志、E2E/Benchmark 日志和最终 `summary.txt`。

## 环境要求

只支持 Linux x86_64。

### 外网 CentOS 8

需要：

- Bash 4+
- 可用的 Docker daemon
- `curl`、`git`、`tar`、`gzip`、`sha256sum`、`awk`、`sed`、`sort`、`mktemp`
- 当前用户有 Docker 权限
- 能访问所选镜像仓库、Volcano Git 仓库、Go/module 渠道及各工具官方下载地址
- 如使用自动发布功能，还需要已登录的 GitHub CLI `gh`

打包脚本不会安装系统软件。它会临时读取 Candidate `go.mod` 并使用 Go module 渠道构建精确 Ginkgo，但不会把 Volcano 源码、Go module cache、E2E 源码或 Benchmark 源码放进交付包。

### 内网 CentOS 7

需要：

- Bash 4.2+
- 可用的 Docker daemon
- Docker buildx 插件，并且 `default` builder 的 driver 是 `docker`
- `curl`、`git`、`tar`、`gzip`、`sha256sum`、`awk`、`sed`、`grep`、`sort`、`mktemp`、`make`、`tee`
- 当前用户有 Docker 权限
- 能访问 Volcano Git 仓库和运行 Candidate 所需的 Go module 渠道；不再需要访问 Kind、kubectl、Helm、jq、Go 的官方下载地址
- 足够的磁盘空间用于 Docker 镜像、Candidate 构建、Kind 节点和测试结果

部署脚本会校验并解压包内精确版本的 Kind、kubectl、Helm、jq、Go 和 Candidate 锁定的 Ginkgo，不会联网重新下载这些工具，也不会安装到系统目录，因此不依赖 CentOS 7 自带的旧 Python 或旧 Go。

如果服务器已有可用的代理环境变量，脚本会自动继承 `HTTP_PROXY`、`HTTPS_PROXY` 和 `NO_PROXY`；不需要填写任何占位符。Go 默认使用：

```text
GOPROXY=https://proxy.golang.org,direct
GOSUMDB=sum.golang.org
```

这里的 Go 渠道用于 Candidate 构建/E2E 所需 module，而不是下载 Go 工具本身。只有内网规定了专用 Go 渠道时才需要显式覆盖：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./BUNDLE.tar.gz \
  --goproxy 'https://YOUR_APPROVED_GO_PROXY,direct' \
  --gosumdb 'YOUR_APPROVED_GOSUMDB'
```

## 模式和版本选择

### E2E

只打包并运行基本 E2E：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.36.1 \
  --volcano-ref master \
  --mode e2e \
  --e2e-type SCHEDULINGGATES \
  --output ./release
```

默认 `E2E_TYPE` 是 `SCHEDULINGGATES`。可用值由所选 Candidate 的 `hack/run-e2e-kind.sh` 决定；打包脚本只记录选择，部署脚本调用 Candidate 自己的 E2E 入口，不复制一份项目外 E2E 实现。

### Benchmark

只打包并运行 Benchmark：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.36.1 \
  --volcano-ref master \
  --mode benchmark \
  --benchmark-scenario gang \
  --benchmark-profile benchmark/testcases/gang/cases/comprehensive.yaml \
  --benchmark-rounds 3 \
  --output ./release
```

Benchmark 的场景和 profile 必须存在于所选 Candidate 源码中。部署脚本调用 Candidate 的 `benchmark/scripts/run-tests.sh`，并为每轮保留单独日志和结果目录。

### E2E 和 Benchmark

`--mode both` 会顺序运行两项验证，并为 E2E 和 Benchmark 分别创建一个全新的 Kind 集群，避免前一项测试的状态污染后一项。因而 `both` 不能与 `--keep-cluster` 一起使用。

### Volcano 分支、tag 或 commit

以下三种写法都支持：

```bash
--volcano-ref master
--volcano-ref v1.12.2
--volcano-ref 0123456789abcdef0123456789abcdef01234567
```

分支和 tag 在外网打包时解析为精确 commit；40 位 commit 直接使用。内网会在检出后再次核对 `HEAD`，不匹配就终止。

### 选择 Kind 和 Helm

```bash
--kind-version v0.32.0
--helm-version v3.21.4
```

kubectl 版本自动跟随 `--k8s-version`。Kind 版本与 Kubernetes 节点镜像不是任意组合：所选 `kindest/node:vX.Y.Z` 必须真实存在，并且该 Kind 版本需要支持目标 Kubernetes 版本。生产验证时建议使用 Kind 发布说明给出的节点镜像 digest，通过 `--node-image` 明确指定。

## 镜像列表维护

默认列表故意保持很小，最多只有以下逻辑项：

```text
kind-node
go-builder
runtime-base
e2e-busybox
e2e-nginx
benchmark-busybox
kwok
```

`e2e-busybox` 和 `benchmark-busybox` 默认指向同一个镜像，保存时会去重。因此 `both` 当前是 7 个逻辑项、6 个唯一镜像。

打包前可先查看本次实际选择：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.36.1 \
  --volcano-ref master \
  --mode both \
  --list-images
```

如果 Candidate 的 Dockerfile 改了基础镜像，使用已选模式中的 key 覆盖：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.36.1 \
  --volcano-ref master \
  --mode both \
  --set-image go-builder=golang:1.26.3 \
  --set-image runtime-base=alpine:3.24.2 \
  --output ./release
```

指定节点镜像可使用简写：

```bash
--node-image kindest/node:v1.36.1@sha256:ACTUAL_RELEASE_DIGEST
```

Candidate 新增了 E2E 或 Benchmark 运行镜像时，直接追加：

```bash
--add-image registry.example.com/project/test-helper:v1
```

`--set-image` 只允许替换当前模式已经选中的已知 key，拼错或跨模式使用会立即报错；新条目统一使用 `--add-image`。若长期默认值发生变化，直接修改 `volcano-v4-package.sh` 文件顶部的默认常量和维护列表即可，不需要引入依赖发现框架。

部署阶段会先检查 Candidate 各组件 Dockerfile 中精确的基础镜像是否已由 `docker load` 导入。如果 Candidate 已改变而包内缺少对应镜像，脚本会在构建前停止；回到外网用 `--set-image` 或 `--add-image` 重新打包。

## 依赖包里有什么

生成的 `.tar.gz` 只有一个顶层目录，目录内固定为五个文件：

```text
volcano-v4-deploy.sh
bundle.meta
images.tar.gz
tools.tar.gz
SHA256SUMS
```

- `volcano-v4-deploy.sh`：内网入口脚本。
- `bundle.meta`：精确版本、Candidate commit、模式、镜像引用/ID、工具路径和工具 SHA256。
- `images.tar.gz`：`docker save` 结果的 gzip 压缩文件。
- `tools.tar.gz`：Kind、kubectl、Helm、jq、Go 和 Ginkgo 的 Linux AMD64 文件。
- `SHA256SUMS`：上述四个运行文件的内部完整性校验。

外层还会生成 `BUNDLE.tar.gz.sha256`。部署脚本在校验文件与压缩包相邻时会先校验外层哈希，解压后始终校验内部 `SHA256SUMS`，然后才执行 `docker load`。Docker 的 containerd 镜像存储会把 OCI 索引/manifest-list 摘要显示为镜像 ID，而 CentOS 7 上的较老 Docker 在加载同一归档后可能显示具体镜像的配置摘要；部署脚本会从已校验的 `images.tar.gz` 中取得配置摘要并接受这两种等价身份，同时仍要求镜像标签存在且实际解析为 `linux/amd64`。

依赖包不包含：

- Volcano 源码或 Git 仓库快照
- E2E/Benchmark 源码副本
- Go module cache
- 已构建的 Volcano Candidate 组件镜像
- Python、项目自定义 Go 辅助程序或额外 registry

这些内容由内网部署脚本根据包内精确 commit 和 Candidate 自身文件在线获取或构建。

## GitHub Release 和替代传输

已安装并登录 `gh` 时，可在打包命令后增加：

```bash
--publish OWNER/REPOSITORY \
--release-tag v4-test-20260817
```

如果 Release 不存在，脚本会创建；存在时会覆盖同名 asset。`OWNER/REPOSITORY` 应替换成最终用于 v4 的仓库，不要误用其他项目的远端。

如果外网服务器不能用命令直接上传 GitHub Release，有三种简单替代方式：

1. 用 `scp`、SFTP 或受控文件交换把 `.tar.gz` 和 `.sha256` 传到能访问 GitHub 的电脑，再在浏览器的 Release 页面上传。
2. 在另一台已登录 `gh` 的机器执行：

   ```bash
   gh release upload TAG BUNDLE.tar.gz BUNDLE.tar.gz.sha256 \
     --repo OWNER/REPOSITORY --clobber
   ```

3. 如果内外网之间已有批准的文件传输渠道，可以不经过 GitHub Release，直接把两个文件送到内网；部署命令使用本地 `--bundle` 路径即可。

大文件可按 GitHub asset 限制拆分：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.36.1 \
  --volcano-ref master \
  --mode both \
  --output ./release \
  --split-size 1900m
```

这会生成连续的 `.part-000`、`.part-001` 等文件和 `.parts.sha256`。把所有 part 与校验文件放在同一目录，内网将 `--bundle` 指向 `.part-000`，部署脚本会校验并自动重组。

## 常用内网选项

指定结果目录：

```bash
--output ./results/run-001
```

保留下载、源码和构建缓存，便于复查或后续增量运行：

```bash
--work-dir /data/volcano-v4-work/run-001
```

`--work-dir` 要求目标目录尚不存在。若只想保留脚本自动创建的临时目录，使用 `--keep-work-dir`。

默认成功或失败后会删除本次创建的项目 Kind 集群。只运行 `e2e` 或 `benchmark` 时可以增加 `--keep-cluster` 供人工检查。已有同名集群不会被接管或删除；请用 `--cluster-prefix` 换一个项目专用前缀。

从一个 `both` 包中只运行一项也可以：

```bash
bash volcano-v4-deploy.sh --bundle ./BUNDLE.tar.gz --mode e2e
```

但 `e2e` 包不能在内网扩展成 `benchmark`，`benchmark` 包也不能扩展成 `e2e`，因为缺少对应运行镜像。

## 支持边界

这个实现支持显式选择 Kubernetes 版本、Volcano 分支/tag/commit、E2E/Benchmark 模式及 Candidate 内存在的测试配置，但不会假设一个固定镜像列表能自动覆盖所有未来版本和全部历史版本。

版本发生依赖变化时，应当：

1. 用 `--list-images` 查看本次默认选择。
2. 检查该 Candidate 的组件 Dockerfile、目标 E2E 和 Benchmark profile。
3. 用 `--set-image` 更新已知基础镜像，或用 `--add-image` 补充新增运行镜像。
4. 在外网重新生成包，再到内网执行一键部署。

默认基本 E2E 并不等于自动运行 Candidate 的每一个 E2E suite；默认 Benchmark 也不等于自动遍历 Candidate 的每一个 profile。完整覆盖哪些 suite/profile，应通过 Candidate 自身支持的 `--e2e-type`、`--benchmark-scenario` 和 `--benchmark-profile` 明确选择，并为它们补齐所需镜像。

## 验收建议

先做一次 `e2e` 小包验证，再做 `both`：

1. 外网 CentOS 8 完成实际镜像拉取、打包及 SHA256 校验。
2. 内网 CentOS 7 确认包能下载或传入，且内部校验通过。
3. 确认所有镜像出现在普通 `docker image ls` 中，没有额外 registry。
4. 确认 Candidate `HEAD` 等于 `summary.txt` 中的 `volcano_commit`。
5. 确认 Candidate 组件构建、Helm 安装和基本 E2E 成功。
6. 使用 `both` 时确认 E2E 与 Benchmark 使用两个不同的新集群，最终都被清理。
7. 保存结果目录以及外层 `.sha256`，作为本次版本验证证据。

在真正的 CentOS 8/7 服务器上完成上述流程后，才能把对应 Kubernetes/Volcano/测试组合标记为已通过；本地脚本语法、静态检查和小镜像打包测试不能替代服务器上的完整 E2E 与 Benchmark。
