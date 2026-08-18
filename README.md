# Volcano Performance Guard v4

本项目用于在受限网络服务器上运行指定 Volcano Candidate 的官方 E2E 和社区 Benchmark。

项目只维护两个 Bash 脚本和两个 TSV 配置文件，不依赖 Python，也不维护 Volcano 测试代码副本：

```text
volcano-v4-package.sh       外网：下载依赖并生成传输包
volcano-v4-deploy.sh        内网：校验并加载依赖，拉取源码，构建 Candidate，运行测试
config/versions.tsv         Kubernetes、Kind、节点镜像和工具版本
config/profiles.tsv         Profile、镜像、资源以及 FULL 运行集合
README.md                   使用说明
```

第一次使用只需要依次阅读“先选哪种包”“最短使用方式”和“Go 增量包怎么用”。后面的 Profile、版本、镜像、Release 和维护章节是按需查询的参考信息。

## 先选哪种包

| 情况 | 建议 | 内网是否还要下载 Go 依赖 |
|---|---|---|
| 内网 Go Proxy、证书或 GitHub 模块下载不可靠 | 使用 `--include-go-modules`，推荐 | 不需要 |
| 内网有稳定、可信的 Go Proxy | 不加 `--include-go-modules` | 需要 |
| 只是更新 `volcano-v4-deploy.sh`，Candidate 和依赖没有变化 | 复用原依赖包，只替换部署脚本 | 不需要重打包 |
| 更换 Volcano tag、branch 或 commit | 重新打包 | 必须重打带 Go 模块的包 |

如果不确定，直接选择带 `--include-go-modules` 的包。它更大，但能避开内网 Go Proxy、GitHub 模块下载和公司 CA 证书问题。

## 最短使用方式

### 方案 A：先验证 Volcano v1.15.0 + Kubernetes v1.32.5

这是目前建议的第一轮验证组合，运行 `e2e-basic` 的 `SCHEDULINGBASE`。

外网服务器执行一条命令：

```bash
bash volcano-v4-package.sh --k8s-version v1.32.5 --volcano-ref v1.15.0 --profile e2e-basic --include-go-modules --output ./release-assets
```

把生成的 `.tar.gz` 和最新版 `volcano-v4-deploy.sh` 传到内网服务器，然后执行一条命令：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.32.5-8fc394c11e8d-e2e-basic.tar.gz --output ./results
```

文件名中的 `8fc394c11e8d` 是打包时解析出的 Candidate commit 前 12 位。实际使用其他 Volcano ref 时，以脚本生成的文件名为准。

### 方案 B：打包完整 E2E + Benchmark

`full` 包含 DRA 和上游 `ALL`。Volcano v1.15.0 的这些能力要求 Kubernetes v1.34+，因此不要把 `v1.32.5` 与 `full` 组合。

外网服务器执行：

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --volcano-ref v1.15.0 --profile full --include-go-modules --output ./release-assets --split-size 1900M
```

把所有 `.part-NNN`、`.parts.sha256` 和最新版 `volcano-v4-deploy.sh` 传到内网服务器，然后执行：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.34.8-8fc394c11e8d-full.tar.gz.part-000 --output ./results
```

部署脚本会校验 `.parts.sha256` 并自动重组分片，不需要手工合并。

## Go 增量包怎么用

### 它实际上是什么

这里所说的“Go 增量包”不是相对于旧压缩包制作的二进制差分，也不是 Go build cache。`--include-go-modules` 会为本次选择的准确 Volcano Candidate 生成一份完整、只读的 Go Module 文件代理：

- 临时检出 `--volcano-ref` 解析出的准确 commit；
- 使用该 Candidate `go.mod` 选择的准确 Go toolchain；
- 执行 `go mod download all`，下载 Candidate 的完整模块图；
- 下载 Candidate `go.mod` 选择的 Ginkgo 及其依赖；
- 只归档 `$GOMODCACHE/cache/download`，生成 `go-modules.tar.gz`；
- 不打包 Volcano 源码、编译缓存、Ginkgo 二进制或最终 Candidate 镜像。

“增量”的含义只是：在原来的镜像、工具和资源包上额外增加 Go 模块归档。它与准确 Candidate commit 绑定，并不能跨 Candidate 随意复用。

### 外网怎么下载

外网能够正常访问公共 Go 服务时，不需要填写任何代理地址：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.32.5 \
  --volcano-ref v1.15.0 \
  --profile e2e-basic \
  --include-go-modules \
  --output ./release-assets
```

