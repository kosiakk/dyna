import re
from term import Term, Cons, Nil

try:
    from numpy import log, exp, sqrt
    from numpy.random import uniform
except ImportError:                       # XXX: should probably issue a warning.
    from math import log, exp, sqrt
    from random import random as _random
    def uniform(a=0, b=1):
        return _random() * (b - a) + a

def split(s, delim='\s+'):
    return todynalist(re.split(delim, s))

def pycall(name, *args):
    """
    Temporary foreign function interface - call Python functions from dyna!
    """
    args = tuple(topython(x) for x in args)
    x = eval(name)(*args)
    return todyna(x)

def todyna(x):
    if isinstance(x, (list, tuple)):
        return todynalist(x)
    return x

def topython(x):
    if isinstance(x, (Cons, Nil)):
        return x.aslist
    return x

def todynalist(x):
    return _todynalist(list(x))

def _todynalist(x):
    if not x:
        return Nil
    return Cons(x[0], _todynalist(x[1:]))
