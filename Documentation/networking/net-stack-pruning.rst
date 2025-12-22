.. SPDX-License-Identifier: GPL-2.0

====================================
net 目录协议栈裁剪快速参考
====================================

基于 ``net/Makefile`` 的子目录梳理，列出常见可选协议栈及其典型关闭场景，方便在裁剪内核时确认可以去掉的内容。实际取舍仍需依据业务与硬件需求。

核心通常保留的组件
------------------

- ``core/``, ``sched/``, ``netlink/``, ``bpf/``, ``ethtool/``：网络核心框架与工具接口。
- IPv4/IPv6 栈（``CONFIG_INET``、``ipv4/``、``ipv6/``）与 UNIX 套接字（``CONFIG_UNIX``）。
- 抓包/用户态工具常用的 ``CONFIG_PACKET``（``packet/``）。

常见可裁剪协议栈
----------------

按功能或场景聚合，若系统未使用对应硬件或协议，可在配置中关闭相关选项（括号内为主要 Kconfig 开关/目录）：

- 旧式或专用有线协议：AppleTalk/AX.25/LAPB/NET/ROM/ROSE/X.25（``CONFIG_ATALK``、``CONFIG_AX25``、``CONFIG_LAPB``、``CONFIG_NETROM``、``CONFIG_ROSE``、``CONFIG_X25``）、HSR/NSH/MPLS（``CONFIG_HSR``、``CONFIG_NET_NSH``、``CONFIG_MPLS``）、Batman-adv Mesh（``CONFIG_BATMAN_ADV``）。
- 近距离/无线：Bluetooth（``CONFIG_BT``）、IEEE 802.15.4/6LoWPAN（``CONFIG_IEEE802154``、``CONFIG_6LOWPAN``、``CONFIG_MAC802154``）、NFC（``CONFIG_NFC``）、QRTR（``CONFIG_QRTR``）、RFKill（``CONFIG_RFKILL``）在无对应硬件或协议时关闭。
- Wi-Fi 协议栈：``wireless/``、``mac80211/`` 及其依赖（``CONFIG_WIRELESS``、``CONFIG_MAC80211``）在纯有线或无 Wi-Fi 设备场景可裁剪。
- 工业/车载/管理链路：CAN（``CONFIG_CAN``）、MCTP（``CONFIG_MCTP``）、NCSI（``CONFIG_NET_NCSI``）、Phonet/CAIF（``CONFIG_PHONET``、``CONFIG_CAIF``）、IUCV/SMC（面向 s390 或 RoCE，``CONFIG_IUCV``、``CONFIG_SMC``）。
- 传输层扩展：SCTP、RDS、TIPC、MPTCP（``CONFIG_IP_SCTP``、``CONFIG_RDS``、``CONFIG_TIPC``、``CONFIG_MPTCP``）在仅使用 TCP/UDP 时可移除。
- 接入/隧道：ATM、L2TP（``CONFIG_ATM``、``CONFIG_L2TP``）在未使用对应 VPN/接入方式时关闭。
- 存储与分布式通信：SunRPC/NFS、9p、Ceph、RXRPC、VMware vSockets（``CONFIG_SUNRPC``、``CONFIG_NET_9P``、``CONFIG_CEPH_LIB``、``CONFIG_AF_RXRPC``、``CONFIG_VSOCKETS``）在未用相关文件系统或虚拟化通道时关闭。
- 交换/转发特性：Bridge、Open vSwitch、DSA/Switchdev、L3 master（``CONFIG_BRIDGE``、``CONFIG_OPENVSWITCH``、``CONFIG_DSA``、``CONFIG_NET_SWITCHDEV``、``CONFIG_NET_L3_MASTER_DEV``）、DCB（``CONFIG_DCB``）在无二层交换或高级数据中心需求时可裁剪。
- 其他辅助模块：NetLabel（``CONFIG_NETLABEL``）、devlink（``CONFIG_NET_DEVLINK``）、psample/IFE（``CONFIG_PSAMPLE``、``CONFIG_NET_IFE``）在不需要策略标签、驱动调试或抽样镜像时关闭。

使用方法
--------

在 ``make menuconfig`` / ``make nconfig`` 中搜索上述 Kconfig 选项，逐项禁用无需求的协议栈即可缩减镜像与攻击面。若对依赖关系不确定，可先查看 ``net/Makefile`` 与对应子目录下的 ``Kconfig`` 描述。
