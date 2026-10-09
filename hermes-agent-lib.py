#!/usr/bin/env python3
"""hermes-agent-lib.py - Python part of the Hermes agent tools (used by hermes-agent-lib.sh).

Not meant to be run by hand. Reads platform.toml (standard library only: tomllib, Python 3.11+),
derives the per-agent values the shell scripts use, checks the definition against the platform rules,
and changes file owners without following symlinks.

  host-env <toml>            shell assignments for host values (only where the variable is not already set)
  agents <toml>              agent names, one per line
  agent-env <toml> <agent>   shell assignments for one agent (values derived from domains, zones, vaults)
  host-lists <toml>          lines "kanban <domain> <home> <group> <gid>", "admin <name>", "forbidden <group>",
                             "service <name> <uid> <home>", "vault <name> <gid rw> <gid ro>", "agentid <agent> <uid> <gid>"
  check <toml>               platform rules; prints ERROR/WARN lines; exit 1 on any ERROR
  owner count <dir>          entries that differ from the code target (count, then up to 3 examples)
  owner manifest <dir> <out> record uid, gid and mode of every entry (one JSON line each)
  owner apply <dir>          owner root:root; no write for group/other; read for all, search on dirs/executables
  owner restore <manifest>   set uid, gid and mode back from a manifest
  owner chown <user|uid> <group|gid> <path>   owner of one directory or file (refuses symlinks)
  owner chmod <octal> <path>  exact mode, also clears setgid (refuses symlinks)
  owner reown <uid> <dir> <manifest>   entries of <uid> below <dir> to owner root (group kept), recorded for restore
  owner renumber <umap> <gmap> <manifest|-> <dir>...   uids/gids and ACL entries old->new ("994:2000,999:2001");
                             uid map only applies to owners and ACL user entries, gid map only to groups and ACL
                             group entries (a uid number may equal an unrelated gid); manifest "-" = count only
  owner restore-full <manifest>   owner, group, mode and ACLs back from a renumber manifest
  owner open <path>...       number of open files and working directories of all processes below the paths
One file system only (like find -xdev); symlinks are never followed. Exit 0 ok, 1 error (message on stderr).
"""
import grp
import json
import os
import pwd
import re
import shlex
import stat
import sys

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,20}$")
SIZE_RE = re.compile(r"^[0-9]+[KMGT]?$")


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def load(path):
    try:
        import tomllib
    except ImportError:
        die("Python %s has no tomllib (3.11+ needed)" % sys.version.split()[0])
    try:
        with open(path, "rb") as f:
            p = tomllib.load(f)
    except FileNotFoundError:
        die("platform file not found: " + path)
    except tomllib.TOMLDecodeError as e:
        die("platform file %s is not valid TOML: %s" % (path, e))
    if p.get("schema") != 1:
        die("platform file %s: schema must be 1" % path)
    for k in ("host", "domains", "zones", "agents"):
        if not isinstance(p.get(k), dict):
            die("platform file %s: section [%s] missing" % (path, k))
    p.setdefault("vaults", {})
    p.setdefault("services", {})
    p.setdefault("exceptions", {})
    return p


def sh(name, value):
    return "%s=%s" % (name, shlex.quote(str(value)))


def domain_of(p, agent):
    return p["zones"][p["agents"][agent]["zone"]]["domain"]


