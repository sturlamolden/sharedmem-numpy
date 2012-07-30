# Written by Sturla Molden and Gael Varoquaux, 2009, 2011.
# Thanks to Philip Semanchuk for advice on System V IPC.
# Released under SciPy license.

DEF DEBUG = 0 # set to 1 for debugging memory allocation

ctypedef Py_ssize_t size_t

cdef extern from "errno.h":
    int errno
    int EEXIST
    int EACCES
    int ENOMEM
 
cdef extern from "string.h":
    void memset(void *addr, int val, size_t len)
    void memcpy(void *trg, void *src, size_t len)

cdef extern from "sys/types.h":
    ctypedef int key_t

cdef extern from "sys/shm.h":

    ctypedef unsigned int shmatt_t

    cdef struct shmid_ds:
        shmatt_t shm_nattch

    int   shmget(key_t key, size_t size, int shmflg)
    void *shmat(int shmid, void *shmaddr, int shmflg)
    int   shmdt(void *shmaddr)
    int   shmctl(int shmid, int cmd, shmid_ds *buf) nogil


cdef extern from "sys/ipc.h":

    key_t ftok(char *path, int id)

    int IPC_STAT, IPC_RMID, IPC_CREAT, IPC_EXCL, IPC_PRIVATE


cdef extern from "unistd.h":
    unsigned int sleep(unsigned int seconds) nogil

cdef extern from "Python.h":
    ctypedef long Py_intptr_t


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
    
    """ Automatic shared segment deattachment
        - without this object we would need to do reference 
        counting manually, as shmdt is global to the process.
        Do not instantiate this class, except from within 
        SharedMemoryBuffer.__init__.  
    """ 
    
    cdef int shmid
    cdef object name
    cdef object __weakref__
    
    def __init__(Handle self, shmid, name):
        self.shmid = <int> shmid
        self.name = name
    
    def gethandle(Handle self):
        return int(self.shmid)
                 
    def __dealloc__(Handle self):
        self.dealloc()

    def dealloc(Handle self):
        cdef object ma, size
        cdef shmid_ds buf
        cdef int _shmid = <int> self.shmid
        cdef void *addr
        cdef int ierr

        with __module_rlock:

            try:
                ma, size = __mapped_addresses[ self.name ]
                addr = <void *>(<Py_intptr_t> ma)
                ierr = shmdt(addr)
                if (ierr < 0):
                    raise MemoryError, "shmdt failed. Possible system-wide memory leak."
                del __mapped_addresses[ self.name ]
                #print "Process %d detached from segment %d\n" % (os.getpid(), int(self.shmid)) # DEBUG
            except KeyError:
                pass

            # Mark segment for removal if nobody is attached:
            # Important:
            # -- this is safer on Windows where the kernel cleans up.
            # -- if you get a memory leak here, only a reboot will help.
            # -- you must own the segment or be superuser to remove it,
            #    i.e. os.setuid is evil in this context.

            if(shmctl(_shmid, IPC_STAT, &buf) < 0):
                raise OSError, "shmctl failed with IPC_STAT - you could have a memory leak!"
            elif (buf.shm_nattch == 0):
                if(shmctl(_shmid, IPC_RMID, NULL) < 0):
                    raise OSError, "shmctl failed with IPC_RMID - you have a memory leak!"
                else:
                    #print "Process %d removed segment %d\n" % (os.getpid(), int(self.shmid)) # DEBUG
                    pass
            else:
                pass



cdef object _os_exit

def _os_exit_monkey_patch(status):

    """
    Monkey patch for os._exit to make sure multiprocessing
    do not cause a permament system wide memory leak by skipping
    manual deletion of shared memory segments.
    """

    cdef object ma, size
    cdef Handle h
    cdef shmid_ds buf
    cdef int shmid
    cdef void *addr
    cdef int ierr

    with __module_rlock:

        for h in __open_handles.itervalues():

            shmid = <int> h.shmid
            try:
                # detach segment corresponding to h
                ma, size = __mapped_addresses[ h.name ]
                addr = <void *>(<Py_intptr_t> ma)
                ierr = shmdt(addr)
                if (ierr < 0):
                    print "Warning: shmdt failed before exit. Possible system-wide memory leak."
                    sys.stdout.flush()
                del __mapped_addresses[ h.name ]
                #print "Process %d detached from segment %d\n" % (os.getpid(), int(h.shmid)) # DEBUG
            except KeyError:
                pass

            # mark segment for removal if nobody is attached
            if(shmctl(shmid, IPC_STAT, &buf) < 0):
                raise OSError, "shmctl failed with IPC_STAT - you could have a memory leak!"
            elif (buf.shm_nattch == 0):
                if(shmctl(shmid, IPC_RMID, NULL) < 0):
                    raise OSError, "shmctl failed with IPC_RMID - you have a memory leak!"
                else:
                    #print "Process %d removed segment %d\n" % (os.getpid(), int(h.shmid)) # DEBUG
                    pass
            else:
                pass

    # remove monkey patch on exit
    # well, it's not like we are going to use it anyway...
    os._exit = _os_exit

    # apoptosis 
    _os_exit(status)

