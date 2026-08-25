# Volcano Performance Guard v4

本项目在外网制作一次通用依赖包，在内网反复选择不同的 Volcano tag、branch 或 commit，构建并运行 Candidate 自带的 E2E 和 Benchmark。

关键边界：

- 外网包与 Volcano 版本完全解耦，不拉取 Volcano 源码，不解析 Volcano ref，也不包含 Go modules；
- 内网首次通过 `--volcano-ref` 选择 Candidate，并通过已批准的公司 Go Proxy 下载该 Candidate 的完整 Go module graph；保存工作目录后可校验并复用该缓存；
- 只要 Kubernetes/Kind、Go toolchain、基础镜像、测试运行镜像和固定资源没有新增或变化，同一个外网包可以一直复用；
- 修改 Volcano 源码或 `go.mod/go.sum` 但没有增加上述非模块依赖时，不需要重新打外网包；
- 项目只维护两个 Bash 脚本和两个 TSV 配置文件，不依赖 Python，也不复制 Volcano 测试代码。

```text
volcano-v4-package.sh       外网：生成通用依赖包
volcano-v4-deploy.sh        内网：选择 Candidate、下载 Go modules、构建并测试
config/versions.tsv         Kubernetes、Kind、节点镜像和通用工具版本
config/profiles.tsv         Profile、基础/运行镜像、资源和 FULL 集合
README.md                   使用说明
```

## 最短使用方式

下面只使用一个 Kubernetes `v1.34.8` 的 `full` 通用包。它覆盖完整 E2E、Gang/Pod/网络拓扑 Benchmark 和 Monitoring；`full` 包含 DRA，因此这里使用 Kubernetes `v1.34+`。

### 1. 外网制作完整包

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --profile full --output ./release-assets --split-size 1900M
```

外网包不包含 Volcano 源码，也没有 `--volcano-ref`。向内网传输最新的 `volcano-v4-deploy.sh`，以及以下同一组、不得改名的文件：

```text
volcano-v4-1.34.8-full.tar.gz.part-000
volcano-v4-1.34.8-full.tar.gz.part-001
volcano-v4-1.34.8-full.tar.gz.part-002
volcano-v4-1.34.8-full.tar.gz.parts.sha256
```

部署时把 `.part-000` 交给 `--bundle`；脚本会校验全部分卷并自动重组。以后只更新部署逻辑时，只替换 `volcano-v4-deploy.sh`，不需要重新制作或传输 full 包。

### 2. 内网验证各个场景

一次运行全部独立 E2E 和全部 Benchmark：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode both --work-dir ./work/v1.15.0-full --output ./results/v1.15.0-full
```

只运行全部独立 E2E：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode e2e --work-dir ./work/v1.15.0-e2e-full --output ./results/v1.15.0-e2e-full
```

只运行一个 E2E TYPE；把 `SCHEDULINGBASE` 换成“Profile 选择”列出的其他 TYPE 即可：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode e2e --e2e-type SCHEDULINGBASE --work-dir ./work/v1.15.0-e2e-schedulingbase --output ./results/v1.15.0-e2e-schedulingbase
```

只运行全部 Benchmark（Gang comprehensive、Gang net-topo 和 Pod）：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode benchmark --work-dir ./work/v1.15.0-benchmark-full --output ./results/v1.15.0-benchmark-full
```

只运行基础 Gang Benchmark：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode benchmark --benchmark-scenario gang --work-dir ./work/v1.15.0-benchmark-gang --output ./results/v1.15.0-benchmark-gang
```

只运行 Pod Benchmark：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode benchmark --benchmark-scenario pod --work-dir ./work/v1.15.0-benchmark-pod --output ./results/v1.15.0-benchmark-pod
```

只运行网络拓扑 Gang Benchmark：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode benchmark --benchmark-scenario gang --benchmark-config benchmark/testcases/gang/cases/net-topo.yaml --work-dir ./work/v1.15.0-benchmark-net-topo --output ./results/v1.15.0-benchmark-net-topo
```

