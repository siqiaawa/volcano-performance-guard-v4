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

只运行全部 Benchmark（Gang comprehensive、Gang net-topo 和 Pod）：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode benchmark --work-dir ./work/v1.15.0-benchmark-full --output ./results/v1.15.0-benchmark-full

只运行一个 E2E TYPE；把 `SCHEDULINGBASE` 换成“Profile 选择”列出的其他 TYPE 即可：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode e2e --e2e-type SCHEDULINGBASE --work-dir ./work/v1.15.0-e2e-schedulingbase --output ./results/v1.15.0-e2e-schedulingbase
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

## 常用场景

### 外网打包脚本

#### 更换 Kubernetes 版本

选择 `config/versions.tsv` 已维护的 Kubernetes 版本时，只需要修改 `--k8s-version`；脚本会自动选择对应的 Kind、kubectl 和 `kindest/node` 镜像。下面以 Kubernetes `v1.35.5` 和完整 E2E+Benchmark 的 `full` 包为例：

```bash
bash volcano-v4-package.sh --k8s-version v1.35.5 --profile full --output ./release-assets --split-size 1900M
```

### 内网部署脚本

#### 保留工作目录并继续运行

直接指定 `--work-dir` 时，该目录无论成功或失败都会保留，不需要再加 `--keep-work-dir`：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --work-dir ./work/v1.15.0-full --output ./results/v1.15.0-full
```

使用同一个 Candidate 继续该工作目录时，Bundle 和结果目录会从保存状态读取。已成功完成的批次会跳过，未完成或失败的批次会重新执行：

```bash
bash volcano-v4-deploy.sh --work-dir ./work/v1.15.0-full --volcano-ref v1.15.0
```

#### 保留并复用 Kind 集群

`--keep-cluster` 会同时保留工作目录和本次 Kind 集群。由于每个 E2E TYPE 或 Benchmark 场景都会重新创建kind集群，必须显式选择单个场景，不能直接运行 `FULL` 多批任务：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --mode e2e --e2e-type SCHEDULINGBASE --work-dir ./work/v1.15.0-e2e-schedulingbase --output ./results/v1.15.0-e2e-schedulingbase --keep-cluster
```

重新进入同一个失败批次时，重复相同运行选择并继续传入 `--keep-cluster`；脚本验证 Bundle、Candidate、Kubernetes 和集群身份后复用集群，并从该 E2E TYPE 或失败的 Benchmark round 开头重新运行：

```bash
bash volcano-v4-deploy.sh --work-dir ./work/v1.15.0-e2e-schedulingbase --volcano-ref v1.15.0 --mode e2e --e2e-type SCHEDULINGBASE --keep-cluster
```

#### 仅创建 Kind 集群

`--cluster-only` 只校验并解压 Bundle、加载镜像并创建一个包含一个 control-plane 和两个 worker 的普通 Kind 集群，不拉取 Volcano、不下载 Go modules，也不运行测试。该模式自动保留工作目录和集群：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --cluster-only --work-dir ./work/kind-1.34.8 --output ./results/kind-1.34.8
```

创建完成后加载脚本生成的环境，即可按普通 Kind/Kubernetes 流程使用：

```bash
source ./results/kind-1.34.8/manual-env.sh && kubectl get nodes -o wide
```

重新验证并进入保存的同一个集群：

```bash
bash volcano-v4-deploy.sh --work-dir ./work/kind-1.34.8 --cluster-only
```

#### 仅安装 Volcano

`--deploy-only` 拉取指定 Candidate、下载其 Go modules、构建组件镜像，创建相同的普通 Kind 集群并使用 Candidate 自己的 Helm Chart 安装 Volcano；安装就绪后停止，不运行 E2E 或 Benchmark。该模式也自动保留工作目录和集群：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-full.tar.gz.part-000 --volcano-ref v1.15.0 --deploy-only --work-dir ./work/v1.15.0-deploy --output ./results/v1.15.0-deploy
```

加载环境后可以按普通 Volcano/Kubernetes 流程使用 kubectl、Helm、vcjob、queue 等资源：

```bash
source ./results/v1.15.0-deploy/manual-env.sh && kubectl -n volcano-system get pods -o wide
```

重新验证并进入保存的同一个 Volcano 集群：

```bash
bash volcano-v4-deploy.sh --work-dir ./work/v1.15.0-deploy --volcano-ref v1.15.0 --deploy-only
```

