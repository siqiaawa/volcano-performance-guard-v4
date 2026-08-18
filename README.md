# Volcano Performance Guard v4

这个项目用一个外网打包命令和一个内网部署命令，在不能访问 Docker Hub、`registry.k8s.io`、Helm Repository、`dl.k8s.io` 的服务器上，运行指定 Volcano Candidate 的官方 E2E 与社区 Benchmark。

实现刻意保持简单：项目逻辑只有两个 Bash 脚本和两个 TSV 配置文件；不依赖 Python，不维护 Volcano 测试代码副本，也不引入本地 Registry、数据库或常驻服务。

```text
volcano-v4-package.sh       外网：下载依赖并生成传输包
volcano-v4-deploy.sh        内网：加载依赖、构建 Candidate、运行测试
config/versions.tsv         Kubernetes / Kind / 节点镜像及工具版本
config/profiles.tsv         Profile、镜像、小型资源和 FULL 运行集合
README.md                   使用与维护说明
```

## 最短使用方式

外网 CentOS 8 服务器执行一条命令：

```bash
bash volcano-v4-package.sh --k8s-version v1.32.5 --volcano-ref v1.15.0 --profile full --output ./release-assets --split-size 1900M
```

把生成的全部 `.part-NNN` 和 `.parts.sha256` 以及独立的 `volcano-v4-deploy.sh` 放到内网 CentOS 7 服务器，然后执行一条命令：

```bash
bash volcano-v4-deploy.sh --bundle ./release-assets/volcano-v4-1.32.5-*-full.tar.gz.part-000 --output ./results
```

`full` 默认依次运行完整 E2E 能力集合和全部已维护 Benchmark 配置。第一次验证建议先用较小的 `e2e-basic`：

```bash
# 外网
bash volcano-v4-package.sh --k8s-version v1.32.5 --volcano-ref v1.15.0 --profile e2e-basic --output ./release-assets

# 内网
bash volcano-v4-deploy.sh --bundle ./release-assets/volcano-v4-1.32.5-*-e2e-basic.tar.gz --output ./results
```

依赖包与部署脚本独立维护。镜像、工具或 Profile 依赖没有变化时，只需要更新几十 KB 的 `volcano-v4-deploy.sh`，不需要重新制作、下载或传输大包。早期依赖包中可能带有生成时的脚本快照；显式执行外部最新脚本并通过 `--bundle` 指向该包时，使用的是外部脚本，包内快照不会被执行。

正常情况下不需要手工填写 `HTTP_PROXY`、`HTTPS_PROXY`、`GOPROXY`、`GOSUMDB` 或 CA 路径。部署脚本会优先使用已有的 HTTP 代理环境；如果环境变量未设置，则自动读取对 `https://github.com/` 生效的 Git `http.proxy`，并把代理传入 Candidate 的 BuildKit 构建。这样 Go Module 渠道回退到 `direct` 时，容器内的 Git 仍通过与宿主 `git clone` 相同的代理访问 GitHub。脚本同时使用宿主网络完成 `go mod download`。对于使用内部 CA 的 HTTPS Go Proxy，脚本会自动从 CentOS/Debian 常见系统路径找到宿主 CA bundle，通过 BuildKit secret 临时挂载给下载步骤；代理参数和 CA 都不会进入 Candidate 最终镜像。只有自动检测不到单位 CA bundle 时才指定例如 `--ca-bundle /etc/pki/tls/certs/ca-bundle.crt`。

```bash
--goproxy https://单位提供的Go代理,direct --gosumdb sum.golang.org
```

代理地址必须由内网运维提供；项目没有可以替所有环境猜测的占位值。

## 网络边界

外网打包机需要访问：

- GitHub 与 GitHub Release；
- Docker Hub、`registry.k8s.io` 等镜像仓库；
- `dl.k8s.io`、`get.helm.sh`、`go.dev`；
- Volcano Candidate 仓库。

内网执行机只需要访问：

- GitHub，用于拉取用户选择的 Volcano Candidate 源码；
- 可用的 Go Module 下载渠道，用于 Candidate 构建和按 Candidate `go.mod` 安装 Ginkgo。

