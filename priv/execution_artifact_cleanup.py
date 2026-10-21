"""Remove one finalized artifact without following path components or symlinks."""
import os
import stat
import sys

FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def remove_tree(name, parent):
    # shutil.rmtree(dir_fd=...) needs Python 3.11; macOS ships 3.9.
    directory = os.open(name, FLAGS, dir_fd=parent)
    try:
        with os.scandir(directory) as entries:
            children = [(entry.name, entry.is_dir(follow_symlinks=False)) for entry in entries]
        for child, is_directory in children:
            if is_directory:
                remove_tree(child, directory)
            else:
                os.unlink(child, dir_fd=directory)
    finally:
        os.close(directory)
    os.rmdir(name, dir_fd=parent)


def remove(root, relative):
    parts = relative.split('/')
    if not os.path.isabs(root) or len(parts) < 3 or any(p in ('', '.', '..') for p in parts):
        raise ValueError('invalid artifact path')
    if '.staging-' in parts[-1] or os.scandir not in os.supports_fd:
        raise ValueError('unsafe artifact deletion')
    parent = os.open('/', FLAGS)
    try:
        for part in root.strip('/').split('/') + parts[:-1]:
            if part in ('', '.', '..'):
                raise ValueError('invalid artifact root')
            child = os.open(part, FLAGS, dir_fd=parent)
            os.close(parent)
            parent = child
        artifact = os.open(parts[-1], FLAGS, dir_fd=parent)
        try:
            if not stat.S_ISREG(os.stat('manifest.json', dir_fd=artifact, follow_symlinks=False).st_mode):
                raise ValueError('artifact is not finalized')
        finally:
            os.close(artifact)
        remove_tree(parts[-1], parent)
    finally:
        os.close(parent)


if __name__ == '__main__':
    try:
        remove(sys.argv[1], sys.argv[2])
    except (OSError, ValueError):
        print('artifact cleanup refused or failed', file=sys.stderr)
        sys.exit(1)