两个模式都会在结果目录生成 `manual-env.sh`、`manual-access.txt`、`kubeconfig` 和 `summary.txt`。使用结束后先 `source manual-env.sh`，再执行 `kind delete cluster --name "$VPG4_KIND_CLUSTER"` 即可删除该项目集群；脚本不会清理宿主机的其他集群或镜像。删除后再次使用原命令和同一工作目录时会重建同名集群；`--deploy-only` 会复用已完成的源码、依赖和镜像构建，再向新集群重新加载组件镜像并安装 Volcano。

### 使用包内工具

部署工作目录完成 Bundle 工具解压后，可以直接把包内 Kind、kubectl、Helm、jq 和默认 Go 加入当前终端的 `PATH`，不会安装到系统目录：

```bash
export PATH="$PWD/work/v1.15.0-full/tools/bin:$PWD/work/v1.15.0-full/tools/go/bin:$PATH"
```

检查实际使用的包内版本：

```bash
kind version && kubectl version --client && helm version --short && jq --version && go version
```

## 外网打包脚本说明

`volcano-v4-package.sh` 只在能够访问公共下载地址和镜像仓库的 Linux x86_64 外网机器运行。它下载并校验通用工具、基础镜像、测试镜像和固定资源，但不会接收 Volcano ref，也不会拉取 Volcano 源码、Go modules 或构建最终 Candidate 镜像。

### 参数说明

| 参数                                              | 含义                                                                            |
| ------------------------------------------------- | ------------------------------------------------------------------------------- |
| `--k8s-version VERSION`                           | 指定包内 Kubernetes 和 kubectl 的精确版本，并从配置中选择对应的 Kind 和节点镜像 |
| `--profile PROFILE`                               | 指定要打包的 E2E、Benchmark 能力和依赖集合                                      |
| `--output DIR`                                    | 指定完整包、校验文件和可选分卷的输出目录                                        |
| `--config-dir DIR`                                | 使用另一套包含 `versions.tsv` 和 `profiles.tsv` 的配置目录                      |
| `--kind-version VERSION`、`--node-image IMAGE`    | 为配置中未维护的 Kubernetes 版本指定 Kind 和节点镜像，两项必须同时使用          |
| `--helm-version VERSION`                          | 临时指定包内 Helm 版本                                                          |
| `--go-version VERSION`、`--go-sha256 SHA256`      | 向包内增加并选择一个宿主 Go 工具链，两项必须同时使用                            |
| `--set-image KEY=IMAGE`                           | 修改当前 Profile 中某个镜像 Key 的外网拉取来源，保存后的内网镜像名不变          |
| `--add-image IMAGE`                               | 临时向本次包增加一个配置中没有的精确镜像                                        |
| `--list-profiles`                                 | 显示配置中维护的全部 Profile 后退出，不进行下载                                 |
| `--list-images`                                   | 显示本次配置将选择的工具版本和镜像，不进行下载                                  |
| `--split-size SIZE`                               | 按指定大小生成 `.part-NNN` 分卷和 `.parts.sha256`，例如 `1900M`                 |
| `--publish OWNER/REPOSITORY`、`--release-tag TAG` | 使用已登录的 `gh` 将产物上传到指定仓库的 Release，两项必须同时使用              |
| `--keep-work-dir`                                 | 保留外网打包临时目录，用于排查下载、镜像保存或归档问题                          |
| `-h`、`--help`                                    | 显示脚本帮助信息                                                                |

### Profile 决定包内能力和依赖

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
- `tools.tar.gz`：当前 Kubernetes 组合指定的唯一 Kind、多个隔离的完整 Go toolchain、kubectl、Helm 和 jq；
- `resources.tar.gz`：KWOK manifest、stage 等固定小资源；
- `SHA256SUMS`：上述四个内容文件的 SHA256。

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

### 镜像和自动清理边界

打包脚本和部署脚本都不会自动执行 `docker system prune`、`docker image prune`、批量 `docker rmi`、`ctr images rm`，也不会删除 `/var/lib/docker` 或 `/var/lib/containerd`。打包阶段拉取的镜像、部署阶段加载的 Bundle 镜像和内网构建的 Candidate 镜像都会保留在宿主机，供后续工作目录或再次验证复用。

