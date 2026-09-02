# dalex-jdk-tzdata

**A personal recipe for rebuilding a Java image with a newer JDK time zone database, with a
build-time sanity check.**

[English](#english) · [中文](#中文)

The JDK never reads `/usr/share/zoneinfo` for zone rules. It carries its own compiled copy at
`$JAVA_HOME/lib/tzdb.dat`, so `apt-get install tzdata` inside a container changes nothing for
the JVM. When a zone's rules change and no JDK release carries the new
data yet, replacing that one file is one way to get a container back to the right time.

This repo does that in a Dockerfile, using **OpenJDK's own build tool and tz database** — no
Oracle account and no hand-edited binaries.

I am in the `America/Edmonton` time zone. This repository exists because of that zone's 2026
rule change, and it is what I run on my own machines.

我人在 `America/Edmonton` 时区。本仓库因该时区 2026 年的规则变化而存在,
也是我自己机器上运行的东西。

## English

### Why this exists

I live in `America/Edmonton`. From IANA tzdata **2026c**, Alberta stops observing the autumn
change: at `2026-11-01 02:00` local the zone goes from MDT to CST, the DST flag and the
abbreviation change, but the offset stays at **-06:00** and the clocks do not move. Hosts and
runtimes still on 2026b or older fall back to MST -07:00 as usual.

At the time of writing, no released JDK carries 2026c — the newest builds I could measure
(Temurin/Corretto 21.0.12, 25.0.4, 26.0.2) all ship 2026b, while OpenJDK upstream has already
integrated 2026c. Since the JDK reads its own `tzdb.dat` and ignores the OS database entirely,
updating the host or the container's `tzdata` package does nothing for the JVM.

So I put this together to test the behaviour, learn how the JDK actually loads zone rules, and
keep my own containers telling the right time. It is a personal utility that seemed worth
writing down — not a product, not a service, and not something I maintain on anyone's behalf.
Everything below describes what this repository does and what I observed on my own machines.

### Two ways to use it

**As a replacement base image** — for images you build yourself:

```bash
./build.sh                                   # the whole default matrix
./build.sh eclipse-temurin:21-jre            # just one
```

```dockerfile
FROM dalex-jdk-tz:temurin-21-jre
COPY target/app.jar /app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
```

**As a one-layer patch on an image you cannot rebuild:**

```bash
docker build -t example-app:1.2-tz \
  --build-arg BASE_IMAGE=example-app:1.2 \
  --build-arg FINAL_USER=appuser .
```

`build.sh` reads the base image's user itself (`docker inspect`), so an image that runs as a
non-root user still runs as that user afterwards.

### Default matrix

`eclipse-temurin` 17/21/25 (jre + jdk) and `amazoncorretto` 17/21/25 + `21-alpine`.
Verified working on glibc and musl bases, and on third-party application images.

> The `openjdk` Docker Hub official image is not in the matrix: its stable tags have been
> withdrawn (only `28-ea-*` remains). `eclipse-temurin` is its designated successor and
> covers the same builds.

### Options

```
--zone <IANA>        Zone the build-time check uses (default America/Edmonton)
--year <YYYY>        Year the build-time check uses (default 2026)
--expect-nov <off>   Offset the patched image must produce on <year>-11-15 (default -06:00)
--jdk-ref <ref>      OpenJDK git ref to take tzdata and tooling from (default master)
--tag-prefix <name>  Image name prefix (default dalex-jdk-tz)
--push <prefix>      Tag and push after a successful build
--dry-run            Print what would be built
```

To pull the artifact out on its own, without patching anything:

```bash
docker build -f Dockerfile.tzdb --target export -o out .
# -> out/tzdb.dat, out/tzdata.version, out/TzVerify.class
```

That `tzdb.dat` is the file to drop into a JDK on a bare host too (back up the original first;
a JVM reads it once at startup, so restart the process).

### The build verifies itself

The last stage runs the patched image and fails the build unless:

- the tzdb version is the one that was compiled in,
- `<zone>` produces the expected offset on `<year>-11-15`,
- the zone id count did not drop, and
- `SystemV/MST7` still resolves.

A failing check ends the build with a non-zero status, so no tag is produced. The check covers
the one file this repository replaces and nothing else in the image. Output of a passing build:

```
tzdb=2026c zones=604 America/Edmonton jan=-07:00 oct=-06:00 nov=-06:00 (no autumn change)
VERIFY OK
```

### How it works, and three traps

Reproduces what the OpenJDK build itself does:

1. Fetch `build/tools/tzdb/{TzdbZoneRulesCompiler,TzdbZoneRulesProvider}.java`.
2. Fetch `java.time.zone/{ZoneRules,ZoneOffsetTransition,ZoneOffsetTransitionRule,Ser}.java`
   and rename their package to `build.tools.tzdb` — exactly what OpenJDK's
   `CopyInterimTZDB.gmk` does. **Without this step the tool does not compile**: 29 errors,
   all `cannot find symbol: ZoneRules`.
3. Compile, then run the compiler over `src/java.base/share/data/tzdata`.

Two more traps worth knowing:

- The compiler matches the version with the regex `tzdata(?<ver>[0-9]{4}[A-z])`, so the
  `VERSION` file must read `tzdata2026c`. The IANA tarball's `version` file contains only
  `2026c`, and feeding that in makes the compiler **exit 1 silently**.
- Building from the IANA tarball instead of OpenJDK's data directory **silently drops 13 zone
  ids** — every `SystemV/*` alias — because they live in OpenJDK's own `jdk11_backward` file.
  Any `ZoneId.of("SystemV/MST7")` in your code would start throwing `ZoneRulesException`.
  The verifier checks for exactly this.

### What is in the box

The licenses these projects state in their own files:

| Layer | Stated license |
|---|---|
| IANA tz database | public domain, per the notice in the data files |
| OpenJDK's copy of it, `jdk11_backward`, and the tzdb compiler | GPLv2 with Classpath Exception |
| `eclipse-temurin` / `amazoncorretto` base images | GPLv2 with Classpath Exception, plus the base OS packages' own licenses |
| This repo's own files | MIT |

**This repository itself contains none of the above.** It holds Dockerfiles, a build script and
one verifier class; the OpenJDK sources and tz data are fetched from upstream at build time.

What the build puts into an image it produces:

- `/NOTICE-tzdb.txt`, stating that the image is a modified build, which file was replaced, what
  it was replaced with, and that the replaced file is kept alongside it as `tzdb.dat.orig`.
- OCI labels `org.opencontainers.image.source`, `io.github.dalexhu.tzdb.patched` and
  `io.github.dalexhu.tzdb.modification` carrying the same information.
- Nothing else. No file of the base image is removed or altered other than `tzdb.dat`, and its
  license and notice files are left as they are.

The image names produced by `build.sh` contain no vendor names; the base image is recorded in
the `NOTICE` file, the labels and the repository description.

---

## 中文

JDK **从不**读 `/usr/share/zoneinfo` 的时区规则,它自带一份编译好的副本在
`$JAVA_HOME/lib/tzdb.dat`。所以在容器里 `apt-get install tzdata` 对 JVM 毫无影响。
当某个时区规则变了、而还没有任何 JDK 发布版本带上新数据时,修容器的唯一办法就是
**替换这一个文件**。

本仓库用 **OpenJDK 自己的构建工具和时区数据**在 Dockerfile 里做这件事 ——
不需要 Oracle 账号,也不手工改二进制。这是我自己机器上在用的做法;
是否适合你的环境,请你自己判断。

### 这个仓库为什么存在

我人在 `America/Edmonton`。从 IANA tzdata **2026c** 起,Alberta 不再执行秋季回拨:
本地时间 `2026-11-01 02:00` 时区由 MDT 变为 CST,DST 标志和缩写变了,但偏移仍是
**-06:00**,**表不动**。仍停留在 2026b 或更早的主机与运行时,会照旧回拨到 MST -07:00。

写这个仓库时,**还没有任何已发布的 JDK 带 2026c** —— 我实测过的最新版本
(Temurin/Corretto 21.0.12、25.0.4、26.0.2)全都是 2026b,而 OpenJDK 上游其实早已合入 2026c。
又因为 JDK 只读自己的 `tzdb.dat`、完全不看操作系统那份,所以升级主机或容器里的
`tzdata` 包对 JVM 毫无作用。

于是我做了这个东西:验证这个行为、搞清楚 JDK 到底怎么加载时区规则、顺便让自己的容器
显示正确的时间。**这是个人自用的小工具**,只是觉得值得记录下来 —— 不是产品,不是服务,
也不代表我为任何人维护它。下面写的是本仓库做了什么,以及我在自己机器上观察到的现象。

### 两种用法

**当作替换的基础镜像** —— 用于你自己构建的镜像:

```bash
./build.sh                                   # 跑完整默认矩阵
./build.sh eclipse-temurin:21-jre            # 只构建一个
```

```dockerfile
FROM dalex-jdk-tz:temurin-21-jre
COPY target/app.jar /app.jar
ENTRYPOINT ["java","-jar","/app.jar"]
```

**当作叠加在已有镜像上的一层补丁** —— 用于你没法重建的镜像:

```bash
docker build -t example-app:1.2-tz \
  --build-arg BASE_IMAGE=example-app:1.2 \
  --build-arg FINAL_USER=appuser .
```

`build.sh` 会自己用 `docker inspect` 读出基础镜像的用户,所以以非 root 用户运行的镜像
补完之后仍以原来的用户运行。

### 默认矩阵

`eclipse-temurin` 17/21/25(jre + jdk)、`amazoncorretto` 17/21/25 + `21-alpine`。
glibc 与 musl 基础镜像、以及第三方应用镜像均已实测通过。

> 矩阵里没有 `openjdk` 官方镜像:它的稳定 tag 已从 Docker Hub 撤下(只剩 `28-ea-*`),
> `eclipse-temurin` 是官方指定的继任者,覆盖同样的构建。

### 构建自带校验

最后一个 stage 会运行补好的镜像,以下任一条不满足就**让构建失败**:

- tzdb 版本不是编译进去的那个,
- `<zone>` 在 `<year>-11-15` 的偏移不是预期值,
- 时区 ID 数量下降,
- `SystemV/MST7` 解析不出来。

任一项不通过,构建以非零状态结束,不会产出 tag。该检查覆盖的是本仓库替换的那一个文件,
不涉及镜像的其余部分。通过时的输出:

```
tzdb=2026c zones=604 America/Edmonton jan=-07:00 oct=-06:00 nov=-06:00 (no autumn change)
VERIFY OK
```

只想单独把产物拿出来(不补任何镜像):

```bash
docker build -f Dockerfile.tzdb --target export -o out .
# -> out/tzdb.dat, out/tzdata.version, out/TzVerify.class
```

这个 `tzdb.dat` 同样可以直接丢进裸机上的 JDK(先备份原文件;JVM 只在启动时读一次,
换完必须重启进程)。

### 原理与三个坑

复刻 OpenJDK 构建时自己做的事:

1. 取 `build/tools/tzdb/{TzdbZoneRulesCompiler,TzdbZoneRulesProvider}.java`。
2. 取 `java.time.zone/{ZoneRules,ZoneOffsetTransition,ZoneOffsetTransitionRule,Ser}.java`,
   把包名改成 `build.tools.tzdb` —— 就是 OpenJDK 的 `CopyInterimTZDB.gmk` 干的事。
   **少了这步根本编译不过**:29 个错误,全是 `cannot find symbol: ZoneRules`。
3. 编译,然后对 `src/java.base/share/data/tzdata` 运行编译器。

另外两个坑:

- 编译器用正则 `tzdata(?<ver>[0-9]{4}[A-z])` 匹配版本,所以 `VERSION` 文件内容必须是
  `tzdata2026c` 这种完整形式。IANA tarball 里的 `version` 只有 `2026c`,直接喂进去会
  **静默 exit 1**,什么提示都没有。
- 用 IANA tarball 而不是 OpenJDK 的数据目录,会**静默丢掉 13 个时区 ID** ——
  全部 `SystemV/*` 别名 —— 因为它们在 OpenJDK 独有的 `jdk11_backward` 文件里。
  代码里任何 `ZoneId.of("SystemV/MST7")` 都会开始抛 `ZoneRulesException`。
  校验器专门检查这一条。

### 里面都有什么

各项目在自己文件中声明的许可:

| 层 | 声明的许可 |
|---|---|
| IANA 时区数据库 | 数据文件里声明为公有领域 |
| OpenJDK 版的同一份数据、`jdk11_backward`、tzdb 编译器 | GPLv2 + Classpath Exception |
| `eclipse-temurin` / `amazoncorretto` 基础镜像 | GPLv2 + Classpath Exception,外加基础 OS 各包自身许可 |
| 本仓库自己的文件 | MIT |

**本仓库自身不包含上述任何一项** —— 里面只有 Dockerfile、构建脚本和一个校验类,
OpenJDK 源码与时区数据都是构建时从上游下载的。

构建产出的镜像里包含什么:

- `/NOTICE-tzdb.txt`:写明该镜像是经过修改的构建、替换了哪个文件、换成了什么,
  以及被替换的原文件以 `tzdb.dat.orig` 保留在原处。
- OCI 标签 `org.opencontainers.image.source`、`io.github.dalexhu.tzdb.patched`、
  `io.github.dalexhu.tzdb.modification`,承载同样的信息。
- 除此之外没有别的。除 `tzdb.dat` 外,基础镜像的任何文件都未被删除或改动,
  其许可与声明文件保持原样。

`build.sh` 产出的镜像名中不含任何厂商名称;基础镜像记录在 `NOTICE` 文件、标签
和仓库描述中。

---

## Disclaimer / 免责声明

**English.** This is a personal utility, shared in case it is useful to someone else, and
provided **as is, without warranty of any kind, express or implied**. The author accepts no
liability for any loss or damage arising from its use.

It is not affiliated with, endorsed by, sponsored by or supported by Oracle, the Eclipse
Foundation, Amazon, IANA, or the maintainers of any base image it touches. All product names
and trademarks mentioned belong to their respective owners and are used only to describe which
software the recipe operates on.

It replaces a file inside a JDK. The result is a **modified, unofficial build that is not
certified against the Java SE TCK**, and no compatibility certification of a base image
carries over to it. The build-time checks cover the one change this recipe makes; they say
nothing about the rest of the image, and they are not a substitute for testing in your own
environment.

Nothing in this repository is legal advice, and nothing in it states what anyone may or may
not do with software belonging to someone else. The author makes no representation about what
obligations apply to any use or distribution of what it builds.

**中文。** 这是个人自用工具,公开出来只是想着或许对别人也有用,
**按原样提供,不附带任何明示或默示的担保**。作者对因使用本项目而产生的任何损失或损害
不承担责任。

本项目与 Oracle、Eclipse 基金会、Amazon、IANA 以及任何被它处理的基础镜像的维护方
**均无关联,未获其背书、赞助或支持**。文中提及的所有产品名称与商标均归其各自所有者所有,
在此仅用于说明本配方所操作的软件对象。

它替换的是 JDK 内部的一个文件。产物是**经过修改的非官方构建,未通过 Java SE TCK 认证**,
基础镜像的任何兼容性认证都不会传递到它上面。构建时自带的校验只覆盖本配方所做的这一处改动,
不说明镜像其余部分的任何情况,也不能替代你在自己环境里的测试。

本仓库中的任何内容均不构成法律意见,也未就任何人可以或不可以对他人的软件做什么作出说明。
对于使用或分发本项目所构建之产物适用何种义务,作者不作任何陈述或保证。

## License

MIT for this repository's own files. See the section above for what the built images carry.