一次只验证一个 E2E TYPE 和一个 Benchmark 场景：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode both --e2e-type SCHEDULINGBASE --benchmark-scenario gang --work-dir ./work/v1.15.0-basic --output ./results/v1.15.0-basic
```

### 3. 更换 Candidate Volcano

同一个 full 包可以反复测试 tag、branch 或 40 位 commit。只修改 `--volcano-ref`，并为新 Candidate 使用新的工作目录和结果目录。例如从 `v1.15.0` 切换到 `release-1.15`：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref release-1.15 --mode e2e --e2e-type SCHEDULINGBASE --work-dir ./work/release-1.15-e2e-schedulingbase --output ./results/release-1.15-e2e-schedulingbase
```

指定精确 commit：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref 8fc394c11e8db0d0ada5c17816b58bced9d7213d --mode benchmark --benchmark-scenario gang --work-dir ./work/8fc394c1-benchmark-gang --output ./results/8fc394c1-benchmark-gang
```

使用内部 Git 镜像时，在上述命令中增加 `--volcano-repo https://内部Git服务/volcano.git`。

## 调试方法

结果目录包含准确 Candidate commit、工具/Go 环境、Bundle 和 Docker load 日志、Candidate build 日志、`candidate-e2e-contracts.txt`、环境补丁、E2E artifacts 或 Benchmark results，以及最终 `summary.txt`。`candidate-e2e-contracts.txt` 会列出每轮的上游 Make 目标、Make 参数、非镜像前置目标和最终注入的环境变量。

保留临时 checkout、Go cache 和构建现场，以便失败后恢复：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --volcano-ref v1.15.0 --output ./results --keep-work-dir
```

失败日志最后会显示准确工作目录，例如：

```text
[vpg4-deploy] kept work directory: /tmp/volcano-v4-deploy.ABC123
```

使用同一个 Candidate 和运行选择恢复时，把这个已保存目录交给 `--work-dir`。Bundle 和结果目录会从恢复状态中读取，不必重复填写：

```bash
bash volcano-v4-deploy.sh --work-dir /tmp/volcano-v4-deploy.ABC123 --volcano-ref v1.15.0
```

恢复会复用已经完成并验证过的 Candidate checkout、Go module cache、Ginkgo 和 Candidate 镜像构建；完整 E2E/Benchmark 中已经成功的独立 E2E 类型和 Benchmark round 会跳过。Bundle、Candidate、profile/mode、测试选择、轮数或集群前缀只要有一项不同，脚本就拒绝混用该工作目录。显式指定过 `--mode`、`--e2e-type`、`--benchmark-scenario`、`--benchmark-config`、`--benchmark-rounds`、`--pods`、`--scheduler-name` 或 `--cluster-prefix` 时，恢复命令必须重复相同参数。

Candidate 身份以仓库地址和精确 commit 为准。`go mod download all` 可能补写 `go.sum`，离线构建适配也会修改 Dockerfile；这些未提交的工作树变化不会阻断后续构建，脚本会把构建补丁前的状态保存到结果目录供追溯。

保留 Kind 集群时，脚本会自动同时保留工作目录：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --volcano-ref v1.15.0 --output ./results --keep-cluster
```

恢复这个集群时同时给出保存目录和 `--keep-cluster`：

```bash
bash volcano-v4-deploy.sh --work-dir /tmp/volcano-v4-deploy.ABC123 --volcano-ref v1.15.0 --keep-cluster
```

脚本会核对本地 run identity、集群内 `vpg4-resume-state` ConfigMap、Kubernetes 版本、Candidate commit 和 Helm release 后才复用集群。E2E 会在原集群中从所选 E2E 类型的开头重新运行，不能从单个 Ginkgo spec 中间继续；Benchmark 会清理未完成工作负载，并从第一个没有成功标记的 round 继续。保存集群不会重新安装 Volcano，因此首次切换到包含新 E2E 契约解析的部署脚本时，应新建一次集群；保存工作目录、Go cache 和 Candidate 镜像仍可继续复用。

`--keep-cluster` 仍只允许一次执行中恰好有一个 E2E 类型或一个 Benchmark 场景；`FULL` 等多运行选择应使用 `--keep-work-dir` 恢复，脚本会跳过已经成功的运行，但不会同时保留多个集群。

只有新脚本创建且包含 `.vpg4-state/run.env` 的工作目录可以恢复；此前旧版本仅由 `--keep-work-dir` 留下的诊断目录没有阶段身份，仍需新开一次运行。

默认会删除本次脚本创建的临时目录和 Kind 集群，不会清理整机 Docker 数据。