脚本自动删除的范围只有它自己创建的临时打包容器、未要求保留的临时目录，以及未使用 `--keep-cluster` 保存的项目 Kind 集群。删除 Kind 集群会删除该集群的节点容器及节点容器内部的数据，但不会清空宿主 Docker 的全部镜像。需要释放磁盘时应由使用者在任务之外审计准确对象后手动清理，部署命令不会隐式替使用者做全局镜像清理。

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
| Candidate 要求的 Go 主次版本不在包内                | 是         | 需要把对应 Go 版本加入 `tools.tar.gz`     |

打包脚本遇到未知 Profile、未配置的 Kubernetes/Kind 组合、缺失镜像 Key、错误平台或校验不一致时会直接停止，不会静默改用其他版本。

### Kubernetes 与工具版本

`config/versions.tsv` 当前维护的 Kubernetes/Kind 组合：

| Kind      | Kubernetes                                              |
| --------- | ------------------------------------------------------- |
| `v0.32.0` | `v1.36.1`、`v1.35.5`、`v1.34.8`、`v1.33.12`             |
| `v0.31.0` | `v1.35.0`、`v1.34.3`、`v1.33.7`、`v1.32.11`、`v1.31.14` |
| `v0.30.0` | `v1.34.0`、`v1.33.4`、`v1.32.8`、`v1.31.12`             |
| `v0.29.0` | `v1.33.1`、`v1.32.5`、`v1.31.9`、`v1.30.13`             |

未列出的 Kubernetes 版本必须同时提供准确 Kind 版本和最好带 digest 的节点镜像，使用前文的 `--kind-version` 与 `--node-image` 配对覆盖。表中维护多个可选择组合，但每次打包只把当前 `--k8s-version` 对应的一个 Kind、一个 kubectl 和一个 `kindest/node` 镜像放进 Bundle，不会把不同 Kubernetes/Kind 组合混装。命令行指定新组合时也只打入该次明确指定的 Kind 和节点镜像。

默认通用工具：

| 工具         | 打包版本/来源                                                   |
| ------------ | --------------------------------------------------------------- |
| Kind         | 仅包含当前 `--k8s-version` 映射或命令行明确指定的一个版本       |
| kubectl      | 与当前 Bundle 的 Kubernetes 相同                                |
| Helm         | `v3.21.4`                                                       |
| jq           | `jq-1.8.2`，校验 SHA256                                         |
| KWOK         | `v0.7.0`                                                        |
| Go toolchain | `go1.23.7`、`go1.24.0`、`go1.25.0`、`go1.26.0`，默认 `go1.25.0` |
| Ginkgo       | 不打包；内网按 Candidate `go.mod` 安装                          |

部署脚本启动时仍使用默认 `go1.25.0`，拉取 Candidate 后再读取其 `toolchain` 或 `go` 声明，在包内选择相同 Go 主次版本且不低于最低要求的最小补丁版本。Candidate 要求 `go1.24.0` 时使用包内 `go1.24.0`；最低要求为 `go1.26.0` 时，默认 `go1.25.0` 不再满足要求，脚本会自动切换到 `go1.26.0`。若对应主次版本不存在，脚本会在下载 Go modules 和构建前直接报错；此时应在 `versions.tsv` 增加 `GO|版本|官方SHA256|-` 后重新打包，或者使用前文的 `--go-version` 与 `--go-sha256` 临时补充。

Go toolchain 压缩包和 Candidate Dockerfile 的 `golang:` 基础镜像仍是两个独立依赖。工具包中的多版本 Go 用于宿主机执行 `go mod download`、安装 Ginkgo 和运行上游 Go 测试；`profiles.tsv` 中的 `golang:1.23.7`、`golang:1.24.0`、`golang:1.25.0`、`golang:1.26.0` 则用于 Candidate Docker builder。这样要求 Go 1.26 的分支在 Dockerfile 同步更新 builder 时也能离线构建。未来 Candidate 使用其他 Go 主次版本时，仍需要同时检查宿主 Go toolchain 与 Docker builder 基础镜像是否都已覆盖。

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

Candidate E2E 中无 tag 的 `busybox`/`nginx` 会在临时 checkout 内固定为包中已有的非 `latest` tag，避免 Kubernetes 默认重新拉取。

