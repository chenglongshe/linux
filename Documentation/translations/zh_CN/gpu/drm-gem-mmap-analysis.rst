.. SPDX-License-Identifier: GPL-2.0

.. include:: ../disclaimer-zh_CN.rst

:Original: Documentation/gpu/drm-mm.rst

:翻译:

 佘成龙 Chenglong She

:校译:

============================================================
DRM子系统抽象分析与drm_gem_create_mmap_offset()使用场景
============================================================

本文档从抽象思维的角度分析Linux DRM（Direct Rendering Manager）子系统的架构
设计，并详细阐述 ``drm_gem_create_mmap_offset()`` 函数的使用场景。

.. contents:: 目录
   :local:
   :depth: 3

DRM子系统的抽象架构分析
========================

分层抽象模型
------------

DRM子系统采用经典的分层抽象设计，可以从以下几个层次来理解：

**用户空间接口层（Userspace Interface Layer）**

最顶层是用户空间接口，通过 ``/dev/dri/cardN`` 设备节点暴露给应用程序。用户空间
通过 ``ioctl()`` 和 ``mmap()`` 系统调用与内核交互。这一层定义了用户态与内核态之间
的契约（Contract），是整个抽象体系的入口。

**核心框架层（Core Framework Layer）**

DRM核心框架（ ``drivers/gpu/drm/drm_*.c`` ）提供设备无关的通用逻辑，包括：

- GEM（Graphics Execution Manager）：内存对象管理
- KMS（Kernel Mode Setting）：显示模式管理
- VMA Offset Manager：虚拟地址偏移管理
- 文件操作与设备管理

**驱动适配层（Driver Adaptation Layer）**

各硬件驱动（如i915、amdgpu、msm、panfrost等）通过回调函数（callback）和嵌入式
结构体（embedded struct）模式扩展核心框架，实现硬件特定的内存分配、命令提交和
显示输出。

关键设计模式
------------

**回调抽象（Callback Abstraction）**

DRM子系统的核心设计模式是通过函数指针表实现多态。以GEM对象为例，
``struct drm_gem_object_funcs`` 定义了一组操作接口::

    struct drm_gem_object_funcs {
        void (*free)(struct drm_gem_object *obj);
        int (*open)(struct drm_gem_object *obj, struct drm_file *file);
        void (*close)(struct drm_gem_object *obj, struct drm_file *file);
        int (*pin)(struct drm_gem_object *obj);
        int (*mmap)(struct drm_gem_object *obj, struct vm_area_struct *vma);
        vm_fault_t (*fault)(struct drm_gem_object *obj, struct vm_fault *vmf);
        ...
    };

每个驱动可以提供自己的实现，DRM核心通过这些回调实现了对不同硬件的统一管理。
这是一种典型的策略模式（Strategy Pattern）在C语言中的实现。

**嵌入式继承（Embedded Struct Inheritance）**

Linux内核广泛使用结构体嵌入来实现继承关系。GEM对象的典型层次结构为::

    struct drm_gem_object          <-- DRM核心基础结构
        └── struct drm_gem_shmem_object  <-- SHMEM辅助层
            └── struct xxx_gem_object    <-- 驱动特定结构

驱动通过 ``container_of()`` 宏从基础结构体获取其扩展结构体的指针，这一模式
贯穿整个DRM子系统。

**偏移量间接寻址（Offset Indirection）**

GEM对象不拥有独立的文件句柄，因此无法直接通过 ``mmap()`` 映射。DRM子系统引入了
"伪偏移量"（fake offset）机制：为每个需要映射的GEM对象分配一个唯一的偏移量值，
用户空间将此偏移量传递给 ``mmap()`` 系统调用，内核再通过偏移量反向查找到对应的
GEM对象。这是一种典型的间接寻址设计模式。

GEM内存管理的核心抽象
---------------------

GEM子系统的设计哲学是 **数据无关性** （Data-agnostic）：它管理抽象的缓冲区对象
而不关心缓冲区的具体内容。这一设计将通用内存管理逻辑与硬件特定操作分离：

- **通用部分** ：对象生命周期、引用计数、句柄管理、mmap偏移量管理
- **硬件特定部分** ：物理内存分配、GPU命令执行、缓存一致性维护

这种分离使得GEM相比TTM（Translation Table Manager）更加简洁：TTM试图提供一个
包含所有硬件场景的统一方案，而GEM只提取共性代码形成支持库，让驱动实现差异化的
部分。

mmap偏移量机制的抽象分析
========================

问题域
------

在Linux中，``mmap()`` 系统调用需要一个文件描述符和一个偏移量来建立内存映射。
然而GEM对象不是独立的文件，它们存在于DRM设备的上下文中。这产生了一个基本问题：

    **如何让用户空间能够mmap一个没有独立文件句柄的内核对象？**

解决方案架构
------------

DRM采用了"伪偏移量"方案来解决这一问题，整体架构涉及以下组件：

