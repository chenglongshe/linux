.. SPDX-License-Identifier: GPL-2.0

.. include:: ../disclaimer-zh_CN.rst

:Original: Documentation/gpu/drm-internals.rst

:翻译:

 佘成龙 Chenglong She

:校译:

============================================================
DRM子系统初始化流程图与场景使用代码流程图
============================================================

本文档从抽象思维的角度梳理Linux DRM（Direct Rendering Manager）子系统的
初始化流程和关键使用场景的代码流程，帮助开发者建立对DRM子系统运行机制的
全局认知。

.. contents:: 目录
   :local:
   :depth: 3

总体架构概览
============

DRM子系统的生命周期可以划分为三个宏观阶段：

1. **系统级初始化** ——DRM核心基础设施的建立
2. **设备级初始化** ——具体GPU设备的注册与配置
3. **运行时使用** ——用户空间通过ioctl/mmap与设备交互

用抽象思维来看，这三个阶段对应了"搭建舞台→布置道具→开始演出"的过程。DRM核心
提供舞台（字符设备、sysfs类、debugfs），驱动程序布置道具（设备对象、KMS管线、
GEM管理器），用户空间在舞台上演出（打开设备、分配缓冲区、设置显示模式、翻页）。

初始化流程图
============

阶段一：DRM核心初始化（module_init）
-------------------------------------

DRM核心作为内核模块，在系统启动时通过 ``module_init`` 完成基础设施初始化。

**入口函数** ： ``drivers/gpu/drm/drm_drv.c`` 第1236行 ``drm_core_init()``

**流程图** ::

    module_init(drm_core_init)
        │
        ├── drm_connector_ida_init()
        │       └── 初始化连接器ID分配器
        │
        ├── drm_memcpy_init_early()
        │       └── 初始化优化的内存拷贝例程
        │
        ├── drm_sysfs_init()
        │       └── 创建 /sys/class/drm/ 类
        │           （所有DRM设备节点的父类）
        │
        ├── drm_debugfs_init_root()
        │       └── 创建 /sys/kernel/debug/dri/ 目录
        │
        ├── register_chrdev(DRM_MAJOR, "drm", &drm_stub_fops)
        │       └── 注册主设备号226的字符设备
        │           drm_stub_fops提供open/ioctl入口
        │
        ├── accel_core_init()
        │       └── 初始化计算加速器子系统
        │
        ├── drm_panic_init()
        │       └── 初始化DRM panic显示支持
        │
        ├── drm_privacy_screen_lookup_init()
        │       └── 初始化隐私屏幕查找表
        │
        └── drm_core_init_complete = true
                └── 设置完成标志
                    （驱动注册的前置条件门）

**抽象理解** ：这一阶段是"搭建剧场"——创建sysfs类（售票处）、注册字符设备
（剧场大门）、准备debugfs（后台监控室）。注意 ``drm_core_init_complete``
标志的设置，它是后续所有驱动注册的门控条件——剧场未建好，演员不能入场。

阶段二：驱动设备分配（devm_drm_dev_alloc）
---------------------------------------------

当具体的GPU驱动模块加载时（如i915、amdgpu、vkms等），首先需要分配并初始化
DRM设备对象。现代驱动推荐使用设备托管（device-managed）的分配方式。

**核心函数** ：

- ``include/drm/drm_drv.h`` 中的 ``devm_drm_dev_alloc()`` 宏
- ``drivers/gpu/drm/drm_drv.c`` 第817行 ``__devm_drm_dev_alloc()``
- ``drivers/gpu/drm/drm_drv.c`` 第701行 ``drm_dev_init()``

**流程图** ::

    驱动probe函数
        │
        └── devm_drm_dev_alloc(parent, driver, type, member)
                │
                ├── kzalloc(sizeof(驱动私有结构体))
                │       └── 分配包含drm_device的驱动结构体
                │
                ├── devm_drm_dev_init(parent, drm, driver)
                │       │
                │       └── drm_dev_init(drm, driver, parent)
                │               │
                │               ├── 检查 drm_core_init_complete 门控
                │               │
                │               ├── kref_init(&dev->ref)
                │               │       └── 初始化引用计数 = 1
                │               │
                │               ├── dev->dev = get_device(parent)
                │               │       └── 绑定父设备（PCI/平台设备）
                │               │
                │               ├── dev->driver = driver
                │               │       └── 绑定驱动回调表
                │               │
                │               ├── 初始化核心数据结构：
                │               │   ├── INIT_LIST_HEAD(&dev->filelist)
                │               │   ├── INIT_LIST_HEAD(&dev->clientlist)
                │               │   ├── INIT_LIST_HEAD(&dev->vblank_event_list)
                │               │   ├── spin_lock_init(&dev->event_lock)
                │               │   ├── mutex_init(&dev->filelist_mutex)
                │               │   └── mutex_init(&dev->master_mutex)
                │               │
                │               ├── drm_fs_inode_new()
                │               │       └── 创建匿名inode
                │               │           用于共享地址空间
                │               │
                │               ├── drm_minor_alloc(dev, DRM_MINOR_RENDER)
                │               │       ├── xa_alloc() 分配minor编号
                │               │       ├── drm_sysfs_minor_alloc()
                │               │       │       └── 准备sysfs设备
                │               │       └── 设置 dev->render = minor
                │               │
                │               ├── drm_minor_alloc(dev, DRM_MINOR_PRIMARY)
                │               │       └── 设置 dev->primary = minor
                │               │
                │               ├── drm_gem_init(dev) [如果 DRIVER_GEM]
                │               │       ├── mutex_init(&dev->object_name_lock)
                │               │       ├── idr_init_base(&dev->object_name_idr, 1)
                │               │       └── drm_vma_offset_manager_init()
                │               │               └── 创建VMA偏移量管理器
                │               │                   （GEM mmap的核心组件）
                │               │
                │               └── drm_debugfs_dev_init(dev)
                │                       └── 初始化设备级debugfs
                │
                └── drmm_add_final_kfree(drm, container)
                        └── 注册最终释放回调
                            确保设备结构体在最后被释放

