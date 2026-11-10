#!/bin/bash
# ---------------------------------------------------------------------------
# Actions-FriendlyWrt 自定义编译入口
#
# 由 .github/workflows/build.yml 的 "Apply customizations" step 调用：
#     cd project && source ../scripts/custome_config.sh
# 工作目录是 project/，其下已通过 repo sync 展开：
#     friendlywrt/            OpenWrt 源码（含 feeds.conf.default）
#     configs/rockchip/       FriendlyWrt 的配置片段目录
#     device/common/          FriendlyWrt 的 rootfs 注入素材
#     device/friendlyelec/    各 SoC 的 base.mk
#
# 本脚本在 `build.sh friendlywrt` 之前执行，而 build.sh 内部会：
#     ./scripts/feeds update -a && ./scripts/feeds install -a
#     mk-friendlywrt.sh rockchip friendlywrt rk3568
# mk-friendlywrt.sh 把 configs/rockchip/ 下的文件按 `ls` 字母序 cat 进 .config，
# 再追加 CONFIG_ALL_KMODS=y，最后跑 make defconfig。
# 所以这里新增的 06-r5s-iptv 排在最后，可覆盖 01-nanopi / 03-custom 的同名项。
# ---------------------------------------------------------------------------
set -eu

echo "==== [r5s-iptv] 开始应用自定义编译配置 ===="

# ---------------------------------------------------------------------------
# 0. 上游原有内容：不生成 toolchain / IB / SDK，节省构建时间
# ---------------------------------------------------------------------------
sed -i -e '/CONFIG_MAKE_TOOLCHAIN=y/d' configs/rockchip/01-nanopi
sed -i -e 's/CONFIG_IB=y/# CONFIG_IB is not set/g' configs/rockchip/01-nanopi
sed -i -e 's/CONFIG_SDK=y/# CONFIG_SDK is not set/g' configs/rockchip/01-nanopi

# ---------------------------------------------------------------------------
# 1. 追加 rtp2httpd feed
#    该仓库根目录本身就是一个 OpenWrt feed，包定义在 openwrt-support/ 下：
#      openwrt-support/rtp2httpd/Makefile            -> 包名 rtp2httpd
#      openwrt-support/luci-app-rtp2httpd/Makefile   -> 包名 luci-app-rtp2httpd
# ---------------------------------------------------------------------------
FEEDS=friendlywrt/feeds.conf.default
if grep -q '^[^#]*rtp2httpd' "${FEEDS}"; then
    echo "==== [r5s-iptv] rtp2httpd feed 已存在，跳过 ===="
else
    {
        echo ''
        echo '# NanoPi R5S IPTV: 组播转单播（stackia/rtp2httpd，C/CMake，含现代 js 版 LuCI 应用）'
        echo 'src-git rtp2httpd https://github.com/stackia/rtp2httpd.git'
    } >> "${FEEDS}"
    echo "==== [r5s-iptv] 已追加 rtp2httpd feed ===="
fi
echo "----- ${FEEDS} -----"
cat "${FEEDS}"

# ---------------------------------------------------------------------------
# 2. 写入自定义配置片段 configs/rockchip/06-r5s-iptv
#    注意：make defconfig 会静默丢弃它不认识的符号，所以 build.yml 里有一个
#    "Verify customizations survived defconfig" step 做硬校验，失败即中止。
# ---------------------------------------------------------------------------
cat > configs/rockchip/06-r5s-iptv <<'CONFIG_EOF'
# ===========================================================================
# NanoPi R5S —— IPTV 旁路由定制（由 Actions-FriendlyWrt fork 注入）
# 目标拓扑：
#   eth0 (千兆)   = IPTV PPPoE 专网，不注入默认路由
#   eth1 (2.5G#1) = 静态 192.168.210.3，rtp2httpd 单播出流 + 设备管理
#   eth2 (2.5G#2) = DHCP 客户端接主内网，AdGuard Home(DNS) + chrony(NTP)
# ===========================================================================

# ---- IPTV 专网 PPPoE（01-nanopi 里只有 ppp-mod-pppoa/pptp 等，缺 pppoe）----
CONFIG_PACKAGE_ppp=y
CONFIG_PACKAGE_ppp-mod-pppoe=y
CONFIG_PACKAGE_kmod-ppp=y
CONFIG_PACKAGE_kmod-pppox=y
CONFIG_PACKAGE_kmod-pppoe=y
CONFIG_PACKAGE_luci-proto-ppp=y

# ---- rtp2httpd：组播转单播 ----
CONFIG_PACKAGE_rtp2httpd=y
CONFIG_PACKAGE_luci-app-rtp2httpd=y
CONFIG_PACKAGE_luci-i18n-rtp2httpd-zh-cn=y