## 外网打包脚本说明

`volcano-v4-package.sh` 只在能够访问公共下载地址和镜像仓库的 Linux x86_64 外网机器运行。它下载并校验通用工具、基础镜像、测试镜像和固定资源，但不会接收 Volcano ref，也不会拉取 Volcano 源码、Go modules 或构建最终 Candidate 镜像。

### 基本语法和必选参数

```bash
bash volcano-v4-package.sh --k8s-version vX.Y.Z --profile PROFILE --output DIR
```

| 参数                   | 含义                                                        |
| ---------------------- | ----------------------------------------------------------- |
| `--k8s-version vX.Y.Z` | Kind 集群使用的精确 Kubernetes 版本，必须包含 patch 版本    |
| `--profile PROFILE`    | 从 `config/profiles.tsv` 选择要打进包里的测试能力和依赖集合 |
| `--output DIR`         | 外网产物目录；目录可以存在，但同名目标包不能已经存在        |

推荐的完整包命令是：

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --profile full --output ./release-assets --split-size 1900M
```

打包命令没有也不接受 `--volcano-ref`。Candidate 的 tag、branch 或 commit 只在内网交给 `volcano-v4-deploy.sh`；只要包内 Kubernetes/Kind、工具、基础镜像、测试运行镜像和固定资源仍覆盖新的 Candidate，同一个外网包就可以一直复用。

### 外网打包机要求

外网打包机需要 Bash、curl、Docker、tar、gzip、sha256sum、awk、sed、grep、sort 和 mktemp；使用 `--split-size` 时还需要 split，使用 `--publish` 时还需要已经登录目标仓库的 GitHub CLI `gh`。外网不需要 Git、Volcano 源码、Python 或本机 Go。

Docker daemon 必须能够拉取 Profile 选择的全部 `linux/amd64` 镜像，主机还要能够访问 Kind、Kubernetes、Helm、jq、Go 和 KWOK 的官方下载地址。打包脚本会校验下载文件的 SHA256、镜像平台和镜像身份。

临时 staging 固定创建在 `/tmp/volcano-v4-package.*`，因此 `/tmp` 所在文件系统必须能容纳解出的工具和压缩后的 `images.tar.gz`。`--output` 所在文件系统必须能容纳最终包；使用分卷时完整 `.tar.gz` 不会被删除，输出目录还会再保存一份等量分卷，因此应预留约两倍最终包大小。

### Profile 决定包内能力和依赖

查看全部 Profile，不下载工具或镜像：

```bash
bash volcano-v4-package.sh --list-profiles
```

当前可用 Profile 以 `--list-profiles` 的实际输出为准；常用选择如下：

| Profile           | 默认运行            | 外网包用途                                                 |
| ----------------- | ------------------- | ---------------------------------------------------------- |
| `e2e-basic`       | `SCHEDULINGBASE`    | 最小 E2E 包，适合第一次验证                                |
| `e2e:<TYPE>`      | 指定 TYPE           | 只包含 `--list-profiles` 已列出的对应 E2E 分支所需通用依赖 |
| `e2e:ALL`         | 上游 `E2E_TYPE=ALL` | 保留 Candidate 上游一次运行 ALL 的语义                     |
| `e2e-full`        | `FULL`              | 包含全部已维护独立 E2E 的依赖和能力元数据                  |
| `benchmark-basic` | gang                | 基础 Gang Benchmark，不含 Monitoring                       |
| `benchmark:gang`  | gang                | Gang Benchmark                                             |
| `benchmark:pod`   | pod                 | Pod Benchmark                                              |
| `benchmark-full`  | `FULL`              | Gang、Pod、网络拓扑和 Monitoring                           |
| `full`            | `FULL`              | 完整 E2E 与完整 Benchmark，推荐长期复用                    |

`e2e-full` 和 `full` 当前维护的独立 E2E TYPE 是：

```text
JOBP JOBSEQ SCHEDULINGBASE SCHEDULINGACTION SCHEDULINGGATES VCCTL STRESS DRA
ADMISSION_POLICY ADMISSION_WEBHOOK HYPERNODE CRONJOB
AGENTSCHEDULER_NONE AGENTSCHEDULER_SOFT AGENTSCHEDULER_HARD
SHARDINGCONTROLLER GANGEVICT
SCHEDULERSHARDING_NONE SCHEDULERSHARDING_SOFT SCHEDULERSHARDING_HARD
```

`FULL` 是写入 `bundle.meta` 的多次运行集合，不等于上游一次 `E2E_TYPE=ALL`。修改 `config/profiles.tsv` 中的 `E2E_FULL`、`BENCHMARK_FULL` 或 Profile 依赖组后，必须重新制作对应包，旧包不会自动获得新的能力元数据或镜像。

由于 `full` 包包含 DRA，给 Volcano v1.15.x 使用时选择 Kubernetes `v1.34+`；Kubernetes `v1.32-v1.33` 只适合不启用 DRA 的较小 Profile。

### 下载前预览包内容

查看 `full` 包将选择的 Kubernetes、Kind、Go 和全部镜像引用，不执行下载：

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --profile full --list-images
```

