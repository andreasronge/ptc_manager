#!/usr/bin/python3 -I
"""Snapshot one managed worktree without changing its index, HEAD, or files."""
import hashlib
import json
import os
import re
import resource
import shutil
import stat
import subprocess
import sys
import tempfile

TOKEN = re.compile(r"^[A-Za-z0-9_-]{20,64}$")
BRANCH = re.compile(r"^ptc-manager/issue-[0-9]+-job-[0-9]+$")
MAX_ARTIFACT_BYTES = 100 * 1024 * 1024
MAX_ARTIFACT_FILE_BYTES = MAX_ARTIFACT_BYTES // 2


def git(path, args, env=None, text=True):
    result = subprocess.run(
        ["/usr/bin/git", "-C", path, "--no-optional-locks", "-c", "core.hooksPath=/dev/null", *args],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=env, text=text, timeout=60
    )
    return result.stdout.strip() if text else result.stdout


def owned_directory(path, shared=False):
    # The shared artifact root is a write-only drop box (1730): workers may
    # create their own staging directory but may not list retained artifacts.
    # O_PATH validates the directory itself without requiring read permission.
    access = os.O_PATH if shared and hasattr(os, "O_PATH") else os.O_RDONLY
    descriptor = os.open(path, access | os.O_DIRECTORY | os.O_NOFOLLOW)
    status = os.fstat(descriptor)
    private = status.st_uid == os.geteuid() and not status.st_mode & 0o022
    sticky_shared = (
        shared and status.st_uid == 0 and status.st_mode & 0o1000
        and (status.st_gid == os.getegid() or status.st_gid in os.getgroups())
        and status.st_mode & 0o020
        and not status.st_mode & 0o002
    )
    if not (private or sticky_shared):
        os.close(descriptor)
        raise PermissionError(path)
    return descriptor


def changed_bytes(path):
    records = git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], text=False).split(b"\0")
    total = 0
    index = 0
    while index < len(records) and records[index]:
        record = records[index]
        if len(record) < 4:
            raise ValueError("invalid git status")
        status = record[:2]
        filename = record[3:]
        index += 2 if b"R" in status or b"C" in status else 1
        try:
            file_status = os.stat(filename, dir_fd=None, follow_symlinks=False)
        except FileNotFoundError:
            continue
        if stat.S_ISREG(file_status.st_mode):
            total += file_status.st_size
            if total > MAX_ARTIFACT_FILE_BYTES:
                raise OSError("retained changes exceed 50 MiB")
    return total


def preserve(root, target, artifact_root, allocation_id, token, expected_branch):
    if (not os.path.isabs(root) or root != os.path.normpath(root) or root == "/"
            or not os.path.isabs(target) or target != os.path.normpath(target)
            or os.path.dirname(target) != root or not os.path.isabs(artifact_root)
            or artifact_root != os.path.normpath(artifact_root)
            or not allocation_id.isdecimal() or not TOKEN.fullmatch(token)
            or not BRANCH.fullmatch(expected_branch)):
        return 2

    root_fd = owned_directory(root)
    artifact_fd = owned_directory(artifact_root, shared=True)
    try:
        target_fd = os.open(
            os.path.basename(target),
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=root_fd,
        )
        target_status = os.fstat(target_fd)
        if target_status.st_uid != os.geteuid():
            os.close(target_fd)
            return 2
        os.fchdir(target_fd)

        if not os.path.samefile(git(".", ["rev-parse", "--show-toplevel"]), "."):
            os.close(target_fd)
            return 2
        if git(".", ["symbolic-ref", "--quiet", "--short", "HEAD"]) != expected_branch:
            os.close(target_fd)
            return 2

        final_name = f"allocation-{allocation_id}-{token}"
        final_path = os.path.join(artifact_root, final_name)
        if os.path.lexists(final_path):
            return 2

        resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_ARTIFACT_FILE_BYTES, MAX_ARTIFACT_FILE_BYTES))
        staging = tempfile.mkdtemp(prefix=f".{final_name}.", dir=artifact_root)
        try:
            changed_bytes(".")
            index = os.path.join(staging, "index")
            env = os.environ.copy()
            env.update({"GIT_INDEX_FILE": index, "GIT_CONFIG_NOSYSTEM": "1"})
            git(".", ["read-tree", "HEAD"], env)
            git(".", ["add", "-A", "--", "."], env)
            tree = git(".", ["write-tree"], env)
            head = git(".", ["rev-parse", "HEAD^{commit}"])
            branch_ref = f"refs/heads/{expected_branch}"

            bundle = os.path.join(staging, "commits.bundle")
            git(".", ["bundle", "create", bundle, branch_ref])

            patch = os.path.join(staging, "worktree.patch")
            with open(patch, "wb") as stream:
                subprocess.run(
                    ["/usr/bin/git", "-C", ".", "--no-optional-locks", "-c", "core.hooksPath=/dev/null",
                     "diff", "--binary", "--no-ext-diff", "--no-textconv", head, tree],
                    check=True, stdout=stream, stderr=subprocess.PIPE, env=env, timeout=60
                )

            os.unlink(index)

            if os.path.getsize(bundle) + os.path.getsize(patch) > MAX_ARTIFACT_BYTES:
                raise OSError("retained artifact exceeds 100 MiB")

            def digest(path):
                value = hashlib.sha256()
                with open(path, "rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        value.update(chunk)
                return value.hexdigest()

            if (git(".", ["symbolic-ref", "--quiet", "--short", "HEAD"]) != expected_branch
                    or git(".", ["rev-parse", "HEAD^{commit}"]) != head
                    or git(".", ["bundle", "list-heads", bundle]) != f"{head} {branch_ref}"):
                raise OSError("worktree changed during preservation")

            metadata = {
                "artifact_path": final_path,
                "branch": expected_branch,
                "bundle_sha256": digest(bundle),
                "head_sha": head,
                "patch_sha256": digest(patch),
                "tree_sha": tree,
            }
            with open(os.path.join(staging, "metadata.json"), "w", encoding="utf-8") as stream:
                json.dump(metadata, stream, sort_keys=True, separators=(",", ":"))
                stream.write("\n")
            os.rename(staging, final_path, src_dir_fd=None, dst_dir_fd=None)
            print(json.dumps(metadata, separators=(",", ":")))
            return 0
        finally:
            if os.path.isdir(staging):
                shutil.rmtree(staging)
            os.close(target_fd)
    finally:
        os.close(root_fd)
        os.close(artifact_fd)


if __name__ == "__main__":
    try:
        code = preserve(*sys.argv[1:]) if len(sys.argv) == 7 else 2
    except (OSError, subprocess.SubprocessError, ValueError, json.JSONDecodeError):
        code = 1
    sys.exit(code)
