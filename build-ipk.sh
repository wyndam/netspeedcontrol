#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PKG_NAME="luci-app-netspeedcontrol"
PKG_VERSION="0.1.0-31"
ARCH="all"
SOURCE_DIR="$ROOT_DIR/$PKG_NAME"
BUILD_DIR="$ROOT_DIR/.ipkbuild/$PKG_NAME"
DIST_DIR="$ROOT_DIR/dist"
TMP_DIR="$ROOT_DIR/.ipkbuild/tmp"
PKG_FILE="$DIST_DIR/$PKG_NAME"_"$PKG_VERSION"_"$ARCH".ipk
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/CONTROL"
mkdir -p "$BUILD_DIR/etc"
mkdir -p "$BUILD_DIR/usr/lib/lua/luci/controller"
mkdir -p "$BUILD_DIR/usr/lib/lua/luci/model/cbi"
mkdir -p "$BUILD_DIR/usr/share/rpcd/acl.d"
cp -R "$SOURCE_DIR/root/etc/config" "$BUILD_DIR/etc/"
cp -R "$SOURCE_DIR/root/etc/init.d" "$BUILD_DIR/etc/"
cp -R "$SOURCE_DIR/root/usr/bin" "$BUILD_DIR/usr/"
cp -R "$SOURCE_DIR/root/usr/share" "$BUILD_DIR/usr/"
cp "$SOURCE_DIR/luasrc/controller/netspeedcontrol.lua" \
	"$BUILD_DIR/usr/lib/lua/luci/controller/netspeedcontrol.lua"
cp "$SOURCE_DIR/luasrc/model/cbi/netspeedcontrol.lua" \
	"$BUILD_DIR/usr/lib/lua/luci/model/cbi/netspeedcontrol.lua"

cat > "$BUILD_DIR/CONTROL/control" <<'EOF'
Package: luci-app-netspeedcontrol
Version: 0.1.0-31
Depends: luci-base, luci-compat, nftables, firewall4
Source: local
License: MIT
Section: luci
Category: LuCI
Title: LuCI support for scheduled device network control
Architecture: all
Installed-Size: 0
Description: LuCI plugin for scheduled client network blocking and light bandwidth limiting by MAC address, with legacy IP fallback.
Maintainer: Codex
EOF

cat > "$BUILD_DIR/CONTROL/conffiles" <<'EOF'
/etc/config/netspeedcontrol
EOF

cat > "$BUILD_DIR/CONTROL/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/netspeedcontrol enable >/dev/null 2>&1 || true
/etc/init.d/netspeedcontrol restart >/dev/null 2>&1 || true
exit 0
EOF

cat > "$BUILD_DIR/CONTROL/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/netspeedcontrol stop >/dev/null 2>&1 || true
/etc/init.d/netspeedcontrol disable >/dev/null 2>&1 || true
exit 0
EOF

chmod 0755 "$BUILD_DIR/CONTROL/postinst" "$BUILD_DIR/CONTROL/prerm"
chmod 0755 "$BUILD_DIR/etc/init.d/netspeedcontrol" "$BUILD_DIR/usr/bin/netspeedcontrol.sh"

mkdir -p "$DIST_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

python3 - "$BUILD_DIR" "$TMP_DIR" "$PKG_FILE" <<'PY'
import gzip
import stat
import sys
import tarfile
from pathlib import Path

build_dir = Path(sys.argv[1])
tmp_dir = Path(sys.argv[2])
pkg_file = Path(sys.argv[3])
control_dir = build_dir / "CONTROL"
epoch = 1700000000

def add_entry(tar, arcname: str, path: Path):
    st = path.lstat()
    info = tarfile.TarInfo(arcname)
    info.mtime = epoch
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    if path.is_dir():
        info.type = tarfile.DIRTYPE
        info.mode = stat.S_IMODE(st.st_mode) or 0o755
        tar.addfile(info)
    elif path.is_file():
        info.type = tarfile.REGTYPE
        info.size = st.st_size
        info.mode = stat.S_IMODE(st.st_mode) or 0o644
        with path.open("rb") as f:
            tar.addfile(info, f)

def iter_data_entries(root: Path):
    yield "./", root
    for path in sorted(root.rglob("*")):
        if path == control_dir or control_dir in path.parents:
            continue
        rel = path.relative_to(root).as_posix()
        yield f"./{rel}", path

def iter_control_entries(root: Path):
    for path in sorted(root.iterdir()):
        yield f"./{path.name}", path

def write_tar_gz(out_path: Path, entries):
    with out_path.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=epoch) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for arcname, path in entries:
                    add_entry(tar, arcname, path)

def tree_size(root: Path):
    total = 0
    for path in root.rglob("*"):
        if control_dir in path.parents or path == control_dir or path.is_dir():
            continue
        total += path.stat().st_size
    return total

control_file = control_dir / "control"
lines = control_file.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith("Installed-Size: "):
        lines[i] = f"Installed-Size: {tree_size(build_dir)}"
control_file.write_text("\n".join(lines) + "\n")

write_tar_gz(tmp_dir / "control.tar.gz", iter_control_entries(control_dir))
write_tar_gz(tmp_dir / "data.tar.gz", iter_data_entries(build_dir))
(tmp_dir / "debian-binary").write_text("2.0\n")

with pkg_file.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=epoch) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for name in ("./debian-binary", "./data.tar.gz", "./control.tar.gz"):
                path = tmp_dir / name[2:]
                add_entry(tar, name, path)
PY

printf 'Built: %s\n' "$PKG_FILE"
