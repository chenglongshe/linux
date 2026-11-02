.. _drm-client-usage-stats:

======================
DRM client usage stats
======================

DRM drivers can choose to export partly standardised text output via the
`fops->show_fdinfo()` as part of the driver specific file operations registered
in the `struct drm_driver` object registered with the DRM core.

One purpose of this output is to enable writing as generic as practically
feasible `top(1)` like userspace monitoring tools.

Given the differences between various DRM drivers the specification of the
output is split between common and driver specific parts. Having said that,
wherever possible effort should still be made to standardise as much as
possible.

.. contents::

File format specification
=========================

- File shall contain one key value pair per one line of text.
- Colon character (`:`) must be used to delimit keys and values.
- All standardised keys shall be prefixed with `drm-`.
- Driver-specific keys shall be prefixed with `driver_name-`, where
  driver_name should ideally be the same as the `name` field in
  `struct drm_driver`, although this is not mandatory.
- Whitespace between the delimiter and first non-whitespace character shall be
  ignored when parsing.
- Keys are not allowed to contain whitespace characters.
- Numerical key value pairs can end with optional unit string.
- Data type of the value is fixed as defined in the specification.

Key types
---------

1. Mandatory, fully standardised.
2. Optional, fully standardised.
3. Driver specific.

Data types
----------

- <uint> - Unsigned integer without defining the maximum value.
- <keystr> - String excluding any above defined reserved characters or whitespace.
- <valstr> - String.

Mandatory fully standardised keys
---------------------------------

- drm-driver: <valstr>

String shall contain the name this driver registered as via the respective
`struct drm_driver` data structure.

Optional fully standardised keys
--------------------------------

Identification
^^^^^^^^^^^^^^

- drm-pdev: <aaaa:bb.cc.d>

For PCI devices this should contain the PCI slot address of the device in
question.

- drm-client-id: <uint>

Unique value relating to the open DRM file descriptor used to distinguish
duplicated and shared file descriptors. Conceptually the value should map 1:1
to the in kernel representation of `struct drm_file` instances.

Uniqueness of the value shall be either globally unique, or unique within the
scope of each device, in which case `drm-pdev` shall be present as well.

Userspace should make sure to not double account any usage statistics by using
the above described criteria in order to associate data to individual clients.

- drm-client-name: <valstr>

String optionally set by userspace using DRM_IOCTL_SET_CLIENT_NAME.


Utilization
^^^^^^^^^^^

- drm-engine-<keystr>: <uint> ns

GPUs usually contain multiple execution engines. Each shall be given a stable
and unique name (keystr), with possible values documented in the driver specific
documentation.

Value shall be in specified time units which the respective GPU engine spent
busy executing workloads belonging to this client.

Values are not required to be constantly monotonic if it makes the driver
implementation easier, but are required to catch up with the previously reported
larger value within a reasonable period. Upon observing a value lower than what
was previously read, userspace is expected to stay with that larger previous
value until a monotonic update is seen.

- drm-engine-capacity-<keystr>: <uint>

Engine identifier string must be the same as the one specified in the
drm-engine-<keystr> tag and shall contain a greater than zero number in case the
exported engine corresponds to a group of identical hardware engines.

In the absence of this tag parser shall assume capacity of one. Zero capacity
is not allowed.

- drm-cycles-<keystr>: <uint>

Engine identifier string must be the same as the one specified in the
drm-engine-<keystr> tag and shall contain the number of busy cycles for the given
engine.

Values are not required to be constantly monotonic if it makes the driver
implementation easier, but are required to catch up with the previously reported
larger value within a reasonable period. Upon observing a value lower than what
was previously read, userspace is expected to stay with that larger previous
value until a monotonic update is seen.

- drm-total-cycles-<keystr>: <uint>

Engine identifier string must be the same as the one specified in the
drm-cycles-<keystr> tag and shall contain the total number cycles for the given
engine.

This is a timestamp in GPU unspecified unit that matches the update rate
of drm-cycles-<keystr>. For drivers that implement this interface, the engine
utilization can be calculated entirely on the GPU clock domain, without
considering the CPU sleep time between 2 samples.

A driver may implement either this key or drm-maxfreq-<keystr>, but not both.

- drm-maxfreq-<keystr>: <uint> [Hz|MHz|KHz]

Engine identifier string must be the same as the one specified in the
drm-engine-<keystr> tag and shall contain the maximum frequency for the given
engine.  Taken together with drm-cycles-<keystr>, this can be used to calculate
percentage utilization of the engine, whereas drm-engine-<keystr> only reflects
time active without considering what frequency the engine is operating as a
percentage of its maximum frequency.