**抽象理解** ：这一阶段是"布置舞台"——分配演出场地（设备对象），安装灯光音响
（minor设备节点），准备道具仓库（GEM管理器）。 ``devm_`` 前缀意味着"设备托管"，
即道具在演员离场时自动清理，无需手动回收。

阶段三：KMS模式配置初始化（drmm_mode_config_init）
----------------------------------------------------

对于支持显示输出的驱动（设置了 ``DRIVER_MODESET`` 标志），需要初始化KMS
（Kernel Mode Setting）管线。

**核心函数** ： ``drivers/gpu/drm/drm_mode_config.c`` 第429行
``drmm_mode_config_init()``

**流程图** ::

    驱动probe函数（devm_drm_dev_alloc之后）
        │
        └── drmm_mode_config_init(dev)
                │
                ├── INIT_LIST_HEAD(&dev->mode_config.fb_list)
                │       └── 帧缓冲链表
                │
                ├── INIT_LIST_HEAD(&dev->mode_config.crtc_list)
                │       └── CRTC链表
                │
                ├── INIT_LIST_HEAD(&dev->mode_config.connector_list)
                │       └── 连接器链表
                │
                ├── INIT_LIST_HEAD(&dev->mode_config.encoder_list)
                │       └── 编码器链表
                │
                ├── INIT_LIST_HEAD(&dev->mode_config.plane_list)
                │       └── 平面链表
                │
                ├── idr_init_base(&dev->mode_config.object_idr, 1)
                │       └── KMS对象ID分配器
                │
                ├── idr_init_base(&dev->mode_config.tile_idr, 1)
                │       └── 瓦片ID分配器
                │
                ├── drm_mode_create_standard_properties(dev)
                │       └── 创建标准属性
                │           （rotation、zpos、alpha等）
                │
                └── drmm_add_action_or_reset(release回调)
                        └── 注册托管清理

    接下来驱动创建KMS对象：
        │
        ├── drm_crtc_init_with_planes()      ── 初始化CRTC
        ├── drm_universal_plane_init()         ── 初始化平面
        ├── drm_encoder_init()                 ── 初始化编码器
        ├── drm_connector_init()               ── 初始化连接器
        └── drm_mode_config_reset()            ── 重置为默认状态

**抽象理解** ：KMS管线是一个"显示管道工厂"——CRTC（显示控制器）是管道入口，
Plane（平面）是混合不同图层的混合器，Encoder（编码器）将数字信号转换为
特定协议（HDMI/DP/LVDS），Connector（连接器）是物理输出端口。
``drmm_mode_config_init`` 创建这些管道的容器和管理结构。

阶段四：设备注册（drm_dev_register）
--------------------------------------

设备完全配置好后，通过 ``drm_dev_register()`` 将其注册到系统中，使其对
用户空间可见。

**核心函数** ： ``drivers/gpu/drm/drm_drv.c`` 第1056行 ``drm_dev_register()``

**流程图** ::

    驱动probe函数（所有初始化完成后）
        │
        └── drm_dev_register(dev, flags)
                │
                ├── drm_mode_config_validate(dev)
                │       └── 验证KMS配置完整性
                │           （检查CRTC/Plane/Encoder/Connector关联）
                │
                ├── drm_debugfs_dev_register(dev)
                │       └── 注册debugfs目录
                │           /sys/kernel/debug/dri/N/
                │
                ├── drm_minor_register(dev, DRM_MINOR_RENDER)
                │       ├── device_add(minor->kdev)
                │       │       └── 创建 /dev/dri/renderDN
                │       └── xa_store() 存入XArray
                │           └── 使 drm_open() 可查找到设备
                │
                ├── drm_minor_register(dev, DRM_MINOR_PRIMARY)
                │       └── 创建 /dev/dri/cardN
                │
                ├── create_compat_control_link(dev)
                │       └── 创建兼容性控制节点链接
                │
                ├── dev->registered = true
                │       └── 标记设备已注册
                │
                ├── drm_modeset_register_all(dev) [如果 DRIVER_MODESET]
                │       ├── drm_connector_register_all()
                │       │       └── 注册所有连接器到sysfs
                │       └── drm_dp_aux_register_devnode_backcompat()
                │               └── DP AUX设备兼容注册
                │
                ├── drm_panic_register(dev)
                │       └── 注册panic显示处理
                │
                └── DRM_INFO("Initialized %s for %s on minor %d\n")
                        └── 打印初始化完成信息

**抽象理解** ：这一阶段是"开门迎客"——在 ``/dev/dri/`` 下创建设备节点（开门），
在sysfs中注册连接器信息（贴海报），设置registered标志（点亮"营业中"灯牌）。
只有在这一步完成后，用户空间应用程序才能发现并访问GPU设备。

完整初始化时序总结
-------------------

