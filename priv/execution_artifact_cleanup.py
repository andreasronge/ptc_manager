"""Remove one finalized artifact without following path components or symlinks."""
import os
import shutil
import stat
import sys


def remove(root, relative):
    parts = relative.split('/')
    if not os.path.isabs(root) or len(parts) < 3 or any(p in ('', '.', '..') for p in parts):
        raise ValueError('invalid artifact path')
    if '.staging-' in parts[-1] or not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError('unsafe artifact deletion')
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    parent = os.open('/', flags)
    try:
        for part in root.strip('/').split('/') + parts[:-1]:
            if part in ('', '.', '..'):
                raise ValueError('invalid artifact root')
            child = os.open(part, flags, dir_fd=parent)
            os.close(parent)
            parent = child
        artifact = os.open(parts[-1], flags, dir_fd=parent)
        try:
            if not stat.S_ISREG(os.stat('manifest.json', dir_fd=artifact, follow_symlinks=False).st_mode):
                raise ValueError('artifact is not finalized')
        finally:
            os.close(artifact)
        shutil.rmtree(parts[-1], dir_fd=parent)
    finally:
        os.close(parent)


if __name__ == '__main__':
    try:
        remove(sys.argv[1], sys.argv[2])
    except (OSError, ValueError):
        print('artifact cleanup refused or failed', file=sys.stderr)
        sys.exit(1)