内网不需要访问 Docker Hub、`registry.k8s.io`、KWOK Helm Repository、Volcano Helm Repository、`dl.k8s.io` 或 `go.dev`。包中的普通镜像通过 `docker image load` 进入本机 Docker，然后通过 `kind load docker-image` 进入 Kind；不会再包装成额外镜像。

## 源码是否打包

不会。依赖包明确不包含：

- Volcano 源码；
- `test/e2e` 或 `benchmark/` 副本；
- Go Module cache；
- Ginkgo 二进制；
- 最终 Candidate Volcano 组件镜像；
- 测试结果或 Baseline。

外网脚本会解析 `--volcano-ref` 到精确 commit，并只读取 Candidate 的 `go.mod` 和已知 Dockerfile，以选择精确 Go 工具链和构建基础镜像。内网脚本重新拉取 Candidate，使用 Candidate 自带 Dockerfile、Helm Chart、`hack/run-e2e-kind.sh`、`benchmark/scripts/run-tests.sh` 和 `TestFromConfig`。因此源码、E2E 与 Benchmark 逻辑始终来自实际被验证的 Candidate。

## Profile 与完整支持的含义

查看所有 Profile：

```bash
bash volcano-v4-package.sh --list-profiles
```

主要 Profile：

| Profile | 默认运行 | 含义 |
|---|---|---|
| `e2e-basic` | `SCHEDULINGBASE` | 最小基础调度验证 |
| `e2e:<TYPE>` | 对应 TYPE | 只准备一个指定 E2E 类型 |
| `e2e:ALL` | 上游 `E2E_TYPE=ALL` | 保持 Volcano 对 `ALL` 的原始定义 |
| `e2e-full` | `FULL` | 依次运行上游 `ALL` 及其没有覆盖的独立分支 |
| `benchmark-basic` | gang comprehensive | 不带 Monitoring 的基础 Benchmark |
| `benchmark:gang` | gang comprehensive | gang 场景 |
| `benchmark:pod` | Candidate pod 模板 | pod 场景，可指定 Pod 数量和调度器 |
| `benchmark-full` | `FULL` | gang comprehensive、gang net-topo、pod，并带完整 Monitoring |
| `full` | `FULL` | `e2e-full` 与 `benchmark-full` 的合集 |

当前维护的具体 E2E Profile 包括：

```text
JOBP JOBSEQ SCHEDULINGBASE SCHEDULINGACTION SCHEDULINGGATES VCCTL STRESS DRA
ADMISSION_POLICY ADMISSION_WEBHOOK HYPERNODE CRONJOB
AGENTSCHEDULER_NONE AGENTSCHEDULER_SOFT AGENTSCHEDULER_HARD
SHARDINGCONTROLLER GANGEVICT
SCHEDULERSHARDING_NONE SCHEDULERSHARDING_SOFT SCHEDULERSHARDING_HARD
```

这里的 `FULL` 是本项目的运行集合，不会冒充上游的 `E2E_TYPE=ALL`。当前 `FULL` 先运行上游 `ALL`，再分别运行 `SCHEDULINGGATES`、`STRESS`、两种 Admission、三种 AgentScheduler、ShardingController、GangEvict 和三种 SchedulerSharding。具体列表只维护在 `config/profiles.tsv`。

“完整 Benchmark”有两个维度：

- 依赖完整：Prometheus、Grafana、kube-state-metrics、audit-exporter 都存在，并强制使用本地镜像；
- 场景完整：运行配置文件中维护的全部 Candidate Benchmark 配置。

当前维护的 Benchmark FULL 配置是 Candidate 的 `gang/cases/comprehensive.yaml`、`gang/cases/net-topo.yaml`，以及由 Candidate `pod/cases/case-template.yaml` 渲染的 pod 配置。新增社区场景时只更新 `config/profiles.tsv`。

## 指定版本与运行项

打包时指定 Volcano branch、tag 或 40 位 commit：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.32.5 \
  --volcano-ref release-1.15 \
  --profile e2e-full \
  --output ./release-assets