将上述四个阶段串联，完整的DRM初始化时序为::

    ┌─────────────────────────────────────────────────────────────┐
    │ 系统启动阶段                                                │
    │                                                             │
    │  module_init(drm_core_init)                                 │
    │      ├── drm_sysfs_init()           创建DRM设备类           │
    │      ├── register_chrdev(226)        注册字符设备            │
    │      └── drm_core_init_complete=true 开放驱动注册            │
    └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ 驱动加载阶段（以VKMS为例）                                   │
    │                                                             │
    │  vkms_init() / 平台驱动probe()                              │
    │      │                                                      │
    │      ├── devm_drm_dev_alloc()        分配设备对象            │
    │      │       ├── drm_dev_init()      初始化核心字段          │
    │      │       │   ├── drm_minor_alloc()  分配minor           │
    │      │       │   └── drm_gem_init()     GEM初始化           │
    │      │       └── devm绑定生命周期                            │
    │      │                                                      │
    │      ├── drmm_mode_config_init()     KMS管线容器             │
    │      │                                                      │
    │      ├── 创建KMS对象：                                      │
    │      │   ├── CRTC + Planes                                  │
    │      │   ├── Encoders                                       │
    │      │   └── Connectors                                     │
    │      │                                                      │
    │      └── drm_dev_register()          对外发布设备            │
    │              ├── drm_minor_register() 创建/dev/dri/节点      │
    │              └── drm_modeset_register_all() 注册KMS          │
    └─────────────────────────────────────────────────────────────┘
                              │
                              ▼
    ┌─────────────────────────────────────────────────────────────┐
    │ 运行时阶段                                                  │
    │                                                             │
    │  用户空间应用程序通过 /dev/dri/cardN 或 renderDN 访问设备    │
    └─────────────────────────────────────────────────────────────┘

场景使用代码流程图
==================

以下梳理DRM子系统在运行时的关键使用场景，每个场景给出完整的代码调用流程。

场景一：打开DRM设备
---------------------

**触发** ：用户空间调用 ``open("/dev/dri/card0", O_RDWR)``

**核心文件** ： ``drivers/gpu/drm/drm_file.c``

**流程图** ::

    用户空间: open("/dev/dri/card0")
        │
        └── VFS → drm_stub_fops.open
                │
                └── drm_open(inode, filp)           [drm_file.c:369]
                        │
                        ├── drm_minor_acquire(&drm_minors_xa, iminor)
                        │       └── 从XArray获取minor对象
                        │           （通过inode次设备号查找）
                        │
                        ├── minor->dev → 获取 drm_device
                        │
                        ├── atomic_fetch_inc(&dev->open_count)
                        │       └── 增加设备打开计数
                        │
                        ├── filp->f_mapping = dev->anon_inode->i_mapping
                        │       └── 共享匿名地址空间
                        │           （多进程mmap同一设备时共享页缓存）
                        │
                        └── drm_open_helper(filp, minor)  [drm_file.c:316]
                                │
                                ├── 验证：O_EXCL被拒绝、CPU有效性检查
                                │
                                ├── drm_file_alloc(minor)   [drm_file.c:132]
                                │       │
                                │       ├── kzalloc(struct drm_file)
                                │       │
                                │       ├── file->client_id = 原子递增ID
                                │       ├── file->pid = 当前进程组ID
                                │       ├── file->authenticated = CAP_SYS_ADMIN?
                                │       │
                                │       ├── 初始化列表和锁：
                                │       │   ├── fbs（帧缓冲列表）
                                │       │   ├── pending_event_list
                                │       │   ├── event_list
                                │       │   └── event_wait（事件等待队列）
                                │       │
                                │       ├── file->event_space = 4096
                                │       │       └── 4KB事件缓冲区
                                │       │
                                │       ├── drm_gem_open(dev, file) [如果DRIVER_GEM]
                                │       │       └── idr_init_base(&file->object_idr, 1)
                                │       │               └── 文件私有的GEM句柄→对象映射
                                │       │
                                │       ├── drm_syncobj_open(file) [如果DRIVER_SYNCOBJ]
                                │       │       └── 初始化同步对象IDR
                                │       │
                                │       ├── drm_prime_init_file_private()
                                │       │       └── 初始化PRIME导入/导出缓存
                                │       │
                                │       └── driver->open(dev, file) [驱动回调]
                                │               └── 驱动特定的文件初始化
                                │
                                ├── drm_master_open(priv) [如果是primary client]
                                │       └── 建立DRM Master关系
                                │
                                ├── filp->private_data = priv
                                │       └── 将drm_file绑定到VFS文件
                                │
                                └── list_add(&priv->lhead, &dev->filelist)
                                        └── 加入设备的文件列表

**抽象理解** ：打开DRM设备就像"领取入场券"。每个 ``drm_file`` 是一张独立的
入场券，持有者拥有自己的GEM句柄空间、事件缓冲区、PRIME缓存。Primary client
还可能成为"场馆管理员"（DRM Master），拥有模式设置的特权。

场景二：创建GEM缓冲区对象
---------------------------

**触发** ：用户空间通过 ``DRM_IOCTL_MODE_CREATE_DUMB`` 创建dumb buffer，
或驱动特定ioctl创建GPU缓冲区

**核心文件** ：

- ``drivers/gpu/drm/drm_dumb_buffers.c`` （dumb buffer路径）
- ``drivers/gpu/drm/drm_gem.c`` （GEM核心）

**流程图（dumb buffer路径）** ::

    用户空间: ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &args)
        │
        └── drm_ioctl() → drm_mode_create_dumb_ioctl()
                │
                └── driver->dumb_create(file_priv, dev, args)
                        │
                        ├── 计算 size = pitch × height
                        │       （驱动可能对齐pitch）
                        │
                        ├── 分配GEM对象（驱动特定）：
                        │   ├── drm_gem_object_init(dev, obj, size)
                        │   │       └── 创建shmem后备存储
                        │   │           obj->filp = shmem_file_setup()
                        │   │
                        │   └── 或 drm_gem_private_object_init()
                        │           └── 驱动自管理内存后端
                        │
                        ├── drm_gem_handle_create(file_priv, obj, &handle)
                        │       │
                        │       ├── idr_alloc(&file_priv->object_idr, obj)
                        │       │       └── 在文件私有IDR中分配句柄
                        │       │
                        │       ├── drm_gem_object_get(obj)
                        │       │       └── 增加引用计数
                        │       │
                        │       └── driver->gem_open_object(obj, file_priv)
                        │               └── 驱动回调（可选）
                        │
                        └── 返回 args->handle, args->pitch, args->size