def derive(p, a, toml_path):
    ag = p["agents"][a]
    dom = domain_of(p, a)
    kb = p["domains"][dom].get("kanban")
    kanban = ag.get("kanban")
    groups, rw = [], []
    vroot = (p["host"].get("vaults_root") or "/srv/vaults").rstrip("/")
    if kanban:
        groups.append(kb["group"])
        rw.append(kb["home"])
    for v, vd in p["vaults"].items():
        if a in vd.get("rw", []):
            groups.append("vault-%s-rw" % v)
            rw.append("%s/%s" % (vroot, v))
        if a in vd.get("ro", []):
            groups.append("vault-%s-ro" % v)
    rw += ag.get("extra_rw", [])
    env = []
    if "a2a_port" in ag:
        env = ["A2A_AGENT_NAME", "A2A_PORT", "A2A_PEER_TOKENS"] + ["A2A_TOKEN_" + x.upper() for x in ag.get("a2a_peers", [])]
    env += ag.get("env_allowed", [])
    ts = ag.get("toolsets", {})
    lim = ag.get("limits", {})
    soul = ag.get("soul", "")
    if soul:
        soul = os.path.join(os.path.dirname(os.path.abspath(toml_path)), soul)
    return {
        "NAME": a, "ID": ag["uid"], "GID": ag.get("gid", ag["uid"]), "DESCRIPTION": ag.get("description", ""),
        "ZONE": ag["zone"], "DOMAIN": dom, "ROLE": ag.get("role", ""),
        "MODEL": ag.get("model", ""), "PROVIDER": ag.get("provider", ""), "BASE_URL": ag.get("base_url", ""),
        "A2A_PORT": ag.get("a2a_port", ""), "A2A_PEERS": " ".join(ag.get("a2a_peers", [])),
        "PLUGINS": " ".join(ag.get("plugins", [])),
        "TOOLSETS_CLI": " ".join(ts.get("cli", [])), "TOOLSETS_A2A": " ".join(ts.get("a2a", [])),
        "TOOLSETS_CRON": " ".join(ts.get("cron", [])),
        "AGENT_GROUPS": " ".join(groups), "RW_PATHS": " ".join(rw), "ENV_ALLOWED": " ".join(env),
        "KANBAN_DISPATCH": "yes" if kanban and kanban.get("dispatch") else "no",
        "KANBAN_MAX": (kanban or {}).get("max", 1),
        "TIMEZONE": ag.get("timezone", "UTC"), "SOUL": soul,
        "MEM_HIGH": lim.get("mem_high", "768M"), "MEM_MAX": lim.get("mem_max", "1G"), "SLICE_MEM": lim.get("slice_mem", "768M"),
        "LINGER": "yes" if ag.get("linger", bool(kanban and kanban.get("dispatch"))) else "no",
        "EXTRA_ENV": " ".join(ag.get("extra_env", [])),
    }


