# Written by Sturla Molden, 2009, 2011
# Released under SciPy license


DEF DEBUG = 0 # set to 1 for debugging memory allocation

cdef extern from "windows.h":

    ctypedef unsigned long DWORD
    ctypedef void *HANDLE
    ctypedef int BOOL
    ctypedef Py_ssize_t SIZE_T
    ctypedef void *LPCTSTR
    ctypedef void *LPVOID
    ctypedef void *LPCVOID
    ctypedef char *LPCSTR
   
    BOOL TRUE, FALSE
    HANDLE INVALID_HANDLE_VALUE
    
    cdef struct SECURITY_ATTRIBUTES:
        pass
    
    ctypedef char * LPCTSTR 
    BOOL CloseHandle(HANDLE h)
    DWORD GetLastError()
    DWORD ERROR_ALREADY_EXISTS, ERROR_INVALID_HANDLE

        
    HANDLE OpenFileMapping(DWORD dwDesiredAccess, BOOL bInheritHandle, LPCTSTR lpName)
    HANDLE CreateFileMapping(HANDLE hFile, SECURITY_ATTRIBUTES *lpAttributes,
        DWORD flProtect, DWORD dwMaximumSizeHigh, DWORD dwMaximumSizeLow, LPCTSTR lpName)
    DWORD PAGE_READWRITE
    LPVOID MapViewOfFile(HANDLE hFileMappingObject, DWORD dwDesiredAccess, DWORD dwFileOffsetHigh, 
                         DWORD dwFileOffsetLow, DWORD dwNumberOfBytesToMap)
    BOOL  UnmapViewOfFile(LPCVOID lpBaseAddress)
    DWORD FILE_MAP_ALL_ACCESS

    HANDLE LoadLibrary(LPCTSTR lpFileName)
    BOOL FreeLibrary(HANDLE hModule)
    LPVOID GetProcAddress(HANDLE hModule, LPCSTR lpProcName)


cdef extern from "Python.h":
    ctypedef long Py_intptr_t



# "Undocumented" NT-kernel system call for obtaining object HANDLE reference count 
# wrapped in C as Cython is not happy about function pointers to
# stdcall methods

cdef extern int get_reference_count(HANDLE h)


import uuid
import weakref
import numpy
import threading
import os
import sys


cdef object __mapped_addresses = dict()
cdef object __open_handles = weakref.WeakValueDictionary()
cdef object __module_rlock = threading.RLock()

cdef class Handle:
    
    """ Windows API HANDLE wrapper """ 
    
    cdef HANDLE handle
    cdef object name
    cdef object __weakref__
    
    def __init__(Handle self, h, name):
        self.handle = <HANDLE>(<Py_intptr_t> h)
        self.name = name
        IF DEBUG:
            with __module_rlock:
                print "Opened handle to %s" % (self.name,)
                sys.stdout.flush()
    
    def gethandle(Handle self):
        return int(<Py_intptr_t>self.handle)
                 
    def __dealloc__(Handle self):
        cdef object ma, size
        cdef BOOL b
        cdef void *addr
        with __module_rlock:
            try:
                ma, size = __mapped_addresses[ self.name ]
                addr = <void *>(<Py_intptr_t> ma)
                UnmapViewOfFile(addr)
                del __mapped_addresses[ self.name ]
            except KeyError:
                pass
            b = CloseHandle(self.handle)
            if (b == FALSE):
                raise OSError, "CloseHandle failed"
            IF DEBUG:
                print "Closed handle to %s" % (self.name,)
                sys.stdout.flush()
    
cdef object _os_exit

def _os_exit_monkey_patch(status):

    """
    Monkey patch for os._exit
    Windows will reference count open handles, so this is strictly
    speaking not needed, but now we can see that everything is cleaned
    up as expected.
    """

    cdef object ma, size
    cdef Handle h
    cdef BOOL b
    cdef void *addr

    with __module_rlock:

        for h in __open_handles.itervalues():

            try:
                ma, size = __mapped_addresses[ h.name ]
                addr = <void *>(<Py_intptr_t> ma)
                UnmapViewOfFile(addr)
                del __mapped_addresses[ h.name ]
            except KeyError:
                pass
            b = CloseHandle(h.handle)
            if (b == FALSE):
                print "Warning: CloseHandle failed before exit."
                sys.stdout.flush()
            IF DEBUG:
                print "Closed handle to %s" % (h.name,)
                sys.stdout.flush()
            
    # remove monkey patch on exit
    # well, it's not like we are going to use it anyway...
    os._exit = _os_exit

    # apoptosis
    _os_exit(status)