默认使用：

```text
GOPROXY=https://proxy.golang.org,direct
GOSUMDB=sum.golang.org
```

只有外网服务器本身要求指定 Go Proxy 时才需要覆盖：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.32.5 \
  --volcano-ref v1.15.0 \
  --profile e2e-basic \
  --include-go-modules \
  --goproxy https://go-proxy.example.corp \
  --gosumdb sum.golang.org \
  --output ./release-assets
```

`https://go-proxy.example.corp` 只是格式示例，不能原样复制；只有管理员已经给出真实地址时才替换使用，不要猜。也可以使用已经在终端中设置的 `GOPROXY` 和 `GOSUMDB` 环境变量。命令行参数优先于环境变量。

### 内网怎么使用

不需要解压或单独安装 Go 模块，也不需要给部署命令填写 `--goproxy`：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --output ./results
```

部署脚本识别到 `GO_MODULES_INCLUDED=true` 后会自动：

1. 校验并解压 `go-modules.tar.gz`；
2. 设置本地 `GOPROXY=file://...` 和 `GOSUMDB=off`；
3. 从包内模块安装准确版本的 Ginkgo；
4. 把模块目录作为 BuildKit build context 交给 Candidate Dockerfile；
5. 强制 Candidate 镜像的 `go mod download` 只访问包内模块代理。

`GOSUMDB=off` 只用于内网不访问公共校验服务。模块内容仍受 Candidate `go.sum`、包内 `SHA256SUMS` 和外层压缩包 SHA256 共同校验。

### 怎么确认一个包包含 Go 模块

此命令只校验并显示能力，不启动 Docker、不创建 Kind 集群：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --list-capabilities --output ./capabilities
```

输出中应包含：

```text
go_modules_included=true
```

### 什么时候必须重新下载 Go 模块

以下情况必须重新执行外网打包：

- 修改了 `--volcano-ref`；
- 同一个 branch 指向了新的 commit；
- Candidate 的 `go.mod`、`go.sum` 或 Go toolchain 发生变化；
- 新 Candidate 的 Dockerfile 增加了新的基础镜像；
- 改用了覆盖后的 `--go-version`。

只修改部署脚本的兼容逻辑时，不需要重新下载大包。部署脚本是独立资产，用最新版脚本读取原包即可；但当前实现要求脚本的 `SCRIPT_VERSION` 与包内版本完全相同，例如两者都是 `v4.2.0`。

如果强行用带 Go 模块的旧包运行不同 Candidate，部署脚本会报告 commit 不一致并停止，不会偷偷回退到联网下载。

### 如果明确不想打 Go 模块

外网命令去掉 `--include-go-modules` 即可：

```bash
bash volcano-v4-package.sh --k8s-version v1.32.5 --volcano-ref v1.15.0 --profile e2e-basic --output ./release-assets
```

内网仍然使用同一个部署入口：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --output ./results
```

此时 Candidate 编译和 Ginkgo 安装会使用内网终端已有的 `GOPROXY`/`GOSUMDB`，或者使用部署参数明确指定的真实地址：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./bundle.tar.gz \
  --goproxy https://go-proxy.example.corp \
  --gosumdb sum.golang.org \
  --output ./results
```

如果你不知道该填什么，说明当前没有可确认的内网 Go 下载渠道，应改用外网生成的 `--include-go-modules` 包，而不是复制示例地址。

## 外网与内网分别做什么

```text
外网 package
  ├─ 解析 Volcano ref 为准确 commit
  ├─ 下载基础镜像、Kind 节点镜像和小型资源
  ├─ 下载 Kind、kubectl、Helm、jq、KWOK 和 Go toolchain
  ├─ 可选：下载准确 Candidate 的完整 Go 模块
  └─ 生成一个依赖包或多个 Release 分片

内网 deploy
  ├─ 校验依赖包、工具、镜像和资源
  ├─ 拉取包中记录的准确 Volcano 源码 commit
  ├─ 使用 Candidate 自己的 Dockerfile 构建组件镜像
  ├─ 使用 Candidate 自己的 E2E/Benchmark 入口
  ├─ 创建、运行并默认删除 Kind 集群
  └─ 保存日志、测试结果、环境补丁和 summary.txt
```

依赖包不包含 Volcano 源码。内网必须能够从 GitHub 或内部 Git 镜像拉取同一个 commit：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./bundle.tar.gz \
  --volcano-repo https://内部Git服务/volcano.git \
  --output ./results
```