def check(p):
    err, warn = [], []
    host, doms, zones, agents, vaults = p["host"], p["domains"], p["zones"], p["agents"], p["vaults"]
    exc = p["exceptions"]
    lo, hi = host.get("id_range", [2000, 2199])
    for k in ("install", "root", "root_group", "root_mode"):
        if k not in host:
            err.append("[host] %s missing" % k)
    for d, dd in doms.items():
        if not NAME_RE.match(d):
            err.append("domain %s: invalid name" % d)
        o = dd.get("orchestrator")
        if o not in agents:
            err.append("domain %s: orchestrator %s is not an agent" % (d, o))
        elif agents[o].get("role") != "orchestrator" or domain_of_safe(p, o) != d:
            err.append("domain %s: orchestrator %s must have role orchestrator and a zone in this domain" % (d, o))
        kb = dd.get("kanban")
        if kb is not None:
            for k in ("home", "group", "boards"):
                if k not in kb:
                    err.append("domain %s: kanban.%s missing" % (d, k))
            if not isinstance(kb.get("gid"), int):
                err.append("domain %s: kanban.gid missing (the group is identified by its gid)" % d)
    homes = [dd["kanban"]["home"] for dd in doms.values() if dd.get("kanban", {}).get("home")]
    if len(homes) != len(set(homes)):
        err.append("two domains share one kanban home")
    for z, zd in zones.items():
        if zd.get("domain") not in doms:
            err.append("zone %s: domain %s does not exist" % (z, zd.get("domain")))
    uids, ports = {}, {}
    for a, ag in agents.items():
        if not NAME_RE.match(a):
            err.append("agent %s: invalid name (a-z, 0-9, -; 2-21 chars)" % a)
        z = ag.get("zone")
        if z not in zones:
            err.append("agent %s: zone %s does not exist" % (a, z))
            continue
        d = zones[z]["domain"]
        if ag.get("role") not in ("orchestrator", "worker"):
            err.append("agent %s: role must be orchestrator or worker" % a)
        for k in ("uid", "model", "provider"):
            if k not in ag:
                err.append("agent %s: %s missing" % (a, k))
        uid = ag.get("uid")
        if uid in uids:
            err.append("agent %s: uid %s already used by %s" % (a, uid, uids[uid]))
        uids[uid] = a
        if isinstance(uid, int) and not lo <= uid <= hi:
            warn.append("agent %s: uid %s outside %s-%s (fixed ids, step 0.8e)" % (a, uid, lo, hi))
        kb = ag.get("kanban")
        if kb:
            dk = doms.get(d, {}).get("kanban")
            if not dk:
                err.append("agent %s: kanban, but domain %s has no kanban" % (a, d))
            elif kb.get("board") not in dk.get("boards", []):
                err.append("agent %s: board %s is not a board of domain %s" % (a, kb.get("board"), d))
            if kb.get("dispatch") and not ag.get("linger", True):
                err.append("agent %s: kanban dispatch needs linger" % a)
        port = ag.get("a2a_port")
        if port is not None:
            if port in ports:
                err.append("agent %s: a2a_port %s already used by %s" % (a, port, ports[port]))
            ports[port] = a
            if isinstance(uid, int) and lo <= uid <= hi and uid != 2000 + port - 9900:
                err.append("agent %s: id rule uid = 2000 + (a2a_port - 9900) violated" % a)
        cross = [sorted(x) for x in exc.get("a2a_cross_domain", [])]
        for peer in ag.get("a2a_peers", []):
            if peer not in agents:
                err.append("agent %s: a2a peer %s does not exist" % (a, peer))
                continue
            if port is None or "a2a_port" not in agents[peer]:
                err.append("agent %s: a2a with %s needs a2a_port on both sides" % (a, peer))
            if a not in agents[peer].get("a2a_peers", []):
                err.append("agent %s: a2a with %s is one-sided (list it on both sides)" % (a, peer))
            if domain_of_safe(p, peer) not in (None, d) and sorted([a, peer]) not in cross:
                err.append("agent %s: a2a with %s crosses domains without an entry in [exceptions]" % (a, peer))
        for e in ag.get("extra_rw", []):
            if not e.startswith("/"):
                err.append("agent %s: extra_rw %s is not absolute" % (a, e))
        for k, v in ag.get("limits", {}).items():
            if not SIZE_RE.match(str(v)):
                err.append("agent %s: limits.%s %s is not a size (e.g. 768M, 1G)" % (a, k, v))
    for s, sd in p["services"].items():
        uid = sd.get("uid")
        if uid in uids:
            err.append("service %s: uid %s already used by %s" % (s, uid, uids[uid]))
        uids[uid] = s
    gids = {}
    for d, dd in doms.items():
        if dd.get("kanban"):
            gids.setdefault(dd["kanban"].get("gid"), []).append("kanban of " + d)
    for a, ag in agents.items():
        gids.setdefault(ag.get("gid", ag.get("uid")), []).append(a + "-agent")
    for v, vd in vaults.items():
        g = vd.get("gids")
        if not (isinstance(g, list) and len(g) == 2 and all(isinstance(x, int) for x in g)):
            err.append("vault %s: gids = [rw, ro] missing" % v)
        else:
            gids.setdefault(g[0], []).append("vault-%s-rw" % v); gids.setdefault(g[1], []).append("vault-%s-ro" % v)
    for g, names in gids.items():
        if len(names) > 1:
            err.append("gid %s used twice: %s" % (g, ", ".join(names)))
        if isinstance(g, int) and not lo <= g <= hi:
            warn.append("gid %s (%s) outside %s-%s" % (g, ", ".join(names), lo, hi))
    for v, vd in vaults.items():
        vz = vd.get("zones", [])
        for z in vz:
            if z not in zones:
                err.append("vault %s: zone %s does not exist" % (v, z))
        vdoms = {zones[z]["domain"] for z in vz if z in zones}
        if len(vdoms) > 1 and v not in exc.get("vault_cross_domain", []):
            err.append("vault %s: zones of more than one domain without an entry in [exceptions]" % v)
        for a in vd.get("rw", []):
            if a not in agents:
                err.append("vault %s: rw agent %s does not exist" % (v, a))
            elif agents[a].get("zone") not in vz:
                err.append("vault %s: %s may not write, zone %s is not a zone of the vault" % (v, a, agents[a].get("zone")))
        for a in vd.get("ro", []):
            if a not in agents:
                err.append("vault %s: ro agent %s does not exist" % (v, a))
            elif domain_of_safe(p, a) not in vdoms:
                err.append("vault %s: %s may not read, it belongs to another domain" % (v, a))
            if a in vd.get("rw", []):
                err.append("vault %s: %s is listed as rw and ro" % (v, a))
    return err, warn