A driver may implement either this key or drm-total-cycles-<keystr>, but not
both.

Memory
^^^^^^

Each possible memory type which can be used to store buffer objects by the GPU
in question shall be given a stable and unique name to be used as the "<region>"
string.

The region name "memory" is reserved to refer to normal system memory.

The value shall reflect the amount of storage currently consumed by the buffer
objects belong to this client, in the respective memory region.

Default unit shall be bytes with optional unit specifiers of 'KiB' or 'MiB'
indicating kibi- or mebi-bytes.

- drm-total-<region>: <uint> [KiB|MiB]

The total size of all requested buffers, including both shared and private
memory. The backing store for the buffers does not need to be currently
instantiated to count under this category. To avoid double-counting, if a buffer
has multiple regions where it can be allocated to, the implementation should
consistently select a single region for accounting purposes.

- drm-shared-<region>: <uint> [KiB|MiB]

The total size of buffers that are shared with another file (i.e., have more
than one handle). The same requirement to avoid double-counting that applies to
drm-total-<region> also applies here.

- drm-resident-<region>: <uint> [KiB|MiB]

The total size of buffers that are resident (i.e., have their backing store
present or instantiated) in the specified region.

- drm-memory-<region>: <uint> [KiB|MiB]

This key is deprecated and is only printed by amdgpu; it is an alias for
drm-resident-<region>.

- drm-purgeable-<region>: <uint> [KiB|MiB]

The total size of buffers that are resident and purgeable.

For example, drivers that implement functionality similar to 'madvise' can count
buffers that have instantiated backing stores but have been marked with an
equivalent of MADV_DONTNEED.

- drm-active-<region>: <uint> [KiB|MiB]

The total size of buffers that are active on one or more engines.

One practical example of this could be the presence of unsignaled fences in a
GEM buffer reservation object. Therefore, the active category is a subset of the
resident category.

Implementation Details
======================

Drivers should use drm_show_fdinfo() in their `struct file_operations`, and
implement &drm_driver.show_fdinfo if they wish to provide any stats which
are not provided by drm_show_fdinfo().  But even driver specific stats should
be documented above and where possible, aligned with other drivers.

Driver specific implementations
-------------------------------

* :ref:`i915-usage-stats`
* :ref:`panfrost-usage-stats`
* :ref:`panthor-usage-stats`
* :ref:`xe-usage-stats`
* :ref:`amdxdna-usage-stats`

Virtio GPU memory accounting
============================

The virtio_gpu driver reports memory for the unique GEM objects referenced by
handles in one DRM client (one open DRM file). Multiple handles to one object
are counted once. Readers should use ``drm-client-id`` to identify duplicated
file descriptors. A client may be shared by multiple processes, and one object
may be counted in multiple clients; these values are not process totals or
device-wide physical memory usage.

``drm-total-memory`` counts page-aligned GEM sizes of local guest shmem
objects, including guest-only blobs and the guest backing of mixed blobs.
``drm-shared-memory`` counts the subset considered shared by the DRM GEM
helper: objects with multiple handles or an associated dma-buf. Export does
not establish that another client has imported the object.

``drm-total-host3d`` and ``drm-shared-host3d`` use the same sharing rule for
host-only blobs, counting original requested blob sizes. They are logical
sizes, not measurements of host RAM or VRAM. Host creation is asynchronous,
so the values do not confirm host resource creation.

``drm-virtio-mixed-blob-logical`` counts original requested sizes of mixed
blobs. Their guest backing is already counted in memory; this supplementary
value does not measure additional host allocation.
``drm-virtio-imported-logical`` counts GEM sizes of external dma-buf imports.
Their backing and residency are unknown, so they are excluded from memory and
host3d totals. A same-device reimport that reuses the original GEM object
follows its original type.

When host-visible memory is supported, ``drm-virtio-host-visible-window``
counts allocated window sizes for this client's local host-only objects.
It is page aligned, may include mappings in progress, and does not indicate
host residency. The field is omitted on devices without host-visible memory.

Statistics are snapshots. Handle membership, sharing and mapping state can
change during collection. If allocation or bounded snapshot retries fail,
all driver memory fields are omitted rather than reporting partial values.
The driver does not report resident, active or purgeable memory statistics.
Host allocations and residency, including the host part of legacy virgl
and mixed resources, are unavailable through the existing guest interface.