**抽象理解** ：创建GEM对象就像"向仓库申请存储空间"。仓库管理员（GEM核心）
分配存储区域（shmem页或驱动私有内存），并给申请者一张取物票（handle）。
每个文件有自己的取物票编号系统，同一物品可以有不同编号的票。

场景三：映射GEM对象到用户空间
-------------------------------

**触发** ：用户空间先通过ioctl获取mmap偏移量，再调用mmap()

**核心文件** ：

- ``drivers/gpu/drm/drm_gem.c``
- ``drivers/gpu/drm/drm_dumb_buffers.c``

**流程图** ::

    步骤1：获取mmap偏移量
    ──────────────────────

    用户空间: ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map)
        │
        └── drm_mode_mmap_dumb_ioctl()
                │
                └── driver->dumb_map_offset() 或 drm_gem_dumb_map_offset()
                        │
                        ├── drm_gem_object_lookup(file_priv, handle)
                        │       └── 从IDR查找GEM对象
                        │
                        ├── drm_gem_create_mmap_offset(obj)
                        │       │
                        │       └── drm_vma_offset_add(manager, &obj->vma_node, pages)
                        │               └── 在VMA偏移量管理器中分配
                        │                   伪偏移量（红黑树）
                        │
                        └── *offset = drm_vma_node_offset_addr(&obj->vma_node)
                                └── 返回伪偏移量给用户空间

    步骤2：执行mmap
    ────────────────

    用户空间: mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, offset)
        │
        └── VFS → drm_gem_mmap(filp, vma)    [drm_gem.c:1342]
                │
                ├── drm_gem_object_lookup_at_offset(filp, pgoff, pages)
                │       │
                │       ├── drm_vma_offset_exact_lookup_locked()
                │       │       └── 通过伪偏移量查找GEM对象的vma_node
                │       │
                │       ├── drm_vma_node_is_allowed()
                │       │       └── 验证文件是否有权访问此对象
                │       │
                │       └── drm_gem_object_get(obj)
                │               └── 增加引用计数
                │
                └── drm_gem_mmap_obj(obj, obj_size, vma)  [drm_gem.c:1188]
                        │
                        ├── vma->vm_private_data = obj
                        │       └── 关联VMA与GEM对象
                        │
                        ├── vma->vm_ops = obj->funcs->vm_ops
                        │       └── 设置页错误处理函数
                        │
                        └── obj->funcs->mmap(obj, vma)
                            或设置默认标志：
                                ├── VM_IO | VM_PFNMAP
                                ├── VM_DONTEXPAND | VM_DONTDUMP
                                └── pgprot_writecombine()

    步骤3：实际页面映射（按需）
    ──────────────────────────

    用户空间首次访问映射地址 → 页错误
        │
        └── vma->vm_ops->fault(vmf)
                └── 驱动特定的fault handler
                    根据内存类型映射物理页

**抽象理解** ：mmap流程是一个两阶段协议。第一阶段是"预约"——分配一个伪偏移量
作为预约号。第二阶段是"入场"——用预约号调用mmap，内核建立VMA映射。实际的物理
页面分配推迟到第三阶段"落座"——首次访问时的页错误处理。这体现了Linux内核
"延迟分配"（lazy allocation）的设计哲学。

场景四：创建帧缓冲（Framebuffer）
-----------------------------------

**触发** ：用户空间调用 ``DRM_IOCTL_MODE_ADDFB2`` 将GEM对象包装为帧缓冲

**核心文件** ： ``drivers/gpu/drm/drm_framebuffer.c``

**流程图** ::

    用户空间: ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &cmd)
        │
        └── drm_mode_addfb2_ioctl()
                │
                └── drm_mode_addfb2(dev, data, file_priv) [drm_framebuffer.c:330]
                        │
                        ├── drm_internal_framebuffer_create() [drm_framebuffer.c:260]
                        │       │
                        │       ├── 验证flags（只允许INTERLACED和MODIFIERS）
                        │       │
                        │       ├── 验证尺寸：
                        │       │   ├── min_width ≤ width ≤ max_width
                        │       │   └── min_height ≤ height ≤ max_height
                        │       │
                        │       ├── 验证像素格式：
                        │       │   └── drm_format_info(pixel_format)
                        │       │
                        │       ├── 验证modifier兼容性
                        │       │
                        │       ├── framebuffer_check(dev, info, r)
                        │       │       ├── 验证每个平面的pitch
                        │       │       ├── 验证buffer handle存在
                        │       │       └── 验证尺寸与格式匹配
                        │       │
                        │       └── dev->mode_config.funcs->fb_create(dev, file, info, r)
                        │               └── 驱动特定的帧缓冲创建
                        │                   （查找GEM对象、绑定到FB结构）
                        │
                        ├── r->fb_id = fb->base.id
                        │       └── 通过KMS对象IDR分配FB ID
                        │
                        └── list_add(&fb->filp_head, &file_priv->fbs)
                                └── 关联到文件的FB列表
                                    （文件关闭时自动清理）