`--list-images` 会应用当前 TSV 配置和命令行镜像覆盖，因此适合在正式打包前审计最终依赖清单。它不要求 `--output`，也不要求 Docker daemon 正在运行。

### 覆盖版本、镜像和配置

| 参数                                        | 使用场景                                                                     |
| ------------------------------------------- | ---------------------------------------------------------------------------- |
| `--config-dir DIR`                          | 使用另一套同时包含 `versions.tsv` 和 `profiles.tsv` 的配置目录               |
| `--kind-version VERSION --node-image IMAGE` | 使用 `config/versions.tsv` 尚未维护的 Kubernetes/Kind 组合；两项必须一起指定 |
| `--helm-version VERSION`                    | 临时覆盖 `versions.tsv` 中的 Helm 版本                                       |
| `--go-version goX.Y.Z --go-sha256 SHA256`   | 临时覆盖内网宿主 Go toolchain；版本与官方压缩包 SHA256 必须一起指定          |
| `--set-image KEY=IMAGE`                     | 从外网可访问的镜像或镜像代理拉取某个已选 Key，但仍按配置中的内网引用保存     |
| `--add-image IMAGE`                         | 向本次包临时增加一个配置中没有的精确基础镜像或测试运行镜像                   |

未列出的 Kubernetes 版本必须使用准确且最好带 digest 的节点镜像，例如：

```bash
bash volcano-v4-package.sh --k8s-version v1.30.0 --profile e2e-basic --kind-version v0.29.0 --node-image kindest/node:v1.30.0@sha256:准确摘要 --output ./release-assets
```

Candidate 要求新的宿主 Go toolchain 和新的 Docker builder 基础镜像时，两者要分别指定：

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --profile full --go-version goX.Y.Z --go-sha256 官方linux-amd64压缩包SHA256 --add-image golang:X.Y.Z --output ./release-assets --split-size 1900M
```

外网只能从镜像代理访问 KWOK 时，覆盖拉取来源但保留内网需要的原始标签：

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --profile full --set-image kwok=registry.example.com/kwok:v0.7.0 --output ./release-assets --split-size 1900M
```

`--set-image` 的 Key 必须已经被当前 Profile 选中。`--add-image` 用于临时补充依赖，不会永久修改 TSV；需要长期支持时应更新 `config/profiles.tsv`。jq、KWOK 等没有独立命令行覆盖项的默认值通过 `config/versions.tsv` 或 `--config-dir` 维护。

### 包的准确内容和边界

每个外网包的顶层目录只包含：

```text
bundle.meta
images.tar.gz
tools.tar.gz
resources.tar.gz
SHA256SUMS
```

- `bundle.meta`：Kubernetes/Profile、工具、镜像、资源及 E2E/Benchmark 能力元数据；
- `images.tar.gz`：选中 Profile 的 `linux/amd64` 基础镜像和测试运行镜像；
- `tools.tar.gz`：Kind、kubectl、Helm、jq 和完整 Go toolchain；
- `resources.tar.gz`：KWOK manifest、stage 等固定小资源；
- `SHA256SUMS`：上述四个内容文件的 SHA256。

外网包明确不包含 Volcano 源码、Go module cache、Ginkgo、最终 Candidate 组件镜像、`volcano-v4-deploy.sh` 或测试结果。部署脚本独立传输，因此修复内网部署逻辑通常只需要替换脚本，不需要重新传输大包。

### 输出、校验、分卷和 Release

不分卷时会生成完整包和外层校验文件：