```

部署默认使用打包时记录的精确 commit。也可以在内网切换 Candidate：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./bundle.tar.gz \
  --volcano-ref v1.15.1 \
  --e2e-type SCHEDULINGBASE \
  --output ./results
```

只有新 Candidate 的 Go 工具链和所有 Dockerfile 基础镜像仍被这个包覆盖时才允许继续；否则脚本会 fail-closed，并要求为新 Candidate 重新打包，不会临时访问外部镜像仓库。

从 `e2e-full` 中只运行一种类型：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --e2e-type DRA --output ./results
```

运行 pod Benchmark 并用 Candidate 模板生成 2000 个 Pod：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./benchmark-pod-bundle.tar.gz \
  --benchmark-scenario pod \
  --pods 2000 \
  --scheduler-name agent-scheduler \
  --benchmark-rounds 3 \
  --output ./results
```

传入 Candidate 自身或本机绝对路径的配置：

```bash
bash volcano-v4-deploy.sh \
  --bundle ./benchmark-gang-bundle.tar.gz \
  --benchmark-scenario gang \
  --benchmark-config benchmark/testcases/gang/cases/comprehensive.yaml \
  --output ./results
```

配置 YAML 原样交给 Candidate `scripts/run-tests.sh`，最终由 Candidate `TestFromConfig` 执行；部署脚本不重新生成 gang 工作负载。

## 默认 Kubernetes / Kind / 节点镜像

`config/versions.tsv` 当前维护以下 linux/amd64 组合。节点镜像使用 Kind Release 公布的 digest，避免同名 tag 漂移。

| Kubernetes | Kind | kindest/node |
|---|---|---|
| v1.36.1 | v0.32.0 | `kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5` |
| v1.35.5 | v0.32.0 | `kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95` |
| v1.34.8 | v0.32.0 | `kindest/node:v1.34.8@sha256:02722c2dedddcfc00febf5d27fbeb9b7b2c14294c82109ff4a85d89ac9ba3256` |
| v1.33.12 | v0.32.0 | `kindest/node:v1.33.12@sha256:3f5c8443c620245e4d355cfe09e96a91ead32ceaa569d3f1ca9edf0cb2fe2ff4` |
| v1.35.0 | v0.31.0 | `kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f` |
| v1.34.3 | v0.31.0 | `kindest/node:v1.34.3@sha256:08497ee19eace7b4b5348db5c6a1591d7752b164530a36f855cb0f2bdcbadd48` |
| v1.33.7 | v0.31.0 | `kindest/node:v1.33.7@sha256:d26ef333bdb2cbe9862a0f7c3803ecc7b4303d8cea8e814b481b09949d353040` |
| v1.32.11 | v0.31.0 | `kindest/node:v1.32.11@sha256:5fc52d52a7b9574015299724bd68f183702956aa4a2116ae75a63cb574b35af8` |
| v1.31.14 | v0.31.0 | `kindest/node:v1.31.14@sha256:6f86cf509dbb42767b6e79debc3f2c32e4ee01386f0489b3b2be24b0a55aac2b` |
| v1.34.0 | v0.30.0 | `kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a` |
| v1.33.4 | v0.30.0 | `kindest/node:v1.33.4@sha256:25a6018e48dfcaee478f4a59af81157a437f15e6e140bf103f85a2e7cd0cbbf2` |
| v1.32.8 | v0.30.0 | `kindest/node:v1.32.8@sha256:abd489f042d2b644e2d033f5c2d900bc707798d075e8186cb65e3f1367a9d5a1` |
| v1.31.12 | v0.30.0 | `kindest/node:v1.31.12@sha256:0f5cc49c5e73c0c2bb6e2df56e7df189240d83cf94edfa30946482eb08ec57d2` |
| v1.33.1 | v0.29.0 | `kindest/node:v1.33.1@sha256:050072256b9a903bd914c0b2866828150cb229cea0efe5892e2b644d5dd3b34f` |
| v1.32.5 | v0.29.0 | `kindest/node:v1.32.5@sha256:e3b2327e3a5ab8c76f5ece68936e4cafaa82edf58486b769727ab0b3b97a5b0d` |
| v1.31.9 | v0.29.0 | `kindest/node:v1.31.9@sha256:b94a3a6c06198d17f59cca8c6f486236fa05e2fb359cbd75dabbfc348a10b211` |
| v1.30.13 | v0.29.0 | `kindest/node:v1.30.13@sha256:397209b3d947d154f6641f2d0ce8d473732bd91c87d9575ade99049aa33cd648` |