如果终端已经通过 `export HTTP_PROXY=...` 和 `export HTTPS_PROXY=...` 配置代理，部署脚本会读取并传递它们。没有环境变量时，脚本还会检查对 GitHub 生效的 Git `http.proxy`。

## Profile 怎么选

先查看脚本当前维护的全部 Profile：

```bash
bash volcano-v4-package.sh --list-profiles
```

常用选择：

| Profile | 默认运行 | 用途 |
|---|---|---|
| `e2e-basic` | `SCHEDULINGBASE` | 第一次验证，依赖最少 |
| `e2e:<TYPE>` | 指定 TYPE | 只准备一种 E2E 所需依赖 |
| `e2e:ALL` | 上游 `E2E_TYPE=ALL` | 保持上游 ALL 的原始含义 |
| `e2e-full` | `FULL` | 上游 ALL 加未被 ALL 覆盖的独立分支 |
| `benchmark-basic` | gang comprehensive | 不带 Monitoring 的基础 Benchmark |
| `benchmark:gang` | gang comprehensive | Gang Benchmark |
| `benchmark:pod` | Candidate pod 模板 | Pod Benchmark |
| `benchmark-full` | `FULL` | 全部维护的 Benchmark 和 Monitoring |
| `full` | `FULL` | `e2e-full` 与 `benchmark-full` 的合集 |

当前维护的独立 E2E TYPE：

```text
JOBP JOBSEQ SCHEDULINGBASE SCHEDULINGACTION SCHEDULINGGATES VCCTL STRESS DRA
ADMISSION_POLICY ADMISSION_WEBHOOK HYPERNODE CRONJOB
AGENTSCHEDULER_NONE AGENTSCHEDULER_SOFT AGENTSCHEDULER_HARD
SHARDINGCONTROLLER GANGEVICT
SCHEDULERSHARDING_NONE SCHEDULERSHARDING_SOFT SCHEDULERSHARDING_HARD
```

`FULL` 是本项目维护的运行集合，不等于上游单次 `E2E_TYPE=ALL`。准确集合只维护在 `config/profiles.tsv` 的 `E2E_FULL` 和 `BENCHMARK_FULL` 条目中。

### 从大 Profile 中只运行一部分

包只允许运行它已经覆盖的能力。例如从 `e2e-full` 包中只运行一种 E2E：

```bash
bash volcano-v4-deploy.sh --bundle ./e2e-full.tar.gz --e2e-type SCHEDULINGBASE --output ./results
```

运行三轮 Pod Benchmark，每轮生成 2000 个 Pod：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./benchmark-full.tar.gz \
  --benchmark-scenario pod \
  --pods 2000 \
  --scheduler-name agent-scheduler \
  --benchmark-rounds 3 \
  --output ./results
```

使用 Candidate 自带或本机绝对路径的 Gang 配置：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./benchmark-full.tar.gz \
  --benchmark-scenario gang \
  --benchmark-config benchmark/testcases/gang/cases/comprehensive.yaml \
  --output ./results
```

Benchmark YAML 原样交给 Candidate 的 `scripts/run-tests.sh` 和 `TestFromConfig`，部署脚本不重新实现工作负载语义。

## Kubernetes 与 Volcano 版本选择

打包时 `--k8s-version`、`--volcano-ref`、`--profile` 都必须明确指定：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.34.8 \
  --volcano-ref release-1.15 \
  --profile e2e-full \
  --include-go-modules \
  --output ./release-assets
