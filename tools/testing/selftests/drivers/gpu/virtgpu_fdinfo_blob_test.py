#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise real virgl blobs and external dma-buf import for virtio-gpu fdinfo."""
import argparse
import ctypes
import fcntl
import glob
import mmap
import os
import struct
import subprocess
import time

def ioctl(fd, nr, fmt, *args):
    data = bytearray(struct.pack(fmt, *args))
    request = (3 << 30) | (len(data) << 16) | (ord('d') << 8) | nr
    fcntl.ioctl(fd, request, data, True)
    return struct.unpack(fmt, data)

def getparam(fd, key):
    value = ctypes.c_uint64()
    ioctl(fd, 0x43, '=QQ', key, ctypes.addressof(value))
    return value.value

def fdinfo(fd):
    return open('/proc/self/fdinfo/' + str(fd)).read()

def value(fd, key):
    fields = dict(line.split(':', 1) for line in fdinfo(fd).splitlines())
    words = fields[key].split()
    return int(words[0]) * ({'KiB': 1024, 'MiB': 1048576}[words[1]]
                            if len(words) > 1 else 1)

def context_init(fd):
    param = (ctypes.c_uint64 * 2)(1, 2)  # CAPSET_ID = VIRGL2
    ioctl(fd, 0x4b, '=IIQ', 1, 0, ctypes.addressof(param))

def blob(fd, memory, size, blob_id, flags):
    # virgl PIPE_RESOURCE_CREATE (48), PIPE_BUFFER, R8_UNORM.
    # A persistent coherent GL buffer, not an unallocated blob_id.
    command = (ctypes.c_uint32 * 12)(
        48 | (11 << 16), 0, 64, 0, size, 1, 1, 1, 0, 0, 6, blob_id)
    result = ioctl(fd, 0x4a, '=IIIIQIIQQII',
                   memory, flags, 0, 0, size, 0, ctypes.sizeof(command),
                   ctypes.addressof(command), blob_id, 0, 0)
    return result[2], result[3]

def mapping(fd, handle, size):
    offset, _, _ = ioctl(fd, 0x41, '=QII', 0, handle, 0)
    return mmap.mmap(fd, size, flags=mmap.MAP_SHARED,
                     prot=mmap.PROT_READ | mmap.PROT_WRITE, offset=offset)

def renderer_copy_check(fd, source_handle, source_id, target_handle, target_id, target_map):
    pattern = bytes(range(256)) * 16
    payload = list(struct.unpack('=1024I', pattern))
    # RESOURCE_INLINE_WRITE has an explicit payload iovec.
    write = [9 | ((11 + len(payload)) << 16),
             source_id, 0, 2, 0, 0, 0, 0, 0, len(pattern), 1, 1] + payload
    copy = [17 | (13 << 16), target_id, 0, 0, 0, 0,
            source_id, 0, 0, 0, 0, len(pattern), 1, 1]
    words = write + copy
    command = (ctypes.c_uint32 * len(words))(*words)
    handles = (ctypes.c_uint32 * 2)(source_handle, target_handle)
    ioctl(fd, 0x42, '=IIQQIiIIIIQQ', 0, ctypes.sizeof(command),
          ctypes.addressof(command), ctypes.addressof(handles), 2, -1,
          0, 0, 0, 0, 0, 0)
    ioctl(fd, 0x48, '=II', target_handle, 0)
    assert target_map[:len(pattern)] == pattern, 'Renderer copy/readback mismatch'

def external_dma_buf(size):
    if os.path.exists('/dev/dma_heap/system'):
        heap = os.open('/dev/dma_heap/system', os.O_RDWR)
        try:
            data = bytearray(struct.pack('=QIIQ', size, 0, os.O_RDWR | os.O_CLOEXEC, 0))
            fcntl.ioctl(heap, 0xc0184800, data, True)
            return struct.unpack('=QIIQ', data)[1]
        finally:
            os.close(heap)
    if os.path.exists('/dev/udmabuf'):
        mem = os.memfd_create('fdinfo-import', os.MFD_ALLOW_SEALING | os.MFD_CLOEXEC)
        dev = os.open('/dev/udmabuf', os.O_RDWR)
        try:
            os.ftruncate(mem, size)
            fcntl.fcntl(mem, fcntl.F_ADD_SEALS, fcntl.F_SEAL_SHRINK)
            return fcntl.ioctl(dev, 0x40187542, struct.pack('=IIQQ', mem, 1, 0, size))
        finally:
            os.close(dev)
            os.close(mem)
    raise RuntimeError('Need CONFIG_DMABUF_HEAPS_SYSTEM=y or CONFIG_UDMABUF=y')

