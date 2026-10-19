"""List every copy of Jetty inside a Spark image's jars (2026-10-18).

Jetty is never a separate jar in a Spark image: it is SHADED inside other jars
(spark-core, hadoop-client-runtime), and image scanners find it through the
Maven ``pom.properties`` files those jars carry.  This prints each such jar,
the Jetty artifacts in it with their versions, and how many shaded classes it
holds -- run it INSIDE the image:

    docker run --rm -v "$PWD/scripts:/s:ro" --entrypoint python3 <image> \
        /s/spark_image_jetty_scan.py [/opt/spark/jars]

Exit 1 when any Jetty older than --min (default 12.1.10, the first release
with both CVE-2026-2332 and CVE-2026-10050 fixed) is present.
"""
from __future__ import annotations

import argparse
import collections
import glob
import re
import sys
import zipfile


def _key(v: str):
    return tuple(int(x) for x in re.findall(r"\d+", v.split(".v")[0])[:3])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("jars_dir", nargs="?", default="/opt/spark/jars")
    ap.add_argument("--min", default="12.1.10")
    a = ap.parse_args()
    found = collections.defaultdict(set)
    classes = collections.Counter()
    for j in sorted(glob.glob(f"{a.jars_dir.rstrip('/')}/*.jar")):
        try:
            z = zipfile.ZipFile(j)
        except Exception:                                   # noqa: BLE001
            continue
        name = j.replace("\\", "/").split("/")[-1]
        for n in z.namelist():
            if "jetty" in n.lower() and n.endswith("pom.properties"):
                props = z.read(n).decode("utf-8", "replace")
                v = re.search(r"version=(.*)", props)
                art = re.search(r"artifactId=(.*)", props)
                found[name].add((art.group(1).strip() if art else "?", v.group(1).strip() if v else "?"))
            if "/jetty/" in n and n.endswith(".class"):
                classes[(name, n.split("/jetty/")[0])] += 1
    old = []
    for jar, arts in sorted(found.items()):
        print(f"JAR {jar}")
        for art, ver in sorted(arts):
            flag = "" if ver == "?" or _key(ver) >= _key(a.min) else f"   <-- older than {a.min}"
            if flag:
                old.append((jar, art, ver))
            print(f"    {art} {ver}{flag}")
    for (jar, pkg), c in classes.most_common():
        print(f"CLASSES {jar} {pkg}/jetty: {c}")
    if not found and not classes:
        print("no Jetty in", a.jars_dir)
    print(f"\n{len(old)} Jetty artifact(s) older than {a.min}")
    return 1 if old else 0


if __name__ == "__main__":
    sys.exit(main())