```

`--volcano-ref` 可以是 tag、branch 或 40 位 commit。打包脚本总会把它解析并记录为准确 commit。

`config/versions.tsv` 当前维护的 Kubernetes/Kind 组合：

| Kind | Kubernetes |
|---|---|
| `v0.32.0` | `v1.36.1`、`v1.35.5`、`v1.34.8`、`v1.33.12` |
| `v0.31.0` | `v1.35.0`、`v1.34.3`、`v1.33.7`、`v1.32.11`、`v1.31.14` |
| `v0.30.0` | `v1.34.0`、`v1.33.4`、`v1.32.8`、`v1.31.12` |
| `v0.29.0` | `v1.33.1`、`v1.32.5`、`v1.31.9`、`v1.30.13` |

每个节点镜像都在 `config/versions.tsv` 中用 Kind Release 公布的 digest 固定。列表表示脚本能够准确下载对应工具和节点镜像，不代表任意 Volcano Candidate、Kubernetes 和 E2E TYPE 的组合都兼容；最终以目标服务器真实运行结果为准。

未列出的 Kubernetes 版本必须同时指定 Kind 和准确节点镜像：

```bash
--kind-version v0.29.0 --node-image kindest/node:v1.30.0@sha256:...
```

不能只指定其中一个。

### Kubernetes v1.32-v1.33 注意事项

Volcano v1.15.0 的 Kind 配置包含 Kubernetes v1.34 才提供的 `DRAConsumableCapacity` 和 MutatingAdmissionPolicy beta API。对 v1.32-v1.33 的非 DRA E2E，部署脚本会在临时 checkout 中做最小兼容调整并把 diff 保存为 `candidate-environment.patch`。

以下选择不会被降级模拟，而是直接拒绝，必须改用 Kubernetes v1.34+：

- `--e2e-type DRA`；
- 上游 `ALL`；
- 包含上游 `ALL` 的 `e2e-full` 或 `full`。

## 默认工具与镜像

工具版本：

| 工具 | 版本来源 |
|---|---|
| Kind | 随所选 Kubernetes 组合 |
| kubectl | 与所选 Kubernetes 版本相同 |
| Helm | `v3.21.4` |
| jq | `jq-1.8.2`，校验官方 SHA256 |
| KWOK | `v0.7.0` |
| Go | Candidate `go.mod` 的准确 toolchain |
| Ginkgo | Candidate `go.mod` 选择的版本 |

Profile 当前可能使用的基础/运行镜像：

| 用途 | 外网拉取引用 | 内网使用引用 |
|---|---|---|
| E2E busybox 默认 | `busybox:1.36` | `busybox:latest` |
| Admission busybox 兼容 | `busybox:1.36` | `busybox:1.24` |
| E2E nginx | `nginx:1.29.3-alpine` | 同名及 `nginx:latest` |
| Kubernetes E2E nginx | `registry.k8s.io/e2e-test-images/nginx:1.14-4` | 同名 |
| KWOK | `registry.k8s.io/kwok/kwok:v0.7.0` | 同名 |
| MPI | `volcanosh/example-mpi:0.0.3` | 同名 |
| TensorFlow | `volcanosh/dist-mnist-tf-example:0.0.1` | 同名 |
| PyTorch | `volcanosh/pytorch-mnist-v1beta1-9ee8fda-example:0.0.1` | 同名 |
| Ray | `rayproject/ray:2.49.0` | 同名 |
| DRA hostpath | `registry.k8s.io/sig-storage/hostpathplugin:v1.16.1` | 同名 |
| Benchmark busybox | `busybox:1.36` | 同名 |
| Prometheus | `prom/prometheus:latest` | 同名 |
| Grafana | `grafana/grafana:latest` | 同名 |
| kube-state-metrics | `docker.io/volcanosh/kube-state-metrics:v2.0.0-beta` | 同名 |

`busybox:1.24` 是 Docker manifest schema 1，Docker 29/containerd 2.1 已拒绝拉取。打包脚本因此拉取现代格式的 `busybox:1.36`，再保存为 Candidate 仍然引用的 `busybox:1.24` 标签，不修改测试源码。

打包脚本还会读取所选 Candidate 的已知组件 Dockerfile，把其中的构建基础镜像加入依赖包。需要 AgentScheduler 或 Monitoring 时，才处理对应 Dockerfile。

只预览 Profile 将使用的镜像，不拉取：

```bash
bash volcano-v4-package.sh --k8s-version v1.32.5 --volcano-ref v1.15.0 --profile e2e-basic --list-images
```

覆盖或增加 Candidate 特有镜像：

```bash
--set-image kwok=registry.internal/kwok:v0.7.0
--add-image example.com/team/extra-image:v1
```

## 包里有什么、没有什么

一个未分片依赖包解压后只包含：

```text
bundle.meta
images.tar.gz
tools.tar.gz
resources.tar.gz
go-modules.tar.gz     仅使用 --include-go-modules 时存在
SHA256SUMS
```

它明确不包含：

- `volcano-v4-deploy.sh`；
- Volcano 源码、`test/e2e` 或 `benchmark/` 副本；
- Go build cache；
- Ginkgo 二进制；
- 最终 Candidate Volcano 组件镜像；
- 测试结果或 Baseline。

部署脚本必须作为独立文件一起传输。这样只修复脚本时可以传几十 KB 的新脚本，不必重新制作和传输大包。

`resources.tar.gz` 当前保存固定版本的 KWOK `kwok.yaml` 和 `stage-fast.yaml`。普通镜像通过 `docker image load` 进入内网 Docker，再使用单平台 archive 和 `kind load image-archive` 载入 Kind，兼容 Docker 29 的 OCI index/attestation 描述符。

## 网络和服务器要求

### 外网打包机

- Linux x86_64，例如 CentOS 8；
- Bash、curl、git、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp；
- Docker daemon 和默认 `docker` buildx driver 可用；
- 能访问 GitHub、镜像仓库、Kubernetes/Helm/Go 下载站点；
- 磁盘能够同时容纳镜像、临时目录和最终压缩包。

外网不要求预装 Kind、kubectl、Helm、jq、Go、Ginkgo 或 Python。

### 内网执行机

- Linux x86_64，例如 CentOS 7；
- Bash、curl、git、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp、make、tee；
- Docker daemon 和默认 `docker` buildx driver 可用；
- 能从 GitHub 或内部镜像拉取准确 Volcano 源码 commit；
- 使用普通包时还必须有 Go Module 下载渠道；使用 Go 模块包时不需要。

内网不要求预装 Python、Kind、kubectl、Helm、jq、Go 或 Ginkgo，也不需要访问 Docker Hub、`registry.k8s.io`、KWOK/Volcano Helm Repository、`dl.k8s.io`、`go.dev` 或公共 Go Proxy。

注意：如果新的 Candidate Dockerfile 自己增加了 `apk add`、`apt`、`curl` 等额外网络下载步骤，这些不属于 Go Module 包。需要相应更新配置或脚本，否则目标服务器仍可能在 Candidate 构建阶段失败。

## 大文件、分片和 GitHub Release

GitHub Release 要求每个 asset 小于 2 GiB，完整 `full` 包应当分片。这里使用 `1900M` 留出余量，限制说明见 [GitHub 官方文档](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.34.8 \
  --volcano-ref v1.15.0 \
  --profile full \
  --include-go-modules \
  --output ./release-assets \
  --split-size 1900M
```