未列出的 Kubernetes 版本必须同时明确提供 Kind 和节点镜像：

```bash
--kind-version v0.29.0 --node-image kindest/node:v1.30.0@sha256:...
```

不能只提供其中一个。

## 默认工具和镜像

当前固定工具默认值：

- Helm `v3.21.4`；
- jq `jq-1.8.2`，同时校验官方二进制 SHA256；
- KWOK `v0.7.0`；
- kubectl 与 Kubernetes 版本相同；
- Go 从 Candidate `go.mod` 的精确 `toolchain` 选择；没有精确 patch 版本的旧 Candidate 可用 `--go-version goX.Y.Z` 明确指定；
- Ginkgo 不预打包，由内网按 Candidate `go.mod` 版本安装。

pod Benchmark 默认沿用 Candidate 的 `agent-scheduler` 语义；`benchmark:pod`、`benchmark-full` 和 `full` 会同时准备并构建 Candidate AgentScheduler。可用 `--scheduler-name volcano` 改为普通 Volcano Scheduler。

`config/profiles.tsv` 当前默认镜像：

| 用途 | 拉取引用 | 内网本地引用 |
|---|---|---|
| E2E busybox 默认别名 | `busybox:1.36` | `busybox:latest` |
| Admission busybox compatibility tag | `busybox:1.36` | `busybox:1.24` |
| E2E nginx | `nginx:1.29.3-alpine` | 同名，并额外标记 `nginx:latest` |
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

打包脚本还会读取 Candidate 的 scheduler、controller-manager、webhook-manager Dockerfile；需要 AgentScheduler 或 Monitoring 时，再读取相应 AgentScheduler / audit-exporter Dockerfile，并把其中的基础镜像追加到包中。这是有限的已知路径检查，不是通用 Dockerfile 解析器。

Volcano 的部分 Admission E2E YAML 仍引用 `busybox:1.24`，但该历史镜像使用 Docker manifest schema 1，Docker 29/containerd 2.1 已拒绝拉取。Profile 因此下载现代格式的 `busybox:1.36`，在外网 Docker 中额外标记为 `busybox:1.24` 后保存；内网和 Candidate 仍看到原始期望标签，不需要修改测试源码。

预览 Profile 的配置镜像而不启动 Docker：

```bash
bash volcano-v4-package.sh --k8s-version v1.32.5 --volcano-ref v1.15.0 --profile full --list-images
```

覆盖或补充 Candidate 特有依赖：

```bash
--set-image kwok=registry.internal/kwok:v0.7.0
--add-image example.com/team/extra-image:v1
```

## Bundle 内容与校验

每个新生成的依赖包只有：

```text
bundle.meta
images.tar.gz
tools.tar.gz
resources.tar.gz
SHA256SUMS
```

`volcano-v4-deploy.sh` 作为独立 Release 资产发布，不属于依赖包内容。部署脚本保持向后兼容：旧包即使仍包含脚本快照，也可以由最新的外部脚本读取和验证。

`resources.tar.gz` 当前只保存固定版本的 KWOK `kwok.yaml` 和 `stage-fast.yaml`，用于避免内网访问 KWOK Helm Repository。`bundle.meta` 是严格逐项解析的数据文件，不会被 `source` 执行。外层包、内层文件、工具、资源和镜像身份都会校验。镜像身份同时兼容旧 Docker 的 config ID 与 Docker 29 containerd image store 的 OCI descriptor ID，但两者都必须来自已校验的 `images.tar.gz`。

查看一个包允许运行的内容，不启动 Docker：

```bash
bash volcano-v4-deploy.sh --bundle ./bundle.tar.gz --list-capabilities --output ./capabilities
```

## 大文件传输和 GitHub Release

直接上传 Release：

