#!/usr/bin/env python3
"""Fake `gh` for the bazaar harnesses. Serves and mutates a JSON state file
($FAKE_GH_STATE) and appends every invocation to $RECORD. Only the surface the
bazaar scripts use is modelled; unknown commands exit 0 with empty output so a
new call site fails a test on its assertion rather than on the stub.

State shape:
  {"repo": "o/r", "default_branch": "main", "login": "me",
   "issues": {"7": {"number":7,"id":1007,"title":..,"body":..,"state":"OPEN","createdAt":..,
                    "labels":[..],"comments":[{"author":..,"body":..,"createdAt":..}],
                    "parent":null,"sub_issues":[..]}},
   "prs": {"12": {"number":12,"headRefName":..,"state":"OPEN","isDraft":true,"mergedAt":null,
                  "body":..,"comments":[..],"reviews":[..],"files":[..],"headRefOid":..}},
   "statuses": [], "labels_created": [], "merged": [], "next_id": 1}
"""
import json, os, sys, datetime

STATE = os.environ["FAKE_GH_STATE"]
RECORD = os.environ.get("RECORD")
args = sys.argv[1:]

def load(): return json.load(open(STATE))
def save(s): json.dump(s, open(STATE, "w"), indent=1)
def now(): return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
def opt(name, default=None):
    if name in args:
        i = args.index(name); return args[i + 1] if i + 1 < len(args) else default
    for a in args:
        if a.startswith(name + "="): return a.split("=", 1)[1]
    return default
def opts(name):
    out = []
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args): out.append(args[i + 1])
        elif a.startswith(name + "="): out.append(a.split("=", 1)[1])
    return out
def body_arg():
    f = opt("--body-file")
    if f == "-": return sys.stdin.read()
    if f: return open(f).read()
    return opt("--body", "")
def positional(after):
    i = args.index(after)
    for a in args[i + 1:]:
        if not a.startswith("-"): return a
    return None

if RECORD:
    with open(RECORD, "a") as r: r.write("CALL=gh " + " ".join(args) + "\n")

s = load()
cmd = args[:2]

if cmd == ["auth", "status"]: sys.exit(0)
if cmd == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": s["repo"], "defaultBranchRef": {"name": s["default_branch"]}})); sys.exit(0)
if cmd == ["api", "user"]: print(json.dumps({"login": s["login"]})); sys.exit(0)
if cmd == ["label", "create"]:
    s.setdefault("labels_created", []).append(args[2]); save(s); sys.exit(0)