# monkey patch os._exit on init
_os_exit = os._exit
os._exit = _os_exit_monkey_patch




cdef int highlow(Py_ssize_t size, DWORD *high, DWORD *low) except -1:
    if size < 0:
        raise ValueError, "Negative buffer size"
    if sizeof(size) == sizeof(DWORD):
        # 32 bit
        high[0] = 0
        low[0] = <DWORD> size
    elif sizeof(size) == 2*sizeof(DWORD):
        # 64 bit
        high[0] = <DWORD> (size >> 32)
        low[0] = <DWORD> (size & 0x00000000FFFFFFFF)
    return 0



cdef class SharedMemoryBuffer:
    
    """ Windows API shared memory segment """
    
    cdef void *mapped_address
    cdef object handle
    cdef HANDLE c_handle
    cdef object name
    cdef Py_ssize_t size
        
    def __init__(SharedMemoryBuffer self, Py_ssize_t buf_size, name=None, unpickling=False):
        cdef HANDLE h
        cdef DWORD high, low
        highlow(buf_size,&high,&low)
        with __module_rlock:
            if name is None:
                self.name = uuid.uuid4().hex
            else:
                self.name = name
            if (name is None) and (unpickling):
                raise TypeError, "Cannot unpickle without a kernel object name."
            try:
                hh = __open_handles[ self.name ]
                self.handle = hh
                self.c_handle = <HANDLE> (<Py_intptr_t> hh.gethandle())
                ma, size = __mapped_addresses[ self.name ]
                self.mapped_address = <void *>(<Py_intptr_t> ma)
                self.size = <Py_ssize_t> size
            except KeyError:
                name = "Local\\%s" % self.name
                # create file mapping from the system paging file
                if not unpickling:
                    while 1:
                        h = CreateFileMapping(INVALID_HANDLE_VALUE, NULL,
                                    PAGE_READWRITE, high, low, <char*> name ) # FIXME : LPTCHAR
                        if h == NULL:
                            if (GetLastError() == ERROR_INVALID_HANDLE):
                                # name alredy exists
                                self.name = uuid.uuid4().hex
                                name = "Local\\%s" % self.name
                            else:
                                # failed for other reasons (e.g. size)
                                raise OSError, "Failed to create file mapping in local namespace."
                        elif (GetLastError() == ERROR_ALREADY_EXISTS):
                            # name alredy mapped
                            self.name = uuid.uuid4().hex
                            name = "Local\\%s" % self.name
                        else:
                            break
                else:
                    h = OpenFileMapping(FILE_MAP_ALL_ACCESS, TRUE, <char*> name ) # FIXME : LPTCHAR
                    if h == NULL:
                        raise OSError, "Failed to open file mapping in local namespace."
                self.handle = Handle(int(<Py_intptr_t> h), self.name)
                self.c_handle = h
                __open_handles[ self.name ] = self.handle

                # map the segment into process address space
                self.mapped_address = MapViewOfFile(self.c_handle, FILE_MAP_ALL_ACCESS, 0, 0, <SIZE_T> buf_size)
                if self.mapped_address == NULL:
                    raise OSError, 'failed to create map view of shared memory segment'
                    # handle will be automatically closed here
                ma = int(<Py_intptr_t> self.mapped_address)
                size = int(buf_size)
                __mapped_addresses[ self.name ] = ma, size
                self.size = buf_size


    # return number of open handles (one per process)
    def gethandlecount(SharedMemoryBuffer self):
        cdef int count
        count = get_reference_count(self.c_handle)
        if count < 0:
            raise OSError, "Could not obtain HANDLE reference count"
        else:
            return int(count)  
     

    # return base address and segment size
    # this will be used by the heap object
    def getbuffer(SharedMemoryBuffer self):
        return int(<Py_intptr_t> self.mapped_address), int(self.size)

    # pickle
    def __reduce__(SharedMemoryBuffer self):
        return (__unpickle_shm, (self.size, self.name))

                   
def __unpickle_shm(*args):
    s, n = args
    return SharedMemoryBuffer(s, name=n, unpickling=True)