除上述镜像引用、Kubernetes 版本兼容、离线镜像加载和保存集群恢复外，部署脚本不改写某个具体 E2E 用例的启动命令、等待时间、网络参数或通过条件。TensorFlow、MPI、Ray 及其他测试均执行所选 Candidate 的原生实现；环境不满足时保留其原始失败结果，由使用者结合 `run-results.tsv` 和各批 `run.log` 判断。

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

### 参数说明

| 参数                          | 含义                                                                                   |
| ----------------------------- | -------------------------------------------------------------------------------------- |
| `--bundle PATH`               | 指定完整 `.tar.gz`、已解压 Bundle 目录或 `.part-000`；从已解压 Bundle 内运行时可以省略 |
| `--bundle-url URL`            | 使用 `curl` 下载一个未分卷的 Bundle；不能用于分卷包                                    |
| `--output DIR`                | 指定测试结果目录；未指定时使用带时间戳的默认目录                                       |
| `--work-dir DIR`              | 指定新的工作目录，或恢复一个此前保存且身份匹配的工作目录                               |
| `--keep-work-dir`             | 保留脚本自动创建的工作目录，供后续恢复或排查问题                                       |
| `--keep-cluster`              | 保留并复用当前工作目录唯一的 Kind 集群                                                 |
| `--cluster-only`              | 创建并保留普通双 worker Kind 集群，不拉取 Candidate，也不运行测试                      |
| `--deploy-only`               | 构建并安装指定 Candidate Volcano，保留集群但不运行 E2E 或 Benchmark                     |
| `--volcano-ref REF`           | 指定 Volcano tag、branch 或 commit；除 `--cluster-only` 外均为必填                      |
| `--volcano-repo URL`          | 指定 Volcano Git 仓库；默认使用官方仓库                                                |
| `--goproxy VALUE`             | 指定内网下载 Candidate Go modules 使用的 Go Proxy                                      |
| `--gonosumdb VALUE`           | 指定 `GONOSUMDB`；默认 `*`                                                             |
| `--gosumdb VALUE`             | 指定 `GOSUMDB`；默认 `off`                                                             |
| `--mode e2e\|benchmark\|both` | 选择运行 E2E、Benchmark 或两者，必须在 Bundle Profile 的覆盖范围内                     |
| `--e2e-type TYPE`             | 指定一个 E2E TYPE 或 `FULL`                                                            |
| `--benchmark-scenario NAME`   | 指定 `gang`、`pod` 或 `FULL` Benchmark                                                 |
| `--benchmark-config PATH`     | 为单次 Benchmark 指定 Candidate 内相对路径或绝对路径的 YAML                            |
| `--benchmark-rounds N`        | 指定每个 Benchmark 的运行轮数；默认 `1`                                                |
| `--pods N`                    | 指定生成式 Pod Benchmark 的 Pod 数量；默认 `1000`                                      |
| `--scheduler-name NAME`       | 指定生成式 Pod Benchmark 使用的调度器；默认 `agent-scheduler`                          |
| `--cluster-prefix NAME`       | 指定 Kind 集群名称前缀；默认 `volcano-v4`                                              |
| `--list-capabilities`         | 校验 Bundle 元数据并显示当前包可运行的 E2E 和 Benchmark，不执行测试                    |
| `-h`、`--help`                | 显示脚本帮助信息                                                                       |

### E2E 参数自动跟随 Candidate

部署脚本不会把 `FEATURE_GATES`、`IGNORED_PROVISIONERS` 等参数按 Volcano 版本硬编码。Candidate checkout 完成后，脚本对每个选中的 TYPE 查找对应的上游 Make 目标，用 `make -n` 取得该目标实际调用 `hack/run-e2e-kind.sh` 时的环境赋值，同时从隔离的 Make 环境继承 Candidate 导出的单行运行变量，并在创建 Kind 前写入 `candidate-e2e-contracts.txt`。宿主机凭据、代理、Go 缓存和部署脚本管理的集群变量不会进入该契约；仅供 Make 内部使用的多行函数也会被忽略。

例如同一个脚本会自动得到：

```text
v1.12.0 SCHEDULINGBASE -> E2E_TYPE=SCHEDULINGBASE
v1.15.0 SCHEDULINGBASE -> E2E_TYPE=SCHEDULINGBASE, IGNORED_PROVISIONERS=kubernetes.io/no-provisioner
v1.14.0 DRA            -> FEATURE_GATES=DynamicResourceAllocation=true
v1.15.0 DRA            -> FEATURE_GATES=DynamicResourceAllocation=true,DRAConsumableCapacity=true
v1.15.0 VCCTL          -> 构建上游 vcctl 前置目标，并继承其 Make 输出目录
```

