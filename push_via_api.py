#!/usr/bin/env python3
"""在 github.com 被网络阻断、但 api.github.com 可达时，用 Git Data API 推送提交。

做法（能精确复现本地 commit）：
  1. 读本地 HEAD 的 tree/parent/author/committer/message
  2. 用 base_tree = parent 的 tree 创建新 tree（只上传改动文件为 blob）
  3. 用与本地完全一致的元数据创建 commit → SHA 应与本地一致
  4. 更新 refs/heads/main（快进）

用法：python3 push_via_api.py [remote] [branch]
"""
import base64
import json
import subprocess
import sys

REPO = "wsytl/thermal-printer"
REMOTE = sys.argv[1] if len(sys.argv) > 1 else "origin"
BRANCH = sys.argv[2] if len(sys.argv) > 2 else "main"


def git(*args) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout.strip()


def api(method: str, path: str, payload: dict | None = None):
    cmd = ["gh", "api", "-X", method, path]
    if payload is not None:
        cmd += ["--input", "-"]
    r = subprocess.run(cmd, input=json.dumps(payload) if payload else None,
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"API 失败 {method} {path}: {r.stderr.strip()}")
    return json.loads(r.stdout) if r.stdout.strip() else {}


def push_full(head, remote_sha, tree_local, msg, meta):
    """全量重建：把本地所有文件上传为 blob，用完整 tree 创建提交，
    保证远程 tree 与本地完全一致（用于两边内容已经不一致时的对齐）。"""
    entries = []
    for line in git("ls-files", "-s").splitlines():
        meta_part, path = line.split("\t")
        mode = meta_part.split()[0]          # 100644 / 100755 / 120000 —— 必须照抄，否则 tree 不一致
        content = base64.b64encode(open(path, "rb").read()).decode()
        blob = api("POST", f"repos/{REPO}/git/blobs", {"content": content, "encoding": "base64"})
        entries.append({"path": path, "mode": mode, "type": "blob", "sha": blob["sha"]})
    print(f"  已上传 {len(entries)} 个文件")
    tree = api("POST", f"repos/{REPO}/git/trees", {"tree": entries})
    print(f"  新 tree {tree['sha'][:10]} / 本地 {tree_local[:10]} "
          f"{'✓ 一致' if tree['sha'] == tree_local else '⚠️ 仍不同'}")
    commit = api("POST", f"repos/{REPO}/git/commits", {
        "message": msg, "tree": tree["sha"], "parents": [remote_sha],
        "author": {"name": meta[0], "email": meta[1], "date": meta[2]},
        "committer": {"name": meta[3], "email": meta[4], "date": meta[5]},
    })
    api("PATCH", f"repos/{REPO}/git/refs/heads/{BRANCH}", {"sha": commit["sha"], "force": False})
    print(f"✅ 已对齐：{REPO} {BRANCH} → {commit['sha'][:10]}")


def main():
    head = git("rev-parse", "HEAD")
    parent = git("rev-parse", "HEAD~1")
    tree_local = git("rev-parse", "HEAD^{tree}")
    msg = git("log", "-1", "--format=%B")
    meta = git("log", "-1", "--format=%an|%ae|%aI|%cn|%ce|%cI").split("|")

    remote_sha = api("GET", f"repos/{REPO}/git/ref/heads/{BRANCH}")["object"]["sha"]
    remote_tree = api("GET", f"repos/{REPO}/git/commits/{remote_sha}")["tree"]["sha"]
    parent_tree = git("rev-parse", f"{parent}^{{tree}}")   # 本地父提交的 tree
    print(f"本地 HEAD   : {head[:10]}  tree {tree_local[:10]}")
    print(f"远程 {BRANCH:<7}: {remote_sha[:10]}  tree {remote_tree[:10]}")
    # 注意：API 创建的提交元数据与本地不同，SHA 可能不同；以 **tree** 判断内容是否一致
    if remote_tree == tree_local:
        print("✅ 远程内容已与本地一致（tree 相同），无需推送")
        return
    if remote_tree != parent_tree:
        print("⚠️ 远程 tree 与本地父提交不同 → 改用全量重建对齐")
        push_full(head, remote_sha, tree_local, msg, meta)
        return
    print("✓ 远程 tree 等于本地父提交，可快进")

    # 改动文件
    changed = [l.split("\t", 1) for l in git("diff", "--name-status", parent, head).splitlines()]
    entries = []
    for status, path in changed:
        if status == "D":
            entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
            print(f"  D {path}")
        else:
            content = base64.b64encode(open(path, "rb").read()).decode()
            blob = api("POST", f"repos/{REPO}/git/blobs",
                       {"content": content, "encoding": "base64"})
            entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})
            print(f"  {status} {path}  blob {blob['sha'][:8]}")

    tree = api("POST", f"repos/{REPO}/git/trees",
               {"base_tree": parent_tree, "tree": entries})
    print(f"新 tree: {tree['sha'][:8]}  本地 tree: {tree_local[:8]}  "
          f"{'✓ 一致' if tree['sha'] == tree_local else '⚠️ 不一致'}")

    commit = api("POST", f"repos/{REPO}/git/commits", {
        "message": msg,
        "tree": tree["sha"],
        "parents": [remote_sha],   # 接到远程现有提交上（本地 SHA 未上传）
        "author": {"name": meta[0], "email": meta[1], "date": meta[2]},
        "committer": {"name": meta[3], "email": meta[4], "date": meta[5]},
    })
    print(f"新 commit: {commit['sha'][:8]}  本地: {head[:8]}  "
          f"{'✓ 一致（本地远程同步）' if commit['sha'] == head else '⚠️ SHA 不同'}")

    api("PATCH", f"repos/{REPO}/git/refs/heads/{BRANCH}",
        {"sha": commit["sha"], "force": False})
    print(f"✅ 已更新 {REPO} {BRANCH} → {commit['sha'][:8]}")


if __name__ == "__main__":
    main()