```bash
bash volcano-v4-package.sh \
  --k8s-version v1.32.5 --volcano-ref v1.15.0 --profile full \
  --output ./release-assets --split-size 1900M \
  --publish siqiaawa/volcano-performance-guard-v4 --release-tag v2.0
```

如果外网服务器无法使用 `gh release upload`，推荐替代方案按优先级是：

1. 打包机只生成文件，然后用能登录 GitHub 的电脑在 Release 网页上传；
2. 用 `scp`、SFTP、内网文件中转或对象存储把文件传到能访问 GitHub 的电脑；
3. 完整包建议始终加 `--split-size 1900M`，使每个 Release asset 低于 GitHub 的 2 GiB 单文件限制；上传所有 `.part-NNN` 和 `.parts.sha256`，内网只需把 `--bundle` 指向 `.part-000`，部署脚本会校验并重组；
4. 在另一台已安装 `gh` 且已认证的机器执行 `gh release upload TAG 文件... --repo siqiaawa/volcano-performance-guard-v4`。

不要只传分片而漏掉 `.parts.sha256`；也不要在传输后跳过 SHA256 校验。

## 服务器要求

外网 CentOS 8：

- linux/amd64；
- Bash、curl、git、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp；
- Docker daemon 与默认 `docker` buildx driver 可用；
- 足够保存节点镜像、大模型测试镜像和最终压缩包的磁盘空间。

内网 CentOS 7：

- linux/amd64；
- Bash、curl、git、Docker、tar、gzip、sha256sum、awk、sed、grep、sort、mktemp、make、tee；
- Docker daemon 与默认 `docker` buildx driver 可用；
- GitHub 与 Go Module 渠道可达；
- 不需要系统 Python、Kind、kubectl、Helm、jq、Go 或 Ginkgo。

脚本不会修改系统安装目录。Kind、kubectl、Helm、jq、Go、Ginkgo、Go cache 和 Candidate checkout 都位于工作目录；成功后默认清理。调试时可加 `--keep-work-dir`，保留集群只能用于单次运行并加 `--keep-cluster`。

## 结果与失败边界

成功结果目录包含精确 Candidate commit、工具版本、Docker load 日志、Candidate 构建日志、环境补丁、E2E artifacts 或 Benchmark results，以及 `summary.txt`。

部署脚本只对 Candidate 做两类受限网络环境适配：

- 把 E2E 的 KWOK Helm Repository 安装替换为包内固定 YAML，并把包内运行镜像加载进新建 Kind；
- 把 Benchmark Monitoring 的外部镜像拉取策略改为 `IfNotPresent`。

适配 diff 会保存为 `candidate-environment.patch`。脚本不会修改 Candidate 的 `pkg/`、`cmd/`、`test/e2e`、`benchmark/testcases` 或 `TestFromConfig`。

任何以下情况都会直接失败：

- Profile 不包含用户请求的 E2E / Benchmark；
- Candidate Go 工具链和包不一致；
- Candidate Dockerfile 出现包内不存在的基础镜像；
- Kubernetes server 版本与请求不一致；
- 工具、资源、镜像、包或分片校验失败；
- Candidate 官方入口、配置或已知环境适配点发生不兼容变化。

这使“版本可选择”和“完整能力可表达”成为脚本的已实现边界；不同 CentOS/Docker/Volcano/Kubernetes 组合是否实际全部通过，仍必须以目标服务器上的 E2E/Benchmark 结果为最终证据，不能由静态检查代替。

## 维护方式

常规升级只改两个配置文件：

- 新 Kubernetes/Kind 组合：在 `config/versions.tsv` 增加一行 `K8S`；
- 默认工具升级：修改 `DEFAULT`；
- 新 Profile、镜像或 KWOK 资源：修改 `config/profiles.tsv`；
- 新独立 E2E 分支：增加 `E2E_FULL`；
- 新 Benchmark 配置：增加 `BENCHMARK_FULL`。

只有 Volcano 改变官方入口、Dockerfile 固定路径、Benchmark 基础设施或 bundle 格式时，才需要修改两个脚本。配置是数据列表，不执行 shell 代码。