def domain_of_safe(p, a):
    z = p["agents"].get(a, {}).get("zone")
    return p["zones"].get(z, {}).get("domain")


# --- owner ---------------------------------------------------------------------------------------------
def entries(top):
    dev = os.lstat(top).st_dev
    yield top
    for d, dirs, files in os.walk(top, followlinks=False):
        dirs[:] = [n for n in dirs if os.lstat(os.path.join(d, n)).st_dev == dev]
        for n in dirs + files:
            yield os.path.join(d, n)


def target(st):
    perm = stat.S_IMODE(st.st_mode)
    new = (perm & ~0o022) | 0o044
    if stat.S_ISDIR(st.st_mode) or perm & 0o100:
        new |= 0o011
    return new


def differs(st):
    if st.st_uid != 0 or st.st_gid != 0:
        return True
    return not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(st.st_mode) != target(st)


ACL_A, ACL_D = "system.posix_acl_access", "system.posix_acl_default"
ACL_USER, ACL_GROUP = 0x02, 0x08


def acl_map(raw, umap, gmap):
    """POSIX ACL xattr (version 2): 4-byte header, entries of tag u16, perm u16, id u32 (little endian)."""
    import struct
    if raw is None or len(raw) < 4:
        return raw
    ents = [struct.unpack_from("<HHI", raw, 4 + 8 * i) for i in range((len(raw) - 4) // 8)]
    new = []
    for tag, perm, i in ents:
        if tag == ACL_USER:
            i = umap.get(i, i)
        elif tag == ACL_GROUP:
            i = gmap.get(i, i)
        new.append((tag, perm, i))
    new.sort(key=lambda e: (e[0], e[2]))   # kernel order: by tag, then id
    return raw[:4] + b"".join(struct.pack("<HHI", *e) for e in new)


def getx(path, name):
    try:
        return os.getxattr(path, name, follow_symlinks=False)
    except OSError:
        return None


def parse_map(text):
    return {int(a): int(b) for a, b in (x.split(":") for x in text.split(",") if x)}


def owner(cmd, args):
    if cmd == "count":
        n, ex = 0, []
        for path in entries(args[0]):
            st = os.lstat(path)
            if differs(st):
                n += 1
                if len(ex) < 3:
                    ex.append("%s %o %s" % (st.st_uid, stat.S_IMODE(st.st_mode), path))
        print(n)
        for e in ex:
            print(e)
    elif cmd == "manifest":
        with open(args[1], "w") as f:
            os.fchmod(f.fileno(), 0o600)
            for path in entries(args[0]):
                st = os.lstat(path)
                f.write(json.dumps([path, st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode), stat.S_ISLNK(st.st_mode)]) + "\n")
    elif cmd == "apply":
        for path in entries(args[0]):
            st = os.lstat(path)
            if not differs(st):
                continue
            os.lchown(path, 0, 0)
            if not stat.S_ISLNK(st.st_mode):
                os.chmod(path, target(os.lstat(path)))
    elif cmd == "restore":
        bad = 0
        for line in open(args[0]):
            path, uid, gid, mode, link = json.loads(line)
            try:
                os.lchown(path, uid, gid)
                if not link:
                    os.chmod(path, mode)
            except FileNotFoundError:
                pass
            except OSError as e:
                bad += 1
                print("restore failed: %s: %s" % (path, e), file=sys.stderr)
        sys.exit(1 if bad else 0)
    elif cmd == "renumber":
        umap, gmap, out, tops = parse_map(args[0]), parse_map(args[1]), args[2], args[3:]
        f = None if out == "-" else open(out, "w")
        if f:
            os.fchmod(f.fileno(), 0o600)
        n = nacl = bad = 0
        for top in tops:
            for path in entries(top):
                st = os.lstat(path)
                link = stat.S_ISLNK(st.st_mode)
                nu, ng = umap.get(st.st_uid, -1), gmap.get(st.st_gid, -1)
                a = d = None
                if not link:
                    a = getx(path, ACL_A)
                    d = getx(path, ACL_D) if stat.S_ISDIR(st.st_mode) else None
                na, nd = acl_map(a, umap, gmap), acl_map(d, umap, gmap)
                if nu == -1 and ng == -1 and na == a and nd == d:
                    continue
                n += 1; nacl += (na != a) + (nd != d)
                if not f:
                    continue
                f.write(json.dumps([path, st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode), link,
                                    a.hex() if a else None, d.hex() if d else None]) + "\n"); f.flush()
                try:
                    if nu != -1 or ng != -1:
                        os.lchown(path, nu, ng)
                    if not link and stat.S_IMODE(os.lstat(path).st_mode) != stat.S_IMODE(st.st_mode):
                        os.chmod(path, stat.S_IMODE(st.st_mode))   # chown may clear setgid on files
                    if na != a:
                        os.setxattr(path, ACL_A, na, follow_symlinks=False)
                    if nd != d:
                        os.setxattr(path, ACL_D, nd, follow_symlinks=False)
                except OSError as e:
                    bad += 1
                    print("failed: %s: %s" % (path, e), file=sys.stderr)
        print("%d entries, %d ACLs%s" % (n, nacl, "" if f else " (count only)"))
        sys.exit(1 if bad else 0)
    elif cmd == "restore-full":
        bad = 0
        for line in open(args[0]):
            path, uid, gid, mode, link, a, d = json.loads(line)
            try:
                os.lchown(path, uid, gid)
                if not link:
                    os.chmod(path, mode)
                    for name, val in ((ACL_A, a), (ACL_D, d)):
                        if val:
                            os.setxattr(path, name, bytes.fromhex(val), follow_symlinks=False)
            except FileNotFoundError:
                pass
            except OSError as e:
                bad += 1
                print("restore failed: %s: %s" % (path, e), file=sys.stderr)
        sys.exit(1 if bad else 0)
    elif cmd == "chmod":
        mode, path = args
        if os.path.islink(path):
            die("refusing symlink: " + path)
        os.chmod(path, int(mode, 8))
    elif cmd == "reown":
        uid, top, out = int(args[0]), args[1], args[2]
        with open(out, "w") as f:
            os.fchmod(f.fileno(), 0o600)
            for path in entries(top):
                st = os.lstat(path)
                if st.st_uid != uid:
                    continue
                f.write(json.dumps([path, st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode), stat.S_ISLNK(st.st_mode)]) + "\n")
                f.flush()
                os.lchown(path, 0, -1)
                if not stat.S_ISLNK(st.st_mode) and stat.S_IMODE(os.lstat(path).st_mode) != stat.S_IMODE(st.st_mode):
                    os.chmod(path, stat.S_IMODE(st.st_mode))   # chown may clear setgid on files; keep the mode
    elif cmd == "chown":
        u, g, path = args
        if os.path.islink(path):
            die("refusing symlink: " + path)
        uid = int(u) if u.isdigit() else pwd.getpwnam(u).pw_uid
        gid = int(g) if g.isdigit() else grp.getgrnam(g).gr_gid
        os.lchown(path, uid, gid)
    elif cmd == "open":
        tops = [os.path.realpath(a) for a in args]
        n = 0
        for pid in filter(str.isdigit, os.listdir("/proc")):
            links = []
            try:
                links.append(os.readlink("/proc/%s/cwd" % pid))
                for fd in os.listdir("/proc/%s/fd" % pid):
                    links.append(os.readlink("/proc/%s/fd/%s" % (pid, fd)))
            except OSError:
                pass
            n += sum(1 for link in links for t in tops if link == t or link.startswith(t + "/"))
        print(n)
    else:
        die("unknown owner mode " + cmd)