**抽象理解** ：帧缓冲是GEM对象的"相框"。GEM对象是一块原始画布（内存），
帧缓冲为其添加了显示所需的元数据——宽高、像素格式、每行步长（pitch）。
同一块画布可以被装入不同规格的相框（不同的Framebuffer对象），
只要尺寸和格式兼容。

场景五：原子模式设置（Atomic Modeset）
----------------------------------------

**触发** ：用户空间调用 ``DRM_IOCTL_MODE_ATOMIC`` 进行原子显示配置

**核心文件** ：

- ``drivers/gpu/drm/drm_atomic_uapi.c`` （用户接口）
- ``drivers/gpu/drm/drm_atomic.c`` （核心逻辑）

**流程图** ::

    用户空间: ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &atomic)
        │
        └── drm_mode_atomic_ioctl()           [drm_atomic_uapi.c:1559]
                │
                ├── 验证前置条件：
                │   ├── 检查 DRIVER_ATOMIC 特性
                │   ├── 检查 file_priv->atomic 已启用
                │   ├── 验证 flags 合法性
                │   └── TEST_ONLY 和 PAGE_FLIP_EVENT 互斥
                │
                ├── drm_atomic_state_alloc(dev)
                │       └── 分配原子状态容器
                │           （保存所有待修改对象的新旧状态）
                │
                ├── drm_modeset_acquire_init(&ctx)
                │       └── 初始化锁获取上下文
                │           （支持死锁避免的ww_mutex）
                │
                ├── 解析用户空间数据（循环）：
                │   │
                │   └── for each (object_id, property_id, value):
                │           │
                │           ├── drm_mode_object_find(obj_id)
                │           │       └── 查找CRTC/Plane/Connector
                │           │
                │           └── drm_atomic_set_property()
                │                   ├── crtc: drm_atomic_crtc_set_property()
                │                   ├── plane: drm_atomic_plane_set_property()
                │                   └── connector: drm_atomic_connector_set_property()
                │
                ├── 处理输出fence：
                │   └── prepare_signaling() → setup_out_fence()
                │
                ├── 根据flags执行：
                │   │
                │   ├── DRM_MODE_ATOMIC_TEST_ONLY:
                │   │       └── drm_atomic_check_only(state)
                │   │               ├── drm_atomic_normalize_zpos()
                │   │               ├── drm_atomic_helper_check()
                │   │               │   ├── check_modeset()
                │   │               │   └── check_planes()
                │   │               └── 不实际提交，仅验证
                │   │
                │   └── 正常提交:
                │           └── drm_atomic_commit(state)    [drm_atomic.c:1760]
                │                   │
                │                   ├── drm_atomic_check_only(state)
                │                   │       └── 先验证再提交
                │                   │
                │                   └── config->funcs->atomic_commit()
                │                           └── 驱动原子提交实现
                │                               （通常是drm_atomic_helper_commit）
                │
                └── 清理：drm_atomic_state_put(state)

    驱动层 drm_atomic_helper_commit():
        │
        ├── drm_atomic_helper_prepare_planes()
        │       └── 为每个平面准备帧缓冲
        │           （pin pages, 准备DMA映射）
        │
        ├── drm_atomic_helper_swap_state()
        │       └── 原子交换新旧状态
        │
        ├── drm_atomic_helper_commit_modeset_disables()
        │       └── 禁用需要关闭的CRTC/Encoder
        │
        ├── drm_atomic_helper_commit_planes()
        │       └── 编程硬件寄存器
        │           设置平面地址、格式、位置
        │
        ├── drm_atomic_helper_commit_modeset_enables()
        │       └── 启用需要打开的CRTC/Encoder
        │
        └── drm_atomic_helper_cleanup_planes()
                └── 清理旧帧缓冲资源

**抽象理解** ：原子模式设置是一种"事务性操作"——所有显示管线的变更要么全部成功
应用，要么全部回滚。就像数据库事务一样，先收集所有修改（set_property），
再统一验证（check_only），最后一次性提交（commit）。TEST_ONLY模式就是
"dry run"——只检查不执行。这避免了传统遗留API中部分成功部分失败导致的
显示异常。

场景六：页面翻转（Page Flip）
-------------------------------

**触发** ：用户空间调用 ``DRM_IOCTL_MODE_PAGE_FLIP`` 请求帧缓冲切换

**核心文件** ： ``drivers/gpu/drm/drm_plane.c``

**流程图** ::

    用户空间: ioctl(fd, DRM_IOCTL_MODE_PAGE_FLIP, &flip)
        │
        └── drm_mode_page_flip_ioctl()        [drm_plane.c:1381]
                │
                ├── 验证flags：
                │   ├── ASYNC翻转需要 dev->mode_config.async_page_flip
                │   └── TARGET_ABSOLUTE 与 TARGET_RELATIVE 互斥
                │
                ├── drm_crtc_find(dev, file_priv, crtc_id)
                │       └── 查找目标CRTC
                │
                ├── drm_lease_held(file_priv, plane->base.id)
                │       └── 检查租约权限
                │
                ├── 计算目标VBlank序号：
                │   ├── ABSOLUTE: 使用指定序号
                │   ├── RELATIVE: 当前序号 + 偏移
                │   └── 默认: 下一个VBlank
                │
                ├── drm_modeset_lock(&crtc->mutex)
                │   drm_modeset_lock(&plane->mutex)
                │       └── 获取CRTC和平面锁
                │
                ├── drm_framebuffer_lookup(dev, file, fb_id)
                │       └── 查找新帧缓冲
                │
                ├── 验证帧缓冲：
                │   ├── 尺寸与视口兼容
                │   └── 像素格式与旧FB一致
                │       （页面翻转不允许改变格式）
                │
                ├── 分配vblank事件（如果请求了EVENT标志）：
                │   ├── kzalloc(drm_pending_vblank_event)
                │   ├── event.type = DRM_EVENT_FLIP_COMPLETE
                │   └── drm_event_reserve_init()
                │
                └── crtc->funcs->page_flip(crtc, fb, event, flags)
                    或 crtc->funcs->page_flip_target(...)
                        └── 驱动编程硬件在下一个VBlank
                            切换显示缓冲区地址

    VBlank中断到达时：
        │
        └── drm_crtc_send_vblank_event(crtc, event)
                │
                ├── drm_send_event_locked(dev, &event->base)
                │       └── 将事件加入 file->event_list
                │
                └── wake_up_interruptible(&file->event_wait)
                        └── 唤醒等待事件的用户进程

    用户空间: read(fd, &event, sizeof(event))
        └── 读取翻页完成事件

