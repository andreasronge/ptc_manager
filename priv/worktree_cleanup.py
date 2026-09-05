#!/usr/bin/python3 -I
"""Remove one validated direct child, as the worker, without following symlinks.

The coordinator validates the configured root and holds the cleanup claim.
Pin that root with a descriptor so replacing its path cannot redirect removal.
"""
import os
import shutil
import sys


def remove(root, target):
    if not shutil.rmtree.avoids_symlink_attacks:
        return 2
    if (not os.path.isabs(root) or root != os.path.normpath(root)
            or root == "/" or not os.path.isabs(target)
            or target != os.path.normpath(target)
            or os.path.dirname(target) != root):
        return 2
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        root_stat = os.fstat(root_fd)
        if root_stat.st_uid != os.geteuid() or root_stat.st_mode & 0o022:
            return 2
        os.fchdir(root_fd)
        name = os.path.basename(target)
        try:
            shutil.rmtree(name)
        except FileNotFoundError as error:
            if error.filename != name:
                raise
        return 0
    finally:
        os.close(root_fd)


if __name__ == "__main__":
    try:
        status = remove(*sys.argv[1:]) if len(sys.argv) == 3 else 2
    except OSError:
        status = 1
    sys.exit(status)