# ---- AdGuard Home ----
# 🔴 不编 adguardhome 本体（CONFIG_PACKAGE_adguardhome 故意不写）：
#    它要现编 Go 工具链 + AGH 源码，2 核 runner 下约 1 小时，是把构建顶过
#    GitHub 6 小时上限的元凶之一。改用官方预编译 arm64 二进制（自带前端），
#    由 build.yml 的 "Fetch AdGuardHome static binary" step 注入 /usr/bin/AdGuardHome，
#    运行时文件（init/config/capabilities/sysctl/uci-defaults）由 overlay 注入，
#    版本对齐 0.107.80，保证下面这个 LuCI 应用兼容。
# luci-app-adguardhome 是纯 LuCI（js + 翻译），不含 Go，编译很快，正常从 feed 编。
CONFIG_PACKAGE_luci-app-adguardhome=y

# ---- chrony NTP（官方 packages net/chrony）----
CONFIG_PACKAGE_chrony=y
CONFIG_PACKAGE_luci-app-chrony=y
CONFIG_PACKAGE_luci-i18n-chrony-zh-cn=y

# ---- Argon 主题 ----
# FriendlyWrt 自带 package/friendlyelec/luci-theme-argon，
# configs/rockchip/03-custom 里已经 =y；这里再显式声明一次以防上游改动。
CONFIG_PACKAGE_luci-theme-argon=y

# ---- 简体中文界面 ----
# configs/rockchip/02-luci_lang 已经全局设了 CONFIG_LUCI_LANG_zh_Hans=y，
# 下面几行是双保险：即使上游哪天改了 02-luci_lang，中文界面也不会丢。
# 包名规律是 luci-i18n-<去掉 luci-app- 前缀的名字>-zh-cn；
# 已核实 openwrt/luci 的 openwrt-25.12 分支里存在对应的 po/zh_Hans 目录：
#   luci-base、luci-app-firewall、luci-app-package-manager、luci-app-chrony ✅
#   luci-app-adguardhome 只有 po/lo（老挝语），没有中文包，所以不列它。
# 写错的符号会被 make defconfig 静默丢弃，不影响构建。
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
CONFIG_PACKAGE_luci-i18n-package-manager-zh-cn=y
# chrony / rtp2httpd 的中文包已经写在各自的分节里，此处不重复

# ---- Caddy ----
# Caddy 已从 openwrt/packages 移除，kenzok8/small、kenzok8/openwrt-packages、
# fichenx/openwrt-package、Lienol/openwrt-package、immortalwrt/packages、
# muink/fantastic-packages 全部没有适配 25.x 的版本。
# 因此改由 build.yml 的 "Fetch Caddy static binary" step 下载官方
# linux/arm64 静态二进制注入 rootfs 的 /usr/bin/caddy，
# 所以本文件里没有任何 caddy 相关的 CONFIG_ 符号。

# ---- 256G M.2 NVMe ----
CONFIG_PACKAGE_kmod-nvme=y
CONFIG_PACKAGE_kmod-fs-f2fs=y
CONFIG_PACKAGE_f2fsck=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_lsblk=y

# ---- IPTV / 组播排障工具 ----
CONFIG_PACKAGE_tcpdump-mini=y
CONFIG_PACKAGE_ethtool=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ip-bridge=y
CONFIG_PACKAGE_ss=y
CONFIG_PACKAGE_socat=y

# ---- 组播转发所需的 netfilter 模块（ALL_KMODS 已覆盖，显式声明便于校验）----
CONFIG_PACKAGE_kmod-nf-socket=y
CONFIG_PACKAGE_kmod-nft-socket=y
CONFIG_PACKAGE_kmod-br-netfilter=y

# ---- rootfs 分区大小 ----
# base.mk 用 TARGET_ROOTFS_PARTSIZE=1280 生成 ext4 镜像，这里把 OpenWrt 侧的
# 同名选项也对齐到 1280，避免 01-nanopi 里的 1024 造成不一致。
CONFIG_TARGET_ROOTFS_PARTSIZE=1280
CONFIG_TARGET_ROOTFS_TARGZ=y
CONFIG_EOF

echo "==== [r5s-iptv] 已写入 configs/rockchip/06-r5s-iptv ===="
echo "----- configs/rockchip/ 目录（ls 顺序即 cat 顺序）-----"
ls -1 configs/rockchip/
echo "----- 06-r5s-iptv 内容 -----"
cat configs/rockchip/06-r5s-iptv

echo "==== [r5s-iptv] 自定义编译配置应用完毕 ===="
