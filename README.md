# Volcano Performance Guard v4

本项目在外网制作一次通用依赖包，在内网反复选择不同的 Volcano tag、branch 或 commit，构建并运行 Candidate 自带的 E2E 和 Benchmark。

关键边界：

- 外网包与 Volcano 版本完全解耦，不拉取 Volcano 源码，不解析 Volcano ref，也不包含 Go modules；
- 内网每次通过 `--volcano-ref` 选择 Candidate，并通过已批准的公司 Go Proxy 下载该 Candidate 的完整 Go module graph；
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

### 1. 外网只打一次包

以 Kubernetes `v1.32.5`、基础 E2E 为例：

```bash
bash volcano-v4-package.sh --k8s-version v1.32.5 --profile e2e-basic --output ./release-assets
```

生成：

```text
release-assets/volcano-v4-1.32.5-e2e-basic.tar.gz
release-assets/volcano-v4-1.32.5-e2e-basic.tar.gz.sha256
```

命令中没有 `--volcano-ref`。这个包可以先测试 `v1.15.0`，以后再测试其他 tag、branch 或 commit。

### 2. 把包和部署脚本传入内网

需要传输：

```text
volcano-v4-1.32.5-e2e-basic.tar.gz
volcano-v4-1.32.5-e2e-basic.tar.gz.sha256
volcano-v4-deploy.sh
```

部署脚本故意不嵌入大包。以后只修复部署逻辑时，只替换几十 KB 的脚本，不需要重新传大包。

### 3. 内网选择 Volcano 版本并运行

内网已验证的 Go 配置是：

```bash
export GOPROXY=https://cmc.centralrepo.rnd.huawei.com/cbu-go,direct
export GONOSUMDB='*'
export GOSUMDB=off
```

注意变量名是 `GOSUMDB`，不是 `GOSUNDM`。部署脚本已经把以上三个值设为默认值，因此通常不需要手工 `export`，直接执行一条命令即可：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.32.5-e2e-basic.tar.gz --volcano-ref v1.15.0 --output ./results
```

以后验证其他 Candidate，复用同一个包，只改变 `--volcano-ref`：

```bash
bash volcano-v4-deploy.sh --bundle ./volcano-v4-1.32.5-e2e-basic.tar.gz --volcano-ref release-1.15 --output ./results-release-1.15
```

也可以指定 40 位 commit。使用内部 Git 镜像时增加：

```bash
--volcano-repo https://内部Git服务/volcano.git
```

## 外网包与内网下载的准确边界

```text
外网 package（与 Volcano 版本无关）
  ├─ Kind、kubectl、Helm、jq、Go toolchain
  ├─ digest 固定的 Kind 节点镜像
  ├─ 配置中维护的 Candidate 通用构建基础镜像
  ├─ Profile 所需的测试/Monitoring 镜像
  ├─ 固定版本的 KWOK 资源
  └─ SHA256 和可选 Release 分片

内网 deploy（每次选择 Volcano Candidate）
  ├─ 校验并加载外网包
  ├─ git fetch 指定的 Volcano tag/branch/commit
  ├─ 从公司 Go Proxy 下载完整 Go modules 和 Candidate 选择的 Ginkgo
  ├─ 使用 Candidate 自己的 Dockerfile 构建组件镜像
  ├─ 使用 Candidate 自己的 E2E/Benchmark 入口
  └─ 保存日志、测试产物、临时兼容补丁和 summary.txt