**VMA偏移量管理器（drm_vma_offset_manager）**

每个DRM设备拥有一个VMA偏移量管理器，它维护一个基于红黑树（ ``drm_mm`` ）的地址
空间::

    struct drm_vma_offset_manager {
        rwlock_t vm_lock;
        struct drm_mm vm_addr_space_mm;
    };

该管理器负责分配和查找偏移量，其地址空间起始于一个高位值
（64位系统上为 ``0xFFFFFFFF >> PAGE_SHIFT + 1`` ），以避免与真实文件偏移量冲突。

**VMA偏移量节点（drm_vma_offset_node）**

每个GEM对象内嵌一个偏移量节点::

    struct drm_gem_object {
        ...
        struct drm_vma_offset_node vma_node;
        ...
    };

    struct drm_vma_offset_node {
        rwlock_t vm_lock;
        struct drm_mm_node vm_node;  /* 在管理器地址空间中的位置 */
        struct rb_root vm_files;     /* 访问权限控制 */
        void *driver_private;
    };

**映射流程**

完整的mmap流程可以抽象为以下步骤：

1. **偏移量分配** ：驱动调用 ``drm_gem_create_mmap_offset()`` 为GEM对象分配
   伪偏移量
2. **偏移量传递** ：驱动通过ioctl将偏移量返回给用户空间
3. **用户空间映射** ：用户空间调用 ``mmap(fd, offset)``
4. **内核查找** ：DRM核心在VMA偏移量管理器中查找偏移量，找到对应的GEM对象
5. **VMA建立** ：设置页错误处理程序，按需映射物理页面

drm_gem_create_mmap_offset()详细分析
=====================================

函数定义
--------

``drm_gem_create_mmap_offset()`` 定义在 ``drivers/gpu/drm/drm_gem.c`` 中::

    int drm_gem_create_mmap_offset(struct drm_gem_object *obj)
    {
        return drm_gem_create_mmap_offset_size(obj, obj->size);
    }

它是 ``drm_gem_create_mmap_offset_size()`` 的简化包装::

    int drm_gem_create_mmap_offset_size(struct drm_gem_object *obj, size_t size)
    {
        struct drm_device *dev = obj->dev;

        return drm_vma_offset_add(dev->vma_offset_manager, &obj->vma_node,
                                  size / PAGE_SIZE);
    }

核心操作是将GEM对象的 ``vma_node`` 注册到设备的 ``vma_offset_manager`` 中，
分配 ``size / PAGE_SIZE`` 个页面的地址空间。该函数是幂等的——对已有偏移量的对象
重复调用会透明地返回成功。

使用场景
--------

以下是 ``drm_gem_create_mmap_offset()`` 在内核中的典型使用场景分类。

场景一：GEM对象创建时立即分配偏移量
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

许多驱动在创建GEM对象时立即分配mmap偏移量，使对象在创建后即可被用户空间映射。
这是最常见的使用模式。

**Qualcomm Adreno GPU（MSM驱动）** ：在 ``drivers/gpu/drm/msm/msm_gem.c`` 中，
创建GEM对象后立即调用::

    /* msm_gem.c 中的对象初始化 */
    ret = drm_gem_create_mmap_offset(obj);
    if (ret)
        goto fail;

**Samsung Exynos** ：在 ``drivers/gpu/drm/exynos/exynos_drm_gem.c`` 中，
GEM对象创建流程的一部分::

    ret = drm_gem_create_mmap_offset(&exynos_gem->base);

**Vivante Etnaviv** ：在 ``drivers/gpu/drm/etnaviv/etnaviv_gem.c`` 中，
嵌入式GPU对象初始化时分配偏移量。

**ARM Panfrost/Panthor（Mali GPU）** ：在
``drivers/gpu/drm/panfrost/panfrost_drv.c`` 和
``drivers/gpu/drm/panthor/panthor_drv.c`` 中，作为GEM对象创建ioctl处理的一部分。

**Imagination PowerVR** ：在 ``drivers/gpu/drm/imagination/pvr_drv.c`` 中。

场景二：DRM核心框架中的默认实现
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

DRM核心提供了通用的dumb buffer映射实现，自动为GEM对象分配偏移量。

**drm_gem_dumb_map_offset()** ：在 ``drivers/gpu/drm/drm_gem.c`` 中::

    /* 当用户空间请求dumb buffer的映射偏移量时 */
    int drm_gem_dumb_map_offset(struct drm_file *file, struct drm_device *dev,
                                uint32_t handle, uint64_t *offset)
    {
        struct drm_gem_object *obj;
        ...
        ret = drm_gem_create_mmap_offset(obj);
        ...
        *offset = drm_vma_node_offset_addr(&obj->vma_node);
        ...
    }

这是最基本的使用场景——当用户空间通过
``DRM_IOCTL_MODE_MAP_DUMB`` 请求映射一个dumb buffer时，核心框架调用此函数
为对象分配偏移量并返回给用户空间。

