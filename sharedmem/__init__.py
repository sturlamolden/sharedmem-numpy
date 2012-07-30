
from sharedmem.heap import cleanup
from sharedmem.array import shared_empty, shared_zeros, shared_ones
empty = shared_empty
zeros = shared_zeros
ones = shared_ones

__all__ = ['empty', 'ones', 'zeros', 'cleanup']





