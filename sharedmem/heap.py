from __future__ import with_statement

import sys
import threading
import multiprocessing

if sys.version_info < (2, 5):
    import multiprocessing._mmap25 as mmap
else:
    import mmap

__all__ = ['BufferWrapper', 'cleanup']


if sys.platform == 'win32':
    from sharedmemory_win import SharedMemoryBuffer 
else:
    from sharedmemory_sysv import SharedMemoryBuffer 


class simple_allocator(object):

    def __init__(self):
        self.lock = threading.Lock()
        self.size = mmap.PAGESIZE
        self.offset = 0
        self.buf = SharedMemoryBuffer(self.size)

    def _allocate_tiny(self, size):
        free = self.size - self.offset
        if (size > free):
            self.size += mmap.PAGESIZE
            if (self.size > 1024**2): self.size = 1024**2
            self.buf = SharedMemoryBuffer(self.size)
            self.offset = size
            addr, _= self.buf.getbuffer()
            return 0, self.buf
        else:
            offset = self.offset
            self.offset += size
            addr, _= self.buf.getbuffer()
            return offset, self.buf
            
    def _allocate_big(self, size):
        buf = SharedMemoryBuffer(size)
        addr, _ = buf.getbuffer()
        return 0, buf

        
    def allocate(self, size):
        with self.lock:
            if size > mmap.PAGESIZE:
                offset, buf = self._allocate_big(size)
            else:
                offset, buf = self._allocate_tiny(size)
        return offset, buf


_heap = simple_allocator()


class BufferWrapper(object):

    def __init__(self, size):
        self.size = size
        self.offset, self.buf = _heap.allocate(size)
        
    def __setstate__(self, _state):
        self.offset, self.buf, self.size = _state

    def __getstate__(self):
        return self.offset, self.buf, self.size
        
    def get_address(self):
        addr, _ = self.buf.getbuffer()
        return self.offset + addr

    def get_size(self):
        return self.size

def cleanup():
    global _heap
    _heap = None
    










