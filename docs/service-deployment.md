# Linux 服务部署与管理

本文说明如何在使用 systemd 的 Linux 电脑上安装、配置和管理 BitSrunLoginGo。
安装过程不要求电脑预先安装 Go，也不会执行登出操作。

## 一键安装

进入项目目录后执行：

```shell
./scripts/install.sh
```

脚本默认读取项目根目录的 `Config.yaml`，将其安全复制到
`/etc/bitsrun/Config.yaml`，然后安装并启动服务。配置文件权限会设置为
`root:bitsrun`、`0640`。

也可以明确指定配置文件：

```shell
./scripts/install.sh --config /path/to/Config.yaml
```

电脑无需预装 Go。脚本会下载临时 Go 工具链，并根据实际连通情况选择 Go 下载源和
模块代理；编译完成后自动删除临时工具链。也可以安装已经准备好的二进制：

```shell
./scripts/install.sh --binary /path/to/bitsrun
```

如果安装时没有可用配置，脚本会安装
`/etc/bitsrun/Config.yaml` 示例文件，但不会立即启动登录服务。

## 修改配置

推荐使用管理命令编辑安装后的配置：

```shell
bitsrunctl config
```

也可以直接编辑：

```shell
sudo vi /etc/bitsrun/Config.yaml
```

登录入口为 `http://10.0.0.55` 时，最重要的配置如下：

```yaml
form:
  domain: 10.0.0.55 # 不要填写 http://，也不要添加路径
  username: "你的校园网账号"
  user_type: "" # 账号没有运营商后缀时留空
  password: "你的校园网密码"

meta:
  acid: "8" # 自动探测失败时使用的回退值

settings:
  guardian:
    enable: true
    duration: 300 # 每 300 秒检查一次在线状态
```

服务启动时始终启用 `--auto-acid`。程序会从入口 URL、HTTP 跳转、最终页面、隐藏表单、
JavaScript 变量和页面链接中自动寻找 `ac_id`；没有找到时才使用 `meta.acid`。

完整配置和逐项注释可参考
[deploy/Config.example.yaml](../deploy/Config.example.yaml)。

## 启动和停止

启动服务：

```shell
bitsrunctl start
```

停止服务：

```shell
bitsrunctl stop
```

手动重启并重新读取配置：

```shell
bitsrunctl restart
```

服务已经设置为开机自动启动。应用内部会按照 `settings.guardian.duration` 定时检测
在线状态；systemd 会在程序异常退出后自动恢复，并且每运行 24 小时重新创建一次进程。

## 查看状态和日志

查看当前运行状态：

```shell
bitsrunctl status
```

持续查看实时日志：

```shell
bitsrunctl logs
```

只查看最近 100 行日志：

```shell
sudo journalctl -u bitsrun.service -n 100 --no-pager
```

状态为 `active (running)` 表示服务正在运行。日志中出现“已登录”或“登录成功”表示
认证正常。

## 配置如何生效

systemd 会监测 `/etc/bitsrun/Config.yaml`。服务正在运行时，配置文件发生变化会自动
触发重启并读取新配置。使用 `bitsrunctl config` 编辑时也会在保存后主动重启服务。

如果服务此前被手动停止，直接修改文件不会将其自动启动；修改完成后执行：

```shell
bitsrunctl start
```

## 常用命令速查

```shell
bitsrunctl status   # 查看服务状态
bitsrunctl start    # 启动服务
bitsrunctl stop     # 停止服务
bitsrunctl restart  # 重启并重新读取配置
bitsrunctl logs     # 持续查看日志
bitsrunctl config   # 编辑配置并重启服务
```

如果命令报告权限不足，请使用具有 `sudo` 权限的账号操作。