```

包内只有：

```text
bundle.meta
images.tar.gz
tools.tar.gz
resources.tar.gz
SHA256SUMS
```

包内明确没有：

- Volcano 源码、tag、commit 或测试源码副本；
- `go-modules.tar.gz`、Go module cache 或 Go build cache；
- Ginkgo 二进制；
- 最终 Candidate 组件镜像；
- `volcano-v4-deploy.sh`；
- 测试结果或 Baseline。

## 什么时候需要重新打外网包

| 变化 | 是否重新打包 | 原因 |
| --- | --- | --- |
| 切换 Volcano tag/branch/commit | 否 | Candidate 在内网选择 |
| Volcano 普通源码变化 | 否 | 源码在内网拉取 |
| `go.mod/go.sum` 增删 Go modules | 否 | Go modules 在内网下载 |
| Ginkgo 版本变化 | 否 | 按 Candidate `go.mod` 在内网安装 |
| 修改 `volcano-v4-deploy.sh` | 否 | 单独替换脚本 |
| Kubernetes/Kind/节点镜像变化 | 是 | 属于外网包内容 |
| Candidate 要求不同 Go toolchain | 是 | Go toolchain 属于通用工具包 |
| Candidate Dockerfile 新增基础镜像 | 是 | 内网构建不能自动拉公共镜像 |
| 测试新增运行镜像或固定资源 | 是 | 必须预装进内网 Docker |

部署脚本会 fail-closed：如果 Candidate `go.mod` 要求的 Go toolchain 与包内版本不同，或 Candidate Dockerfile 使用了包内不存在的基础镜像，会直接说明缺少的依赖并停止，不会静默换版本。

当前是 `v4.3.0` 通用包格式。以前绑定 Volcano commit 或包含 Go 增量包的 `v4.2.0` 包不能与新版脚本混用；这次需要重新制作一次通用包，之后按上表长期复用。

## Profile 选择

查看全部 Profile：

```bash
bash volcano-v4-package.sh --list-profiles
```

常用 Profile：

| Profile | 默认运行 | 用途 |
| --- | --- | --- |
| `e2e-basic` | `SCHEDULINGBASE` | 第一次验证，依赖最少 |
| `e2e:<TYPE>` | 指定 TYPE | 只准备一个 E2E 分支 |
| `e2e:ALL` | 上游 `E2E_TYPE=ALL` | 保持上游 ALL 原意 |
| `e2e-full` | `FULL` | 上游 ALL 加独立 E2E 分支 |
| `benchmark-basic` | gang | 基础 Benchmark，不含 Monitoring |
| `benchmark:gang` | gang | Gang Benchmark |
| `benchmark:pod` | pod | Pod Benchmark |
| `benchmark-full` | `FULL` | Gang、Pod 和 Monitoring |
| `full` | `FULL` | 完整 E2E 与 Benchmark |

当前维护的独立 E2E TYPE：

```text
JOBP JOBSEQ SCHEDULINGBASE SCHEDULINGACTION SCHEDULINGGATES VCCTL STRESS DRA
ADMISSION_POLICY ADMISSION_WEBHOOK HYPERNODE CRONJOB
AGENTSCHEDULER_NONE AGENTSCHEDULER_SOFT AGENTSCHEDULER_HARD
SHARDINGCONTROLLER GANGEVICT
SCHEDULERSHARDING_NONE SCHEDULERSHARDING_SOFT SCHEDULERSHARDING_HARD
```

`FULL` 是 `config/profiles.tsv` 明确维护的多次运行集合，不等于上游一次 `E2E_TYPE=ALL`。

从大包中只运行已覆盖的一部分时仍要指定 Candidate：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./volcano-v4-1.34.8-e2e-full.tar.gz \
  --volcano-ref v1.15.0 \
  --e2e-type SCHEDULINGBASE \
  --output ./results
```

运行三轮 Pod Benchmark，每轮 2000 个 Pod：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./volcano-v4-1.34.8-benchmark-full.tar.gz \
  --volcano-ref v1.15.0 \
  --benchmark-scenario pod \
  --pods 2000 \
  --scheduler-name agent-scheduler \
  --benchmark-rounds 3 \
  --output ./results