# monkey patch os._exit on init
_os_exit = os._exit
os._exit = _os_exit_monkey_patch


cdef class SharedMemoryBuffer:
    
    """ Windows API shared memory segment """
    
    cdef void *mapped_address
    cdef object name
    cdef object handle
    cdef int shmid
    cdef Py_ssize_t size
        
    def __init__(SharedMemoryBuffer self, Py_ssize_t buf_size,
                        name=None, unpickling=False):
        cdef void* mapped_address
        cdef long  mode
        cdef int   shmid
        cdef int   ikey
        cdef key_t key
        
        lkey = 1 if IPC_PRIVATE < 0 else IPC_PRIVATE + 1

        if (name is None) and (unpickling):
            raise TypeError, "Cannot unpickle without a kernel object name."

        elif (name is None) and not unpickling:

            # create a brand new shared segment
            with __module_rlock:
                while 1:
                    self.name = numpy.random.random_integers(lkey, int(2147483646))
                    ikey = <int> self.name
                    memset(<void *> &key, 0, sizeof(key_t))
                    memcpy(<void *> &key, <void *> &ikey, sizeof(int)) # key_t is large enough to contain an int
                    shmid = shmget(key, buf_size, IPC_CREAT|IPC_EXCL|0600)
                    if (shmid < 0):
                        if (errno != EEXIST):
                            raise OSError, "Failed to open shared memory"
                    else: # we have an open segment
                        #print "Process %d created segment %d\n" % (os.getpid(), int(shmid)) # DEBUG
                        break

                self.handle = Handle(int(shmid), self.name)
                __open_handles[ self.name ] = self.handle

                mapped_address = shmat(shmid, NULL, 0)
                if (mapped_address == <void *> -1):
                    if errno == EACCES:
                        raise OSError, "Failed to attach shared memory: permission denied"
                    elif errno == ENOMEM:
                        raise OSError, "Failed to attach shared memory: insufficient memory"
                    else:
                        raise OSError, "Failed to attach shared memory"
                else:
                    #print "Process %d attached to segment %d\n" % (os.getpid(), int(shmid)) # DEBUG
                    pass

                self.shmid = shmid
                self.size = buf_size
                self.mapped_address = mapped_address
                ma = int(<Py_intptr_t> self.mapped_address)
                size = int(buf_size)
                __mapped_addresses[ self.name ] = ma, size 

              
        else: # unpickling
            with __module_rlock:
                self.name = name
                try:

                    # check if this process has an open handle to
                    # this segment already

                    self.handle = __open_handles[ self.name ]
                    self.shmid = <int> self.handle.gethandle()
                    ma, size = __mapped_addresses[ self.name ]
                    self.mapped_address = <void *>(<Py_intptr_t> ma)
                    self.size = <Py_ssize_t> size

                except KeyError:

                    # unpickle a segment created by another process

                    ikey = <int> self.name
                    memset(<void *> &key, 0, sizeof(key_t))
                    memcpy(<void *> &key, <void *> &ikey, sizeof(int))
                    shmid = shmget(key, buf_size, 0)
                    if (shmid < 0):
                        raise OSError, "Failed to open shared memory"
                    self.handle = Handle(int(shmid), name)
                    __open_handles[ self.name ] = self.handle

                    mapped_address = shmat(shmid, NULL, 0)
                    if (mapped_address == <void *> -1):
                        raise OSError, "Failed to attach shared memory"
                    self.shmid = shmid
                    self.size = buf_size
                    self.mapped_address = mapped_address
                    ma = int(<Py_intptr_t> self.mapped_address)
                    size = int(buf_size)
                    __mapped_addresses[ self.name ] = ma, size  

   
    # return number of open handles (one per process)
    def gethandlecount(SharedMemoryBuffer self):
        cdef shmid_ds buf
        if (shmctl(self.shmid, IPC_STAT, &buf) < 0):
            raise OSError, "shmctl failed with IPC_STAT."
        else:
            return int(buf.shm_nattch)

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









