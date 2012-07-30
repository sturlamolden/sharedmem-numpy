
# This was posted by Robert Kern to scipy-user@scipy.org 

# Modified by Sturla Molden, 2009

import copy_reg
import sharedmem.heap as heap
from pickle import PicklingError

import numpy as np

__all__ = ['shared_empty', 'shared_zeros', 'shared_ones']


def get_fortran_strides(shape, dtype):
    """ Create a strides entry for the given structural information for
    a Fortran-strided array.
    """
    strides = tuple(dtype.itemsize * np.cumprod((1,) + shape[:-1]))
    return strides

class BufferWrapperArray(object):
    """ An object that exists to expose a BufferWrapper with an
    __array_interface__.
    """
    def __init__(self, wrapper, shape, dtype, order, strides, offset):
        
        self.wrapper = wrapper
        
        if strides is None:
            if order == 'C':
                strides = None
            else:
                strides = get_fortran_strides(shape, dtype)
        
        self.__array_interface__ = dict(
            data = (wrapper.get_address() + offset, False),
            descr = dtype.descr,
            shape = shape,
            strides = strides,
            typestr = dtype.str,
            version = 3,
        )


def reduce_shared_array(obj):
    """ Return the information that Pickler needs to serialize a shared-memory
    ndarray.
    """

    if obj.base is None:
        # normal ndarray
        # use numpy's default reduction
        return numpy_reduce(obj)

    elif isinstance(obj.base, BufferWrapperArray):
        # normal ndarray with shared memory
        # calculate data offset and keep the strides
        # offset will almost always be zero ... but someone may pickle a depickled view
        order = 'C'
        if obj.flags['F_CONTIGUOUS'] and not obj.flags['C_CONTIGUOUS']:
            order = 'F'
        base_addr = obj.base.wrapper.get_address()
        data_start = obj.__array_interface__['data'][0]
        offset = data_start - base_addr
        strides = obj.strides
        return rebuild_array, (obj.base.wrapper, obj.shape, obj.dtype, order, strides, offset)

    elif isinstance(obj.base, np.ndarray):

        # view array -- recurse backwards on base objects
        # to find out what we are looking at

        stack = [obj.base]
        while isinstance(stack[-1], np.ndarray):
            _b = stack[-1].base
            stack.append(_b)
        base = stack.pop()

        if base is None:
            # view of normal ndarray
            # use numpy's default reduction
            return numpy_reduce(obj)

        elif isinstance(base, BufferWrapperArray):
            # view of shared array
            # calculate data offset and keep the strides
            order = 'C'
            if obj.flags['F_CONTIGUOUS'] and not obj.flags['C_CONTIGUOUS']:
                order = 'F'
            base_addr = base.wrapper.get_address()
            data_start = obj.__array_interface__['data'][0]
            offset = data_start - base_addr
            strides = obj.strides
            return rebuild_array, (base.wrapper, obj.shape, obj.dtype, order, strides, offset)

        else:
            # view of something else
            # use numpy's default reduction
            return numpy_reduce(obj)
    else:
        # some other unknown buffer
        # use numpy's default reduction
        return numpy_reduce(obj)


def rebuild_array(wrapper, shape, dtype, order, strides, offset):
    """ Rebuild an array with the given information.
    """
    arr = np.asarray(BufferWrapperArray(wrapper, shape, dtype, order, strides, offset))
    return arr

numpy_reduce = np.ndarray.__reduce__
copy_reg.pickle(np.ndarray, reduce_shared_array)


def shared_empty(shape, dtype=float, order='C'):
    """ Create a shared-memory ndarray without initializing its contents.
    """
    dtype = np.dtype(dtype)
    if isinstance(shape, (int, long, np.integer)):
        shape = (shape,)
    shape = tuple(shape)
    size = int(np.prod(shape))
    nbytes = size * dtype.itemsize
    wrapper = heap.BufferWrapper(nbytes)
    strides = None
    offset = 0
    arr = rebuild_array(wrapper, shape, dtype, order, strides, offset)
    return arr

def shared_zeros(shape, dtype=float, order='C'):
    """ Create a shared-memory ndarray filled with 0s.
    """
    arr = shared_empty(shape, dtype, order)
    x = np.zeros((), arr.dtype)
    arr[...] = x
    return arr

def shared_ones(shape, dtype=float, order='C'):
    """ Create a shared-memory ndarray filled with 1s.
    """
    arr = shared_empty(shape, dtype, order)
    x = np.ones((), arr.dtype)
    arr[...] = x
    return arr