```

## Kubernetes 与工具版本

打包时只选择 Kubernetes 和 Profile：

```bash
bash volcano-v4-package.sh --k8s-version v1.34.8 --profile full --output ./release-assets
```

`config/versions.tsv` 当前维护的 Kubernetes/Kind 组合：

| Kind | Kubernetes |
| --- | --- |
| `v0.32.0` | `v1.36.1`、`v1.35.5`、`v1.34.8`、`v1.33.12` |
| `v0.31.0` | `v1.35.0`、`v1.34.3`、`v1.33.7`、`v1.32.11`、`v1.31.14` |
| `v0.30.0` | `v1.34.0`、`v1.33.4`、`v1.32.8`、`v1.31.12` |
| `v0.29.0` | `v1.33.1`、`v1.32.5`、`v1.31.9`、`v1.30.13` |

未列出的 Kubernetes 版本必须同时提供准确 Kind 和节点镜像：

```bash
--kind-version v0.29.0 --node-image kindest/node:v1.30.0@sha256:...
```

默认通用工具：

| 工具 | 默认版本/来源 |
| --- | --- |
| Kind | 随 Kubernetes 组合 |
| kubectl | 与 Kubernetes 相同 |
| Helm | `v3.21.4` |
| jq | `jq-1.8.2`，校验 SHA256 |
| KWOK | `v0.7.0` |
| Go toolchain | `go1.25.0` |
| Ginkgo | 不打包；内网按 Candidate `go.mod` 安装 |

如 Candidate 将 Go toolchain 改为其他准确版本，重新制作通用包时使用：

```bash
--go-version goX.Y.Z \
--go-sha256 该版本linux-amd64官方SHA256 \
--add-image golang:X.Y.Z
```

Go toolchain 压缩包和 Candidate Dockerfile 的 `golang:` 基础镜像是两个独立依赖；如果 Candidate 同时改变了两者，需要像上面一样都加入新通用包。默认 `go1.25.0` 与 `golang:1.25.0` 分别维护在 `versions.tsv` 和 `profiles.tsv`。

## 默认基础镜像和运行镜像

每个 Profile 都会包含以下 Candidate 通用构建基础镜像：

| Key | 镜像 |
| --- | --- |
| `candidate-builder` | `golang:1.25.0` |
| `candidate-runtime` | `alpine:latest` |

Profile 按需选择的默认镜像：

| 分组 | Key | 外网拉取引用 | 内网使用引用 |
| --- | --- | --- | --- |
| E2E | `busybox-default` | `busybox:1.36` | `busybox:latest` |
| E2E | `busybox-1-24` | `busybox:1.36` | `busybox:1.24` |
| E2E | `nginx-default` | `nginx:1.29.3-alpine` | 同名 |
| E2E | `nginx-latest` | `nginx:1.29.3-alpine` | `nginx:latest` |
| E2E | `k8s-e2e-nginx` | `registry.k8s.io/e2e-test-images/nginx:1.14-4` | 同名 |
| E2E/Benchmark | `kwok` | `registry.k8s.io/kwok/kwok:v0.7.0` | 同名 |
| JobSeq | `mpi` | `volcanosh/example-mpi:0.0.3` | 同名 |
| JobSeq | `tensorflow` | `volcanosh/dist-mnist-tf-example:0.0.1` | 同名 |
| JobSeq | `pytorch` | `volcanosh/pytorch-mnist-v1beta1-9ee8fda-example:0.0.1` | 同名 |
| JobSeq | `ray` | `rayproject/ray:2.49.0` | 同名 |
| DRA | `dra-hostpath` | `registry.k8s.io/sig-storage/hostpathplugin:v1.16.1` | 同名 |
| Benchmark | `benchmark-busybox` | `busybox:1.36` | 同名 |
| Monitoring | `prometheus` | `prom/prometheus:latest` | 同名 |
| Monitoring | `grafana` | `grafana/grafana:latest` | 同名 |
| Monitoring | `kube-state-metrics` | `docker.io/volcanosh/kube-state-metrics:v2.0.0-beta` | 同名 |

`busybox:1.24` 使用旧 schema 1，Docker 29/containerd 2.1 会拒绝拉取。因此脚本保存现代 `busybox:1.36`，同时创建 Candidate 仍引用的 `busybox:1.24` 本地标签。

只预览某个通用包会包含的镜像，不下载：

```bash
bash volcano-v4-package.sh --k8s-version v1.32.5 --profile e2e-basic --list-images
```

使用外网可访问的镜像仓库拉取、但保持内网标签不变：

```bash
--set-image kwok=registry.example.com/kwok:v0.7.0
```

Candidate 新增构建基础镜像或测试运行镜像时，可以更新 `config/profiles.tsv`，也可以临时增加：

```bash
--add-image example.com/team/extra-image:v1
```

## Kubernetes v1.32-v1.33 注意事项

Volcano v1.15.0 的 Kind 配置包含 Kubernetes v1.34 才提供的 `DRAConsumableCapacity` 和 MutatingAdmissionPolicy beta API。对 v1.32-v1.33 的非 DRA E2E，部署脚本会在临时 checkout 中做最小兼容调整并把 diff 保存为 `candidate-environment.patch`。

以下选择不会被降级模拟，而会直接拒绝，必须改用 Kubernetes v1.34+：

- `--e2e-type DRA`；
- 上游 `ALL`；
- 包含上游 `ALL` 的 `e2e-full` 或 `full`。

## 网络和服务器要求

外网打包机：Linux x86_64、Bash、curl、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp；能够访问镜像仓库和 Kind/Kubernetes/Helm/jq/Go/KWOK 下载地址。外网不需要 Git 或 Volcano 源码。

内网执行机：Linux x86_64、Bash、curl、git、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp、make、tee；能够访问 Volcano Git 仓库和公司 Go Proxy。无需预装 Python、Kind、kubectl、Helm、jq、Go 或 Ginkgo。

终端已经 `export HTTP_PROXY/HTTPS_PROXY` 时，脚本会传入 Candidate 的 Docker build。没有这些环境变量时，脚本会读取对 GitHub 生效的 Git `http.proxy`。

Go 模块下载发生在两个位置：宿主环境安装 Ginkgo，以及 Candidate Dockerfile 的 `go mod download`。部署脚本会把相同的 `GOPROXY/GONOSUMDB/GOSUMDB` 传给两者。

## 旧版 Docker 的 `image save` 兼容

较老的 Docker 不支持：

```text
docker image save --platform=linux/amd64
```

部署脚本先验证每个待保存镜像确实是 `linux/amd64`。如果 `docker image save --help` 支持 `--platform` 就使用它；否则自动退回普通 `docker image save`。因此不会再因为 `unknown flag: --platform` 中断，同时仍保持平台校验。

## 大包分片和 Release

完整 `full` 包可能超过单个 GitHub Release asset 的 2 GiB 限制，建议分为 1900M：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.34.8 \
  --profile full \
  --output ./release-assets \
  --split-size 1900M
```

