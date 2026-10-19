"""Remove Hadoop's shaded Jetty 9.4 from hadoop-client-runtime-*.jar (2026-10-19).

Jetty 9.4 gets no open-source fix for CVE-2026-2332 / CVE-2026-10050.  Inside
hadoop-client-runtime it serves Hadoop's own web servers (NameNode UI, KMS,
WebHDFS), which an s3a CLIENT never starts -- proven on Docker: 1,000,000 rows
written and read through s3a with it removed.  Only Hadoop's copy: spark-core's
Jetty must stay (SparkContext cannot start without it).
"""
import glob
import os
import shutil
import sys
import zipfile

PREFIXES = ("org/apache/hadoop/shaded/org/eclipse/jetty/", "META-INF/maven/org.eclipse.jetty")
jars = glob.glob("/opt/spark/jars/hadoop-client-runtime-*.jar")
if not jars:
    sys.exit("no hadoop-client-runtime jar found")
for j in jars:
    tmp, dropped = j + ".tmp", 0
    with zipfile.ZipFile(j) as src, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            if info.filename.startswith(PREFIXES):
                dropped += 1
                continue
            dst.writestr(info, src.read(info.filename))
    shutil.move(tmp, j)
    os.chmod(j, 0o644)
    print("stripped", os.path.basename(j), dropped, "entries")
