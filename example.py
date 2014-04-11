import multiprocessing as mp
import numpy as np
import sharedmem as shm

def proc(qin, qout):
     print("grabbing array from queue")
     a = qin.get()
     print(a)
     print("putting array in queue")
     b = shm.zeros(10)
     print(b)
     qout.put(b)
     print("waiting for array to be updated by another process")
     a = qin.get()
     print(b)

if __name__ == "__main__":
     qin = mp.Queue()
     qout = mp.Queue()
     p = mp.Process(target=proc, args=(qin,qout))
     p.start()
     a = shm.zeros(4)
     qin.put(a)
     b = qout.get()
     b[:] = range(10)
     qin.put(None)
     p.join()
     

sturla$ python example.py
grabbing array from queue
[ 0.  0.  0.  0.]
putting array in queue
[ 0.  0.  0.  0.  0.  0.  0.  0.  0.  0.]
waiting for array to be updated by another process
[ 0.  1.  2.  3.  4.  5.  6.  7.  8.  9.]