def main():
    if len(sys.argv) < 2:
        die("usage: see the docstring of this file")
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "owner":
        owner(args[0], args[1:])
        return
    p = load(args[0])
    if cmd == "host-env":
        h = p["host"]
        for var, key in (("HERMES_INSTALL", "install"), ("HERMES_ROOT", "root"), ("ROOT_GROUP", "root_group"), ("ROOT_MODE", "root_mode")):
            v = str(h.get(key, ""))
            if not re.match(r"^[A-Za-z0-9_./-]+$", v):
                die("[host] %s: missing or not a plain path/name: %r" % (key, v))
            print(': "${%s:=%s}"' % (var, v))   # an already set variable wins (tests, overrides)
    elif cmd == "host-lists":
        for d in sorted(p["domains"]):
            kb = p["domains"][d].get("kanban")
            if kb:
                print("kanban %s %s %s %s" % (d, kb["home"], kb["group"], kb.get("gid", "")))
        for a in p["host"].get("admins", []):
            print("admin " + a)
        for v, vd in sorted(p["vaults"].items()):
            g = vd.get("gids", ["", ""])
            print("vault %s %s %s" % (v, g[0], g[1]))
        for a, ag in sorted(p["agents"].items()):
            print("agentid %s %s %s" % (a, ag["uid"], ag.get("gid", ag["uid"])))
        for sname, sd in sorted(p["services"].items()):
            print("service %s %s %s" % (sname, sd.get("uid", ""), sd.get("home", "")))
        forb = set()
        for d in p["domains"].values():
            if d.get("kanban"):
                forb.add(d["kanban"]["group"])
        for v in p["vaults"]:
            forb.update(("vault-%s-rw" % v, "vault-%s-ro" % v))
        for a in p["agents"]:
            forb.add(a + "-agent")
        for g in sorted(forb):
            print("forbidden " + g)
    elif cmd == "agents":
        for a in sorted(p["agents"]):
            print(a)
    elif cmd == "agent-env":
        a = args[1]
        if a not in p["agents"]:
            die("agent %s is not defined in %s" % (a, args[0]))
        if p["agents"][a].get("zone") not in p["zones"]:
            die("agent %s: zone %s does not exist" % (a, p["agents"][a].get("zone")))
        for k, v in derive(p, a, args[0]).items():
            print(sh(k, v))
    elif cmd == "check":
        err, warn = check(p)
        for w in warn:
            print("WARN: " + w)
        for e in err:
            print("ERROR: " + e)
        print("%d errors, %d warnings, %d agents, %d domains, %d zones, %d vaults" % (
            len(err), len(warn), len(p["agents"]), len(p["domains"]), len(p["zones"]), len(p["vaults"])))
        sys.exit(1 if err else 0)
    else:
        die("unknown command " + cmd)


if __name__ == "__main__":
    main()