if cmd == ["api", "graphql"]:
    nodes = [{"number": i["number"], "title": i["title"], "createdAt": i["createdAt"], "body": i.get("body", ""),
              "labels": {"nodes": [{"name": l} for l in i["labels"]]},
              "parent": ({"number": i["parent"]} if i.get("parent") else None)}
             for i in sorted(s["issues"].values(), key=lambda x: x["createdAt"]) if i["state"] == "OPEN"]
    print(json.dumps({"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}}))
    sys.exit(0)

if cmd == ["issue", "view"]:
    n = args[2]; i = s["issues"][n]
    print(json.dumps({"number": i["number"], "id": i["id"], "title": i["title"], "body": i.get("body", ""), "state": i["state"],
                      "labels": [{"name": l} for l in i["labels"]],
                      "comments": [{"author": {"login": c["author"]}, "body": c["body"], "createdAt": c["createdAt"]} for c in i["comments"]]}))
    sys.exit(0)
if cmd == ["issue", "edit"]:
    n = args[2]; i = s["issues"][n]
    for l in opts("--add-label"):
        if l not in i["labels"]: i["labels"].append(l)
    for l in opts("--remove-label"):
        if l in i["labels"]: i["labels"].remove(l)
    if opt("--body-file") or opt("--body") is not None: i["body"] = body_arg()
    if opt("--title"): i["title"] = opt("--title")
    save(s); sys.exit(0)
if cmd == ["issue", "comment"]:
    n = args[2]; s["issues"][n]["comments"].append({"author": s["login"], "body": body_arg(), "createdAt": now()}); save(s); sys.exit(0)
if cmd == ["issue", "close"]:
    s["issues"][args[2]]["state"] = "CLOSED"; save(s); sys.exit(0)
if cmd == ["issue", "create"]:
    num = max([int(k) for k in s["issues"]] + [0]) + 1; s["next_id"] = s.get("next_id", 1) + 1
    s["issues"][str(num)] = {"number": num, "id": 1000 + num, "title": opt("--title", ""), "body": body_arg(), "state": "OPEN",
                             "createdAt": now(), "labels": opts("--label"), "comments": [], "parent": None, "sub_issues": []}
    save(s); print(f"https://github.com/{s['repo']}/issues/{num}"); sys.exit(0)

if cmd == ["pr", "list"]:
    head = opt("--head"); out = [p for p in s["prs"].values() if not head or p["headRefName"] == head]
    print(json.dumps([{k: p.get(k) for k in ["number", "state", "isDraft", "mergedAt", "body", "headRefName", "headRefOid", "url"]} for p in out])); sys.exit(0)
if cmd == ["pr", "view"]:
    p = s["prs"][args[2]]
    print(json.dumps({"number": p["number"], "state": p["state"], "isDraft": p["isDraft"], "mergedAt": p.get("mergedAt"), "body": p.get("body", ""),
                      "headRefName": p["headRefName"], "headRefOid": p.get("headRefOid", "deadbeef"), "files": [{"path": f} for f in p.get("files", [])],
                      "comments": [{"author": {"login": c["author"]}, "body": c["body"], "createdAt": c["createdAt"]} for c in p.get("comments", [])],
                      "reviews": [{"author": {"login": r["author"]}, "state": r["state"], "body": r.get("body", "")} for r in p.get("reviews", [])]})); sys.exit(0)
if cmd == ["pr", "comment"]:
    s["prs"][args[2]].setdefault("comments", []).append({"author": s["login"], "body": body_arg(), "createdAt": now()}); save(s); sys.exit(0)
if cmd == ["pr", "edit"]:
    p = s["prs"][args[2]]
    if opt("--body-file") or opt("--body") is not None: p["body"] = body_arg()
    for l in opts("--add-label"): p.setdefault("labels", []).append(l)
    save(s); sys.exit(0)
if cmd == ["pr", "ready"]:
    s["prs"][args[2]]["isDraft"] = "--undo" in args; save(s); sys.exit(0)
if cmd == ["pr", "merge"]:
    p = s["prs"][args[2]]
    if os.environ.get("FAKE_GH_MERGE_FAIL"): print("merge blocked", file=sys.stderr); sys.exit(1)
    p["state"] = "MERGED"; p["mergedAt"] = now(); s.setdefault("merged", []).append(p["number"]); save(s); sys.exit(0)
if cmd == ["pr", "close"]:
    s["prs"][args[2]]["state"] = "CLOSED"; save(s); sys.exit(0)
if cmd == ["pr", "create"]:
    num = max([int(k) for k in s["prs"]] + [100]) + 1
    s["prs"][str(num)] = {"number": num, "headRefName": opt("--head", ""), "state": "OPEN", "isDraft": "--draft" in args,
                          "mergedAt": None, "body": body_arg(), "comments": [], "reviews": [], "files": [], "headRefOid": "cafe%03d" % num,
                          "url": f"https://github.com/{s['repo']}/pull/{num}"}
    save(s); print(s["prs"][str(num)]["url"]); sys.exit(0)

if args[0] == "api":
    path = args[1] if args[1] != "-X" else args[3]
    method = opt("-X", "GET")
    if "/statuses/" in path and method == "POST":
        kv = dict(a.split("=", 1) for a in args if "=" in a and not a.startswith("-"))
        s.setdefault("statuses", []).append({"sha": path.rsplit("/", 1)[1], "context": kv.get("context"), "state": kv.get("state")}); save(s); print("{}"); sys.exit(0)
    if path.endswith("/sub_issues") and method == "GET":
        n = path.split("/issues/")[1].split("/")[0]
        print(json.dumps([{"number": s["issues"][str(c)]["number"], "id": s["issues"][str(c)]["id"], "title": s["issues"][str(c)]["title"],
                           "state": s["issues"][str(c)]["state"].lower(), "body": s["issues"][str(c)].get("body", ""), "labels": [{"name": l} for l in s["issues"][str(c)]["labels"]]} for c in s["issues"][n].get("sub_issues", [])])); sys.exit(0)
    if path.endswith("/sub_issues") and method == "POST":
        n = path.split("/issues/")[1].split("/")[0]
        sid = None
        for a in args:
            if a.startswith("sub_issue_id="): sid = int(a.split("=", 1)[1])
        child = next(k for k, v in s["issues"].items() if v["id"] == sid)
        s["issues"][n].setdefault("sub_issues", []).append(int(child)); s["issues"][child]["parent"] = int(n); save(s); print("{}"); sys.exit(0)
    if "/pulls/" in path and path.endswith("/comments"): print("[]"); sys.exit(0)
    print("{}"); sys.exit(0)

sys.exit(0)
