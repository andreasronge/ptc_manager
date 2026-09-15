#!/usr/bin/python3 -I
"""Validate and make one retained-work artifact immutable to managed agents."""
import hashlib
import json
import os
import re
import stat
import sys

NAME = re.compile(r"^allocation-[0-9]+-[A-Za-z0-9_-]{20,64}$")
FILES = {"commits.bundle", "worktree.patch", "metadata.json"}


def digest(descriptor):
    value = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    for chunk in iter(lambda: os.read(descriptor, 1024 * 1024), b""):
        value.update(chunk)
    return value.hexdigest()


def seal(root, target):
    if (not os.path.isabs(root) or root != os.path.normpath(root) or root == "/"
            or not os.path.isabs(target) or target != os.path.normpath(target)
            or os.path.dirname(target) != root or not NAME.fullmatch(os.path.basename(target))):
        return 2

    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        root_status = os.fstat(root_fd)
        if root_status.st_uid != os.geteuid() or not root_status.st_mode & stat.S_ISVTX:
            return 21
        artifact_fd = os.open(
            os.path.basename(target), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd
        )
        descriptors = {}
        try:
            artifact_status = os.fstat(artifact_fd)
            if os.geteuid() == 0 and artifact_status.st_uid == 0:
                return 22
            if set(os.listdir(artifact_fd)) != FILES:
                return 23
            for filename in FILES:
                descriptor = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=artifact_fd)
                descriptors[filename] = descriptor
                status = os.fstat(descriptor)
                if not stat.S_ISREG(status.st_mode) or status.st_uid != artifact_status.st_uid:
                    return 24

            metadata_bytes = b""
            os.lseek(descriptors["metadata.json"], 0, os.SEEK_SET)
            for chunk in iter(lambda: os.read(descriptors["metadata.json"], 65_537), b""):
                metadata_bytes += chunk
                if len(metadata_bytes) > 65_536:
                    return 25
            metadata = json.loads(metadata_bytes)
            if (metadata.get("artifact_path") != target
                    or digest(descriptors["commits.bundle"]) != metadata.get("bundle_sha256")
                    or digest(descriptors["worktree.patch"]) != metadata.get("patch_sha256")):
                return 26

            for descriptor in descriptors.values():
                os.fchown(descriptor, os.geteuid(), os.getegid())
                os.fchmod(descriptor, 0o400)
            os.fchown(artifact_fd, os.geteuid(), os.getegid())
            os.fchmod(artifact_fd, 0o500)
            print(target)
            return 0
        finally:
            for descriptor in descriptors.values():
                os.close(descriptor)
            os.close(artifact_fd)
    finally:
        os.close(root_fd)


if __name__ == "__main__":
    try:
        code = seal(*sys.argv[1:]) if len(sys.argv) == 3 else 2
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(str(error), file=sys.stderr)
        code = 1
    sys.exit(code)