上传以下全部文件：

```text
*.part-000
*.part-001
...
*.parts.sha256
volcano-v4-deploy.sh
```

不要遗漏 `.parts.sha256`。

打包机已经安装并认证 `gh` 时，可直接发布：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.34.8 \
  --volcano-ref v1.15.0 \
  --profile full \
  --include-go-modules \
  --output ./release-assets \
  --split-size 1900M \
  --publish siqiaawa/volcano-performance-guard-v4 \
  --release-tag v2.0
```

如果服务器无法直接上传 GitHub Release，可以把生成文件通过 `scp`、SFTP、对象存储或内网文件中转传到能登录 GitHub 的电脑，再使用网页或：

```bash
gh release upload v2.0 文件... --repo siqiaawa/volcano-performance-guard-v4
```

## 结果、调试与清理

结果目录包含：

- 准确 Candidate commit 和工具版本；
- Bundle、Docker load 和 Candidate build 日志；
- `candidate-environment.patch`；
- E2E artifacts 或 Benchmark results；
- 最终 `summary.txt`。

默认情况下，临时 Go、Ginkgo、源码 checkout 和 Kind 集群会在完成后清理。调试时可以保留工作目录：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --output ./results --keep-work-dir
```

只在单次运行时保留最后一个 Kind 集群：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --output ./results --keep-cluster
```

脚本采用 fail-closed：Profile 不覆盖请求能力、Candidate commit/Go 模块不一致、基础镜像缺失、工具或 SHA256 不一致、Kubernetes 版本不匹配时都会直接停止，不会静默联网补依赖或换版本。

## 维护配置

常规版本更新优先只修改 TSV：

- 新 Kubernetes/Kind/节点镜像组合：修改 `config/versions.tsv`；
- 默认 Helm、jq、KWOK：修改 `config/versions.tsv` 的 `DEFAULT`；
- 新 Profile、镜像或 KWOK 资源：修改 `config/profiles.tsv`；
- 新独立 E2E：增加 `E2E_FULL` 或 Profile；
- 新 Benchmark 配置：增加 `BENCHMARK_FULL`。

只有 Volcano 改变官方入口、已知 Dockerfile、Benchmark 基础设施或 Bundle 格式时，才需要修改两个脚本。配置文件只是数据列表，不执行 Shell 代码。