**抽象理解** ：页面翻转是一种"双缓冲切换"操作。想象一个画廊有两个相框位（前台
和后台），艺术家在后台相框上放好新画作，然后在观众看不到的瞬间（VBlank消隐期）
将前后台互换。EVENT标志就是让画廊通知观众"换画完成了"。与原子提交不同，页面翻转
是轻量级的——它只切换缓冲区地址，不改变显示模式。

场景七：PRIME缓冲区共享
--------------------------

**触发** ：进程间或设备间通过DMA-buf共享GPU缓冲区

**核心文件** ： ``drivers/gpu/drm/drm_prime.c``

**流程图** ::

    导出流程（GEM Handle → DMA-buf FD）：
    ─────────────────────────────────────

    进程A: ioctl(fd, DRM_IOCTL_PRIME_HANDLE_TO_FD, &args)
        │
        └── drm_prime_handle_to_fd_ioctl()     [drm_prime.c:533]
                │
                └── drm_gem_prime_handle_to_fd(dev, file, handle, flags, &fd)
                        │
                        ├── drm_gem_object_lookup(file_priv, handle)
                        │       └── 从文件IDR查找GEM对象
                        │
                        ├── drm_prime_lookup_buf_by_handle()
                        │       └── 检查缓存：此handle是否已导出？
                        │           如果是，直接返回已有dma_buf
                        │
                        ├── obj->funcs->export(obj, flags)
                        │   或 drm_gem_prime_export(obj, flags)
                        │       │
                        │       ├── dma_buf_export(&exp_info)
                        │       │       └── 创建dma_buf对象
                        │       │           关联GEM的DMA操作
                        │       │
                        │       └── obj->dma_buf = dmabuf
                        │               └── 缓存导出结果
                        │
                        ├── drm_prime_add_buf_handle()
                        │       └── 缓存 handle ↔ dma_buf 映射
                        │
                        └── dma_buf_fd(dmabuf, flags)
                                └── 安装到进程文件描述符表
                                    返回fd给用户空间

    导入流程（DMA-buf FD → GEM Handle）：
    ─────────────────────────────────────

    进程B: ioctl(fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &args)
        │
        └── drm_prime_fd_to_handle_ioctl()     [drm_prime.c:362]
                │
                └── drm_gem_prime_fd_to_handle(dev, file, prime_fd, &handle)
                        │
                        ├── dma_buf_get(prime_fd)
                        │       └── 从fd获取dma_buf对象
                        │
                        ├── drm_prime_lookup_buf_handle()
                        │       └── 检查缓存：此dma_buf是否已导入？
                        │
                        ├── 如果是同设备导出的buf：
                        │   └── 直接使用原始GEM对象
                        │       （避免不必要的导入开销）
                        │
                        ├── driver->gem_prime_import(dev, dma_buf)
                        │   或 drm_gem_prime_import(dev, dma_buf)
                        │       │
                        │       ├── dma_buf_attach(dma_buf, dev->dev)
                        │       │       └── 建立DMA映射关系
                        │       │
                        │       ├── dma_buf_map_attachment()
                        │       │       └── 获取scatter-gather表
                        │       │
                        │       └── driver->gem_prime_import_sg_table()
                        │               └── 驱动用sg_table创建GEM对象
                        │
                        └── drm_gem_handle_create(file, obj, &handle)
                                └── 为导入的对象分配本地句柄

**抽象理解** ：PRIME是DRM的"跨域快递服务"。导出方将GEM对象打包为DMA-buf
（通用快递箱），通过文件描述符传递。导入方收到快递箱后拆包为本地GEM对象。
关键优化是"同城快递不出城"——如果dma_buf来自同一设备，直接复用原对象，
无需重新包装。缓存机制确保同一包裹不被重复封装。

场景八：连接器状态检测
------------------------

**触发** ：用户空间调用 ``DRM_IOCTL_MODE_GETCONNECTOR`` 查询连接器信息

**核心文件** ： ``drivers/gpu/drm/drm_connector.c``

