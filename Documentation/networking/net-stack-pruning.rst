.. SPDX-License-Identifier: GPL-2.0

==============================================
Quick reference for pruning net/ protocol stacks
==============================================

This note inventories the protocol stacks under ``net/`` so you can disable
unused pieces when size or attack surface matters. It is based on
``net/Makefile``; always validate choices against your hardware and workload.

Core pieces usually kept
------------------------

- ``core/``, ``sched/``, ``netlink/``, ``bpf/``, ``ethtool/``: common
  infrastructure used by most drivers and tooling.
- IPv4/IPv6 stack (``CONFIG_INET``, ``ipv4/``, ``ipv6/``) and UNIX sockets
  (``CONFIG_UNIX``).
- ``CONFIG_PACKET`` (``packet/``) for tcpdump and similar capture tools.

Stacks commonly trimmed when unused
-----------------------------------

- Legacy or niche wired protocols: AppleTalk/AX.25/LAPB/NET/ROM/ROSE/X.25
  (``CONFIG_ATALK``, ``CONFIG_AX25``, ``CONFIG_LAPB``, ``CONFIG_NETROM``,
  ``CONFIG_ROSE``, ``CONFIG_X25``), HSR/NSH/MPLS (``CONFIG_HSR``,
  ``CONFIG_NET_NSH``, ``CONFIG_MPLS``), Batman-adv mesh
  (``CONFIG_BATMAN_ADV``).
- Wireless/short-range: Bluetooth (``CONFIG_BT``), IEEE 802.15.4 /
  6LoWPAN (``CONFIG_IEEE802154``, ``CONFIG_6LOWPAN``, ``CONFIG_MAC802154``),
  NFC (``CONFIG_NFC``), QRTR (``CONFIG_QRTR``), RFKill (``CONFIG_RFKILL``)
  when no matching radios are present.
- Wi-Fi stack: ``wireless/`` and ``mac80211/`` (``CONFIG_WIRELESS``,
  ``CONFIG_MAC80211``) in wired-only systems.
- Industrial/management links: CAN (``CONFIG_CAN``), MCTP (``CONFIG_MCTP``),
  NCSI (``CONFIG_NET_NCSI``), Phonet/CAIF (``CONFIG_PHONET``,
  ``CONFIG_CAIF``), IUCV/SMC (``CONFIG_IUCV``, ``CONFIG_SMC``) when the
  corresponding buses are absent.
- Transport extensions: SCTP/RDS/TIPC/MPTCP (``CONFIG_IP_SCTP``,
  ``CONFIG_RDS``, ``CONFIG_TIPC``, ``CONFIG_MPTCP``) if only TCP/UDP is
  required.
- Access/tunneling: ATM/L2TP (``CONFIG_ATM``, ``CONFIG_L2TP``) when those
  access technologies or VPNs are not used.
- Storage and distributed channels: SunRPC/NFS, 9p, Ceph, RXRPC, VMware
  vSockets (``CONFIG_SUNRPC``, ``CONFIG_NET_9P``, ``CONFIG_CEPH_LIB``,
  ``CONFIG_AF_RXRPC``, ``CONFIG_VSOCKETS``) when the related file systems
  or hypervisors are not needed.
- Switching/forwarding features: bridge, Open vSwitch, DSA/Switchdev, L3
  master, DCB (``CONFIG_BRIDGE``, ``CONFIG_OPENVSWITCH``, ``CONFIG_DSA``,
  ``CONFIG_NET_SWITCHDEV``, ``CONFIG_NET_L3_MASTER_DEV``, ``CONFIG_DCB``)
  in hosts that do not perform switching.
- Debug/telemetry helpers: NetLabel, devlink, psample, IFE
  (``CONFIG_NETLABEL``, ``CONFIG_NET_DEVLINK``, ``CONFIG_PSAMPLE``,
  ``CONFIG_NET_IFE``) when policy labels or sampling are unnecessary.

How to use
----------

Look up these Kconfig symbols in ``make menuconfig``/``make nconfig`` and
disable stacks you do not need. Review the corresponding ``Kconfig`` files
under each subdirectory when uncertain about dependencies.
