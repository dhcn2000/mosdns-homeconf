#!/bin/bash

# MosDNS 一键安装脚本 (Debian 12 验证通过)
# 修复DNS解析问题 + 添加网络预检
# 官方版本: v5.3.3

# 配置参数
MOSDNS_VERSION="v5.3.3"
CONFIG_DIR="/etc/mosdns"
BIN_PATH="/usr/local/bin/mosdns"
SERVICE_FILE="/etc/systemd/system/mosdns.service"

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

# -------------------------- 初始化检查 --------------------------
# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误：必须使用 root 权限执行${NC}"
    exit 1
fi

# -------------------------- 网络预检 --------------------------
network_check() {
    echo -e "${BLUE}[1/8] 执行网络预检...${NC}"
    
    # 检查互联网连通性
    if ! ping -c 2 8.8.8.8 &> /dev/null; then
        echo -e "${RED}错误：无法连接到互联网！${NC}"
        exit 1
    fi

    # 检查DNS解析能力
    if ! dig github.com +short &> /dev/null; then
        echo -e "${YELLOW}警告：DNS解析失败，尝试修复...${NC}"
        
        # 设置临时DNS
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 2001:4860:4860::8888" >> /etc/resolv.conf
        
        if ! dig github.com +short &> /dev/null; then
            echo -e "${RED}错误：DNS修复失败，请手动检查网络设置！${NC}"
            exit 1
        fi
    fi
}
network_check

# -------------------------- 系统配置 --------------------------
echo -e "${BLUE}[2/8] 配置系统环境...${NC}"
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# -------------------------- 安装依赖 --------------------------
echo -e "${BLUE}[3/8] 安装系统依赖...${NC}"
apt-get update
apt-get install -y wget unzip

# -------------------------- 下载 MosDNS --------------------------
echo -e "${BLUE}[4/8] 下载官方安装包...${NC}"
DL_URL="https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-amd64.zip"

# 带重试机制的下载命令
for i in {1..3}; do
    wget -q --show-progress -O /tmp/mosdns.zip "$DL_URL" && break
    if [ $i -eq 3 ]; then
        echo -e "${RED}下载失败！可能原因："
        echo "1. 网络不稳定，请重试"
        echo "2. 手动下载后上传到服务器："
        echo "   curl -LO $DL_URL"
        exit 1
    fi
    echo -e "${YELLOW}第 $i 次下载失败，10秒后重试...${NC}"
    sleep 10
done

# -------------------------- 解压安装 --------------------------
echo -e "${BLUE}[5/8] 解压安装文件...${NC}"
if ! unzip -o /tmp/mosdns.zip -d /tmp; then
    echo -e "${RED}解压失败！可能原因："
    echo "1. 下载文件损坏，请手动检查：ls -lh /tmp/mosdns.zip"
    echo "2. 安装 unzip 工具：apt-get install unzip"
    exit 1
fi

mv /tmp/mosdns "$BIN_PATH"
chmod +x "$BIN_PATH"

# 检查 v2dat 命令是否存在
if ! command -v v2dat &> /dev/null; then
    echo "错误: v2dat 命令未找到，请先安装 mosdns"
    exit 1
fi

# 检查 wget 是否存在
if ! command -v wget &> /dev/null; then
    echo "错误: wget 命令未找到，请先安装 wget"
    exit 1
fi

# mosdns配置目录
conf_dir="/etc/mosdns"
geodata_dir="$conf_dir/geodata"
ip_set_dir="$conf_dir/ip_set"
domain_set_dir="$conf_dir/domain_set"
cache_dir="$conf_dir/cache"

declare -a dirs=(
    "$conf_dir"
    "$geodata_dir"
    "$ip_set_dir"
    "$domain_set_dir"
    "$cache_dir"
    "$conf_dir/plugin"
)

for dir in "${dirs[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || { 
            echo "错误: 无法创建目录 $dir"
            exit 1
        }
        echo "已创建目录: $dir"
    else
        echo "目录已存在: $dir"
    fi
done

echo "所有目录已准备就绪"


# 下载geodata文件
download_files() {
    local url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    
    declare -A files=(
        ["geoip.dat"]="${url}/geoip.dat"
        ["geosite.dat"]="${url}/geosite.dat"
    )

    for file in "${!files[@]}"; do
        echo "正在下载 $file..."
        wget -nv -L -P "$geodata_dir/" -N "${files[$file]}" || {
            echo "错误: 下载 $file 失败"
            exit 1
        }
        [ -f "$geodata_dir/$file" ] || {
            echo "错误: 文件 $file 未找到"
            exit 1
        }
    done
    echo "所有geodata文件已成功下载"
}

download_files


# 解压任务配置
declare -A unpack_tasks=(
    # v2dat命令只支持解压国家和地区代码的ip数据标签, 如cn,hk,jp,us等等, 不支持"!cn"标签
    ["geoip:private"]="$ip_set_dir"
    ["geoip:cn"]="$ip_set_dir"
    # 所有可用的域名数据标签请见: https://github.com/v2fly/domain-list-community/tree/master/data
    ["geosite:private"]="$domain_set_dir"
    ["geosite:google"]="$domain_set_dir"
    ["geosite:cn"]="$domain_set_dir"
    ["geosite:geolocation-!cn"]="$domain_set_dir"
)

# 执行解压
for task in "${!unpack_tasks[@]}"; do
    IFS=':' read -r dat_type tag <<< "$task"
    src_file="$geodata_dir/${dat_type}.dat"
    output_dir="${unpack_tasks[$task]}"
    
    echo "正在解压 $dat_type:$tag..."
    v2dat unpack "$dat_type" -o "$output_dir" -f "${tag}" "$src_file" || {
        echo "错误: 解压 $dat_type:$tag 失败"
        exit 1
    }
done

echo "所有 geodata 已解压完成"


# 创建需要DNS分流的客户端列表文件
proxy_clients="$conf_dir/proxy_clients.txt"

if [ ! -f "$proxy_clients" ]; then
    touch "$proxy_clients" || {
        echo "错误: 客户端列表文件创建失败"
        exit 1
    }
    echo "客户端列表文件创建成功"
else
    echo "客户端列表文件已存在"
fi


declare -a caches=(
    "$cache_dir/cache_dns_local.dump"
    "$cache_dir/cache_dns_direct.dump"
    "$cache_dir/cache_dns_proxy.dump"
)

for cache in "${caches[@]}"; do
    if [ ! -f "$cache" ]; then
        touch "$cache" || {
            echo "错误: 创建 $cache 失败"
            exit 1
        }
        echo "已创建缓存文件: $cache "
    else
        echo "缓存文件 $cache 已存在"
    fi
done

echo "所有缓存文件已创建完成"