**流程图** ::

    用户空间: ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn)
        │                   ┌──────────────────────────────┐
        │                   │ 第一次调用：count_modes = 0   │
        │                   │ → 触发探测，获取计数           │
        │                   │ 第二次调用：带足够缓冲区      │
        │                   │ → 填充模式数据                 │
        │                   └──────────────────────────────┘
        │
        └── drm_mode_getconnector()            [drm_connector.c:3316]
                │
                ├── drm_connector_lookup(dev, file, connector_id)
                │       └── 查找连接器对象
                │
                ├── 填充编码器列表：
                │   └── drm_connector_for_each_possible_encoder()
                │           └── 枚举关联的编码器ID
                │
                ├── 填充连接器基本信息：
                │   ├── connector_type（HDMI/DP/VGA/...）
                │   ├── connector_type_id
                │   └── connection状态（connected/disconnected/unknown）
                │
                ├── 强制探测模式（如果是Master且count_modes==0）：
                │   │
                │   └── connector->funcs->fill_modes()
                │           │
                │           ├── drm_helper_probe_single_connector_modes()
                │           │       │
                │           │       ├── connector->funcs->detect()
                │           │       │       └── 硬件级连接检测
                │           │       │           （HPD引脚、I2C探测等）
                │           │       │
                │           │       ├── drm_connector_get_modes()
                │           │       │       └── connector->funcs->get_modes()
                │           │       │               └── 读取EDID
                │           │       │                   解析支持的分辨率列表
                │           │       │
                │           │       └── drm_mode_prune_invalid()
                │           │               └── 裁剪硬件不支持的模式
                │           │
                │           └── 更新 connector->status
                │
                ├── 填充显示物理信息：
                │   ├── mm_width, mm_height（物理尺寸mm）
                │   └── subpixel_order（子像素排列）
                │
                └── 拷贝模式列表到用户空间：
                    └── for each mode in connector->modes:
                            drm_mode_convert_to_umode(&u_mode, mode)
                            copy_to_user(mode_ptr, &u_mode)

**抽象理解** ：连接器探测是一种"两遍扫描"协议。第一遍告诉用户空间"有多少结果"，
用户空间据此分配缓冲区，第二遍填充数据。强制探测时，驱动通过硬件手段
（HPD热插拔检测引脚、I2C总线读取EDID）获取显示器的能力信息。
这类似于"先问问画廊里有多少幅画，再带足够大的清单本去抄录"。

场景九：VBlank等待与事件
--------------------------

**触发** ：用户空间等待特定VBlank事件

**核心文件** ： ``drivers/gpu/drm/drm_vblank.c``

**流程图** ::

    用户空间: ioctl(fd, DRM_IOCTL_WAIT_VBLANK, &vblwait)
        │
        └── drm_wait_vblank_ioctl()            [drm_vblank.c:1734]
                │
                ├── 解析CRTC管道号：
                │   ├── HIGH_CRTC_MASK → pipe_index
                │   └── drm_lease_held() 验证租约权限
                │
                ├── drm_vblank_get(dev, pipe)
                │       │
                │       ├── atomic_add_return(1, &vblank->refcount)
                │       │
                │       └── 如果 0→1 转换：
                │               └── drm_vblank_enable(dev, pipe)
                │                       └── dev->driver->enable_vblank(crtc)
                │                               └── 使能硬件VBlank中断
                │
                ├── seq = drm_vblank_count(dev, pipe)
                │       └── 获取当前VBlank计数
                │
                ├── 计算目标序号：
                │   ├── RELATIVE: req_seq = seq + request.sequence
                │   ├── ABSOLUTE: req_seq = request.sequence
                │   └── NEXTONMISS: 如果已过期，等下一个
                │
                ├── 如果请求EVENT标志：
                │   │
                │   ├── 分配 drm_pending_vblank_event
                │   ├── drm_vblank_put(dev, pipe) [不阻塞等待]
                │   └── 事件在VBlank中断时异步发送：
                │           └── drm_handle_vblank(crtc)
                │                   └── drm_send_event()
                │
                └── 如果同步等待：
                        │
                        ├── wait_event_interruptible_timeout(
                        │       vblank->queue,
                        │       vblank_passed(seq, req_seq),
                        │       timeout)
                        │       └── 阻塞等待VBlank中断
                        │           更新计数器到目标值
                        │
                        ├── drm_wait_vblank_reply(dev, pipe, &reply)
                        │       └── 填充时间戳和序号
                        │
                        └── drm_vblank_put(dev, pipe)
                                └── 如果refcount降为0：
                                    启动关闭定时器
                                    （5个VBlank后禁用中断节电）

**抽象理解** ：VBlank机制是DRM的"心跳系统"。显示器每刷新一帧产生一次VBlank
中断，就像心脏跳动。引用计数机制确保"有人需要心跳监测时才开启心电图仪"——
第一个订阅者使能中断，最后一个退订者触发延迟关闭。EVENT模式是"异步通知"，
同步等待是"阻塞直到心跳到达"。5个VBlank的延迟关闭是一种"防抖"优化，
避免频繁开关中断。

场景十：关闭DRM设备
---------------------

**触发** ：用户空间调用 ``close(fd)``

**核心文件** ： ``drivers/gpu/drm/drm_file.c``

**流程图** ::

    用户空间: close(fd)
        │
        └── VFS → drm_release(inode, filp)     [drm_file.c:427]
                │
                ├── drm_close_helper(filp)
                │       │
                │       └── drm_file_free(file_priv)
                │               │
                │               ├── 通知驱动：
                │               │   └── driver->postclose(dev, file_priv)
                │               │
                │               ├── 释放DRM Master：
                │               │   └── drm_master_release(file_priv)
                │               │
                │               ├── 清理帧缓冲：
                │               │   └── list_for_each_entry(fb, &file->fbs)
                │               │           drm_framebuffer_remove(fb)
                │               │
                │               ├── 清理pending事件：
                │               │   └── list_for_each_entry(e, &file->pending_event_list)
                │               │           释放事件空间
                │               │
                │               ├── 清理GEM句柄：
                │               │   └── drm_gem_release(dev, file_priv)
                │               │           idr_for_each(object_idr, drm_gem_object_release_handle)
                │               │           └── 释放每个句柄的引用
                │               │
                │               ├── 清理SYNCOBJ：
                │               │   └── drm_syncobj_release(file_priv)
                │               │
                │               ├── 清理PRIME缓存：
                │               │   └── drm_prime_destroy_file_private()
                │               │
                │               └── list_del(&file->lhead)
                │                       └── 从设备文件列表移除
                │
                ├── atomic_dec_and_test(&dev->open_count)
                │       └── 如果是最后一个关闭：
                │               └── drm_lastclose(dev)
                │                       ├── drm_client_dev_restore()
                │                       │       └── 恢复内核DRM客户端
                │                       │           （如fbcon控制台）
                │                       └── vga_switcheroo_process_delayed_switch()
                │                               └── 处理延迟的GPU切换
                │
                └── drm_minor_release(minor)
                        └── 释放minor引用