场景三：GEM辅助层的集成
^^^^^^^^^^^^^^^^^^^^^^^^^^

DRM提供了基于不同内存后端的GEM辅助层，这些辅助层在内部使用
``drm_gem_create_mmap_offset()`` 。

**DMA辅助层** ：在 ``drivers/gpu/drm/drm_gem_dma_helper.c`` 中，
为基于DMA的连续内存GEM对象分配偏移量。适用于需要物理连续内存的嵌入式设备。

**SHMEM辅助层** ：在 ``drivers/gpu/drm/drm_gem_shmem_helper.c`` 中，
为基于shmem的可分页GEM对象分配偏移量。这是大多数UMA设备使用的标准辅助层。

场景四：虚拟化GPU的VRAM对象
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Virtio-GPU** ：在 ``drivers/gpu/drm/virtio/virtgpu_vram.c`` 中，虚拟化GPU
创建VRAM类型的GEM对象后分配偏移量::

    drm_gem_private_object_init(vgdev->ddev, obj, params->size);
    ret = drm_gem_create_mmap_offset(obj);

这里使用 ``drm_gem_private_object_init()`` 而非 ``drm_gem_object_init()`` ，
因为VRAM对象不使用shmem后端，但仍然需要mmap偏移量以支持用户空间映射。

场景五：MMIO映射的GEM对象
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Intel Xe GPU** ：在 ``drivers/gpu/drm/xe/xe_mmio_gem.c`` 中，为MMIO
（Memory-Mapped I/O）区域创建的GEM对象分配偏移量。这允许用户空间通过mmap直接
访问GPU的MMIO寄存器区域。

场景六：计算加速器
^^^^^^^^^^^^^^^^^^^^

**Qualcomm AI引擎（QAIC）** ：在 ``drivers/accel/qaic/qaic_data.c`` 中，
AI加速器使用DRM GEM框架管理设备内存，同样需要通过
``drm_gem_create_mmap_offset()`` 支持用户空间映射。这展示了GEM框架的通用性——
它不仅服务于GPU，还能服务于各类计算加速器。

场景七：自定义大小的偏移量
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

**Texas Instruments OMAP** ：在 ``drivers/gpu/drm/omapdrm/omap_gem.c`` 中，
使用 ``drm_gem_create_mmap_offset_size()`` 而非
``drm_gem_create_mmap_offset()`` ，允许虚拟映射大小与物理对象大小不同::

    ret = drm_gem_create_mmap_offset_size(obj, omap_gem_mmap_size(obj));

这在显示控制器的某些tiling模式下是必要的，此时映射到用户空间的虚拟大小可能大于
实际的物理存储大小。

使用模式总结
^^^^^^^^^^^^

从抽象角度看， ``drm_gem_create_mmap_offset()`` 的使用可归纳为以下通用模式::

    /* 步骤1: 创建GEM对象 */
    drm_gem_object_init(dev, obj, size);
    /* 或 drm_gem_private_object_init(dev, obj, size); */

    /* 步骤2: 分配mmap偏移量 */
    ret = drm_gem_create_mmap_offset(obj);
    if (ret)
        goto fail;

    /* 步骤3: 将偏移量传递给用户空间 */
    *offset = drm_vma_node_offset_addr(&obj->vma_node);

    /* 用户空间随后调用:
     * void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
     *                  MAP_SHARED, drm_fd, offset);
     */

对应的清理操作使用 ``drm_gem_free_mmap_offset()`` 释放偏移量。

设计启示
========

DRM子系统的mmap偏移量机制体现了几个重要的系统设计原则：

1. **间接层解耦** ：通过引入伪偏移量这一间接层，将GEM对象与Unix文件抽象解耦，
   使得GEM对象无需拥有独立的文件描述符即可支持mmap操作。

2. **延迟绑定** ：偏移量分配与实际物理页面映射分离。偏移量分配是轻量级的元数据
   操作，而物理页面映射则推迟到页错误时按需完成。

3. **幂等性设计** ：``drm_gem_create_mmap_offset_size()`` 对已有偏移量的对象
   透明处理，驱动无需维护偏移量分配状态，简化了驱动开发。

4. **框架与策略分离** ：DRM核心提供偏移量管理的框架（mechanism），各驱动决定
   何时分配偏移量以及如何响应页错误（policy），体现了Linux内核的"机制与策略
   分离"设计原则。

参考资料
========

- ``drivers/gpu/drm/drm_gem.c`` — GEM核心实现
- ``include/drm/drm_gem.h`` — GEM对象定义
- ``include/drm/drm_vma_manager.h`` — VMA偏移量管理器
- ``Documentation/gpu/drm-mm.rst`` — DRM内存管理英文文档
- `GEM - the Graphics Execution Manager <http://lwn.net/Articles/283798/>`__ — LWN上的GEM设计文章