传输全部 `.part-NNN`、`.parts.sha256` 和部署脚本。内网把 `.part-000` 交给 `--bundle`，脚本会校验并自动重组。

打包机已经登录 `gh` 时可直接上传：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.34.8 \
  --profile full \
  --output ./release-assets \
  --split-size 1900M \
  --publish siqiaawa/volcano-performance-guard-v4 \
  --release-tag v2.0
```

不能从服务器直传时，可通过 `scp`、SFTP、对象存储或文件中转到能访问 GitHub 的电脑，然后用网页或：

```bash
gh release upload v2.0 文件... --repo siqiaawa/volcano-performance-guard-v4
```

## 结果、调试与清理

结果目录包含准确 Candidate commit、工具/Go 环境、Bundle 和 Docker load 日志、Candidate build 日志、环境补丁、E2E artifacts 或 Benchmark results，以及最终 `summary.txt`。

保留临时 checkout、Go cache 和构建现场：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --volcano-ref v1.15.0 --output ./results --keep-work-dir
```

只在单次运行时保留 Kind 集群：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --volcano-ref v1.15.0 --output ./results --keep-cluster
```

默认会删除本次脚本创建的临时目录和 Kind 集群，不会清理整机 Docker 数据。

## 维护配置

- 新 Kubernetes/Kind/节点镜像组合：修改 `config/versions.tsv`；
- 默认 Helm、jq、KWOK 或 Go toolchain：修改 `config/versions.tsv` 的 `DEFAULT`；
- 新 Profile、基础/运行镜像或固定资源：修改 `config/profiles.tsv`；
- 新独立 E2E：增加 `E2E_FULL` 或 Profile；
- 新 Benchmark 配置：增加 `BENCHMARK_FULL`。

配置文件只是数据列表，不执行 Shell 代码。只有 Volcano 改变官方 E2E/Benchmark 入口、组件 Dockerfile 结构或 Bundle 格式时，才需要修改脚本。