**抽象理解** ：关闭设备是"退场清理"。每个观众（drm_file）离场时需要归还入场券
（释放句柄）、清理占座（释放帧缓冲）、取消预约（释放事件）。最后一个观众
离场时（open_count归零），场馆恢复为默认状态——控制台重新接管显示。
这体现了"谁申请谁释放"和"最后离开的人关灯"的资源管理原则。

流程图之间的关系
================

上述场景并非孤立存在，它们构成一个完整的使用周期：

**典型的显示应用生命周期** ::

    ┌──────────────────────────────────────────────────────────┐
    │                    初始化阶段                             │
    │                                                          │
    │  1. open("/dev/dri/card0")          → 场景一：打开设备   │
    │  2. drmGetResources()               → 获取KMS资源        │
    │  3. drmModeGetConnector()           → 场景八：检测连接器 │
    └──────────────┬───────────────────────────────────────────┘
                   │
                   ▼
    ┌──────────────────────────────────────────────────────────┐
    │                    配置阶段                               │
    │                                                          │
    │  4. drmModeCreateDumb()             → 场景二：创建缓冲区 │
    │  5. drmModeMapDumb() + mmap()       → 场景三：映射缓冲区 │
    │  6. 渲染内容到缓冲区                                     │
    │  7. drmModeAddFB2()                 → 场景四：创建帧缓冲 │
    │  8. drmModeAtomicCommit()           → 场景五：设置模式   │
    └──────────────┬───────────────────────────────────────────┘
                   │
                   ▼
    ┌──────────────────────────────────────────────────────────┐
    │                    运行阶段（循环）                       │
    │                                                          │
    │  9. 渲染到后台缓冲区                                     │
    │ 10. drmModePageFlip()               → 场景六：页面翻转   │
    │ 11. read(fd) 等待翻页完成事件       → 场景九：VBlank事件 │
    │ 12. 回到步骤9                                            │
    │                                                          │
    │  跨进程共享（可选）：                                    │
    │  - drmPrimeHandleToFD()             → 场景七：PRIME导出  │
    │  - drmPrimeFDToHandle()             → 场景七：PRIME导入  │
    └──────────────┬───────────────────────────────────────────┘
                   │
                   ▼
    ┌──────────────────────────────────────────────────────────┐
    │                    清理阶段                               │
    │                                                          │
    │ 13. close(fd)                       → 场景十：关闭设备   │
    │     └── 自动清理所有关联资源                              │
    └──────────────────────────────────────────────────────────┘

设计模式总结
============

通过对DRM子系统初始化和使用流程的梳理，可以提炼出以下核心设计模式：

1. **门控初始化** ：``drm_core_init_complete`` 标志确保核心就绪后驱动才能注册。
   系统性地防止了初始化顺序错误。

2. **设备托管资源** ：``devm_`` / ``drmm_`` 前缀的分配函数将资源生命周期绑定到
   设备，实现自动清理。这是RAII（Resource Acquisition Is Initialization）模式
   在C语言中的实现。

3. **引用计数** ：GEM对象、DRM设备、minor设备、帧缓冲等核心对象都通过
   ``kref`` 或原子引用计数管理生命周期，支持安全的跨上下文共享。

4. **回调抽象** ：``struct drm_driver`` 、 ``struct drm_crtc_funcs`` 、
   ``struct drm_gem_object_funcs`` 等函数指针表实现了面向对象的多态，
   使核心框架与驱动实现解耦。

5. **原子事务** ：原子模式设置将多个显示管线变更封装为事务，支持check-then-commit
   模式和test-only验证，保证了显示状态的一致性。

6. **延迟分配** ：mmap流程中物理页面在页错误时才分配，VBlank中断在无需时自动
   关闭，体现了按需分配的效率优化。

7. **两遍协议** ：连接器查询等ioctl采用"先获取数量，再获取数据"的两遍调用模式，
   使接口能适应可变长度的数据。

参考源文件
==========

- ``drivers/gpu/drm/drm_drv.c`` — DRM核心驱动与设备管理
- ``drivers/gpu/drm/drm_file.c`` — 文件操作（open/close）
- ``drivers/gpu/drm/drm_gem.c`` — GEM内存对象管理
- ``drivers/gpu/drm/drm_framebuffer.c`` — 帧缓冲管理
- ``drivers/gpu/drm/drm_atomic.c`` — 原子提交核心
- ``drivers/gpu/drm/drm_atomic_uapi.c`` — 原子模式设置用户接口
- ``drivers/gpu/drm/drm_plane.c`` — 平面与页面翻转
- ``drivers/gpu/drm/drm_prime.c`` — PRIME/DMA-buf共享
- ``drivers/gpu/drm/drm_connector.c`` — 连接器管理
- ``drivers/gpu/drm/drm_vblank.c`` — VBlank处理
- ``drivers/gpu/drm/drm_mode_config.c`` — KMS模式配置
- ``include/drm/drm_drv.h`` — drm_driver结构体定义
- ``include/drm/drm_gem.h`` — GEM对象定义
- ``include/drm/drm_mode_config.h`` — 模式配置定义