def kernel_log():
    p = subprocess.run(['dmesg', '--color=never'], capture_output=True, text=True)
    if p.returncode:
        raise RuntimeError('Run as root so host error responses can be checked')
    return p.stdout.splitlines()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hold', nargs='?', type=int, const=-1, default=0,
                        help='keep handles for N seconds; no N means until Ctrl+C')
    args = parser.parse_args()
    fds, maps = [], []
    try:
        devices = {}
        for path in sorted(glob.glob('/dev/dri/card[0-9]*')):
            fd = os.open(path, os.O_RDWR | os.O_CLOEXEC)
            fds.append(fd)
            try:
                if 'drm-driver:\tvirtio_gpu' not in fdinfo(fd):
                    continue
                devices[bool(getparam(fd, 1))] = (path, fd)
            except OSError:
                continue
        if True not in devices or False not in devices:
            raise RuntimeError('Need separate virgl and non-virgl blob-capable virtio-gpu devices')
        path3d, gpu = devices[True]
        path2d, importer = devices[False]
        if not getparam(gpu, 3) or not getparam(importer, 3):
            raise RuntimeError('Both devices must advertise blob support')
        if not getparam(gpu, 4):
            raise RuntimeError('3D device needs host-visible memory (QEMU hostmem)')
        baseline = kernel_log()
        context_init(gpu)
        host_size, mixed_size, import_size = 1 << 20, 2 << 20, 3 << 20

        host, host_id = blob(gpu, 2, host_size, 101, 1)
        host_map = mapping(gpu, host, host_size)
        maps.append(host_map)
        pattern = b'virtio-fdinfo-host-map-test'
        host_map[:len(pattern)] = pattern
        assert host_map[:len(pattern)] == pattern
        _, name = ioctl(gpu, 0x0a, '=II', host, 0)
        _, alias, _ = ioctl(gpu, 0x0b, '=IIQ', name, 0, 0)
        assert host != alias

        mixed, mixed_id = blob(gpu, 3, mixed_size, 102, 0)
        guest_map = mapping(gpu, mixed, mixed_size)
        maps.append(guest_map)
        # virglrenderer 1.1 does not wire mixed iov into its pipe transfer
        # path. Validate the actual mixed GL storage with renderer commands.
        renderer_copy_check(gpu, mixed, mixed_id, host, host_id, host_map)

        dma_fd = external_dma_buf(import_size)
        fds.append(dma_fd)
        imported, _, _ = ioctl(importer, 0x2e, '=IIi', 0, 0, dma_fd)
        assert imported

        # Check renderer/device errors as well as guest-visible counters.
        time.sleep(0.3)
        lines = kernel_log()
        new_lines = lines[len(baseline):] if lines[:len(baseline)] == baseline else lines
        bad = [line for line in new_lines
               if 'virtio_gpu' in line and ('ERROR' in line or 'WARNING' in line)]
        if bad:
            raise RuntimeError('Device/renderer errors:\n' + '\n'.join(bad))

        assert value(gpu, 'drm-total-host3d') == host_size
        assert value(gpu, 'drm-shared-host3d') == host_size
        assert value(gpu, 'drm-total-memory') == mixed_size
        assert value(gpu, 'drm-virtio-mixed-blob-logical') == mixed_size
        assert value(importer, 'drm-virtio-imported-logical') == import_size
        assert value(importer, 'drm-total-memory') == 0
        print('PASS: host map, shared alias dedup, mixed renderer write/copy readback, external import', flush=True)
        print('PID:', os.getpid(), flush=True)
        for path, fd in ((path3d, gpu), (path2d, importer)):
            print('FD %d: %s\n%s' % (fd, path, fdinfo(fd)), flush=True)
        if args.hold:
            print('Keeping resources alive; Ctrl+C closes all test objects.', flush=True)
            deadline = time.monotonic() + args.hold
            while args.hold < 0 or time.monotonic() < deadline:
                time.sleep(1)
    finally:
        for view in reversed(maps):
            view.close()
        for fd in reversed(fds):
            os.close(fd)

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
