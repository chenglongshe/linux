# virtio-gpu fdinfo blob integration test

Run as root from a kernel checkout:

```sh
python3 tools/testing/selftests/drivers/gpu/virtgpu_fdinfo_blob_test.py
python3 tools/testing/selftests/drivers/gpu/virtgpu_fdinfo_blob_test.py --hold
```

This is a standalone integration test, not an automatically discovered kselftest.
It needs the fdinfo patch and the following guest devices:

- One virgl2 virtio-gpu with blob support and a host-visible aperture.
- A second non-3D virtio-gpu with blob support.
- A system dma-heap or udmabuf allocator (CONFIG_DMABUF_HEAPS_SYSTEM or CONFIG_UDMABUF).

The tested configuration used Linux 7.3.0-fdinfo-test+, QEMU 10.0.13,
virglrenderer 1.1.0, a virgl GPU with hostmem=256 MiB, and a second
virtio-gpu-pci device with blob=true. The QEMU process also needs access to
the host /dev/udmabuf device for the non-3D blob backend.

The current driver rejects external dma-buf imports on virgl devices.
The test therefore reports two DRM clients rather than pretending that
host-only and external-import sizes can be obtained from one FD.

Expected values on the 3D FD:

| Field | Value |
| --- | --- |
| drm-total-host3d | 1 MiB |
| drm-shared-host3d | 1 MiB |
| drm-total-memory | 2 MiB |
| drm-virtio-mixed-blob-logical | 2 MiB |
| drm-virtio-host-visible-window | 1 MiB |

Expected values on the non-3D FD:

| Field | Value |
| --- | --- |
| drm-virtio-imported-logical | 3 MiB |
| drm-total-memory | 0 |

The test creates renderer GL buffers with VIRGL_CCMD_PIPE_RESOURCE_CREATE
before binding blob IDs. It checks host-only mapping, a second handle for
the same host-only object, mixed renderer inline writes and copy/readback,
and an external dma-buf import. New virtio-gpu kernel errors cause failure.
The sizes remain logical sizes; this does not measure host RAM or VRAM.

The initial mixed guest-backing transfer probe did not pass on
virglrenderer 1.1.0 (the host logged an Illegal resource error). The passing
test instead writes an explicit inline payload to the mixed GL buffer,
copies it to the mapped host-only GL buffer and verifies the bytes.
It does not claim guest-backing TRANSFER_TO_HOST/FROM_HOST coverage.

Without --hold, resources are released after the assertions.
With --hold, the printed PID and FDs can be used to inspect
/proc/PID/fdinfo/FD until Ctrl+C. A numeric argument limits the hold time.

Protocol references:

- https://sources.debian.org/src/virglrenderer/1.1.0-2/src/virgl_protocol.h/
- https://sources.debian.org/src/virglrenderer/1.1.0-2/src/vrend_decode.c/
- https://chromium.googlesource.com/chromiumos/platform/minigbm/+/refs/heads/main/virtgpu_virgl.c

The driver, test and documentation were prepared with OpenAI Codex assistance.