每个独立 E2E 开始前都会先清空上一轮解析出的测试变量，再加载本轮契约，因此 DRA 或 SchedulingGates 的 Feature Gate 不会泄漏到后续测试。带前置构建目标的测试会先执行 Candidate 自己声明的前置目标，再以同一份 Make 输出目录环境调用上游 runner；这不是对 VCCTL 或其他测试名称的硬编码。对于较早的 Candidate，`FULL` 中该版本尚未定义的独立 Make 目标会在预检阶段记录并跳过；显式选择一个 Candidate 不存在的 TYPE 则会直接报错。

KWOK manifest 应用或 `kwok-controller` 就绪等待失败属于整批测试共享的基础设施失败。部署脚本会立即结束当前批次并记录失败，再按所选 `FULL` 流程继续下一批，而不会在未就绪的 KWOK 集群上制造后续误报。这一判断只检查通用基础设施状态，不修改任何具体测试用例的等待时间、命令或通过条件。

普通参数变化、参数新增或前置目标变化不要求重新制作外网包；只有上游改掉 Make 目标或 `hack/run-e2e-kind.sh` 的入口结构时，部署脚本才会在预检阶段 fail-closed，并需要增加小型兼容适配。`e2e:ALL` 保留 Candidate 自己的一次性 `E2E_TYPE=ALL` 语义，`FULL` 则逐个调用当前 Candidate 已定义的独立上游目标。

### 内网服务器和网络要求

完整测试和 `--deploy-only` 需要 Linux x86_64、Bash、curl、git、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp、make 和 tee，并能够访问 Volcano Git 仓库和公司 Go Proxy。`--cluster-only` 不拉取 Candidate，不需要 git、make 或 Go Proxy。所有模式都无需预装 Python、Kind、kubectl、Helm、jq 或 Go；这些工具来自 Bundle。

终端已经 `export HTTP_PROXY/HTTPS_PROXY` 时，脚本会传入 Candidate 的 Docker build。没有这些环境变量时，脚本会读取对 GitHub 生效的 Git `http.proxy`。

Go 模块的 HTTPS 下载只发生在内网宿主机。部署脚本拉取 Candidate 后先选择与 Candidate `go.mod` 主次版本匹配的包内 Go toolchain，再使用相同的 `GOPROXY/GONOSUMDB/GOSUMDB` 执行 `go mod download all`，随后把 `$GOMODCACHE/cache/download` 转成临时标准 Go file proxy。Candidate Dockerfile 中的 `go mod download` 会被临时改为：

```bash
GOPROXY=file:///tmp/vpg4-goproxy GONOSUMDB='*' GOSUMDB=off go mod download
```

因此 Docker builder 不再访问公司 HTTPS Go Proxy，也不需要继承宿主机的公司 CA。宿主预下载日志保存在 `go-mod-download.log`，临时 file proxy 的校验值保存在 `inner-go-modules.sha256`；临时归档默认随工作目录清理，不进入外网包和最终 Candidate 镜像。

Webhook 离线运行时使用包内已有的 Go builder 基础镜像代替会执行 `apk add` 和下载 kubectl 的 Alpine 阶段；脚本会显式把最终阶段的 `WORKDIR` 设为 `/`，保证 Helm admission-init 的 `./gen-admission-secret.sh` 与上游运行方式一致。

## 维护配置

- 新 Kubernetes/Kind/节点镜像组合：修改 `config/versions.tsv`；
- 默认 Helm、jq、KWOK 或 Go toolchain：修改 `config/versions.tsv` 的 `DEFAULT`；新增宿主 Go 版本时增加 `GO` 行；
- 新 Profile、基础/运行镜像或固定资源：修改 `config/profiles.tsv`；
- 新独立 E2E：增加 `E2E_FULL` 或 Profile；
- 新 Benchmark 配置：增加 `BENCHMARK_FULL`。

配置文件只是数据列表，不执行 Shell 代码。Volcano 仅改变 E2E 目标的环境参数或简单前置目标时不需要维护版本表；部署脚本会从 Candidate Makefile 自动取得。只有 Volcano 改变官方 E2E/Benchmark 入口结构、组件 Dockerfile 结构或 Bundle 格式时，才需要修改脚本。
