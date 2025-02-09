#!/bin/bash

set -euo pipefail

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行此脚本 (e.g., sudo $0)"
    exit 1
fi

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
    local url="https://github.404cafe.fun/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    
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
    # 所有可用的域名数据标签请见: https://github.404cafe.fun/https://github.com/v2fly/domain-list-community/tree/master/data
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