```text
volcano-v4-K8S-PROFILE.tar.gz
volcano-v4-K8S-PROFILE.tar.gz.sha256
```

当前依赖集合制作出的完整 `full` 包会超过 [GitHub Release 单个 asset 必须小于 2 GiB 的限制](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)，因此推荐 `--split-size 1900M`。分卷时仍会在外网本地保留完整 `.tar.gz`，并额外生成 `.part-NNN` 和 `.parts.sha256`；内网只需要全部分卷及分卷校验清单。

打包机已经安装并登录 `gh` 时，可以在打包后创建或更新 Release；同名 asset 会被覆盖：

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --profile full --output ./release-assets --split-size 1900M --publish siqiaawa/volcano-performance-guard-v4 --release-tag v4.0
```

使用 `--split-size` 和 `--publish` 时，脚本上传分卷与 `.parts.sha256`，不会上传超过限制的完整 `.tar.gz`。不能从打包机访问 GitHub 时，使用 SCP、SFTP、对象存储或其他文件中转方式，把这些产物交给能够上传 Release 的电脑即可。

打包临时目录默认在 `/tmp/volcano-v4-package.*`，成功或失败后自动清理。排查下载、镜像保存或归档问题时增加 `--keep-work-dir`，日志会显示保留下来的准确目录；它只保留 staging，不改变最终输出目录。

### 什么时候必须重新制作外网包

| 变化                                                | 是否重打包 | 原因                                      |
| --------------------------------------------------- | ---------- | ----------------------------------------- |
| 切换 Volcano tag、branch 或 commit                  | 否         | Candidate 在内网选择                      |
| 修改普通 Volcano 源码                               | 否         | 源码在内网拉取和构建                      |
| `go.mod/go.sum` 增删 Go modules                     | 否         | Go modules 在内网从批准的 Go Proxy 下载   |
| Ginkgo 版本变化                                     | 否         | 内网按 Candidate `go.mod` 安装            |
| 只修改 `volcano-v4-deploy.sh`                       | 否         | 部署脚本不在外网包内                      |
| 修改 `E2E_FULL`、`BENCHMARK_FULL` 或 Profile 依赖组 | 是         | 能力元数据和依赖集合写在 `bundle.meta` 中 |
| Kubernetes、Kind、节点镜像或通用工具变化            | 是         | 它们属于包内容                            |
| Candidate Dockerfile 新增基础镜像                   | 是         | 内网构建不能自动拉取公共镜像              |
| E2E/Benchmark 新增运行镜像或固定资源                | 是         | 必须预装进内网 Docker                     |
| Candidate 要求比包内更新的 Go toolchain             | 是         | 宿主 Go toolchain 属于 `tools.tar.gz`     |

打包脚本遇到未知 Profile、未配置的 Kubernetes/Kind 组合、缺失镜像 Key、错误平台或校验不一致时会直接停止，不会静默改用其他版本。

### Kubernetes 与工具版本

`config/versions.tsv` 当前维护的 Kubernetes/Kind 组合：

| Kind      | Kubernetes                                              |
| --------- | ------------------------------------------------------- |
| `v0.32.0` | `v1.36.1`、`v1.35.5`、`v1.34.8`、`v1.33.12`             |
| `v0.31.0` | `v1.35.0`、`v1.34.3`、`v1.33.7`、`v1.32.11`、`v1.31.14` |
| `v0.30.0` | `v1.34.0`、`v1.33.4`、`v1.32.8`、`v1.31.12`             |
| `v0.29.0` | `v1.33.1`、`v1.32.5`、`v1.31.9`、`v1.30.13`             |

未列出的 Kubernetes 版本必须同时提供准确 Kind 版本和最好带 digest 的节点镜像，使用前文的 `--kind-version` 与 `--node-image` 配对覆盖。

默认通用工具：

| 工具         | 默认版本/来源                          |
| ------------ | -------------------------------------- |
| Kind         | 随 Kubernetes 组合                     |
| kubectl      | 与 Kubernetes 相同                     |
| Helm         | `v3.21.4`                              |
| jq           | `jq-1.8.2`，校验 SHA256                |
| KWOK         | `v0.7.0`                               |
| Go toolchain | `go1.25.0`                             |
| Ginkgo       | 不打包；内网按 Candidate `go.mod` 安装 |

包内 `go1.25.0` 可以运行最低 Go 版本不高于它的 Candidate，并保留 Candidate Dockerfile 自己选择的准确 Go builder。若 Candidate 将最低 Go toolchain 提高到更新版本，重新制作通用包时同时使用前文的 `--go-version`、`--go-sha256` 和 `--add-image golang:X.Y.Z`。

Go toolchain 压缩包和 Candidate Dockerfile 的 `golang:` 基础镜像是两个独立依赖。默认宿主工具链是 `go1.25.0`；构建基础镜像同时维护 `golang:1.23.7`、`golang:1.24.0` 和 `golang:1.25.0`，对应稳定 Volcano `v1.12.x` 到 `v1.15.x`。未来 Candidate 使用其他 builder 时仍需更新 `profiles.tsv` 或使用 `--add-image`。

### 默认基础镜像和运行镜像

每个 Profile 都会包含以下 Candidate 通用构建基础镜像：

| Key                        | 镜像            |
| -------------------------- | --------------- |
| `candidate-builder-go1-23` | `golang:1.23.7` |
| `candidate-builder-go1-24` | `golang:1.24.0` |
| `candidate-builder`        | `golang:1.25.0` |
| `candidate-runtime`        | `alpine:latest` |

Profile 按需选择的默认镜像：

| 分组           | Key                    | 外网拉取引用                                            | 内网使用引用         |
| -------------- | ---------------------- | ------------------------------------------------------- | -------------------- |
| E2E            | `busybox-default`      | `busybox:1.36`                                          | `busybox:latest`     |
| E2E            | `busybox-1-24`         | `busybox:1.36`                                          | `busybox:1.24`       |
| E2E            | `nginx-default`        | `nginx:1.29.3-alpine`                                   | 同名                 |
| E2E            | `nginx-latest`         | `nginx:1.29.3-alpine`                                   | `nginx:latest`       |
| Kubernetes E2E | `k8s-e2e-agnhost-2-53` | `registry.k8s.io/e2e-test-images/agnhost:2.53`          | 同名                 |
| Kubernetes E2E | `k8s-e2e-agnhost-2-56` | `registry.k8s.io/e2e-test-images/agnhost:2.56`          | 同名                 |
| Kubernetes E2E | `k8s-e2e-agnhost-2-59` | `registry.k8s.io/e2e-test-images/agnhost:2.59`          | 同名                 |
| Kubernetes E2E | `k8s-e2e-busybox-1-36` | `registry.k8s.io/e2e-test-images/busybox:1.36.1-1`      | 同名                 |
| Kubernetes E2E | `k8s-e2e-busybox-1-37` | `registry.k8s.io/e2e-test-images/busybox:1.37.0-1`      | 同名                 |
| E2E            | `k8s-e2e-nginx`        | `registry.k8s.io/e2e-test-images/nginx:1.14-4`          | 同名                 |
| E2E/Benchmark  | `kwok`                 | `registry.k8s.io/kwok/kwok:v0.7.0`                      | 同名                 |
| JobSeq         | `mpi`                  | `volcanosh/example-mpi:0.0.3`                           | 同名                 |
| JobSeq         | `tensorflow`           | `volcanosh/dist-mnist-tf-example:0.0.1`                 | 同名                 |
| JobSeq         | `pytorch`              | `volcanosh/pytorch-mnist-v1beta1-9ee8fda-example:0.0.1` | 同名                 |
| JobSeq         | `ray-bitnami`          | `rayproject/ray:2.49.0`                                 | `bitnami/ray:2.49.0` |
| JobSeq         | `ray`                  | `rayproject/ray:2.49.0`                                 | 同名                 |
| DRA            | `dra-hostpath-1-7`     | `registry.k8s.io/sig-storage/hostpathplugin:v1.7.3`     | 同名                 |
| DRA            | `dra-hostpath`         | `registry.k8s.io/sig-storage/hostpathplugin:v1.16.1`    | 同名                 |
| Benchmark      | `benchmark-busybox`    | `busybox:1.36`                                          | 同名                 |
| Monitoring     | `prometheus`           | `prom/prometheus:latest`                                | 同名                 |
| Monitoring     | `grafana`              | `grafana/grafana:latest`                                | 同名                 |
| Monitoring     | `kube-state-metrics`   | `docker.io/volcanosh/kube-state-metrics:v2.0.0-beta`    | 同名                 |

打包脚本会在外网宿主机下载并逐项校验 TensorFlow 所需的 MNIST 和 PyTorch 所需的 FashionMNIST，再把数据交给完全禁网的临时容器转换、固化并验证。下载因此使用打包命令所在宿主机的代理，不要求 Docker 容器能够连接宿主代理。内网脚本会在创建 Kind 集群前重复该禁网检查；JOBSEQ 的 Ray 用例保留已装入节点的离线镜像，不执行上游测试中的 containerd image prune；Candidate E2E 中无 tag 的 `busybox`/`nginx` 也会在临时 checkout 内固定为包中已有的非 `latest` tag，避免 Kubernetes 默认重新拉取。因此完整 E2E 不会在 Pod 启动后继续下载这两套训练数据、删除刚装入的 Ray 镜像，或因隐式 `latest` 再访问镜像仓库。

`busybox:1.24` 使用旧 schema 1，Docker 29/containerd 2.1 会拒绝拉取。因此脚本保存现代 `busybox:1.36`，同时创建 Candidate 仍引用的 `busybox:1.24` 本地标签。

Volcano `v1.13.0` 引用的 `bitnami/ray:2.49.0` 已无法从公共仓库取得，`v1.13.1` 起上游改为 `rayproject/ray:2.49.0`。打包脚本因此只下载仍可用的 upstream Ray 镜像，并额外保存旧本地标签；两个条目共享同一组镜像 layer。

Kubernetes E2E 镜像不是 Volcano 源码中的普通字符串，而是由 Candidate 的 `k8s.io/kubernetes` 模块选择。部署脚本会从已下载模块的 `test/utils/image/manifest.go` 和 DRA manifest 中解析准确引用，写入 `candidate-e2e-images.txt`，并在创建 Kind 前验证包内镜像。当前审计结果如下：

| Volcano 稳定线 | Kubernetes 测试模块 | agnhost | E2E busybox | DRA hostpathplugin |
| -------------- | ------------------- | ------- | ----------- | ------------------ |
| `v1.12.x`      | `v1.32.2`           | `2.53`  | `1.36.1-1`  | `v1.7.3`           |
| `v1.13.x`      | `v1.33.2`           | `2.53`  | `1.36.1-1`  | `v1.7.3`           |
| `v1.14.x`      | `v1.34.1`           | `2.56`  | `1.37.0-1`  | `v1.7.3`           |
| `v1.15.x`      | `v1.35.3`           | `2.59`  | `1.37.0-1`  | `v1.16.1`          |

完整 `e2e-full`/`full` 会包含上述全部版本变体、JobSeq 和 DRA 镜像。`benchmark-full` 的 Candidate `v1.15.x` 路径使用 `busybox:1.36`、KWOK、Prometheus、Grafana、kube-state-metrics，以及在内网从 Candidate 源码构建的 audit-exporter；这些镜像均已列入相应分组。Volcano `v1.12.x-v1.14.x` 的旧 Benchmark 目录结构与当前 `benchmark/testcases` 入口不同，不应仅凭镜像清单宣称可由当前 Benchmark runner 执行。

## 内网部署脚本说明

### E2E 参数自动跟随 Candidate

部署脚本不会把 `FEATURE_GATES`、`IGNORED_PROVISIONERS` 等参数按 Volcano 版本硬编码。Candidate checkout 完成后，脚本对每个选中的 TYPE 查找对应的上游 Make 目标，用 `make -n` 取得该目标实际调用 `hack/run-e2e-kind.sh` 时的环境赋值，并在创建 Kind 前写入 `candidate-e2e-contracts.txt`。

例如同一个脚本会自动得到：

```text
v1.12.0 SCHEDULINGBASE -> E2E_TYPE=SCHEDULINGBASE
v1.15.0 SCHEDULINGBASE -> E2E_TYPE=SCHEDULINGBASE, IGNORED_PROVISIONERS=kubernetes.io/no-provisioner
v1.14.0 DRA            -> FEATURE_GATES=DynamicResourceAllocation=true
v1.15.0 DRA            -> FEATURE_GATES=DynamicResourceAllocation=true,DRAConsumableCapacity=true
v1.15.0 VCCTL          -> 先构建上游 vcctl 前置目标
```

每个独立 E2E 开始前都会先清空上一轮解析出的测试变量，再加载本轮契约，因此 DRA 或 SchedulingGates 的 Feature Gate 不会泄漏到后续测试。对于较早的 Candidate，`FULL` 中该版本尚未定义的独立 Make 目标会在预检阶段记录并跳过；显式选择一个 Candidate 不存在的 TYPE 则会直接报错。

普通参数变化、参数新增或前置目标变化不要求重新制作外网包；只有上游改掉 Make 目标或 `hack/run-e2e-kind.sh` 的入口结构时，部署脚本才会在预检阶段 fail-closed，并需要增加小型兼容适配。`e2e:ALL` 保留 Candidate 自己的一次性 `E2E_TYPE=ALL` 语义，`FULL` 则逐个调用当前 Candidate 已定义的独立上游目标。

### Kubernetes v1.32-v1.33 注意事项

Volcano v1.15.0 的 Kind 配置包含 Kubernetes v1.34 才提供的 `DRAConsumableCapacity` 和 MutatingAdmissionPolicy beta API。对 v1.32-v1.33 的非 DRA E2E，部署脚本会在临时 checkout 中做最小兼容调整并把 diff 保存为 `candidate-environment.patch`。DRA 判断来自当前 Candidate 的 Make 契约和 Kind 配置，不再假定所有 Volcano 版本都使用 v1.15.0 的 Feature Gate。

当当前 Candidate 实际启用了 `DRAConsumableCapacity` 时，以下选择不会被降级模拟，而会直接拒绝，必须改用 Kubernetes v1.34+：

- `--e2e-type DRA`；
- 上游 `ALL`；
- 包含 DRA 独立目标的 `e2e-full` 或 `full`。

### 内网服务器和网络要求

内网执行机需要 Linux x86_64、Bash、curl、git、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp、make 和 tee；能够访问 Volcano Git 仓库和公司 Go Proxy。无需预装 Python、Kind、kubectl、Helm、jq、Go 或 Ginkgo。

终端已经 `export HTTP_PROXY/HTTPS_PROXY` 时，脚本会传入 Candidate 的 Docker build。没有这些环境变量时，脚本会读取对 GitHub 生效的 Git `http.proxy`。

Go 模块的 HTTPS 下载只发生在内网宿主机。部署脚本拉取 Candidate 后先使用包内 Go toolchain 和相同的 `GOPROXY/GONOSUMDB/GOSUMDB` 执行 `go mod download all`，再把 `$GOMODCACHE/cache/download` 转成临时标准 Go file proxy。Candidate Dockerfile 中的 `go mod download` 会被临时改为：

```bash
GOPROXY=file:///tmp/vpg4-goproxy GONOSUMDB='*' GOSUMDB=off go mod download
```

因此 Docker builder 不再访问公司 HTTPS Go Proxy，也不需要继承宿主机的公司 CA。宿主预下载日志保存在 `go-mod-download.log`，临时 file proxy 的校验值保存在 `inner-go-modules.sha256`；临时归档默认随工作目录清理，不进入外网包和最终 Candidate 镜像。

Webhook 离线运行时使用包内已有的 Go builder 基础镜像代替会执行 `apk add` 和下载 kubectl 的 Alpine 阶段；脚本会显式把最终阶段的 `WORKDIR` 设为 `/`，保证 Helm admission-init 的 `./gen-admission-secret.sh` 与上游运行方式一致。

## 维护配置

- 新 Kubernetes/Kind/节点镜像组合：修改 `config/versions.tsv`；
- 默认 Helm、jq、KWOK 或 Go toolchain：修改 `config/versions.tsv` 的 `DEFAULT`；
- 新 Profile、基础/运行镜像或固定资源：修改 `config/profiles.tsv`；
- 新独立 E2E：增加 `E2E_FULL` 或 Profile；
- 新 Benchmark 配置：增加 `BENCHMARK_FULL`。

配置文件只是数据列表，不执行 Shell 代码。Volcano 仅改变 E2E 目标的环境参数或简单前置目标时不需要维护版本表；部署脚本会从 Candidate Makefile 自动取得。只有 Volcano 改变官方 E2E/Benchmark 入口结构、组件 Dockerfile 结构或 Bundle 格式时，才需要修改脚本。
