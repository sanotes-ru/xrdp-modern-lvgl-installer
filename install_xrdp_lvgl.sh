#!/bin/bash
set -e

echo "[1/6] Updating system and installing X11 + build dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y

# Install core X11 utilities, session manager dependencies, and fonts (Quicksand for LVGL, DejaVu for Unicode)
apt install -y --no-install-recommends \
    dbus-x11 xinit x11-xserver-utils \
    xserver-xorg-core xserver-xorg-legacy fonts-dejavu-core fonts-quicksand

# Install build tools and development headers required for LVGL, xrdp, and xorgxrdp
apt install -y \
    git cmake build-essential pkg-config autoconf automake libtool \
    libssl-dev libpam0g-dev libsystemd-dev libx11-dev libxfixes-dev libxrandr-dev \
    libimlib2-dev libfontconfig1-dev libfreetype-dev nasm xsltproc \
    libxml2-utils xserver-xorg-dev libpixman-1-dev

echo "[2/6] Cloning and building LVGL library v9.3..."
cd /tmp && rm -rf lvgl
git clone --depth 1 --branch release/v9.3 https://github.com/lvgl/lvgl.git
cd lvgl

# Activate configuration file from template
cp lv_conf_template.h lv_conf.h
sed -i 's/^#if 0/#if 1/' lv_conf.h

# Enable mandatory macros required by xrdp configuration check
sed -i 's/^[[:space:]]*#define LV_USE_STDLIB_MALLOC.*/#define LV_USE_STDLIB_MALLOC LV_STDLIB_CLIB/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_ENABLE_GLOBAL_CUSTOM.*/#define LV_ENABLE_GLOBAL_CUSTOM 0/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_DRAW_SW.*/#define LV_USE_DRAW_SW 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_DRAW_SW_COMPLEX.*/#define LV_DRAW_SW_COMPLEX 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_DRAW_SW_SUPPORT_XRGB8888.*/#define LV_DRAW_SW_SUPPORT_XRGB8888 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_DRAW_SW_DRAW_UNIT_CNT.*/#define LV_DRAW_SW_DRAW_UNIT_CNT 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_LABEL.*/#define LV_USE_LABEL 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_BUTTON.*/#define LV_USE_BUTTON 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_TEXTAREA.*/#define LV_USE_TEXTAREA 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_DROPDOWN.*/#define LV_USE_DROPDOWN 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_IMAGE.*/#define LV_USE_IMAGE 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_FLEX.*/#define LV_USE_FLEX 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_USE_FREETYPE.*/#define LV_USE_FREETYPE 1/' lv_conf.h
sed -i 's/^[[:space:]]*#define LV_TXT_ENC.*/#define LV_TXT_ENC LV_TXT_ENC_UTF8/' lv_conf.h

# Build and install LVGL with system freetype2 include path
mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_SHARED_LIBS=ON -DCMAKE_C_FLAGS="-I/usr/include/freetype2"
make -j$(nproc)
make install

# Copy private headers which are skipped by default cmake install rule
cp -r --update=none /tmp/lvgl/src/* /usr/local/include/lvgl/src/
ldconfig

echo "[3/6] Building xrdp (devel branch) with LVGL and Imlib2 support..."
cd /tmp && rm -rf xrdp
git clone --depth 1 --branch devel --recursive --shallow-submodules https://github.com/neutrinolabs/xrdp.git
cd xrdp
./bootstrap

export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/pkgconfig
# Explicitly linking freetype to bypass missing dependency flags in standard package config
LIBS="-lfreetype" ./configure --enable-lvgl --with-imlib2 --enable-pixman --with-systemdsystemunitdir=/usr/lib/systemd/system
make -j$(nproc)
make install

echo "[4/6] Building xorgxrdp video driver (devel branch)..."
cd /tmp && rm -rf xorgxrdp
git clone --depth 1 --branch devel https://github.com/neutrinolabs/xorgxrdp.git
cd xorgxrdp
./bootstrap
# Hardware 3D acceleration (glamor) is disabled to prevent Xorg crashes on virtual servers
./configure --disable-glamor
make -j$(nproc)
make install

echo "[5/6] Securing daemon, configuring system permissions and LVGL UI..."
# Set up a dedicated unprivileged service user for xrdp runtime
id -u xrdp &>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/run/xrdp xrdp
mkdir -p /run/xrdp
chown -R xrdp:xrdp /run/xrdp
chmod 755 /run/xrdp
# Ensure /run/xrdp is persistently recreated across system reboots
echo "d /run/xrdp 0755 xrdp xrdp -" > /etc/tmpfiles.d/xrdp.conf

# Generate RSA/TLS certificates and grant read access to xrdp group
[ -f /etc/xrdp/rsakeys.ini ] || xrdp-keygen xrdp /etc/xrdp/rsakeys.ini
[ -f /etc/xrdp/cert.pem ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem -days 3650 -subj "/CN=xrdp"
chown root:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem /etc/xrdp/rsakeys.ini
chmod 640 /etc/xrdp/key.pem /etc/xrdp/rsakeys.ini
chmod 644 /etc/xrdp/cert.pem

# Allow non-root users to spin up Xorg instances to fix /dev/tty0 permission blocks
cat << 'EOF' > /etc/X11/Xwrapper.config
allowed_users=anybody
needs_root_rights=yes
EOF

# Update sesman.ini: map native Ubuntu Xorg path and explicitly drop root RDP logins
sed -i 's|^param=Xorg$|param=/usr/lib/xorg/Xorg|' /etc/xrdp/sesman.ini
sed -i 's/^AllowRootLogin=.*/AllowRootLogin=false/' /etc/xrdp/sesman.ini

# Update xrdp.ini: enforce modern LVGL interface and map Unicode compatible font
if grep -q "^ls_ui=" /etc/xrdp/xrdp.ini; then
    sed -i 's/^ls_ui=.*/ls_ui=lvgl/' /etc/xrdp/xrdp.ini
else
    sed -i '/^\[Globals\]/a ls_ui=lvgl' /etc/xrdp/xrdp.ini
fi
sed -i '/^ls_ui=lvgl/a ls_font_file=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf' /etc/xrdp/xrdp.ini

echo "[6/6] Cleaning up build files and enabling services..."
rm -rf /tmp/lvgl /tmp/xrdp /tmp/xorgxrdp
systemctl daemon-reload
systemctl enable --now xrdp-sesman xrdp

echo "=== SUCCESS! xrdp with LVGL UI has been installed ==="
echo "Note: Ensure a Desktop Environment (e.g., XFCE, GNOME, MATE) and a non-root user are configured before connecting."
